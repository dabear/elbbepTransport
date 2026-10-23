import Foundation

/// A host app's active glucose alert settings, in mg/dL.
public struct LupedAlertConfiguration: Equatable {
    public var urgentLowMgDL: Double
    public var lowMgDL: Double
    public var highMgDL: Double
    public var urgentLowEnabled: Bool
    public var lowEnabled: Bool
    public var highEnabled: Bool
    public var urgentLowRepeat: TimeInterval
    /// `nil` when the host alerts once per low episode.
    public var lowRepeat: TimeInterval?
    /// `nil` when the host alerts once per high episode.
    public var highRepeat: TimeInterval?

    public init(
        urgentLowMgDL: Double, lowMgDL: Double, highMgDL: Double,
        urgentLowEnabled: Bool, lowEnabled: Bool, highEnabled: Bool,
        urgentLowRepeat: TimeInterval, lowRepeat: TimeInterval?, highRepeat: TimeInterval?
    ) {
        self.urgentLowMgDL = urgentLowMgDL
        self.lowMgDL = lowMgDL
        self.highMgDL = highMgDL
        self.urgentLowEnabled = urgentLowEnabled
        self.lowEnabled = lowEnabled
        self.highEnabled = highEnabled
        self.urgentLowRepeat = urgentLowRepeat
        self.lowRepeat = lowRepeat
        self.highRepeat = highRepeat
    }
}

/// What the host app knows about its glucose alerts right now.
public struct LupedAlertState: Equatable {
    /// `nil` when the host has no glucose alert settings to mirror.
    public var configuration: LupedAlertConfiguration?
    /// `false` while the host leaves glucose alerts to the CGM's own alerts.
    public var hostAlertsActive: Bool
    /// When the host's alert mute ends, if its alerts are muted now.
    public var hostMuteEnd: Date?

    public init(configuration: LupedAlertConfiguration?, hostAlertsActive: Bool, hostMuteEnd: Date?) {
        self.configuration = configuration
        self.hostAlertsActive = hostAlertsActive
        self.hostMuteEnd = hostMuteEnd
    }
}

extension LupedAlarmSettings {
    /// Mirrors the host's active glucose alert settings. All watch alarms are
    /// off while the host defers glucose alerts to the CGM's own alerts, or
    /// when the user turned off watch alarms, and until a followed host alert
    /// mute ends.
    init(_ alerts: LupedAlertState, watchAlarmsEnabled: Bool, followHostMute: Bool) {
        guard let configuration = alerts.configuration else {
            self = .disabled
            return
        }
        var mask = 0
        if alerts.hostAlertsActive, watchAlarmsEnabled {
            if configuration.urgentLowEnabled { mask |= Self.urgentLowBit }
            if configuration.lowEnabled { mask |= Self.lowBit }
            if configuration.highEnabled { mask |= Self.highBit }
        }
        let mutedUntil = followHostMute ? alerts.hostMuteEnd : nil
        let muted = mask != 0 && mutedUntil != nil
        self.init(
            urgentLowMgDL: configuration.urgentLowMgDL,
            lowMgDL: configuration.lowMgDL,
            highMgDL: configuration.highMgDL,
            enabledMask: muted ? 0 : mask,
            urgentLowRepeat: configuration.urgentLowRepeat,
            lowRepeat: configuration.lowRepeat ?? Self.oncePerEpisode,
            highRepeat: configuration.highRepeat ?? Self.oncePerEpisode,
            mutedUntil: muted ? mutedUntil : nil
        )
    }

    /// Whether the watch alarms are on, for the communication log. The host issues
    /// the alerts itself (DATA index 15) and applies its own alert mute, so the only
    /// control on the watch is the user's Watch Alarms switch — that is all this reports.
    static func status(watchAlarmsEnabled: Bool) -> String {
        watchAlarmsEnabled ? "Watch alarms on" : "Watch alarms off: Watch Alarms is turned off"
    }
}
