import Combine
import ElbbepTransport
import Foundation

/// AppMessage dictionary keys from the Luped watchface's `messageKeys`.
private enum LupedMessageKey {
    static let command: UInt32 = 10_000
    static let data: UInt32 = 10_001
    static let configured: UInt32 = 10_003
    static let diagnostics: UInt32 = 10_004
}

/// Luped's delivery policy for readings.
private enum LupedDelivery {
    /// Backoff for re-sending a rejected or unacknowledged reading. The phone
    /// cannot observe the watchface starting, and Luped asks for data only once.
    static let initialRetryDelay: TimeInterval = 30
    static let maximumRetryDelay: TimeInterval = 300
}

/// The glucose and alert state a host app supplies for the next Luped payload.
public struct LupedSnapshot {
    /// Recent CGM readings; user-entered and display-only values excluded.
    public var readings: [LupedReading]
    /// How many samples the host read, for the log when none are usable.
    public var storedSampleCount: Int
    public var unit: LupedUnit
    public var alerts: LupedAlertState

    public init(readings: [LupedReading], storedSampleCount: Int, unit: LupedUnit, alerts: LupedAlertState) {
        self.readings = readings
        self.storedSampleCount = storedSampleCount
        self.unit = unit
        self.alerts = alerts
    }
}

/// Sends a host app's glucose readings and alert settings to the Luped
/// watchface over a `PebbleTransport`.
///
/// The host supplies a `snapshotProvider` and calls `refresh()` when readings,
/// its display unit, its alert settings or its alert mute change. Luped's own
/// settings are applied whenever `settings` changes.
///
/// The latest payload is kept so a watchface `refresh` or a new session can
/// re-send it. A rejected or unacknowledged send is retried with backoff, and
/// immediately on a glucose update, a watchface refresh, or a new session.
@MainActor
public final class LupedTransport: PebbleTransportDelegate {
    /// The host app's name in log lines, such as "Loop" or "Trio".
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
    /// Supplies the current readings and alert state. Returns `nil` while the
    /// host is not ready; throwing logs the error.
    public var snapshotProvider: (() async throws -> LupedSnapshot?)?

    /// Last logged alarm state, so the log records each change once.
    private var alarmStatus: String?
    private var settingsObservers: Set<AnyCancellable> = []
    private var latestPayload: LupedPayload?
    /// Incremented on every send request; a send completing with an older
    /// value means another request arrived while it was in flight.
    private var requestGeneration = 0
    private var deliveredGeneration = 0
    private var inflightPush: (transactionID: UInt8, generation: Int, payload: LupedPayload, sentAt: Date)?
    /// A COMMAND push awaiting the watch's ACK; pushes are sent one at a time.
    private var inflightCommand: (transactionID: UInt8, command: String)?
    private var diagnosticsRequested = false
    private var diagnosticsReplyTimeout: Task<Void, Never>?
    /// Whether Luped has messaged the phone since this session opened. Alloy
    /// disables a watchface's outbox whenever a non-system session (like this
    /// one) opens or closes; only a watchface restart re-enables it.
    private var heardFromWatchThisSession = false
    /// Waiting for Luped to start again after the phone restarted it.
    private var awaitingWatchfaceRestart: Task<Void, Never>?
    private var pushAckTimeout: Task<Void, Never>?
    private var retryDelay: TimeInterval = 0
    /// Set after the full retry backoff got no ACK: pushes stop until the
    /// watchface makes contact, a new session opens, or the user sends.
    private var paused = false {
        didSet { status.paused = paused }
    }
    private var pushRetry: Task<Void, Never>?

    public init(hostName: String, settings: LupedSettings) {
        self.hostName = hostName
        self.settings = settings
        transport = PebbleTransport(isEnabled: settings.isEnabled, appUUID: settings.watchfaceUUID)
        transport.delegate = self
    }

    /// Keeps the settings in `defaults` (Settings → Devices → Pebble) and
    /// follows changes to them.
    public convenience init(hostName: String, defaults: UserDefaults = .standard) {
        self.init(hostName: hostName, settings: defaults.lupedSettings)
        Publishers.MergeMany(
            defaults.publisher(for: \.lupedPebbleEnabled).map { _ in () }.eraseToAnyPublisher(),
            defaults.publisher(for: \.lupedPebbleWatchfaceUUID).map { _ in () }.eraseToAnyPublisher(),
            defaults.publisher(for: \.lupedPebbleAlarmsEnabled).map { _ in () }.eraseToAnyPublisher(),
            defaults.publisher(for: \.lupedPebbleFollowAlertMute).map { _ in () }.eraseToAnyPublisher(),
            defaults.publisher(for: \.lupedPebbleFullScreen).map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in self?.settings = defaults.lupedSettings }
        .store(in: &settingsObservers)
    }

    /// Writes to the communication log and the host's diagnostic log.
    private func record(_ kind: LupedCommunicationLog.Kind, _ message: String) {
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

        let alarms = LupedAlarmSettings(
            snapshot.alerts,
            watchAlarmsEnabled: settings.alarmsEnabled,
            followHostMute: settings.followAlertMute
        )
        let status = LupedAlarmSettings.status(alarms, alerts: snapshot.alerts, watchAlarmsEnabled: settings.alarmsEnabled, hostName: hostName)
        if status != alarmStatus {
            alarmStatus = status
            record(.info, status)
        }
        guard let payload = LupedPayload(readings: snapshot.readings, unit: snapshot.unit, alarms: alarms, fullScreen: settings.fullScreen) else {
            record(.info, String(format: "No usable CGM readings among %ld stored samples; nothing to send", snapshot.storedSampleCount))
            return
        }

        latestPayload = payload
        requestSend()
    }

    // MARK: - Settings

    private func settingsDidChange(from old: LupedSettings) {
        if settings.alarmsEnabled != old.alarmsEnabled {
            record(.info, "Watch alarms \(settings.alarmsEnabled ? "enabled" : "disabled")")
        }
        if settings.followAlertMute != old.followAlertMute {
            record(.info, "Follow \(hostName) alert mute \(settings.followAlertMute ? "enabled" : "disabled")")
        }
        if settings.fullScreen != old.fullScreen {
            record(.info, "Watch display: \(settings.fullScreen ? "full-screen ring" : "ring with graph")")
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
        record(.info, String(format: "Settings changed: %@ for app %@", enabled ? "enabled" : "disabled", uuid.uuidString))
        transport.reconfigure(isEnabled: enabled, appUUID: uuid)

        guard enabled else {
            // Fully off: no Bluetooth manager, no retries, no payload building.
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
        sendIfNeeded(force: true)
    }

    public func pebbleTransportSessionWillReset(_ transport: PebbleTransport) {
        if inflightPush != nil {
            record(.info, "Session reset before the watch acknowledged the pushed reading")
        }
        inflightPush = nil
        pushAckTimeout?.cancel()
        pushAckTimeout = nil
        // A new session re-sends the reading itself.
        pushRetry?.cancel()
        pushRetry = nil
        retryDelay = 0
        paused = false
        status.retryAt = nil
        inflightCommand = nil
        heardFromWatchThisSession = false
        awaitingWatchfaceRestart?.cancel()
        awaitingWatchfaceRestart = nil
    }

    public func pebbleTransport(_ transport: PebbleTransport, didReceive tuples: [UInt32: AppMessageTuple], message: [UInt8]) {
        heardFromWatchThisSession = true
        if awaitingWatchfaceRestart != nil {
            awaitingWatchfaceRestart?.cancel()
            awaitingWatchfaceRestart = nil
            record(.info, "Watchface restarted; it can reply again")
        }
        let hex = PebbleTransport.hex(message.dropFirst(18))
        if let diagnostics = tuples[LupedMessageKey.diagnostics]?.string {
            record(.fromWatch, "Watch diagnostics: \(diagnostics)")
            status.diagnostics = LupedWatchDiagnostics(json: diagnostics)
            status.watchInfoNote = nil
            diagnosticsReplyTimeout?.cancel()
        }
        // Alloy sends a ready handshake (key 15025) when the watchface starts and
        // keeps its own outbox closed until the phone sends any message back;
        // only then does Luped send its `refresh` command. Answer both with the
        // latest reading.
        let command = tuples[LupedMessageKey.command]?.string
        if tuples[PebbleAppMessage.alloyReadyKey] != nil || command == "refresh" {
            record(.fromWatch, "Watchface requested refresh (\(command.map { "COMMAND \($0)" } ?? "ready handshake"))\n" + LupedPayload.alignedRows([("tuples", hex)]))
            sendIfNeeded(force: true)
        } else if tuples[LupedMessageKey.diagnostics] == nil {
            record(.fromWatch, "Watch message\n" + LupedPayload.alignedRows([("tuples", hex)]))
        }
    }

    public func pebbleTransport(_ transport: PebbleTransport, didReceiveReply acknowledged: Bool, transactionID: UInt8, message: [UInt8]) {
        let reply = acknowledged ? "ACK" : "NACK"
        if let pending = inflightCommand, pending.transactionID == transactionID {
            inflightCommand = nil
            record(.fromWatch, "#\(transactionID) \(reply) · COMMAND \(pending.command)\n" + LupedPayload.alignedRows([("bytes", PebbleTransport.hex(message))]))
            if !acknowledged {
                status.watchInfoNote = NSLocalizedString("The watch rejected the request; the watchface is probably not running.", bundle: .module, comment: "Pebble watch info note: request rejected")
            } else {
                awaitDiagnosticsReply()
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
            record(.fromWatch, "#\(transactionID) ACK in \(elapsed) ms · watch stored the \(readingTime) reading, \(push.payload.readingCount) history points\n" + LupedPayload.alignedRows([("bytes", PebbleTransport.hex(message))]))
            deliveredGeneration = push.generation
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

    /// The Pebble SDK's Alloy runtime disables a watchface's outbox whenever a
    /// non-system session (like this one) opens or closes, until the watchface
    /// restarts. The watch still acknowledges the request but cannot answer.
    private func awaitDiagnosticsReply() {
        diagnosticsReplyTimeout?.cancel()
        diagnosticsReplyTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.heardFromWatchThisSession = false
            self.record(.error, "No diagnostics reply within 5 s; the next request restarts the watchface first")
            self.status.watchInfoNote = NSLocalizedString("The watch did not reply. Tap Refresh Watch Info again to restart the watchface and retry.", bundle: .module, comment: "Pebble watch info note: no reply")
        }
    }

    /// Pushes the current reading now, re-sending it even if already delivered.
    public func sendNow() {
        record(.info, "Send Now requested")
        status.lastResult = nil
        guard transport.isSessionOpen else {
            status.lastResult = NSLocalizedString("No watch session; the reading is sent as soon as the watch connects.", bundle: .module, comment: "Pebble Send Now result: no watch session")
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

    /// Asks Luped for its diagnostics snapshot (battery and counters). If Luped
    /// has not messaged the phone since this session opened, its outbox is disabled,
    /// so the phone first restarts the watchface over the app run-state endpoint.
    public func requestDiagnostics() {
        record(.info, "Watch info requested")
        status.watchInfoNote = nil
        guard transport.isSessionOpen else {
            status.watchInfoNote = NSLocalizedString("The watch is not connected.", bundle: .module, comment: "Pebble watch info note: no session")
            return
        }
        diagnosticsRequested = true
        if !heardFromWatchThisSession, awaitingWatchfaceRestart == nil {
            restartWatchface()
        }
        sendPendingCommand()
    }

    /// Stops and relaunches the watchface. On start, Alloy's ready handshake
    /// reaches the phone and its reply re-enables the watchface's outbox.
    private func restartWatchface() {
        status.watchInfoNote = NSLocalizedString("Restarting the watchface so it can reply…", bundle: .module, comment: "Pebble watch info note: restarting the watchface")
        record(.toWatch, "App run state STOP for \(transport.appUUID.uuidString) (restart so the watchface can reply)")
        transport.sendAppRunState(run: false)
        awaitingWatchfaceRestart = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.record(.toWatch, "App run state RUN for \(self.transport.appUUID.uuidString)")
            self.transport.sendAppRunState(run: true)
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self.awaitingWatchfaceRestart = nil
            self.diagnosticsRequested = false
            self.record(.error, "The watchface did not start within 15 s")
            self.status.watchInfoNote = NSLocalizedString("The watchface did not restart. Open it on the watch, then try again.", bundle: .module, comment: "Pebble watch info note: restart failed")
        }
    }

    private func sendPendingCommand() {
        guard diagnosticsRequested, awaitingWatchfaceRestart == nil, inflightPush == nil, inflightCommand == nil, transport.isSessionOpen else {
            return
        }
        diagnosticsRequested = false
        let transactionID = transport.makeTransactionID()
        inflightCommand = (transactionID, "diagnostics")

        record(.toWatch, "#\(transactionID) COMMAND diagnostics")
        transport.push(transactionID: transactionID, tuples: [(LupedMessageKey.command, .cString("diagnostics"))])

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PebbleAppMessage.ackTimeout * 1_000_000_000))
            guard let self, self.inflightCommand?.transactionID == transactionID else { return }
            self.record(.error, "#\(transactionID) no reply within \(Int(PebbleAppMessage.ackTimeout)) s")
            self.inflightCommand = nil
            self.sendIfNeeded()
        }
    }

    // MARK: - Delivery

    private func requestSend() {
        requestGeneration += 1
        sendIfNeeded()
    }

    /// Pushes the latest payload unless it was already delivered; `force` re-sends
    /// it for a new session or a watchface refresh request.
    private func sendIfNeeded(force: Bool = false) {
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
    /// Feedback for Send Now or a watch request that could not complete.
    @Published public var lastResult: String?
    @Published public var diagnostics: LupedWatchDiagnostics?
    /// Why the last watch-info request got no answer, if it did not.
    @Published public var watchInfoNote: String?
}

/// Luped's diagnostics snapshot (`DIAGNOSTICS`, format version 2).
public struct LupedWatchDiagnostics {
    public let receivedAt: Date
    public let battery: Int?
    public let countingSince: Date?
    public let readingsReceived: Int?
    public let refreshRequests: Int?
    public let urgentLowAlarms: Int?
    public let lowAlarms: Int?
    public let highAlarms: Int?
    public let messagesIn: Int?
    public let messagesOut: Int?
    public let staleTransitions: Int?
    public let phoneDisconnects: Int?
    public let phoneDisconnectedSeconds: Int?

    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any],
              (values.first as? NSNumber)?.intValue == 2
        else {
            return nil
        }
        func int(_ index: Int) -> Int? {
            index < values.count ? (values[index] as? NSNumber)?.intValue : nil
        }
        receivedAt = Date()
        battery = int(2)
        countingSince = int(3).map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
        readingsReceived = int(13)
        refreshRequests = int(14)
        urgentLowAlarms = int(16)
        lowAlarms = int(17)
        highAlarms = int(18)
        messagesIn = int(19)
        messagesOut = int(21)
        staleTransitions = int(31)
        phoneDisconnects = int(34)
        phoneDisconnectedSeconds = int(35).map { $0 / 1_000 }
    }
}

/// The most recent watch communication events, newest last, kept in memory.
@MainActor
public final class LupedCommunicationLog: ObservableObject {
    public enum Kind {
        case toWatch, fromWatch, info, error
    }

    public struct Entry: Identifiable {
        public let id = UUID()
        public let date: Date
        public let kind: Kind
        public let message: String
    }

    public static let capacity = 500

    public init() {}

    @Published public private(set) var entries: [Entry] = []

    public func append(_ kind: Kind, _ message: String) {
        entries.append(Entry(date: Date(), kind: kind, message: message))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    public func clear() {
        entries.removeAll()
    }

    /// Plain text for sharing, oldest first.
    public var text: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { entry in
            let marker: String
            switch entry.kind {
            case .toWatch: marker = "→"
            case .fromWatch: marker = "←"
            case .info: marker = "·"
            case .error: marker = "!"
            }
            return "\(formatter.string(from: entry.date)) \(marker) \(entry.message)"
        }.joined(separator: "\n")
    }
}

