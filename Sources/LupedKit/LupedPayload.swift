import Foundation

/// A glucose display unit.
public enum LupedUnit: Equatable {
    case milligramsPerDeciliter
    case millimolesPerLiter

    /// mg/dL per mmol/L, from the molar mass of glucose (180.15588 g/mol).
    static let milligramsPerDeciliterPerMillimolePerLiter = 180.1558800000541 / 10

    func value(fromMilligramsPerDeciliter mgdl: Double) -> Double {
        self == .millimolesPerLiter ? mgdl / Self.milligramsPerDeciliterPerMillimolePerLiter : mgdl
    }
}

/// A CGM trend, in Luped's direction order (`DATA` index 3).
public enum LupedTrend: Int, CaseIterable {
    case doubleDown = 0, singleDown, fortyFiveDown, flat, fortyFiveUp, singleUp, doubleUp
}

/// One CGM reading.
public struct LupedReading: Equatable {
    public var date: Date
    public var milligramsPerDeciliter: Double
    /// The CGM's own trend, if it reports one.
    public var trend: LupedTrend?

    public init(date: Date, milligramsPerDeciliter: Double, trend: LupedTrend?) {
        self.date = date
        self.milligramsPerDeciliter = milligramsPerDeciliter
        self.trend = trend
    }
}

/// Glucose alarm settings mirrored to the Luped watchface from the host app's
/// active glucose alert settings.
public struct LupedAlarmSettings: Equatable {
    /// Luped's alarm-enable bitmask (`DATA` index 9). Older Luped builds read
    /// any non-zero value as "all alarms on".
    static let urgentLowBit = 1
    static let lowBit = 2
    static let highBit = 4

    /// A repeat interval long enough that the watch alarms once per episode;
    /// Luped re-arms when glucose returns to range.
    static let oncePerEpisode: TimeInterval = 24 * 60 * 60

    var urgentLowMgDL: Double
    var lowMgDL: Double
    var highMgDL: Double
    var enabledMask: Int
    var urgentLowRepeat: TimeInterval
    var lowRepeat: TimeInterval
    var highRepeat: TimeInterval
    /// End of the host's alert mute while it silences the watch. The mask is
    /// sent as `0` until then and restored when the mute ends.
    var mutedUntil: Date? = nil

    /// Display-only defaults with alarms off, used without alert settings.
    static let disabled = LupedAlarmSettings(
        urgentLowMgDL: 55,
        lowMgDL: 80,
        highMgDL: 200,
        enabledMask: 0,
        urgentLowRepeat: oncePerEpisode,
        lowRepeat: oncePerEpisode,
        highRepeat: oncePerEpisode
    )
}

/// The AppMessage `DATA` value understood by the Luped watchface.
///
/// Values are deliberately constructed from stored glucose samples rather than
/// CGM-manager-specific display state, so every supported CGM follows the same
/// path and a restarted app can restore the watchface from persisted history.
public struct LupedPayload: Equatable {
    /// History needed to fill the watchface graph at a 5-minute CGM cadence.
    public static let historyInterval: TimeInterval = 2 * 60 * 60

    /// Readings further apart than this are not used for delta or computed trend.
    private static let maximumDeltaInterval: TimeInterval = 15 * 60

    let data: String
    /// Start date of the latest reading, for diagnostics.
    let latestDate: Date
    /// Number of readings in the history graph, for diagnostics.
    let readingCount: Int
    /// One line for the communication log, e.g. "7.0 mmol/L ↓ -0.2 at 11:15:02".
    let logSummary: String
    /// Aligned label/value lines under the summary, ending with the raw `DATA` JSON.
    let logDetails: String

    /// Indexed by the protocol's direction value (DoubleDown … DoubleUp).
    private static let trendArrows = ["⇊", "↓", "↘", "→", "↗", "↑", "⇈"]

    init?(readings: [LupedReading], unit: LupedUnit, alarms: LupedAlarmSettings, fullScreen: Bool, hostAlertLevel: Int = 0) {
        let readings = readings
            .sorted { $0.date < $1.date }
            .suffix(12)
        guard let latest = readings.last else {
            return nil
        }

        let values = readings.map { reading in
            Self.rounded(unit.value(fromMilligramsPerDeciliter: reading.milligramsPerDeciliter), for: unit)
        }
        let previous = Self.previousReading(in: readings)
        let delta = previous.map { unit.value(fromMilligramsPerDeciliter: latest.milligramsPerDeciliter) - unit.value(fromMilligramsPerDeciliter: $0.milligramsPerDeciliter) } ?? 0
        let direction = latest.trend?.rawValue ?? Self.directionIndex(from: previous, to: latest)
        func converted(_ milligramsPerDeciliter: Double) -> NSDecimalNumber {
            Self.rounded(unit.value(fromMilligramsPerDeciliter: milligramsPerDeciliter), for: unit)
        }
        func minutes(_ interval: TimeInterval) -> Int {
            max(1, Int((interval / 60).rounded()))
        }
        let timestamp = Int64(latest.date.timeIntervalSince1970 * 1_000)

        let unitName = unit == .millimolesPerLiter ? "mmol/L" : "mg/dL"
        let zones = [
            (LupedAlarmSettings.urgentLowBit, "urgent low"),
            (LupedAlarmSettings.lowBit, "low"),
            (LupedAlarmSettings.highBit, "high"),
        ].filter { alarms.enabledMask & $0.0 != 0 }.map(\.1)
        var alarmDescription = "watch alarms \(zones.isEmpty ? "off" : zones.joined(separator: ", "))"
        if let mutedUntil = alarms.mutedUntil {
            alarmDescription += " · muted until \(DateFormatter.localizedString(from: mutedUntil, dateStyle: .none, timeStyle: .short))"
        }

        // Each DATA field paired with the description shown under the summary in
        // the communication log, so the wire format and its decode share one
        // definition and cannot drift apart.
        let fields: [(value: Any, description: String)] = [
            (1, "protocol version"),
            (values[values.count - 1], "current glucose (\(unitName))"),
            (Self.rounded(delta, for: unit), "delta (\(unitName))"),
            (direction, "trend code \(Self.trendArrows[direction])"),
            (values, "glucose history (\(values.count) readings)"),
            (unit == .millimolesPerLiter ? 1 : 0, "\(unitName) display"),
            (converted(alarms.urgentLowMgDL), "urgent-low threshold (\(unitName))"),
            (converted(alarms.lowMgDL), "low threshold (\(unitName))"),
            (converted(alarms.highMgDL), "high threshold (\(unitName))"),
            (alarms.enabledMask, alarmDescription),
            (minutes(alarms.lowRepeat), "low repeat interval (minutes)"),
            (minutes(alarms.highRepeat), "high repeat interval (minutes)"),
            (timestamp, "timestamp (milliseconds since Unix epoch)"),
            (fullScreen ? 1 : 0, fullScreen ? "full-screen ring" : "ring with graph"),
            (minutes(alarms.urgentLowRepeat), "urgent-low repeat interval (minutes)"),
            (hostAlertLevel, "host-issued alert level: \(Self.alertLevelNames[hostAlertLevel] ?? "unknown")"),
        ]
        let message = fields.map(\.value)

        guard JSONSerialization.isValidJSONObject(message),
              let encoded = try? JSONSerialization.data(withJSONObject: message),
              let data = String(data: encoded, encoding: .utf8)
        else {
            return nil
        }

        self.data = data
        self.latestDate = latest.date
        self.readingCount = readings.count

        let time = DateFormatter.localizedString(from: latest.date, dateStyle: .none, timeStyle: .medium)
        let roundedDelta = Self.rounded(delta, for: unit)
        let deltaText = (roundedDelta.doubleValue > 0 ? "+" : "") + roundedDelta.stringValue
        self.logSummary = "\(values[values.count - 1].stringValue) \(unitName) \(Self.trendArrows[direction]) \(deltaText) at \(time)"
        self.logDetails = Self.decodeTable(fields)
    }

    /// Indented "label  value" lines with the labels padded to one width, for the
    /// monospaced communication log.
    static func alignedRows(_ rows: [(label: String, value: String)]) -> String {
        let width = rows.map(\.label.count).max() ?? 0
        return rows
            .map { "  " + $0.label.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + $0.value }
            .joined(separator: "\n")
    }

    /// The raw `DATA` array decoded one field per line for the communication log,
    /// `index:  value  description`, values left-aligned in a single column so the
    /// descriptions line up.
    static func decodeTable(_ fields: [(value: Any, description: String)]) -> String {
        let values = fields.map { Self.displayString(for: $0.value) }
        let width = values.map(\.count).max() ?? 0
        let rows = fields.indices.map { index -> String in
            let value = values[index].padding(toLength: width, withPad: " ", startingAt: 0)
            return String(format: "  %2d:  ", index) + value + "  " + fields[index].description
        }
        return "raw [\n" + rows.joined(separator: "\n") + "\n]"
    }

    /// A compact display string for one `DATA` value. The history array is
    /// abbreviated to its first two and last readings so the value column stays narrow.
    private static func displayString(for value: Any) -> String {
        switch value {
        case let number as NSDecimalNumber:
            return number.stringValue
        case let array as [NSDecimalNumber]:
            let parts = array.map(\.stringValue)
            guard parts.count > 4 else { return "[" + parts.joined(separator: ", ") + "]" }
            return "[\(parts[0]), \(parts[1]), …, \(parts[parts.count - 1])]"
        case let value as Int64:
            return String(value)
        case let value as Int:
            return String(value)
        default:
            return String(describing: value)
        }
    }

    /// Names for the host-issued alert level carried in `DATA` index 15.
    private static let alertLevelNames: [Int: String] = [0: "none", 1: "info", 2: "warning", 3: "critical"]

    /// Rounds to the watchface's display precision: one decimal for mmol/L, whole mg/dL.
    ///
    /// `NSDecimalNumber` serializes exactly ("7.9"), whereas a `Double` would
    /// carry binary noise into the JSON ("7.9000000000000004").
    private static func rounded(_ value: Double, for unit: LupedUnit) -> NSDecimalNumber {
        let behavior = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: unit == .millimolesPerLiter ? 1 : 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        return NSDecimalNumber(value: value).rounding(accordingToBehavior: behavior)
    }

    /// The reading before the latest, if it is recent enough to compare against.
    private static func previousReading(in readings: ArraySlice<LupedReading>) -> LupedReading? {
        guard readings.count > 1,
              let previous = readings.dropLast().last,
              let latest = readings.last,
              latest.date.timeIntervalSince(previous.date) <= maximumDeltaInterval
        else {
            return nil
        }
        return previous
    }

    /// Fallback for CGMs that do not report a trend.
    private static func directionIndex(from previous: LupedReading?, to latest: LupedReading) -> Int {
        guard let previous else {
            return 3 // Flat
        }

        let elapsedMinutes = latest.date.timeIntervalSince(previous.date) / 60
        guard elapsedMinutes > 0 else {
            return 3
        }

        let rate = (latest.milligramsPerDeciliter - previous.milligramsPerDeciliter) / elapsedMinutes

        switch rate {
        case ...(-3): return 0 // DoubleDown
        case ...(-2): return 1 // SingleDown
        case ...(-1): return 2 // FortyFiveDown
        case ..<1: return 3 // Flat
        case ..<2: return 4 // FortyFiveUp
        case ..<3: return 5 // SingleUp
        default: return 6 // DoubleUp
        }
    }
}
