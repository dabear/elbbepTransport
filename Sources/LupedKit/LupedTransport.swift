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
    /// The answer to `COMMAND recommend:<grams>`, to Luped Remote only.
    static let recommendation: UInt32 = 10_006
    /// The answer to `COMMAND presets`, to Luped Remote only.
    static let presets: UInt32 = 10_007
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
    /// Once the loop has run on a new reading, how long to wait before sending:
    /// the loop's dose is stored a few seconds after its result, and IOB moves
    /// with it. Sending at once meant a second message with the same reading
    /// and the new IOB, about 3–4 s later, 87 times a day (device log, 2026-11-01).
    static let loopSettleWindow: TimeInterval = 6
    /// How long after an alert send the next reading still counts as the alert's
    /// own. The host issues a glucose alert as soon as the reading is stored, before
    /// its snapshot with that reading is built, so the alert goes out with the
    /// previous reading and the new one follows within a few seconds.
    static let alertReadingWindow: TimeInterval = 30
    /// How long after its ready handshake the watchface's `refresh` counts as the
    /// one Luped sends when it starts.
    static let startupRefreshWindow: TimeInterval = 10

    enum Timing: Equatable {
        /// Alerts, display and settings changes, or nothing to wait for.
        case now
        /// A new reading while loop status is sent, before the loop has run on it:
        /// wait for the loop result, at most `newReadingHold`.
        case holdForLoopResult
        /// Only loop status or status line changed: collect for `followUpWindow`.
        case collectFollowUps
        /// A new reading the loop has run on: wait `loopSettleWindow` for the
        /// loop's dose, so the IOB it changes goes in the same message.
        case settleAfterLoopResult
    }

    /// When to send `new`, compared with what the watch has or is about to get
    /// (`previous`). Alert changes are never delayed, and neither is the first
    /// reading newer than `alertReading`, the latest reading an alert went out with.
    static func timing(new: LupedPayload, previous: LupedPayload?, needsLoopStatus: Bool, alertReading: Date? = nil) -> Timing {
        guard let previous else { return .now }
        if alertChanged(new: new, previous: previous) {
            return .now
        }
        if new.latestDate != previous.latestDate {
            guard needsLoopStatus else { return .now }
            // The reading the alert was issued for: show it with the buzz.
            if let alertReading, new.latestDate > alertReading { return .now }
            // The loop has run on this reading: send both once its dose is stored.
            if let lastLoop = new.lastLoopCompleted, lastLoop >= new.latestDate { return .settleAfterLoopResult }
            return .holdForLoopResult
        }
        if new.coreData != previous.coreData {
            return .now
        }
        return .collectFollowUps
    }

    static func alertChanged(new: LupedPayload, previous: LupedPayload?) -> Bool {
        guard let previous else { return false }
        return new.hostAlertState != previous.hostAlertState || new.alertEvent != previous.alertEvent
    }

    /// The RESULT to send again when the watchface restarted while it was in
    /// flight; `nil` for other commands (diagnostics), which are just dropped.
    static func resultToResend(afterRestart inflightCommand: String) -> String? {
        inflightCommand.hasPrefix("RESULT ") ? String(inflightCommand.dropFirst("RESULT ".count)) : nil
    }

    /// Whether a host refresh produced `DATA` the watch already has (acknowledged
    /// in this session) or is about to get (in flight), so it needn't be sent.
    /// Watch refresh requests, new sessions and Send Now always send.
    ///
    /// While a message is in flight, the watch ends up with that one, so only it
    /// counts: data that went back to what was delivered before it (A, then B in
    /// flight, then A again) is sent after it.
    static func unchangedData(_ data: String, delivered: String?, inFlight: String?) -> Unchanged? {
        if let inFlight {
            return data == inFlight ? .inFlight : nil
        }
        return data == delivered ? .delivered : nil
    }

    /// Whether the watchface's `refresh` is already answered. Luped sends it when
    /// it starts, right after Alloy's ready handshake, which the phone answers
    /// with the latest `DATA`: when that answer reached this watchface run, or is
    /// on its way, and the data is unchanged, a second copy only costs the watch.
    static func refreshAnsweredAtStartup(_ data: String, watchfaceStartedAt: Date?, delivered: String?, inFlight: String?, now: Date) -> Bool {
        guard let watchfaceStartedAt, now.timeIntervalSince(watchfaceStartedAt) <= startupRefreshWindow else { return false }
        return unchangedData(data, delivered: delivered, inFlight: inFlight) != nil
    }
}

/// Sends a host app's glucose readings, alerts and loop status to the Luped
/// watchface, and to Luped Remote, each over its own `PebbleTransport`.
///
/// The host supplies a `snapshotProvider` and calls `refresh()` when any of them
/// change. Luped's own settings are applied whenever `settings` changes.
///
/// The latest payload is kept so a watchface `refresh` or a new session can
/// re-send it. A rejected or unacknowledged send is retried with backoff, and
/// immediately on a glucose update, a watchface refresh, or a new session.
///
/// The watch runs one of the two apps at a time and keeps both sessions open,
/// so everything goes to the `foreground` app: the one that last started or
/// sent something, or the other one after it rejects a push. Requests from
/// either app reach the same callbacks, and a `RESULT` goes to the app running
/// when it is sent, so the watchface shows the answer to a request Luped
/// Remote sent before it closed.
@MainActor
public final class LupedTransport: PebbleTransportDelegate {
    /// The host app's name, such as "Loop" or "Trio": in log lines, and sent as
    /// `DATA` index 15 so a watch can tell two apps on the same phone apart.
    public let hostName: String
    // Internal for tests, which open sessions through `handlePacket`.
    let watchfaceTransport: PebbleTransport
    let remoteTransport: PebbleTransport
    /// The app messages go to; see the type's documentation.
    public private(set) var foreground = LupedWatchApp.watchface {
        didSet { status.foreground = foreground }
    }
    /// Apps that rejected a push since an app last accepted one or sent a message.
    private var rejectedApps = Set<LupedWatchApp>()
    /// When each app last accepted a message or sent one: a rejection soon after
    /// is from a busy app, not a closed one (`LupedRouting.isBusy`).
    private var lastHeard: [LupedWatchApp: Date] = [:]
    /// Whether the foreground app's busy rejection was already retried once since
    /// it last accepted or sent something.
    private var busyRetried = false
    /// The app a rejection moved away from, until the new foreground app accepts
    /// or sends something: if it doesn't answer at all, the phone goes back.
    private var movedAwayFrom: LupedWatchApp?
    /// After moving to an app that may not be running either: give it a bolus
    /// key once it accepts the reading, not before.
    var bolusKeyOnDelivery = false
    /// The foreground app's transport.
    private var transport: PebbleTransport { transport(for: foreground) }

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
    /// Called when a Luped app reports a speaker (`COMMAND speaker:on|quiet`),
    /// with whether the watch's Quiet Time is on, so the host keeps
    /// `LupedSettings.watchHasSpeaker` and offers the alarm sound.
    public var speakerDidReport: ((Bool) -> Void)?
    /// Whether to ask the watchface for its speaker (`COMMAND speaker`), once per
    /// session after it acknowledges a reading. The host turns it on while it
    /// doesn't know the watch has one (a watch added again, its watchface still
    /// running); a speaker report turns it off. Watches older than Luped 0.1.26
    /// ignore the question, as they ignore any `COMMAND` they don't know.
    public var asksForSpeaker = false
    /// Begins a background task named for its purpose and returns what ends it.
    /// A delayed send (waiting for the loop result, its dose, or more changes)
    /// holds one until it has sent, so iOS doesn't suspend the host halfway and
    /// leave the watch without the reading until the app is opened again. The
    /// host ends it itself if iOS takes the time back first. `nil`: no task.
    public var beginBackgroundTask: (@MainActor (_ name: String) -> (@MainActor () -> Void))?
    /// Supplies the current readings and alert state. Returns `nil` while the
    /// host is not ready; throwing logs the error.
    public var snapshotProvider: (() async throws -> LupedSnapshot?)?
    /// Called when the watch asks to mute the host's alerts (`COMMAND`
    /// `mute:<minutes>`), with the requested duration (0 for `mute:cancel`, to end
    /// the mute) and when the user confirmed
    /// it (see `LupedCommandTiming`; `nil` when the command didn't say). The host
    /// decides whether its user allowed muting from the watch.
    public var alertMuteRequested: ((_ duration: TimeInterval, _ requestedAt: Date?) -> Void)?
    /// Called when the watch asks to add carbs (`COMMAND carbs:<grams>`), with
    /// the grams the watch chose and when the user confirmed them (see
    /// `LupedCommandTiming`; `nil` when the command didn't say). The host runs
    /// its own checks.
    public var carbsRequested: ((_ grams: Double, _ absorption: LupedCarbAbsorption?, _ requestedAt: Date?) -> Void)?
    /// Called when the watch asks to start an override preset (`COMMAND
    /// override:<preset name or id>`) or end the running one (`override:cancel`),
    /// with when the user confirmed it (see `LupedCommandTiming`; `nil` when the
    /// command didn't say). Without it, the request is logged and answered
    /// `override:ignored`.
    public var overrideRequested: ((_ action: LupedPresetAction, _ requestedAt: Date?) -> Void)?
    /// The same for temp target presets (`COMMAND temptarget:<preset name or
    /// id>`, `temptarget:cancel`), answered `temptarget:ignored` without it.
    public var tempTargetRequested: ((_ action: LupedPresetAction, _ requestedAt: Date?) -> Void)?
    /// Called once for each signed bolus request from the watch that passed
    /// `LupedBolusAuth` (`COMMAND signedbolus:<units>[:<grams>]…`, or
    /// `signedforcedbolus:` to skip only the host's recommendation check), with
    /// the units, the carbs to add first (`nil` for none) and when the user
    /// confirmed them. There is no unsigned bolus request. The host runs its own checks. Answer with `sendResult`
    /// (`carbs:<outcome>` first when there were carbs, then
    /// `signedbolus:<outcome>` or `signedforcedbolus:<outcome>`), so a resent
    /// request gets the same answer.
    public var bolusRequested: ((_ units: Double, _ forced: Bool, _ grams: Double?, _ absorption: LupedCarbAbsorption?, _ requestedAt: Date) -> Void)?
    /// Called when Luped Remote asks what bolus the host would recommend with the
    /// carbs the user is about to add (`COMMAND recommend:<grams>`, 0 for none),
    /// before the user picks one. Nothing is to be added or delivered. Answer with
    /// `sendBolusRecommendation` or `sendBolusRecommendationRefusal`; without it,
    /// the request is answered `ignored`.
    public var bolusRecommendationRequested: ((_ grams: Double, _ absorption: LupedCarbAbsorption?) -> Void)?
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

    private(set) var latestPayload: LupedPayload?
    /// The host's snapshot `latestPayload` was built from, to rebuild it for the other app.
    /// Internal for preset requests, which map a watch id back to the host's.
    private(set) var latestSnapshot: LupedSnapshot?
    /// Incremented on every send request; a send completing with an older
    /// value means another request arrived while it was in flight.
    private var requestGeneration = 0
    private var deliveredGeneration = 0
    private var inflightPush: (transactionID: UInt8, generation: Int, payload: LupedPayload, sentAt: Date)?
    /// The `DATA` the running watchface acknowledged. A host refresh that
    /// produces the same `DATA` is not sent again; cleared when the session
    /// resets or the watchface restarts.
    private var deliveredPayload: LupedPayload?
    /// When the running watchface sent its ready handshake.
    private var watchfaceStartedAt: Date?
    /// A send waiting for the loop result or collecting loop-only changes; it
    /// sends `latestPayload` when it fires.
    private var delayedSend: Task<Void, Never>?
    private var delayedSendTiming: LupedDelivery.Timing?
    private var delayedSendStarted = Date.distantPast
    /// Ends the background task the delayed send holds.
    private var endDelayedSendBackgroundTask: (@MainActor () -> Void)?
    /// Until then, sends aren't delayed: the user just changed a setting, and the
    /// host's snapshot with what it now requests should show at once.
    private var sendImmediatelyUntil = Date.distantPast
    /// The latest reading an alert send carried, and when: the next newer reading
    /// within `alertReadingWindow` is the alert's own and goes at once.
    private var alertReading: (readingDate: Date, sentAt: Date)?
    /// Alert fires the watch acknowledged at a level above 0, newest last,
    /// checked against the buzz records in the watch's diagnostics.
    private var deliveredAlerts: [LupedDeliveredAlert] = []
    /// A COMMAND push awaiting the watch's ACK; pushes are sent one at a time.
    private var inflightCommand: (transactionID: UInt8, command: String)?
    private var diagnosticsRequested = false
    /// Whether the current alert event is sounded (`LupedPayload`'s `alertSound`).
    private var alertSoundDecision: (event: Int, sounded: Bool)?
    /// Find my Pebble (`COMMAND findpebble:<seconds>`), until sent, and the one
    /// in flight, which goes to the other app if this one rejects it.
    private var pendingFind: LupedFindRequest?
    private var inflightFind: LupedFindRequest?
    /// `asksForSpeaker`'s question, until sent, and whether this watchface
    /// session was asked already.
    private var speakerQueryPending = false
    private var speakerAskedInSession = false
    /// Outcomes of the watch's requests waiting to go back to it (`RESULT`), oldest first.
    private var pendingResults: [String] = []
    /// The answer to Luped Remote's recommendation request (`RECOMMEND`), until sent.
    /// Answers only Luped Remote asks for (`RECOMMEND`, `PRESETS`), until sent.
    private var pendingRemoteAnswers: [(key: UInt32, name: String, value: String)] = []
    var bolusAuth = LupedBolusAuth()
    /// The app that acknowledged the current session's key. Moving back to it,
    /// when it hasn't restarted meanwhile, keeps that key: a request it signed is
    /// still accepted. Cleared whenever the session changes or ends.
    var keyHolder: LupedWatchApp?
    /// The `COMMAND auth:…` handing the watch its bolus session key, until sent.
    var pendingBolusKey: String?
    private var diagnosticsReplyTimeout: Task<Void, Never>?
    private var pushAckTimeout: Task<Void, Never>?
    /// The reply timeout of `inflightCommand`. Each app's session numbers its own
    /// messages, so a timeout outliving its command could match the next app's.
    private var commandAckTimeout: Task<Void, Never>?
    private var retryDelay: TimeInterval = 0
    /// Set after the full retry backoff got no ACK: pushes stop until the
    /// watchface makes contact, a new session opens, or the user sends.
    private var paused = false {
        didSet { status.paused = paused }
    }
    private var pushRetry: Task<Void, Never>?
    private var crossedMessageResend: Task<Void, Never>?
    /// Times the services were published again while a Pebble stayed connected
    /// without opening them (`LupedRepublish`); reset when a watch subscribes or
    /// the link settings change.
    private var republishAttempts = 0

    public init(hostName: String, settings: LupedSettings) {
        self.hostName = hostName
        self.settings = settings
        watchfaceTransport = PebbleTransport(isEnabled: settings.isEnabled, appUUID: settings.watchfaceUUID)
        remoteTransport = PebbleTransport(isEnabled: settings.servesRemote, appUUID: settings.remoteUUID)
        watchfaceTransport.delegate = self
        remoteTransport.delegate = self
    }

    private func transport(for app: LupedWatchApp) -> PebbleTransport {
        app == .watchface ? watchfaceTransport : remoteTransport
    }

    private func app(of transport: PebbleTransport) -> LupedWatchApp {
        transport === remoteTransport ? .remote : .watchface
    }

    private var openSessions: Set<LupedWatchApp> {
        Set([LupedWatchApp.watchface, .remote].filter { transport(for: $0).isSessionOpen })
    }

    /// Sends to `app` from now on. What the previous app hadn't acknowledged is
    /// dropped (a `RESULT` goes to `app` instead), and `app` gets the reading
    /// and, when the host issues them, a bolus key of its own: now, or with
    /// `keyOnDelivery` once it accepts the reading.
    private func switchForeground(to app: LupedWatchApp, _ reason: String, keyOnDelivery: Bool = false, restarted: Bool = false) {
        movedAwayFrom = nil
        busyRetried = false
        guard app != foreground else { return }
        record(.info, "Sending to \(app.name) from now on: \(reason)")
        dropUnacknowledgedMessages(because: "\(foreground.name) is no longer running")
        foreground = app
        if let latestSnapshot {
            latestPayload = payload(from: latestSnapshot, for: app)
        }
        deliveredPayload = nil
        // A recommendation answers the app that asked, which has closed.
        pendingRemoteAnswers.removeAll()
        pushRetry?.cancel()
        pushRetry = nil
        retryDelay = 0
        paused = false
        status.retryAt = nil
        if keyHolder == app, !restarted {
            // It still has the current key (see `keyHolder`).
            bolusKeyOnDelivery = false
            return
        }
        bolusKeyOnDelivery = keyOnDelivery
        if issuesBolusKey, !keyOnDelivery {
            startBolusSession()
        }
    }

    /// After the foreground app rejected a message (`command`'s label, or `nil`
    /// for a reading): returns `true` when it was handled here. A busy app (it
    /// accepted or sent something within `LupedRouting.busyWindow`) gets the
    /// message again once, shortly; otherwise the phone moves to the other app
    /// when its session is open and it hasn't rejected one too.
    private func moveOnAfterRejection(of command: String?) -> Bool {
        let now = Date()
        if !busyRetried, LupedRouting.isBusy(rejectedAt: now, lastHeard: lastHeard[foreground]) {
            busyRetried = true
            let seconds = now.timeIntervalSince(lastHeard[foreground] ?? now)
            record(.info, String(format: "%@ rejected a message %.0f s after it accepted or sent one: it's busy, not closed; sending again in %.0f s", foreground.name, seconds, LupedRouting.busyRetryDelay))
            let isReading = command == nil
            if let command, let id = Self.bolusSessionID(inLabel: command) {
                // The same key again with the retry, while keys are on and it is
                // still the current session's (turned off or replaced meanwhile:
                // nothing to send).
                if issuesBolusKey, let key = bolusAuth.keyCommand(forSession: id) {
                    pendingBolusKey = key
                }
            } else if command == "COMMAND speaker" {
                speakerQueryPending = true
            }
            pushRetry?.cancel()
            pushRetry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(LupedRouting.busyRetryDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.sendIfNeeded(force: isReading)
            }
            return true
        }
        rejectedApps.insert(foreground)
        guard let next = LupedRouting.next(afterRejectionBy: foreground, rejected: rejectedApps, openSessions: openSessions) else {
            rejectedApps.removeAll()
            return false
        }
        let previous = foreground
        switchForeground(to: next, "\(foreground.name) rejected a message, so it isn't running", keyOnDelivery: true)
        movedAwayFrom = previous
        sendIfNeeded(force: true)
        return true
    }

    /// After the foreground app gave no reply at all: when a rejection moved the
    /// phone to it, goes back to the app it moved away from and returns `true`.
    /// The silent app counts as rejected, so the two can't take turns for ever.
    private func moveBackAfterSilence() -> Bool {
        guard let back = movedAwayFrom, openSessions.contains(back) else { return false }
        let silent = foreground
        switchForeground(to: back, "\(silent.name) didn't answer after \(back.name) rejected a message, so \(back.name) gets it again", keyOnDelivery: true)
        rejectedApps.insert(silent)
        sendIfNeeded(force: true)
        return true
    }

    /// The app accepted a message or sent one: it is running.
    private func heard(from app: LupedWatchApp) {
        lastHeard[app] = Date()
        if app == foreground {
            busyRetried = false
            movedAwayFrom = nil
        }
    }

    /// Writes to the communication log and the host's diagnostic log.
    func record(_ kind: LupedCommunicationLog.Kind, _ message: String) {
        diagnosticLog?(kind, message)
        communicationLog.append(kind, message)
    }

    /// Starts the GATT services if Pebble support is on.
    public func start() {
        watchfaceTransport.start()
        remoteTransport.start()
    }

    /// Builds the payload from the host's current snapshot and sends it if it
    /// is new.
    public func refresh() async {
        guard let snapshotProvider else {
            return
        }
        guard watchfaceTransport.isEnabled, settings.isEnabled else {
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

        latestSnapshot = snapshot
        guard let payload = payload(from: snapshot, for: foreground) else {
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

    /// The `DATA` for `app`: the watchface's follows its display settings;
    /// Luped Remote always gets IOB, COB and loop status, and no history.
    func payload(from snapshot: LupedSnapshot, for app: LupedWatchApp) -> LupedPayload? {
        let shown = app == .remote ? settings.remote : settings
        // Whether an alert sounds is decided when it first goes out with a
        // level above 0, and kept, so a settings change doesn't buzz it again.
        // A snapshot with the new event before its level decides nothing.
        if alertSoundDecision?.event != snapshot.alertEvent {
            alertSoundDecision = snapshot.hostAlertState > 0
                ? (snapshot.alertEvent, settings.soundsAlarm(hostAlertState: snapshot.hostAlertState))
                : nil
        }
        return LupedPayload(readings: snapshot.readings, unit: snapshot.unit, fullScreen: shown.fullScreen, hostAlertState: snapshot.hostAlertState, hostAlertReason: snapshot.hostAlertReason, alertEvent: snapshot.alertEvent, alertSound: alertSoundDecision?.sounded, loopStatus: shown.loopStatusToSend(snapshot.loopStatus), statusLine: LupedPayload.statusLine(shown.shownStatusLine, therapy: snapshot.therapy, unit: snapshot.unit), hostName: hostName, settings: shown, remote: app == .remote, usesCarbAbsorption: snapshot.usesCarbAbsorption)
    }

    /// Sends now, or after a short wait so a reading and the loop result that
    /// follows it, or several loop-only changes, go in one message.
    private func scheduleSend(_ payload: LupedPayload) {
        let previous = inflightPush?.payload ?? deliveredPayload
        if let pending = alertReading, Date().timeIntervalSince(pending.sentAt) > LupedDelivery.alertReadingWindow {
            alertReading = nil
        }
        let needsLoopStatus = foreground == .remote || settings.needsLoopStatus
        let timing = Date() < sendImmediatelyUntil ? .now : LupedDelivery.timing(new: payload, previous: previous, needsLoopStatus: needsLoopStatus, alertReading: alertReading?.readingDate)
        if LupedDelivery.alertChanged(new: payload, previous: previous) {
            alertReading = (payload.latestDate, Date())
        } else if let pending = alertReading, payload.latestDate > pending.readingDate {
            alertReading = nil
            if timing == .now, previous?.latestDate != payload.latestDate {
                record(.info, String(format: "The alert's reading arrived %.1f s after the alert: sending it now", Date().timeIntervalSince(pending.sentAt)))
            }
        }
        switch timing {
        case .now:
            cancelDelayedSend()
            requestSend()
        case .settleAfterLoopResult:
            // A running settle window ends soon and sends the latest payload.
            guard delayedSendTiming != .settleAfterLoopResult else { return }
            if delayedSendTiming == .holdForLoopResult {
                record(.info, String(format: "Loop result in after %.1f s: sending it with the reading in %.0f s, once the loop's dose is stored", Date().timeIntervalSince(delayedSendStarted), LupedDelivery.loopSettleWindow))
            } else {
                record(.info, String(format: "New reading with the loop result: sending in %.0f s, once the loop's dose is stored", LupedDelivery.loopSettleWindow))
            }
            startDelayedSend(after: LupedDelivery.loopSettleWindow, timing: timing)
        case .holdForLoopResult:
            // A running hold or settle window already ends soon; a follow-up window gives way to it.
            guard delayedSendTiming != .holdForLoopResult, delayedSendTiming != .settleAfterLoopResult else { return }
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
        // The new task first, so the app keeps running while one ends and the other begins.
        let endPrevious = endDelayedSendBackgroundTask
        endDelayedSendBackgroundTask = beginBackgroundTask?("Luped: send the reading to the watch")
        endPrevious?()
        delayedSend = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if timing == .holdForLoopResult {
                self.record(.info, String(format: "No loop result within %.0f s: sending the reading without it", delay))
            }
            self.delayedSend = nil
            self.delayedSendTiming = nil
            defer { self.endDelayedSendBackgroundTaskIfAny() }
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
        endDelayedSendBackgroundTaskIfAny()
    }

    private func endDelayedSendBackgroundTaskIfAny() {
        let end = endDelayedSendBackgroundTask
        endDelayedSendBackgroundTask = nil
        end?()
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
        if settings.remoteEnabled != old.remoteEnabled {
            record(.info, "Luped Remote \(settings.remoteEnabled ? "on" : "off: it gets no watch session")")
        }
        if settings.remoteUUID != old.remoteUUID {
            record(.info, "Luped Remote UUID: \(settings.remoteUUID.uuidString.lowercased())")
        }
        if settings.isEnabled, settings.remoteEnabled, settings.remoteUUID == settings.watchfaceUUID {
            record(.error, "Luped Remote has the watchface's UUID: it gets no watch session of its own")
        }
        if settings.isEnabled != watchfaceTransport.isEnabled || settings.watchfaceUUID != watchfaceTransport.appUUID {
            applyLink()
        } else if settings.servesRemote != remoteTransport.isEnabled || settings.remoteUUID != remoteTransport.appUUID {
            applyRemoteLink()
            Task { await refresh() }
        } else {
            Task { await refresh() }
        }
    }

    /// Turns the watch link on or off, or moves it to another watchface.
    private func applyLink() {
        let enabled = settings.isEnabled
        let uuid = settings.watchfaceUUID
        record(.info, enabled ? "Watch link settings changed: watchface \(uuid.uuidString.lowercased())" : "Watch link off")
        watchfaceTransport.reconfigure(isEnabled: enabled, appUUID: uuid)
        republishAttempts = 0
        applyRemoteLink()

        guard enabled else {
            // Fully off: no Bluetooth manager, no retries, no payload building.
            endBolusSession()
            pushRetry?.cancel()
            pushRetry = nil
            latestPayload = nil
            latestSnapshot = nil
            record(.info, "Pebble support off: Bluetooth service removed")
            return
        }
        // Build the current reading now rather than waiting for the next one.
        Task { await refresh() }
    }

    /// Publishes or removes Luped Remote's service; without it, everything goes
    /// to the watchface.
    private func applyRemoteLink() {
        let enabled = settings.servesRemote
        let uuid = settings.remoteUUID
        guard enabled != remoteTransport.isEnabled || uuid != remoteTransport.appUUID else { return }
        remoteTransport.reconfigure(isEnabled: enabled, appUUID: uuid)
        republishAttempts = 0
        rejectedApps.remove(.remote)
        switchForeground(to: .watchface, enabled ? "Luped Remote's watch session moved to \(uuid.uuidString.lowercased())" : "Luped Remote's watch session was removed")
    }

    // MARK: - PebbleTransportDelegate

    public func pebbleTransport(_ source: PebbleTransport, log kind: PebbleLogKind, _ message: String) {
        let message = "\(app(of: source).logLabel): \(message)"
        switch kind {
        case .toWatch: record(.toWatch, message)
        case .fromWatch: record(.fromWatch, message)
        case .info: record(.info, message)
        case .error: record(.error, message)
        }
    }

    public func pebbleTransportDidChangeLink(_ source: PebbleTransport) {
        if source.hasWatch {
            republishAttempts = 0
        }
        if app(of: source) == .remote {
            if status.remoteLink != source.link {
                status.remoteLink = source.link
            }
        } else if status.link != source.link {
            status.link = source.link
        }
    }

    public func pebbleTransportSessionDidOpen(_ source: PebbleTransport) {
        let opened = app(of: source)
        if opened == .watchface {
            speakerAskedInSession = false
        }
        let next = LupedRouting.foreground(afterOpening: opened, current: foreground, openSessions: openSessions.subtracting([opened]))
        guard next == opened else {
            // The watch opens a session for each app; this one is sent to once
            // it shows it's running.
            record(.info, "\(opened.name)'s session opened; still sending to \(foreground.name)")
            return
        }
        if foreground != opened {
            // Starts a bolus session for it.
            switchForeground(to: opened, "its session opened and \(foreground.name)'s is closed")
        } else if issuesBolusKey {
            startBolusSession()
        }
        sendIfNeeded(force: true)
    }

    /// Publishes every enabled service again, as restarting the app does, when a
    /// Pebble is connected to this iPhone but none of them has its watch: the
    /// watch dropped them all and doesn't look again until they're published anew.
    /// While one app keeps its watch, nothing is touched.
    public func pebbleTransport(_ source: PebbleTransport, isWaitingWithPebbleConnected pebbleConnected: Bool) {
        let transports = [watchfaceTransport, remoteTransport]
        guard LupedRepublish.shouldRepublish(transports: transports.map { ($0.isEnabled, $0.hasWatch) }, pebbleConnected: pebbleConnected) else {
            return
        }
        let enabled = transports.filter(\.isEnabled)
        let names = enabled.map { app(of: $0).name }
        republishAttempts += 1
        let next = LupedRepublish.checkDelay(afterAttempts: republishAttempts)
        let wait = next < 60 ? String(format: "%.0f s", next) : String(format: "%.0f min", next / 60)
        record(.info, String(format: "A Pebble is connected to this iPhone, but no watch session for %@: publishing %@ again, as restarting %@ does (attempt %ld; next check in %@)", names.joined(separator: " or "), enabled.count == 1 ? "its service" : "their services", hostName, republishAttempts, wait))
        // Each one checks again `next` seconds after its service is published.
        enabled.forEach { $0.republishService(nextWaitCheckIn: next) }
    }

    public func pebbleTransportSessionWillReset(_ source: PebbleTransport) {
        // Nothing is in flight to an app that isn't the foreground one.
        guard app(of: source) == foreground else { return }
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
        // A RESULT or Find my Pebble the watch didn't acknowledge goes out again
        // in the new session; the watch may have taken it, and showing or
        // starting it twice is harmless, losing it isn't.
        if let pending = inflightCommand {
            if let result = LupedDelivery.resultToResend(afterRestart: pending.command) {
                record(.info, "RESULT \(result), unacknowledged at the session reset, goes out again")
                pendingResults.insert(result, at: 0)
            }
            if let find = inflightFind {
                record(.info, "COMMAND \(find.command), unacknowledged at the session reset, goes out again")
                pendingFind = find
            }
        }
        inflightFind = nil
        inflightCommand = nil
        commandAckTimeout?.cancel()
        commandAckTimeout = nil
        pendingRemoteAnswers.removeAll()
        endBolusSession()
    }

    public func pebbleTransport(_ source: PebbleTransport, didReceive tuples: [UInt32: AppMessageTuple], message: [UInt8]) {
        // Only the running app sends anything.
        rejectedApps.removeAll()
        let sender = app(of: source)
        heard(from: sender)
        if sender == .remote {
            status.remoteLastSeen = Date()
        }
        let started = tuples[PebbleAppMessage.alloyReadyKey] != nil
        let switched = sender != foreground
        if switched {
            switchForeground(to: sender, started ? "it started" : "it sent a message", restarted: started)
        }
        resendIfCrossed()
        if started {
            // A switch already dropped what went to the other app, and what it
            // sent since (the new app's key) went to this run.
            if !switched {
                dropUnacknowledgedMessages(because: "\(sender.name) restarted")
            }
            // The new watchface run has none of what the previous one acknowledged.
            deliveredPayload = nil
            watchfaceStartedAt = Date()
            // A new watchface run has no key: give it a new one, so nothing the
            // previous run signed is accepted any more (a switch gave it one).
            if issuesBolusKey, !switched {
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
        // only then does Luped send its `refresh` command. Answer the handshake
        // with the latest reading, and the startup `refresh` only if that answer
        // didn't reach the watch or the data changed since.
        let command = tuples[LupedMessageKey.command]?.string
        let base = command.map(LupedCommandTiming.stripped)
        if let command, LupedSignedBolus.isSigned(command) {
            handleSignedBolus(command)
        } else if let command, let base, let request = LupedWatchRequest(command: base) {
            handleWatchRequest(request, command: command)
        } else if tuples[PebbleAppMessage.alloyReadyKey] != nil || command == "refresh" {
            record(.fromWatch, "\(sender == .watchface ? "Watchface" : "Luped Remote") requested refresh (\(command.map { "COMMAND \($0)" } ?? "ready handshake"))\n" + LupedPayload.alignedRows([("tuples", hex)]))
            if tuples[PebbleAppMessage.alloyReadyKey] == nil, let latest = latestPayload,
               LupedDelivery.refreshAnsweredAtStartup(latest.data, watchfaceStartedAt: watchfaceStartedAt, delivered: deliveredPayload?.data, inFlight: inflightPush?.payload.data, now: Date()) {
                record(.info, "The watchface's startup refresh: its ready handshake was answered with the same DATA; not sent again")
            } else {
                sendIfNeeded(force: true)
            }
        } else if let command, let quietTime = LupedWatchSpeaker.quietTime(reportedIn: command) {
            record(.fromWatch, "\(sender.logLabel) has a speaker for the alarm sound" + (quietTime ? "; the watch's Quiet Time is on, which can mute it" : "") + " (COMMAND \(command))")
            status.speaker = LupedWatchSpeaker(quietTime: quietTime, reportedAt: Date())
            asksForSpeaker = false
            speakerQueryPending = false
            speakerDidReport?(quietTime)
        } else if let command {
            // An action LupedKit doesn't know (`bolus:` is gone) or a malformed
            // one: nothing is passed to the host.
            record(.error, "Watch command ignored: this plugin doesn't handle it (COMMAND \(command))\n" + LupedPayload.alignedRows([("tuples", hex)]))
        } else if tuples[LupedMessageKey.diagnostics] == nil {
            record(.fromWatch, "Watch message\n" + LupedPayload.alignedRows([("tuples", hex)]))
        }
        // An app that was already running when the phone moved to it has the
        // reading only from its own session: send it (a refresh already did).
        if switched, !started, command != "refresh" {
            sendIfNeeded(force: true)
        }
    }

    public func pebbleTransport(_ source: PebbleTransport, didReceiveReply acknowledged: Bool, transactionID: UInt8, message: [UInt8]) {
        let reply = acknowledged ? "ACK" : "NACK"
        // Each session numbers its own messages; only the foreground app's are in flight.
        guard app(of: source) == foreground else {
            record(.fromWatch, "#\(transactionID) \(reply) from \(app(of: source).name), which nothing is in flight to; ignored")
            return
        }
        if acknowledged {
            rejectedApps.removeAll()
            heard(from: foreground)
        }
        if let pending = inflightCommand, pending.transactionID == transactionID {
            inflightCommand = nil
            record(.fromWatch, "#\(transactionID) \(reply) · \(pending.command)\n" + LupedPayload.alignedRows([("bytes", PebbleTransport.hex(message))]))
            let find = inflightFind
            inflightFind = nil
            if !acknowledged, pending.command != "COMMAND diagnostics" {
                // A RESULT or Find my Pebble goes to the other app if that is
                // the one running; a bolus key is replaced by one of the other
                // app's own.
                let result = LupedDelivery.resultToResend(afterRestart: pending.command)
                if let result {
                    pendingResults.insert(result, at: 0)
                }
                if let find {
                    pendingFind = find
                }
                if moveOnAfterRejection(of: pending.command) {
                    return
                }
                if result != nil {
                    pendingResults.removeFirst()
                }
                if find != nil {
                    pendingFind = nil
                    findNotDelivered("neither Luped CGM nor Luped Remote is running on the watch", noLupedApp: true)
                    sendIfNeeded()
                    return
                }
            }
            if acknowledged, let find {
                record(.info, find.seconds > 0 ? "\(foreground.name) took Find my Pebble (\(find.seconds) s)" : "\(foreground.name) stopped Find my Pebble")
                status.findNote = find.seconds == 0
                    ? NSLocalizedString("Stopped.", bundle: .lupedKit, comment: "Pebble find note: stopped")
                    : find.seconds == 60
                    ? NSLocalizedString("The watch is buzzing for a minute. Press a button on it to stop.", bundle: .lupedKit, comment: "Pebble find note: delivered for the default minute")
                    : String(format: NSLocalizedString("The watch is buzzing for %d seconds. Press a button on it to stop.", bundle: .lupedKit, comment: "Pebble find note: delivered (seconds)"), find.seconds)
            }
            if pending.command == "COMMAND diagnostics" {
                if !acknowledged {
                    status.watchInfoNote = NSLocalizedString("Open Luped CGM on the watch, then try again.", bundle: .lupedKit, comment: "Pebble watch info note: request rejected")
                } else {
                    awaitDiagnosticsReply()
                }
            } else if acknowledged, let id = Self.bolusSessionID(inLabel: pending.command) {
                bolusAuth.keyDelivered(session: id)
                if bolusAuth.session?.id == id {
                    keyHolder = foreground
                }
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
            record(.fromWatch, "#\(transactionID) ACK in \(elapsed) ms · watch stored the \(readingTime) reading, \(push.payload.readingCount == 0 ? (foreground == .remote ? "no history (Luped Remote)" : "no history (Large Glucose)") : "\(push.payload.readingCount) history points")\n" + LupedPayload.alignedRows([("bytes", PebbleTransport.hex(message))]))
            deliveredGeneration = push.generation
            deliveredPayload = push.payload
            if bolusKeyOnDelivery {
                bolusKeyOnDelivery = false
                if issuesBolusKey {
                    startBolusSession()
                }
            }
            if asksForSpeaker, foreground == .watchface, !speakerAskedInSession {
                speakerAskedInSession = true
                speakerQueryPending = true
            }
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
            // The watch rejects pushes while the app is not running.
            record(.fromWatch, "#\(transactionID) NACK in \(elapsed) ms · watch rejected the \(readingTime) reading; \(foreground.name) is probably not running\n" + LupedPayload.alignedRows([("bytes", PebbleTransport.hex(message))]))
            if moveOnAfterRejection(of: nil) {
                return
            }
            if pendingFind != nil {
                pendingFind = nil
                findNotDelivered("neither Luped CGM nor Luped Remote is running on the watch", noLupedApp: true)
            }
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
        // The watchface first: whoever presses Send Now is usually looking at it,
        // stuck on an old reading. If it isn't running it rejects the reading and
        // Luped Remote gets it, as after any rejection.
        if foreground != .watchface, openSessions.contains(.watchface) {
            rejectedApps.removeAll()
            let previous = foreground
            switchForeground(to: .watchface, "Send Now goes to the watchface first", keyOnDelivery: true)
            // A watchface that doesn't answer at all sends the phone back.
            movedAwayFrom = previous
        }
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
            status.watchInfoNote = NSLocalizedString("The watch isn't connected.", bundle: .lupedKit, comment: "Pebble watch info note: no session")
            return
        }
        // Only the watchface reports diagnostics.
        guard foreground == .watchface else {
            status.watchInfoNote = NSLocalizedString("Luped Remote is open on the watch. Close it, then try again.", bundle: .lupedKit, comment: "Pebble watch info note: the remote app is running")
            return
        }
        diagnosticsRequested = true
        sendPendingCommand()
    }

    /// Find my Pebble: whichever Luped app is running buzzes, beeps (on watches
    /// with a speaker) and lights up for `seconds`; 0 stops it. Watches older
    /// than Luped 0.1.24 and Luped Remote 0.1.6 ignore it. `status.findNote`
    /// says which app took it, or that neither is running.
    public func findPebble(seconds: Int = 60) {
        record(.info, seconds > 0 ? "Find my Pebble requested (\(seconds) s)" : "Find my Pebble stop requested")
        guard transport.isSessionOpen else {
            status.findNote = NSLocalizedString("The watch isn't connected.", bundle: .lupedKit, comment: "Pebble find note: no session")
            return
        }
        pendingFind = LupedFindRequest(seconds: max(0, seconds), requestedAt: Date())
        status.findNote = NSLocalizedString("Sending to the watch…", bundle: .lupedKit, comment: "Pebble find note: sending")
        sendIfNeeded()
    }

    /// Logs why Find my Pebble wasn't delivered, and tells the user what to do:
    /// open a Luped app when neither is running, otherwise that the watch didn't answer.
    private func findNotDelivered(_ reason: String, noLupedApp: Bool = false) {
        record(.error, "Find my Pebble not delivered: \(reason)")
        status.findNote = noLupedApp
            ? NSLocalizedString("Open Luped on the watch, then try again.", bundle: .lupedKit, comment: "Pebble find note: neither Luped app is open on the watch")
            : NSLocalizedString("No answer from the watch.", bundle: .lupedKit, comment: "Pebble find note: the watch didn't answer")
    }

    /// Shows a diagnostics report the host saved from an earlier launch until the
    /// watch sends a newer one. Pair with `diagnosticsDidArrive`.
    public func restoreDiagnostics(json: String, receivedAt: Date) {
        guard status.diagnostics == nil else { return }
        status.diagnostics = LupedWatchDiagnostics(json: json, receivedAt: receivedAt)
    }

    /// Only a freshly started app sends the ready handshake, and the watch runs
    /// one app at a time, so anything still awaiting an ACK when an app starts
    /// or the phone moves to the other app will never be answered. Drop it so
    /// the new app is answered at once instead of after the ACK timeout and a
    /// retry. A RESULT goes out again to the new app; a diagnostics request is
    /// dropped (the watchface reports on its own).
    private func dropUnacknowledgedMessages(because reason: String) {
        crossedMessageResend?.cancel()
        crossedMessageResend = nil
        if let push = inflightPush {
            record(.info, "#\(push.transactionID) dropped: \(reason) before acknowledging it")
            inflightPush = nil
            pushAckTimeout?.cancel()
            pushAckTimeout = nil
        }
        if let pending = inflightCommand {
            record(.info, "#\(pending.transactionID) \(pending.command) dropped: \(reason) before acknowledging it")
            if let result = LupedDelivery.resultToResend(afterRestart: pending.command) {
                pendingResults.insert(result, at: 0)
            }
            if let find = inflightFind {
                pendingFind = find
                inflightFind = nil
            }
            inflightCommand = nil
            commandAckTimeout?.cancel()
            commandAckTimeout = nil
        }
    }

    /// Tells the watch how one of its requests ended (`RESULT`), kept short as
    /// `<action>:<outcome>`, e.g. `mute:ok` or `signedbolus:refused`, so the
    /// watchface can react to it, and with `reason` why it wasn't done
    /// (`carbs:refused:too soon`; see `LupedResultReason`). The full reason
    /// goes to the communication log. Sent after any pending reading; the last
    /// few are kept until a session opens.
    public func sendResult(_ result: String, reason: LupedResultReason? = nil) {
        let result = reason?.appended(to: result) ?? result
        bolusAuth.record(result: result)
        queueResult(result)
    }

    /// Answers Luped Remote's recommendation request: the units the host
    /// recommends with `grams` of carbs, and its maximum bolus
    /// (`<grams>:ok:<units>:<maximum bolus>`, the maximum empty when unknown).
    public func sendBolusRecommendation(grams: Double, units: Double, maximumBolus: Double?) {
        queueRecommendation("\(Self.number(grams)):ok:\(Self.number(units)):\(maximumBolus.map(Self.number) ?? "")")
    }

    /// Answers Luped Remote's recommendation request without one:
    /// `<grams>:<outcome>[:<reason>]`, with the outcomes and reasons of `RESULT`.
    public func sendBolusRecommendationRefusal(grams: Double, outcome: String = "refused", reason: LupedResultReason?) {
        queueRecommendation("\(Self.number(grams)):\(outcome)\(reason.map { ":\($0.rawValue)" } ?? "")")
    }

    func queueRecommendation(_ value: String) {
        queueRemoteAnswer(key: LupedMessageKey.recommendation, name: "RECOMMEND", value: value)
    }

    /// Answers Luped Remote's `COMMAND presets` with the host's presets:
    /// `[overrides, temp targets]`, each `[[id, name, running], …]` or null for a
    /// kind the host doesn't have (Loop: temp targets).
    func sendPresets() {
        let answer: [Any] = [
            LupedPreset.watchList(latestSnapshot?.overridePresets),
            LupedPreset.watchList(latestSnapshot?.tempTargetPresets),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: answer, options: .withoutEscapingSlashes),
              let value = String(data: data, encoding: .utf8)
        else { return }
        queueRemoteAnswer(key: LupedMessageKey.presets, name: "PRESETS", value: value)
    }

    func queueRemoteAnswer(key: UInt32, name: String, value: String) {
        // Only Luped Remote asks; once it has closed, nobody waits for the answer.
        guard foreground == .remote else {
            record(.info, "\(name) \(value) not sent: Luped Remote is no longer running")
            return
        }
        pendingRemoteAnswers.removeAll { $0.key == key }
        pendingRemoteAnswers.append((key, name, value))
        sendIfNeeded()
    }

    /// A number for the watch: at most three decimals, without trailing zeros.
    nonisolated static func number(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
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
        if let find = pendingFind, Date().timeIntervalSince(find.requestedAt) > LupedFindRequest.expiry {
            pendingFind = nil
            findNotDelivered("the watch didn't take it within 30 s")
        }
        guard pendingFind != nil || pendingBolusKey != nil || !pendingRemoteAnswers.isEmpty || diagnosticsRequested || !pendingResults.isEmpty || speakerQueryPending, inflightPush == nil, inflightCommand == nil, transport.isSessionOpen else {
            return
        }
        let transactionID = transport.makeTransactionID()
        if let find = pendingFind {
            // First: someone is looking for the watch.
            pendingFind = nil
            inflightFind = find
            inflightCommand = (transactionID, "COMMAND \(find.command)")
            record(.toWatch, "#\(transactionID) COMMAND \(find.command) to \(foreground.name)")
            transport.push(transactionID: transactionID, tuples: [(LupedMessageKey.command, .cString(find.command))])
        } else if let key = pendingBolusKey {
            pendingBolusKey = nil
            // The key itself never goes in a log.
            let label = Self.bolusKeyLabel(bolusAuth.session?.id ?? "")
            inflightCommand = (transactionID, label)
            record(.toWatch, "#\(transactionID) \(label)")
            transport.push(transactionID: transactionID, tuples: [(LupedMessageKey.command, .cString(key))])
        } else if !pendingRemoteAnswers.isEmpty {
            let answer = pendingRemoteAnswers.removeFirst()
            inflightCommand = (transactionID, "\(answer.name) \(answer.value)")
            record(.toWatch, "#\(transactionID) \(answer.name) \(answer.value)")
            transport.push(transactionID: transactionID, tuples: [(answer.key, .cString(answer.value))])
        } else if diagnosticsRequested {
            diagnosticsRequested = false
            inflightCommand = (transactionID, "COMMAND diagnostics")
            record(.toWatch, "#\(transactionID) COMMAND diagnostics")
            transport.push(transactionID: transactionID, tuples: [(LupedMessageKey.command, .cString("diagnostics"))])
        } else if !pendingResults.isEmpty {
            let result = pendingResults.removeFirst()
            inflightCommand = (transactionID, "RESULT \(result)")
            record(.toWatch, "#\(transactionID) RESULT \(result)")
            transport.push(transactionID: transactionID, tuples: [(LupedMessageKey.result, .cString(result))])
        } else {
            // Last: the watchface answers with its speaker report, if it has one.
            speakerQueryPending = false
            inflightCommand = (transactionID, "COMMAND speaker")
            record(.toWatch, "#\(transactionID) COMMAND speaker: asking the watchface whether it has a speaker for the alarm sound")
            transport.push(transactionID: transactionID, tuples: [(LupedMessageKey.command, .cString("speaker"))])
        }

        commandAckTimeout?.cancel()
        commandAckTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PebbleAppMessage.ackTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, let pending = self.inflightCommand, pending.transactionID == transactionID else { return }
            self.record(.error, "#\(transactionID) no reply within \(Int(PebbleAppMessage.ackTimeout)) s")
            self.noteUndelivered(pending.command, "no reply")
            if self.inflightFind != nil {
                self.inflightFind = nil
                self.findNotDelivered("no reply from the watch")
            }
            self.inflightCommand = nil
            if self.moveBackAfterSilence() {
                return
            }
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
            // Its session closed while the other app's is open: the watch would
            // get no reading until that app sends something.
            if let other = openSessions.first {
                switchForeground(to: other, "\(foreground.name)'s session is closed")
                sendIfNeeded(force: true)
                return
            }
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
            if self.moveBackAfterSilence() {
                return
            }
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

    /// The watchface's session; the watch shows it whichever app runs.
    @Published public var link = Link.off
    /// Luped Remote's session (off while it isn't served).
    @Published public var remoteLink = Link.off
    /// The app the phone sends to.
    @Published public var foreground = LupedWatchApp.watchface
    /// When Luped Remote last sent something (it does when it starts), so the
    /// phone knows it is installed: its session alone opens without it.
    @Published public var remoteLastSeen: Date?
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
    /// Where the last Find my Pebble request went, or why it didn't.
    @Published public var findNote: String?
    /// The watch's last speaker report, if a Luped app on it has a speaker.
    @Published public var speaker: LupedWatchSpeaker?
}

/// A watch's `COMMAND speaker:on` or `speaker:quiet`: it has a speaker for the
/// alarm sound, and whether its Quiet Time (which can mute it) is on.
public struct LupedWatchSpeaker: Equatable {
    public var quietTime: Bool
    public var reportedAt: Date

    /// Whether Quiet Time is on, or nil when `command` isn't a speaker report.
    static func quietTime(reportedIn command: String) -> Bool? {
        switch command {
        case "speaker:on": false
        case "speaker:quiet": true
        default: nil
        }
    }
}

/// A Find my Pebble request: how long the watch looks for attention, and when
/// the user asked (a request that can't be sent within `expiry` is dropped, so
/// the watch never starts buzzing long after).
struct LupedFindRequest: Equatable {
    static let expiry: TimeInterval = 30
    var seconds: Int
    var requestedAt: Date

    var command: String { "findpebble:\(seconds)" }
}
