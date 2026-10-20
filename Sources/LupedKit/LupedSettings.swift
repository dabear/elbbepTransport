import Foundation

/// Luped's own settings: whether the watch link is on, which watchface it
/// serves, and how the watch alarms and display behave.
///
/// The host owns persistence. A plugin keeps `rawValue` in its own state; an
/// app can instead keep the settings in `UserDefaults` with
/// `LupedTransport(hostName:defaults:)`.
public struct LupedSettings: Equatable {
    public typealias RawValue = [String: Any]

    public static let defaultWatchfaceUUID = UUID(uuidString: "bf32924c-4839-449e-9e56-ee190249acb2")!

    /// Whether a Pebble has been added; off until then.
    public var isEnabled: Bool
    public var watchfaceUUID: UUID
    /// Watch vibration alarms. The host app's own alerts are unaffected.
    public var alarmsEnabled: Bool
    /// Mutes watch alarms while the host app's alerts are muted.
    public var followAlertMute: Bool
    /// Full-screen glucose ring instead of ring and graph.
    public var fullScreen: Bool

    public init(
        isEnabled: Bool = false,
        watchfaceUUID: UUID = LupedSettings.defaultWatchfaceUUID,
        alarmsEnabled: Bool = true,
        followAlertMute: Bool = true,
        fullScreen: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.watchfaceUUID = watchfaceUUID
        self.alarmsEnabled = alarmsEnabled
        self.followAlertMute = followAlertMute
        self.fullScreen = fullScreen
    }

    /// Restores settings from `rawValue`, using the defaults for missing keys.
    public init(rawValue: RawValue) {
        let defaults = LupedSettings()
        self.init(
            isEnabled: rawValue[UserDefaults.lupedPebbleEnabledKey] as? Bool ?? defaults.isEnabled,
            watchfaceUUID: (rawValue[UserDefaults.lupedPebbleWatchfaceUUIDKey] as? String).flatMap(UUID.init(uuidString:)) ?? defaults.watchfaceUUID,
            alarmsEnabled: rawValue[UserDefaults.lupedPebbleAlarmsEnabledKey] as? Bool ?? defaults.alarmsEnabled,
            followAlertMute: rawValue[UserDefaults.lupedPebbleFollowAlertMuteKey] as? Bool ?? defaults.followAlertMute,
            fullScreen: rawValue[UserDefaults.lupedPebbleFullScreenKey] as? Bool ?? defaults.fullScreen
        )
    }

    public var rawValue: RawValue {
        [
            UserDefaults.lupedPebbleEnabledKey: isEnabled,
            UserDefaults.lupedPebbleWatchfaceUUIDKey: watchfaceUUID.uuidString.lowercased(),
            UserDefaults.lupedPebbleAlarmsEnabledKey: alarmsEnabled,
            UserDefaults.lupedPebbleFollowAlertMuteKey: followAlertMute,
            UserDefaults.lupedPebbleFullScreenKey: fullScreen,
        ]
    }
}

/// Settings → Devices → Pebble kept in `UserDefaults`. The property names equal
/// the defaults keys so they can be observed with KVO.
public extension UserDefaults {
    static let lupedPebbleEnabledKey = "lupedPebbleEnabled"
    static let lupedPebbleWatchfaceUUIDKey = "lupedPebbleWatchfaceUUID"
    static let lupedPebbleAlarmsEnabledKey = "lupedPebbleAlarmsEnabled"
    static let lupedPebbleFollowAlertMuteKey = "lupedPebbleFollowAlertMute"
    static let lupedPebbleFullScreenKey = "lupedPebbleFullScreen"
    static let lupedDefaultWatchfaceUUID = LupedSettings.defaultWatchfaceUUID.uuidString.lowercased()

    /// The Luped settings stored in these defaults.
    var lupedSettings: LupedSettings {
        LupedSettings(
            isEnabled: lupedPebbleEnabled,
            watchfaceUUID: lupedPebbleWatchfaceUUIDValue,
            alarmsEnabled: lupedPebbleAlarmsEnabled,
            followAlertMute: lupedPebbleFollowAlertMute,
            fullScreen: lupedPebbleFullScreen
        )
    }

    /// Whether a Pebble has been added in Settings → Devices; off until then.
    @objc dynamic var lupedPebbleEnabled: Bool {
        bool(forKey: Self.lupedPebbleEnabledKey)
    }

    /// Deletes the Pebble device: stops the transport and resets its settings.
    func deleteLupedPebble() {
        set(false, forKey: Self.lupedPebbleEnabledKey)
        removeObject(forKey: Self.lupedPebbleAlarmsEnabledKey)
        removeObject(forKey: Self.lupedPebbleFollowAlertMuteKey)
        removeObject(forKey: Self.lupedPebbleFullScreenKey)
        removeObject(forKey: Self.lupedPebbleWatchfaceUUIDKey)
    }

    /// Watch vibration alarms, on unless the user turned them off. The host
    /// app's own alerts are unaffected.
    @objc dynamic var lupedPebbleAlarmsEnabled: Bool {
        object(forKey: Self.lupedPebbleAlarmsEnabledKey) as? Bool ?? true
    }

    /// Mutes watch alarms while the host app's alerts are muted; on unless the
    /// user turned it off.
    @objc dynamic var lupedPebbleFollowAlertMute: Bool {
        object(forKey: Self.lupedPebbleFollowAlertMuteKey) as? Bool ?? true
    }

    /// Full-screen glucose ring instead of ring and graph; off by default.
    @objc dynamic var lupedPebbleFullScreen: Bool {
        bool(forKey: Self.lupedPebbleFullScreenKey)
    }

    @objc dynamic var lupedPebbleWatchfaceUUID: String {
        string(forKey: Self.lupedPebbleWatchfaceUUIDKey) ?? Self.lupedDefaultWatchfaceUUID
    }

    var lupedPebbleWatchfaceUUIDValue: UUID {
        UUID(uuidString: lupedPebbleWatchfaceUUID) ?? LupedSettings.defaultWatchfaceUUID
    }
}
