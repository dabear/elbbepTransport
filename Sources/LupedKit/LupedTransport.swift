import Combine
import ElbbepTransport
import Foundation

/// AppMessage dictionary keys from the Luped watchface's `messageKeys`.
enum LupedMessageKey {
    static let command: UInt32 = 10_000
    static let data: UInt32 = 10_001
    static let configured: UInt32 = 10_003
    static let diagnostics: UInt32 = 10_004
    static let result: UInt32 = 10_005
}

/// Luped's delivery policy for readings.
enum LupedDelivery {
    /// Backoff for re-sending a rejected or unacknowledged reading. The phone
    /// cannot observe the watchface starting, and Luped asks for data only once.
    static let initialRetryDelay: TimeInterval = 30
    /// When the watch sends its own message while a reading is unanswered, the two
    /// may have crossed and the watch dropped the reading: if there is still no
    /// reply this long after, send it again instead of waiting for the timeout
    /// and the retry delay. The watch just showed it's there.
    static let crossedMessageResendDelay: TimeInterval = 1
    static let maximumRetryDelay: TimeInterval = 300

    enum Unchanged: Equatable { case delivered, inFlight }

    /// After a new reading, the longest wait for the loop result (IOB, last loop)
    /// so both go in one message. The reading goes out as soon as a snapshot's
    /// last loop is later than the reading (the loop ran on it), usually within a
    /// second; this timeout only applies when the loop doesn't run.
    static let newReadingHold: TimeInterval = 10
    /// How long to collect changes that touch only the loop status or status line
    /// (`DATA` 10–14) before sending them in one message.
    static let followUpWindow: TimeInterval = 3

    enum Timing: Equatable {
        /// Alerts, display and settings changes, or nothing to wait for.
        case now
        /// A new reading while loop status is sent, before the loop has run on it:
        /// wait for the loop result, at most `newReadingHold`.
        case holdForLoopResult
        /// Only loop status or status line changed: collect for `followUpWindow`.
        case collectFollowUps
    }

    /// When to send `new`, compared with what the watch has or is about to get
    /// (`previous`). Alert changes are never delayed.
    static func timing(new: LupedPayload, previous: LupedPayload?, needsLoopStatus: Bool) -> Timing {
        guard let previous else { return .now }
        if new.hostAlertState != previous.hostAlertState || new.alertEvent != previous.alertEvent {
            return .now
        }
        if new.latestDate != previous.latestDate {
            guard needsLoopStatus else { return .now }
            // The loop has run on this reading: its result is in, send both now.
            if let lastLoop = new.lastLoopCompleted, lastLoop >= new.latestDate { return .now }
            return .holdForLoopResult
        }
        if new.coreData != previous.coreData {
            return .now
        }
        return .collectFollowUps
    }

    /// The RESULT to send again when the watchface restarted while it was in
    /// flight; `nil` for other commands (diagnostics), which are just dropped.
    static func resultToResend(afterRestart inflightCommand: String) -> String? {
        inflightCommand.hasPrefix("RESULT ") ? String(inflightCommand.dropFirst("RESULT ".count)) : nil
    }

    /// Whether a host refresh produced `DATA` the watch already has (acknowledged
    /// in this session) or is about to get (in flight), so it needn't be sent.
    /// Watch refresh requests, new sessions and Send Now always send.
    static func unchangedData(_ data: String, delivered: String?, inFlight: String?) -> Unchanged? {
        if data == inFlight { return .inFlight }
        if data == delivered { return .delivered }
        return nil
    }
}

/// Sends a host app's glucose readings, alerts and loop status to the Luped
/// watchface over a `PebbleTransport`.
///
/// The host supplies a `snapshotProvider` and calls `refresh()` when any of them
/// change. Luped's own settings are applied whenever `settings` changes.
///
/// The latest payload is kept so a watchface `refresh` or a new session can
/// re-send it. A rejected or unacknowledged send is retried with backoff, and
/// immediately on a glucose update, a watchface refresh, or a new session.
@MainActor
public final class LupedTransport: PebbleTransportDelegate {
    /// The host app's name, such as "Loop" or "Trio": in log lines, and sent as
    /// `DATA` index 15 so a watch can tell two apps on the same phone apart.
    public let hostName: String
    private let transport: PebbleTransport

    /// Luped's own settings. The host persists them; assigning applies them.
    public var settings: LupedSettings {
        didSet {
            if settings != oldValue {
                settingsDidChange(from: oldValue)
            }
        }
    }

    /// The watch communication log shown in Settings → Devices → Pebble.
    public let communicationLog = LupedCommunicationLog()
    /// Live link state and watch diagnostics for Settings → Devices → Pebble.
    public let status = LupedLinkStatus()
    /// Mirrors every communication-log line to the host's diagnostic log.
    public var diagnosticLog: ((LupedCommunicationLog.Kind, String) -> Void)?
    /// Called with each watch diagnostics report (raw JSON, arrival time) so the
    /// host can keep the latest across launches and hand it to `restoreDiagnostics`.
    /// The watchface reports about once an hour on its own.
    public var diagnosticsDidArrive: ((String, Date) -> Void)?
    /// Supplies the current readings and alert state. Returns `nil` while the
    /// host is not ready; throwing logs the error.
    public var snapshotProvider: (() async throws -> LupedSnapshot?)?
    /// Called when the watch asks to mute the host's alerts (`COMMAND`
    /// `mute:<minutes>`), with the requested duration and when the user confirmed
    /// it (see `LupedCommandTiming`; `nil` when the command didn't say). The host
    /// decides whether its user allowed muting from the watch.
    public var alertMuteRequested: ((_ duration: TimeInterval, _ requestedAt: Date?) -> Void)?
    /// Called when the watch asks to add carbs (`COMMAND carbs:<grams>`), with
    /// the grams the watch chose and when the user confirmed them (see
    /// `LupedCommandTiming`; `nil` when the command didn't say). The host runs
    /// its own checks.
    public var carbsRequested: ((_ grams: Double, _ requestedAt: Date?) -> Void)?
    /// Called when the watch asks to start a preset (`COMMAND override:<preset
    /// name or id>`) or end the running one (`override:cancel`), with when the
    /// user confirmed it (see `LupedCommandTiming`; `nil` when the command didn't
    /// say). Without it, the request is logged and answered `override:ignored`.
    public var overrideRequested: ((_ action: LupedOverrideAction, _ requestedAt: Date?) -> Void)?
    /// Called once for each signed bolus request from the watch that passed
    /// `LupedBolusAuth` (`COMMAND signedbolus:<units>[:<grams>]…`, or
    /// `signedforcedbolus:` to skip only the host's recommendation check), with
    /// the units, the carbs to add first (`nil` for none) and when the user
    /// confirmed them. There is no unsigned bolus request. The host runs its own checks. Answer with `sendResult`
    /// (`carbs:<outcome>` first when there were carbs, then
    /// `signedbolus:<outcome>` or `signedforcedbolus:<outcome>`), so a resent
    /// request gets the same answer.
    public var bolusRequested: ((_ units: Double, _ forced: Bool, _ grams: Double?, _ requestedAt: Date) -> Void)?
    /// Whether to hand the watch a bolus session key. Off unless the host may
    /// take boluses from this watch; turning it off forgets the key.
    public var issuesBolusKey = false {
        didSet {
            guard issuesBolusKey != oldValue else { return }
            if issuesBolusKey {
                startBolusSession()
            } else {
                endBolusSession()
            }
        }
    }

    private var latestPayload: LupedPayload?
    /// Incremented on every send request; a send completing with an older
    /// value means another request arrived while it was in flight.
    private var requestGeneration = 0
    private var deliveredGeneration = 0
    private var inflightPush: (transactionID: UInt8, generation: Int, payload: LupedPayload, sentAt: Date)?
    /// The `DATA` the watch acknowledged in this session. A host refresh that
    /// produces the same `DATA` is not sent again; cleared when the session resets.
    private var deliveredPayload: LupedPayload?
    /// A send waiting for the loop result or collecting loop-only changes; it
    /// sends `latestPayload` when it fires.
    private var delayedSend: Task<Void, Never>?
    private var delayedSendTiming: LupedDelivery.Timing?
    private var delayedSendStarted = Date.distantPast
    /// Until then, sends aren't delayed: the user just changed a setting, and the
    /// host's snapshot with what it now requests should show at once.
    private var sendImmediatelyUntil = Date.distantPast
    /// Alert fires the watch acknowledged at a level above 0, newest last,
    /// checked against the buzz records in the watch's diagnostics.
    private var deliveredAlerts: [LupedDeliveredAlert] = []
    /// A COMMAND push awaiting the watch's ACK; pushes are sent one at a time.
    private var inflightCommand: (transactionID: UInt8, command: String)?
    private var diagnosticsRequested = false
    /// Outcomes of the watch's requests waiting to go back to it (`RESULT`), oldest first.
    private var pendingResults: [String] = []
    var bolusAuth = LupedBolusAuth()
    /// The `COMMAND auth:…` handing the watch its bolus session key, until sent.
    var pendingBolusKey: String?
    private var diagnosticsReplyTimeout: Task<Void, Never>?
    private var pushAckTimeout: Task<Void, Never>?
    private var retryDelay: TimeInterval = 0
    /// Set after the full retry backoff got no ACK: pushes stop until the
    /// watchface makes contact, a new session opens, or the user sends.
    private var paused = false {
        didSet { status.paused = paused }
    }
    private var pushRetry: Task<Void, Never>?
    private var crossedMessageResend: Task<Void, Never>?

    public init(hostName: String, settings: LupedSettings) {
        self.hostName = hostName
        self.settings = settings
        transport = PebbleTransport(isEnabled: settings.isEnabled, appUUID: settings.watchfaceUUID)
        transport.delegate = self
    }

    /// Writes to the communication log and the host's diagnostic log.
    func record(_ kind: LupedCommunicationLog.Kind, _ message: String) {
        diagnosticLog?(kind, message)
        communicationLog.append(kind, message)
    }

    /// Starts the GATT service if Pebble support is on.
    public func start() {
        transport.start()
    }

    /// Builds the payload from the host's current snapshot and sends it if it
    /// is new.
    public func refresh() async {
        guard let snapshotProvider else {
            return
        }
        guard transport.isEnabled, settings.isEnabled else {
            return
        }

        let snapshot: LupedSnapshot
        do {
            guard let current = try await snapshotProvider() else {
                return
            }
            snapshot = current
        } catch {
            record(.error, String(format: "Unable to read glucose: %@", String(describing: error)))
            return
        }

        guard let payload = LupedPayload(readings: snapshot.readings, unit: snapshot.unit, fullScreen: settings.fullScreen, hostAlertState: snapshot.hostAlertState, hostAlertReason: snapshot.hostAlertReason, alertEvent: snapshot.alertEvent, loopStatus: settings.loopStatusToSend(snapshot.loopStatus), statusLine: LupedPayload.statusLine(settings.shownStatusLine, therapy: snapshot.therapy, unit: snapshot.unit), hostName: hostName, settings: settings) else {
            record(.info, String(format: "No usable CGM readings among %ld stored samples; nothing to send", snapshot.storedSampleCount))
            return
        }

        latestPayload = payload
        switch LupedDelivery.unchangedData(payload.data, delivered: deliveredPayload?.data, inFlight: inflightPush?.payload.data) {
        case .delivered:
            requestGeneration = deliveredGeneration
            record(.info, "Unchanged DATA; the watch already has it, not sent again")
        case .inFlight:
            requestGeneration = max(deliveredGeneration, inflightPush?.generation ?? 0)
            record(.info, "Unchanged DATA; the same message is already on its way")
        case nil:
            scheduleSend(payload)
        }
    }

    /// Sends now, or after a short wait so a reading and the loop result that
    /// follows it, or several loop-only changes, go in one message.
    private func scheduleSend(_ payload: LupedPayload) {
        let timing = Date() < sendImmediatelyUntil ? .now : LupedDelivery.timing(new: payload, previous: inflightPush?.payload ?? deliveredPayload, needsLoopStatus: settings.needsLoopStatus)
        switch timing {
        case .now:
            if delayedSendTiming == .holdForLoopResult, let lastLoop = payload.lastLoopCompleted, lastLoop >= payload.latestDate {
                record(.info, String(format: "Loop result in after %.1f s: sending it with the reading", Date().timeIntervalSince(delayedSendStarted)))
            }
            cancelDelayedSend()
            requestSend()
        case .holdForLoopResult:
            // A running hold already ends soon; a follow-up window gives way to it.
            guard delayedSendTiming != .holdForLoopResult else { return }
            startDelayedSend(after: LupedDelivery.newReadingHold, timing: timing)
            record(.info, String(format: "New reading: waiting for %@'s loop result (at most %.0f s) to send both together", hostName, LupedDelivery.newReadingHold))
        case .collectFollowUps:
            guard delayedSend == nil else { return }
            startDelayedSend(after: LupedDelivery.followUpWindow, timing: timing)
            record(.info, String(format: "Loop values changed: collecting further changes for %.0f s", LupedDelivery.followUpWindow))
        }
    }

    private func startDelayedSend(after delay: TimeInterval, timing: LupedDelivery.Timing) {
        delayedSend?.cancel()
        delayedSendTiming = timing
        delayedSendStarted = Date()
        delayedSend = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if timing == .holdForLoopResult {
                self.record(.info, String(format: "No loop result within %.0f s: sending the reading without it", delay))
            }
            self.delayedSend = nil
            self.delayedSendTiming = nil
            // A forced send (new session, watch request, Send Now) may have sent it already.
            guard let latest = self.latestPayload,
                  LupedDelivery.unchangedData(latest.data, delivered: self.deliveredPayload?.data, inFlight: self.inflightPush?.payload.data) == nil
            else { return }
            self.requestSend()
        }
    }

    private func cancelDelayedSend() {
        delayedSend?.cancel()
        delayedSend = nil
        delayedSendTiming = nil
    }

    // MARK: - Settings

    private func settingsDidChange(from old: LupedSettings) {
        sendImmediatelyUntil = Date().addingTimeInterval(5)
        if settings.alarmsEnabled != old.alarmsEnabled {
            record(.info, "Watch Alarms \(settings.alarmsEnabled ? "on" : "off: the watch won't buzz")")
        }
        if settings.statusLine != old.statusLine {
            record(.info, "Watch status line: \(settings.statusLine.displayName)")
        }
        if settings.showsLoopRing != old.showsLoopRing {
            record(.info, "Watch Last Loop \(settings.showsLoopRing ? "on" : "off: the watch won't show when \(hostName) last looped")")
        }
        if settings.fullScreen != old.fullScreen {
            record(.info, "Watch layout: \(settings.fullScreen ? "Large Glucose (no graph, status line or Last Loop)" : "Graph")")
        }
        if settings.isEnabled != transport.isEnabled || settings.watchfaceUUID != transport.appUUID {
            applyLink()
        } else {
            Task { await refresh() }
        }
    }

    /// Turns the watch link on or off, or moves it to another watchface.
    private func applyLink() {
        let enabled = settings.isEnabled
        let uuid = settings.watchfaceUUID
        record(.info, enabled ? "Watch link settings changed: watchface \(uuid.uuidString.lowercased())" : "Watch link off")
        transport.reconfigure(isEnabled: enabled, appUUID: uuid)

        guard enabled else {
            // Fully off: no Bluetooth manager, no retries, no payload building.
            endBolusSession()
            pushRetry?.cancel()
            pushRetry = nil
            latestPayload = nil
            record(.info, "Pebble support off: Bluetooth service removed")
            return
        }
        // Build the current reading now rather than waiting for the next one.
        Task { await refresh() }
    }

    // MARK: - PebbleTransportDelegate

    public func pebbleTransport(_ transport: PebbleTransport, log kind: PebbleLogKind, _ message: String) {
        switch kind {
        case .toWatch: record(.toWatch, message)
        case .fromWatch: record(.fromWatch, message)
        case .info: record(.info, message)
        case .error: record(.error, message)
        }
    }

    public func pebbleTransportDidChangeLink(_ transport: PebbleTransport) {
        if status.link != transport.link {
            status.link = transport.link
        }
    }

    public func pebbleTransportSessionDidOpen(_ transport: PebbleTransport) {
        if issuesBolusKey {
            startBolusSession()
        }
        sendIfNeeded(force: true)
    }

    public func pebbleTransportSessionWillReset(_ transport: PebbleTransport) {
        if inflightPush != nil {
            record(.info, "Session reset before the watch acknowledged the pushed reading")
        }
        inflightPush = nil
        deliveredPayload = nil
        cancelDelayedSend()
        pushAckTimeout?.cancel()
        pushAckTimeout = nil
        // A new session re-sends the reading itself.
        pushRetry?.cancel()
        pushRetry = nil
        crossedMessageResend?.cancel()
        crossedMessageResend = nil
        retryDelay = 0
        paused = false
        status.retryAt = nil
        inflightCommand = nil
        endBolusSession()
    }

    public func pebbleTransport(_ transport: PebbleTransport, didReceive tuples: [UInt32: AppMessageTuple], message: [UInt8]) {
        resendIfCrossed()
        if tuples[PebbleAppMessage.alloyReadyKey] != nil {
            dropMessagesToPreviousWatchface()
            // A new watchface run has no key: give it a new one, so nothing the
            // previous run signed is accepted any more.
            if issuesBolusKey {
                startBolusSession()
            }
        }
        let hex = PebbleTransport.hex(message.dropFirst(18))
        if let diagnostics = tuples[LupedMessageKey.diagnostics]?.string {
            record(.fromWatch, "Watch diagnostics\n" + LupedWatchDiagnostics.logDecode(json: diagnostics))
            let receivedAt = Date()
            if let check = LupedWatchDiagnostics.buzzCheck(json: diagnostics, delivered: deliveredAlerts, receivedAt: receivedAt) {
                record(check.missing.isEmpty ? .info : .error, check.message)
            }
            status.diagnostics = LupedWatchDiagnostics(json: diagnostics, receivedAt: receivedAt)
            diagnosticsDidArrive?(diagnostics, receivedAt)
            status.watchInfoNote = nil
            diagnosticsReplyTimeout?.cancel()
        }
        // Alloy sends a ready handshake (key 15025) when the watchface starts and
        // keeps its own outbox closed until the phone sends any message back;
        // only then does Luped send its `refresh` command. Answer both with the
        // latest reading.
        let command = tuples[LupedMessageKey.command]?.string
        let base = command.map(LupedCommandTiming.stripped)
        if let command, let base, base.hasPrefix("mute:"), let minutes = Int(base.dropFirst(5)), minutes > 0 {
            let requestedAt = LupedCommandTiming(command: command)?.confirmedAt
            record(.fromWatch, "Watch asked to mute \(hostName) alerts for \(minutes) min\(requestedAt == nil ? ", without the watch's timing" : "") (COMMAND \(command))")
            alertMuteRequested?(TimeInterval(minutes * 60), requestedAt)
        } else if let command, LupedSignedBolus.isSigned(command) {
            handleSignedBolus(command)
        } else if let command, let base, let request = LupedWatchRequest(command: base) {
            let requestedAt = LupedCommandTiming(command: command)?.confirmedAt
            let confirmed = requestedAt.map { String(format: ", confirmed %.0f s ago", Date().timeIntervalSince($0)) } ?? ", without the watch's timing"
            switch request {
            case .carbs(let grams?):
                record(.fromWatch, String(format: "Watch asked to add %g g of carbs%@ (COMMAND %@)", grams, confirmed, command))
                carbsRequested?(grams, requestedAt)
            case .carbs(nil):
                record(.error, "Watch request without a valid amount ignored (COMMAND \(command))")
                sendResult("\(request.action):failed")
            case .override(let action?):
                let asked = switch action {
                case .start(let preset): "start the preset \"\(preset)\""
                case .cancel: "end the running preset"
                }
                guard let overrideRequested else {
                    record(.error, "Watch asked to \(asked)\(confirmed): ignored, this plugin doesn't take preset requests (COMMAND \(command))")
                    sendResult("\(request.action):ignored")
                    break
                }
                record(.fromWatch, "Watch asked to \(asked)\(confirmed) (COMMAND \(command))")
                overrideRequested(action, requestedAt)
            case .override(nil):
                record(.error, "Watch preset request without a preset ignored (COMMAND \(command))")
                sendResult("\(request.action):failed")
            }
        } else if tuples[PebbleAppMessage.alloyReadyKey] != nil || command == "refresh" {
            record(.fromWatch, "Watchface requested refresh (\(command.map { "COMMAND \($0)" } ?? "ready handshake"))\n" + LupedPayload.alignedRows([("tuples", hex)]))
            sendIfNeeded(force: true)
        } else if let command {
            // An action this plugin doesn't take (`bolus:` is gone, presets were
            // never offered) or a malformed one: nothing is passed to the host.
            record(.error, "Watch command ignored: this plugin doesn't handle it (COMMAND \(command))\n" + LupedPayload.alignedRows([("tuples", hex)]))
        } else if tuples[LupedMessageKey.diagnostics] == nil {
            record(.fromWatch, "Watch message\n" + LupedPayload.alignedRows([("tuples", hex)]))
        }
    }

    public func pebbleTransport(_ transport: PebbleTransport, didReceiveReply acknowledged: Bool, transactionID: UInt8, message: [UInt8]) {
        let reply = acknowledged ? "ACK" : "NACK"
        if let pending = inflightCommand, pending.transactionID == transactionID {
            inflightCommand = nil
            record(.fromWatch, "#\(transactionID) \(reply) · \(pending.command)\n" + LupedPayload.alignedRows([("bytes", PebbleTransport.hex(message))]))
            if pending.command == "COMMAND diagnostics" {
                if !acknowledged {
                    status.watchInfoNote = NSLocalizedString("The watch rejected the request; the watchface is probably not running.", bundle: .lupedKit, comment: "Pebble watch info note: request rejected")
                } else {
                    awaitDiagnosticsReply()
                }
            } else if acknowledged, let id = Self.bolusSessionID(inLabel: pending.command) {
                bolusAuth.keyDelivered(session: id)
                record(.info, "Watch has the key for bolus session \(id): it can sign bolus requests")
            } else if !acknowledged {
                noteUndelivered(pending.command, "the watch rejected it")
            }
            sendIfNeeded()
            return
        }
        guard let push = inflightPush, push.transactionID == transactionID else {
            record(.fromWatch, "#\(transactionID) \(reply) matches no message in flight; ignored\n" + LupedPayload.alignedRows([("bytes", PebbleTransport.hex(message))]))
            return
        }
        inflightPush = nil
        pushAckTimeout?.cancel()
        pushAckTimeout = nil
        let elapsed = Int(Date().timeIntervalSince(push.sentAt) * 1_000)
        let readingTime = DateFormatter.localizedString(from: push.payload.latestDate, dateStyle: .none, timeStyle: .medium)
        if acknowledged {
            record(.fromWatch, "#\(transactionID) ACK in \(elapsed) ms · watch stored the \(readingTime) reading, \(push.payload.readingCount == 0 ? "no history (Large Glucose)" : "\(push.payload.readingCount) history points")\n" + LupedPayload.alignedRows([("bytes", PebbleTransport.hex(message))]))
            deliveredGeneration = push.generation
            deliveredPayload = push.payload
            if push.payload.hostAlertState > 0, push.payload.alertEvent != deliveredAlerts.last?.event {
                deliveredAlerts.append(.init(event: push.payload.alertEvent, level: push.payload.hostAlertState, deliveredAt: Date()))
                deliveredAlerts = Array(deliveredAlerts.suffix(10))
            }
            pushRetry?.cancel()
            pushRetry = nil
            retryDelay = 0
            paused = false
            status.lastDelivery = .init(readingDate: push.payload.latestDate, deliveredAt: Date(), milliseconds: elapsed)
            status.lastRejectedAt = nil
            status.retryAt = nil
            sendIfNeeded()
        } else {
            // The watch rejects pushes while Luped is not the running watchface.
            record(.fromWatch, "#\(transactionID) NACK in \(elapsed) ms · watch rejected the \(readingTime) reading; the watchface is probably not running\n" + LupedPayload.alignedRows([("bytes", PebbleTransport.hex(message))]))
            status.lastRejectedAt = Date()
            scheduleRetry()
        }
    }

    // MARK: - Commands

    /// Alloy turns a watchface's writes off whenever a non-system session (like
    /// this one) opens or closes. Luped (0.1.9+) then reopens its message channel
    /// and sends what is pending, at most once every 30 s, so a reply can take up
    /// to that long after a session change.
    private func awaitDiagnosticsReply() {
        diagnosticsReplyTimeout?.cancel()
        diagnosticsReplyTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.record(.error, "No diagnostics reply within 35 s")
            self.status.watchInfoNote = NSLocalizedString("The watch did not reply. Check that Luped CGM is the active watchface, then try again.", bundle: .lupedKit, comment: "Pebble watch info note: no reply")
        }
    }

    /// Pushes the current reading now, re-sending it even if already delivered.
    public func sendNow() {
        record(.info, "Send Now requested")
        status.lastResult = nil
        guard transport.isSessionOpen else {
            status.lastResult = NSLocalizedString("The watch isn't connected; the reading is sent as soon as it connects.", bundle: .lupedKit, comment: "Pebble Send Now result: no watch session")
            Task { await refresh() }
            return
        }
        Task {
            // A new reading is pushed by refresh itself; force a re-send only
            // when the latest reading was already delivered.
            await refresh()
            if inflightPush == nil {
                sendIfNeeded(force: true)
            }
        }
    }

    /// Asks Luped for its diagnostics snapshot (battery and counters).
    public func requestDiagnostics() {
        record(.info, "Watch info requested")
        status.watchInfoNote = nil
        guard transport.isSessionOpen else {
            status.watchInfoNote = NSLocalizedString("The watch is not connected.", bundle: .lupedKit, comment: "Pebble watch info note: no session")
            return
        }
        diagnosticsRequested = true
        sendPendingCommand()
    }

    /// Shows a diagnostics report the host saved from an earlier launch until the
    /// watch sends a newer one. Pair with `diagnosticsDidArrive`.
    public func restoreDiagnostics(json: String, receivedAt: Date) {
        guard status.diagnostics == nil else { return }
        status.diagnostics = LupedWatchDiagnostics(json: json, receivedAt: receivedAt)
    }

    /// Only a freshly started watchface sends the ready handshake, so anything
    /// still awaiting an ACK went to the previous instance and will never be
    /// answered. Drop it so the handshake is answered at once instead of after
    /// the ACK timeout and a retry. A RESULT goes out again to the new watchface;
    /// a diagnostics request is dropped (the watch reports on its own).
    private func dropMessagesToPreviousWatchface() {
        if let push = inflightPush {
            record(.info, "#\(push.transactionID) dropped: the watchface restarted before acknowledging it")
            inflightPush = nil
            pushAckTimeout?.cancel()
            pushAckTimeout = nil
        }
        if let pending = inflightCommand {
            record(.info, "#\(pending.transactionID) \(pending.command) dropped: the watchface restarted before acknowledging it")
            if let result = LupedDelivery.resultToResend(afterRestart: pending.command) {
                pendingResults.insert(result, at: 0)
            }
            inflightCommand = nil
        }
    }

    /// Tells the watch how one of its requests ended (`RESULT`), kept short as
    /// `<action>:<outcome>`, e.g. `mute:ok` or `signedbolus:refused`, so the
    /// watchface can react to it. The reason goes to the communication log.
    /// Sent after any pending reading; the last few are kept until a session opens.
    public func sendResult(_ result: String) {
        bolusAuth.record(result: result)
        queueResult(result)
    }

    func queueResult(_ result: String) {
        pendingResults.append(result)
        if pendingResults.count > 5 {
            let dropped = pendingResults.prefix(pendingResults.count - 5)
            pendingResults.removeFirst(dropped.count)
            record(.error, "RESULT \(dropped.joined(separator: ", ")) dropped: more than 5 results were waiting for the watch")
        }
        sendIfNeeded()
    }

    private func sendPendingCommand() {
        guard pendingBolusKey != nil || diagnosticsRequested || !pendingResults.isEmpty, inflightPush == nil, inflightCommand == nil, transport.isSessionOpen else {
            return
        }
        let transactionID = transport.makeTransactionID()
        if let key = pendingBolusKey {
            pendingBolusKey = nil
            // The key itself never goes in a log.
            let label = Self.bolusKeyLabel(bolusAuth.session?.id ?? "")
            inflightCommand = (transactionID, label)
            record(.toWatch, "#\(transactionID) \(label)")
            transport.push(transactionID: transactionID, tuples: [(LupedMessageKey.command, .cString(key))])
        } else if diagnosticsRequested {
            diagnosticsRequested = false
            inflightCommand = (transactionID, "COMMAND diagnostics")
            record(.toWatch, "#\(transactionID) COMMAND diagnostics")
            transport.push(transactionID: transactionID, tuples: [(LupedMessageKey.command, .cString("diagnostics"))])
        } else {
            let result = pendingResults.removeFirst()
            inflightCommand = (transactionID, "RESULT \(result)")
            record(.toWatch, "#\(transactionID) RESULT \(result)")
            transport.push(transactionID: transactionID, tuples: [(LupedMessageKey.result, .cString(result))])
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PebbleAppMessage.ackTimeout * 1_000_000_000))
            guard let self, let pending = self.inflightCommand, pending.transactionID == transactionID else { return }
            self.record(.error, "#\(transactionID) no reply within \(Int(PebbleAppMessage.ackTimeout)) s")
            self.noteUndelivered(pending.command, "no reply")
            self.inflightCommand = nil
            self.sendIfNeeded()
        }
    }

    /// Says what is lost when the watch didn't take a key or a result.
    private func noteUndelivered(_ label: String, _ reason: String) {
        if let id = Self.bolusSessionID(inLabel: label) {
            bolusKeyNotDelivered(id, reason)
        } else if let result = LupedDelivery.resultToResend(afterRestart: label) {
            record(.error, "RESULT \(result) not delivered (\(reason)): the watch won't show this outcome; it's in this log")
        }
    }

    // MARK: - Delivery

    private func requestSend() {
        requestGeneration += 1
        sendIfNeeded()
    }

    /// Pushes the latest payload unless it was already delivered; `force` re-sends
    /// it for a new session or a watchface refresh request.
    func sendIfNeeded(force: Bool = false) {
        if force {
            requestGeneration = max(requestGeneration, deliveredGeneration + 1)
            paused = false
        } else if paused {
            return
        }
        guard inflightPush == nil, inflightCommand == nil else {
            record(.info, "Send deferred: previous message still in flight")
            return
        }
        guard deliveredGeneration < requestGeneration else {
            sendPendingCommand()
            return
        }
        guard let payload = latestPayload else {
            record(.info, "Send skipped: no payload yet")
            return
        }
        guard transport.isSessionOpen else {
            record(.info, "Send skipped: no watch session")
            return
        }

        let transactionID = transport.makeTransactionID()
        inflightPush = (transactionID, requestGeneration, payload, Date())

        record(.toWatch, "#\(transactionID) DATA  \(payload.logSummary)\n\(payload.logDetails)")
        transport.push(transactionID: transactionID, tuples: [
            (LupedMessageKey.configured, .uint8(1)),
            (LupedMessageKey.data, .cString(payload.data)),
        ])

        pushAckTimeout?.cancel()
        pushAckTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PebbleAppMessage.ackTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.inflightPush?.transactionID == transactionID else { return }
            self.record(.error, "#\(transactionID) no reply within \(Int(PebbleAppMessage.ackTimeout)) s")
            self.inflightPush = nil
            self.scheduleRetry()
        }
    }

    /// Called for every message from the watch: if a reading is still unanswered a
    /// moment later, it crossed this message and was dropped, so send it again now.
    private func resendIfCrossed() {
        guard let push = inflightPush, crossedMessageResend == nil else { return }
        let transactionID = push.transactionID
        crossedMessageResend = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LupedDelivery.crossedMessageResendDelay * 1_000_000_000))
            guard let self else { return }
            self.crossedMessageResend = nil
            guard !Task.isCancelled, self.inflightPush?.transactionID == transactionID else { return }
            self.record(.info, "#\(transactionID) crossed a message from the watch and got no reply: sending it again")
            self.inflightPush = nil
            self.pushAckTimeout?.cancel()
            self.pushAckTimeout = nil
            self.sendIfNeeded(force: true)
        }
    }

    /// Re-sends the undelivered reading after a growing delay, so a watchface
    /// that starts later still receives it even if its refresh request is lost.
    private func scheduleRetry() {
        guard !paused else { return }
        guard retryDelay < LupedDelivery.maximumRetryDelay else {
            // 30 s + 1 + 2 + 4 + 5 min of rejections: stop until the watch is back.
            pushRetry?.cancel()
            pushRetry = nil
            status.retryAt = nil
            paused = true
            record(.info, "Paused sending: the watchface has not accepted a reading for about 12 minutes. Resumes when it starts, on a new watch session, or with Send Now.")
            return
        }
        retryDelay = retryDelay == 0 ? LupedDelivery.initialRetryDelay : min(retryDelay * 2, LupedDelivery.maximumRetryDelay)
        let delay = retryDelay
        status.retryAt = Date().addingTimeInterval(delay)
        record(.info, String(format: "Retrying in %.0f s", delay))
        pushRetry?.cancel()
        pushRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.status.retryAt = nil
            self?.sendIfNeeded()
        }
    }
}

/// Link state and watch diagnostics shown in Settings → Devices → Pebble.
@MainActor
public final class LupedLinkStatus: ObservableObject {
    public typealias Link = PebbleLinkState

    public init() {}

    public struct Delivery {
        public let readingDate: Date
        public let deliveredAt: Date
        public let milliseconds: Int
    }

    @Published public var link = Link.off
    @Published public var lastDelivery: Delivery?
    @Published public var lastRejectedAt: Date?
    @Published public var retryAt: Date?
    /// Sending paused after the watchface stopped accepting readings.
    @Published public var paused = false
    /// Feedback for Send Now when it could not send.
    @Published public var lastResult: String?
    @Published public var diagnostics: LupedWatchDiagnostics?
    /// Why the last watch-info request got no answer, if it did not.
    @Published public var watchInfoNote: String?
}
