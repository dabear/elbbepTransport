import Foundation

/// Luped's own settings: whether the watch link is on, which watchface it
/// serves, whether Luped Remote is served too, and how the watch alarms and
/// display behave.
///
/// The host owns persistence: a plugin keeps `rawValue` in its own state.
public struct LupedSettings: Equatable {
    public typealias RawValue = [String: Any]

    /// The `rawValue` keys.
    private enum Key {
        static let enabled = "lupedPebbleEnabled"
        static let watchfaceUUID = "lupedPebbleWatchfaceUUID"
        static let alarmsEnabled = "lupedPebbleAlarmsEnabled"
        static let fullScreen = "lupedPebbleFullScreen"
        static let statusLine = "lupedPebbleStatusLine"
        static let loopRing = "lupedPebbleLoopRing"
        static let remoteEnabled = "lupedPebbleRemoteEnabled"
        static let remoteUUID = "lupedPebbleRemoteUUID"
    }

    public static let defaultWatchfaceUUID = UUID(uuidString: "bf32924c-4839-449e-9e56-ee190249acb2")!
    /// Luped Remote, the watchapp that shows the same reading and sends the
    /// watchface's requests from its buttons.
    public static let defaultRemoteUUID = UUID(uuidString: "738255f4-b58b-41cd-a7ae-27fc80e81fcb")!

    /// Whether a Pebble has been added; off until then.
    public var isEnabled: Bool
    public var watchfaceUUID: UUID
    /// Watch vibration alarms. The host app's own alerts are unaffected.
    public var alarmsEnabled: Bool
    /// The Large Glucose layout (a full-screen glucose ring) instead of Graph.
    /// It has no graph, status line or loop ring, so it needs only readings.
    public var fullScreen: Bool
    /// What the left of the watch's status strip shows.
    public var statusLine: LupedStatusLine
    /// Last Loop: the watch's loop ring (minutes since the last loop, closed or
    /// open) while the status line is None. Every shown line needs the loop's
    /// age, which dims the line when the loop is stale, so the ring is always on
    /// then.
    public var loopRing: Bool
    /// Luped Remote gets its own watch session next to the watchface's. Its
    /// requests are the watchface's, so the host's own switches decide them.
    /// Off by default: Luped Remote is a separate watchapp the user installs.
    public var remoteEnabled: Bool
    /// The remote's app UUID, like `watchfaceUUID` for a build of its own.
    public var remoteUUID: UUID

    public init(
        isEnabled: Bool = false,
        watchfaceUUID: UUID = LupedSettings.defaultWatchfaceUUID,
        alarmsEnabled: Bool = true,
        fullScreen: Bool = false,
        statusLine: LupedStatusLine = .iobAndCob,
        loopRing: Bool = true,
        remoteEnabled: Bool = false,
        remoteUUID: UUID = LupedSettings.defaultRemoteUUID
    ) {
        self.isEnabled = isEnabled
        self.watchfaceUUID = watchfaceUUID
        self.alarmsEnabled = alarmsEnabled
        self.fullScreen = fullScreen
        self.statusLine = statusLine
        self.loopRing = loopRing
        self.remoteEnabled = remoteEnabled
        self.remoteUUID = remoteUUID
    }

    /// Whether Luped Remote gets a watch session: it's on, and its UUID isn't
    /// the watchface's (one UUID can have only one session).
    public var servesRemote: Bool {
        isEnabled && remoteEnabled && remoteUUID != watchfaceUUID
    }

    /// The status line the watch shows: none with Large Glucose, which has no
    /// strip. The chosen `statusLine` is kept for when Graph is chosen again.
    public var shownStatusLine: LupedStatusLine { fullScreen ? .none : statusLine }

    /// Whether the watch shows the loop ring: never with Large Glucose; otherwise
    /// always with a status line, and with None only while `loopRing` is on.
    public var showsLoopRing: Bool { !fullScreen && (statusLine != .none || loopRing) }

    /// Whether the watch needs the loop status (`DATA` 10–13) from the host.
    public var needsLoopStatus: Bool { showsLoopRing }

    /// Whether the host should supply the loop status: for the watchface's
    /// choices, or for Luped Remote, which always shows it.
    public var hostNeedsLoopStatus: Bool { needsLoopStatus || remoteEnabled }

    /// The display choices Luped Remote is sent with, whatever the watchface
    /// shows: IOB, COB and the loop's age and mode, for its main screen and its
    /// bolus and carbs confirmations.
    var remote: LupedSettings {
        var settings = self
        settings.fullScreen = false
        settings.statusLine = .iobAndCob
        settings.loopRing = true
        return settings
    }

    /// Whether the status line is formatted from the host's therapy values.
    public var needsTherapy: Bool { shownStatusLine.needsTherapy }

    /// The part of `status` the watch gets: the loop's age and mode (12–13) while
    /// the loop ring shows, and IOB and COB (10–11) only for the IOB & COB line,
    /// the only line the watch formats from them. Everything else is `null`.
    public func loopStatusToSend(_ status: LupedLoopStatus?) -> LupedLoopStatus? {
        guard needsLoopStatus, var status else { return nil }
        if shownStatusLine != .iobAndCob {
            status.insulinOnBoard = nil
            status.carbsOnBoard = nil
        }
        return status
    }

    /// Restores settings from `rawValue`, using the defaults for missing keys.
    public init(rawValue: RawValue) {
        let defaults = LupedSettings()
        self.init(
            isEnabled: rawValue[Key.enabled] as? Bool ?? defaults.isEnabled,
            watchfaceUUID: (rawValue[Key.watchfaceUUID] as? String).flatMap(UUID.init(uuidString:)) ?? defaults.watchfaceUUID,
            alarmsEnabled: rawValue[Key.alarmsEnabled] as? Bool ?? defaults.alarmsEnabled,
            fullScreen: rawValue[Key.fullScreen] as? Bool ?? defaults.fullScreen,
            statusLine: (rawValue[Key.statusLine] as? String).flatMap(LupedStatusLine.init(rawValue:)) ?? defaults.statusLine,
            loopRing: rawValue[Key.loopRing] as? Bool ?? defaults.loopRing,
            remoteEnabled: rawValue[Key.remoteEnabled] as? Bool ?? defaults.remoteEnabled,
            remoteUUID: (rawValue[Key.remoteUUID] as? String).flatMap(UUID.init(uuidString:)) ?? defaults.remoteUUID
        )
    }

    public var rawValue: RawValue {
        [
            Key.enabled: isEnabled,
            Key.watchfaceUUID: watchfaceUUID.uuidString.lowercased(),
            Key.alarmsEnabled: alarmsEnabled,
            Key.fullScreen: fullScreen,
            Key.statusLine: statusLine.rawValue,
            Key.loopRing: loopRing,
            Key.remoteEnabled: remoteEnabled,
            Key.remoteUUID: remoteUUID.uuidString.lowercased(),
        ]
    }
}

/// What the left of the watch's status strip shows: nothing, IOB and COB (the
/// watch formats them and dims them when the loop is stale), or a line the phone
/// formats from the host's therapy values in the display unit.
///
/// Only what the choice needs goes to the watch; the rest of `DATA` 10–14 is
/// `null`, and a host needn't supply it (see `LupedSettings.needsLoopStatus` and
/// `needsTherapy`, which also account for the loop ring).
public enum LupedStatusLine: String, CaseIterable, Equatable {
    /// An empty strip; with Last Loop off too, `DATA` 10–14 are all `null`.
    case none
    case iobAndCob
    case tempBasal
    case eventualGlucose
    case sensitivityAndTarget

    /// The choice's name in the communication log.
    public var displayName: String {
        switch self {
        case .none: "None"
        case .iobAndCob: "IOB & COB"
        case .tempBasal: "Temp Basal"
        case .eventualGlucose: "Eventual Glucose"
        case .sensitivityAndTarget: "ISF & Target"
        }
    }

    /// Whether the line is formatted from the host's therapy values.
    public var needsTherapy: Bool {
        switch self {
        case .tempBasal, .eventualGlucose, .sensitivityAndTarget: true
        case .none, .iobAndCob: false
        }
    }
}
