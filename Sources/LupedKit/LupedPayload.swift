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
    /// Each `DATA` field with its meaning, one per line, for the communication log.
    let fieldDescription: String

    private static let directionNames = ["DoubleDown", "SingleDown", "FortyFiveDown", "Flat", "FortyFiveUp", "SingleUp", "DoubleUp"]

    init?(readings: [LupedReading], unit: LupedUnit, alarms: LupedAlarmSettings, fullScreen: Bool) {
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

        let message: [Any] = [
            1,
            values[values.count - 1],
            Self.rounded(delta, for: unit),
            direction,
            values,
            unit == .millimolesPerLiter ? 1 : 0,
            converted(alarms.urgentLowMgDL),
            converted(alarms.lowMgDL),
            converted(alarms.highMgDL),
            alarms.enabledMask,
            minutes(alarms.lowRepeat),
            minutes(alarms.highRepeat),
            timestamp,
            fullScreen ? 1 : 0,
            minutes(alarms.urgentLowRepeat)
        ]

        guard JSONSerialization.isValidJSONObject(message),
              let encoded = try? JSONSerialization.data(withJSONObject: message),
              let data = String(data: encoded, encoding: .utf8)
        else {
            return nil
        }

        self.data = data
        self.latestDate = latest.date
        self.readingCount = readings.count

        func repeatText(_ interval: TimeInterval) -> String {
            interval >= LupedAlarmSettings.oncePerEpisode ? "once per episode" : "\(minutes(interval)) min"
        }
        let unitName = unit == .millimolesPerLiter ? "mmol/L" : "mg/dL"
        let zones = [
            (LupedAlarmSettings.urgentLowBit, "urgent low"),
            (LupedAlarmSettings.lowBit, "low"),
            (LupedAlarmSettings.highBit, "high"),
        ].filter { alarms.enabledMask & $0.0 != 0 }.map(\.1)
        let time = DateFormatter.localizedString(from: latest.date, dateStyle: .none, timeStyle: .medium)
        self.fieldDescription = [
            " 0 protocol version: 1",
            " 1 glucose: \(values[values.count - 1].stringValue) \(unitName)",
            " 2 delta: \(Self.rounded(delta, for: unit).stringValue)",
            " 3 trend: \(Self.directionNames[direction])",
            " 4 history: \(values.count) readings, oldest first: \(values.map(\.stringValue).joined(separator: " "))",
            " 5 unit: \(unitName)",
            " 6-8 thresholds: urgent low \(converted(alarms.urgentLowMgDL).stringValue), low \(converted(alarms.lowMgDL).stringValue), high \(converted(alarms.highMgDL).stringValue)",
            " 9 alarms (mask \(alarms.enabledMask)): \(zones.isEmpty ? "off" : zones.joined(separator: ", "))\(alarms.mutedUntil.map { ", muted until \(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short))" } ?? "")",
            "10-11 repeat: low \(repeatText(alarms.lowRepeat)), high \(repeatText(alarms.highRepeat))",
            "12 reading time: \(time) (\(timestamp))",
            "13 display: \(fullScreen ? "full-screen ring" : "ring with graph")",
            "14 urgent-low repeat: \(repeatText(alarms.urgentLowRepeat))",
        ].joined(separator: "\n")
    }

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
