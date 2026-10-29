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

/// The AppMessage `DATA` value understood by the Luped watchface.
///
/// Values are deliberately constructed from stored glucose samples rather than
/// CGM-manager-specific display state, so every supported CGM follows the same
/// path and a restarted app can restore the watchface from persisted history.
public struct LupedPayload: Equatable {
    /// History needed to fill the watchface graph at a 5-minute CGM cadence.
    public static let historyInterval: TimeInterval = 2 * 60 * 60

    /// The watch draws history values 5 minutes apart, so readings from a CGM
    /// with a faster cadence (1-minute readings) are thinned to one about every
    /// 5 minutes. The margin keeps every reading of a 5-minute CGM whose
    /// timestamps jitter by a few seconds.
    static let graphSpacing: TimeInterval = 4.5 * 60

    /// Readings further apart than this are not used for delta or computed trend.
    private static let maximumDeltaInterval: TimeInterval = 15 * 60

    let data: String
    /// `DATA` indexes 0–9 (glucose, history, display, alerts) without the loop
    /// status and status line, so the transport can tell a loop-only change apart.
    let coreData: String
    /// Start date of the latest reading; the send timing compares it with the loop result.
    let latestDate: Date
    /// The loop status's last loop completed time (`DATA` 12), if sent. Later
    /// than `latestDate` once the loop has run on that reading.
    let lastLoopCompleted: Date?
    /// Number of history readings sent (index 4), for diagnostics. `0` in
    /// the Large Glucose layout, which has no graph.
    let readingCount: Int
    /// The host alert level (index 8) and alert event (index 9) sent, so the
    /// transport can check the watch's buzz records against them.
    let hostAlertState: Int
    let alertEvent: Int
    /// One line for the communication log, e.g. "7.0 mmol/L ↓ -0.2 at 11:15:02".
    let logSummary: String
    /// Aligned label/value lines under the summary, ending with the raw `DATA` JSON.
    let logDetails: String

    /// Indexed by the protocol's direction value (DoubleDown … DoubleUp).
    private static let trendArrows = ["⇊", "↓", "↘", "→", "↗", "↑", "⇈"]

    /// The status-strip text for `choice`, formatted in the display unit. ISF &
    /// target is too long for the space before the glucose ring, so it is sent as
    /// "ISF\ttarget": the watch puts the target between the ring and the CGM time.
    /// `nil` for none, for IOB and COB (the watch formats those), or when the host
    /// sent nothing to show.
    public static func statusLine(_ choice: LupedStatusLine, therapy: LupedTherapy?, unit: LupedUnit) -> String? {
        let glucose = { (mgdl: Double) -> String in
            unit == .millimolesPerLiter ? String(format: "%.1f", unit.value(fromMilligramsPerDeciliter: mgdl)) : String(format: "%.0f", mgdl)
        }
        switch choice {
        case .none, .iobAndCob:
            return nil
        case .tempBasal:
            if let temp = therapy?.tempBasalRate { return String(format: "Temp %.2f U/h", temp) }
            return therapy?.scheduledBasalRate.map { String(format: "Basal %.2f U/h", $0) }
        case .eventualGlucose:
            return therapy?.eventualGlucose.map { "Eventual " + glucose($0) }
        case .sensitivityAndTarget:
            let isf = therapy?.insulinSensitivity.map { "ISF " + glucose($0) } ?? ""
            let target = therapy?.correctionRange.map { glucose($0.lowerBound) + "–" + glucose($0.upperBound) } ?? ""
            return isf.isEmpty && target.isEmpty ? nil : isf + "\t" + target
        }
    }

    /// Why a loop status field is `null`, for the log decode.
    static func notSent(insulinAndCarbs: Bool, settings: LupedSettings) -> String {
        if settings.fullScreen {
            return " (not sent: Layout is Large Glucose)"
        }
        if insulinAndCarbs, settings.statusLine != .iobAndCob {
            return " (not sent: Status Line is \(settings.statusLine.displayName))"
        }
        if !insulinAndCarbs, !settings.needsLoopStatus {
            return " (not sent: Status Line is None and Last Loop is off)"
        }
        return " (not provided by the host)"
    }

    /// The log description of `DATA` index 14.
    static func statusLineDescription(_ line: String?, settings: LupedSettings) -> String {
        if line != nil { return "status line" }
        if settings.fullScreen { return "status line: none (Layout is Large Glucose)" }
        switch settings.statusLine {
        case .none: return "status line: none (Status Line is None)"
        case .iobAndCob: return "status line: IOB and COB, formatted on the watch"
        default: return "status line: empty (the host provided no \(settings.statusLine.displayName) value)"
        }
    }

    /// `alertEvent` changes each time the host fires a glucose alert (the first
    /// fire and every repeat), so the watch can buzz on a repeat even though the
    /// alert level stays the same.
    /// `settings` lets the log decode say why a loop status or status line field is
    /// `null`: the user's Layout, Status Line and Last Loop choices, or a value the host
    /// didn't provide.
    init?(readings: [LupedReading], unit: LupedUnit, fullScreen: Bool, hostAlertState: Int = 0, hostAlertReason: String? = nil, alertEvent: Int = 0, loopStatus: LupedLoopStatus? = nil, statusLine: String? = nil, settings: LupedSettings = LupedSettings()) {
        let readings = Self.graphReadings(readings, limit: 12)
        guard let latest = readings.last else {
            return nil
        }

        let values = readings.map { reading in
            Self.rounded(unit.value(fromMilligramsPerDeciliter: reading.milligramsPerDeciliter), for: unit)
        }
        let previous = Self.previousReading(in: readings)
        let delta = previous.map { unit.value(fromMilligramsPerDeciliter: latest.milligramsPerDeciliter) - unit.value(fromMilligramsPerDeciliter: $0.milligramsPerDeciliter) } ?? 0
        let direction = latest.trend?.rawValue ?? Self.directionIndex(from: previous, to: latest)
        let timestamp = Int64(latest.date.timeIntervalSince1970 * 1_000)
        // Large Glucose has no graph, so it gets no history. Switching back to
        // Graph sends a new DATA right away, which brings the history back.
        let history = fullScreen ? [] : values
        let unitName = unit == .millimolesPerLiter ? "mmol/L" : "mg/dL"

        // Each DATA field paired with the description shown under the summary in the
        // communication log, so the wire format and its decode share one definition
        // and cannot drift apart. Alerts are host-issued (index 8), and the watch
        // colours its ring from that, so no thresholds travel.
        let fields: [(value: Any, description: String)] = [
            (1, "protocol version"),
            (values[values.count - 1], "current glucose (\(unitName))"),
            (Self.rounded(delta, for: unit), "delta (\(unitName))"),
            (direction, "trend code \(Self.trendArrows[direction])"),
            (history, fullScreen ? "glucose history (not sent: Large Glucose has no graph)" : "glucose history (\(history.count) readings)"),
            (unit == .millimolesPerLiter ? 1 : 0, "\(unitName) display"),
            (timestamp, "timestamp (milliseconds since Unix epoch)"),
            (fullScreen ? 1 : 0, fullScreen ? "layout: Large Glucose" : "layout: Graph"),
            (hostAlertState, "host alert: \(Self.alertStateName(hostAlertState))" + (hostAlertReason.map { " (\($0))" } ?? "")),
            (alertEvent, "alert event (changes each time the host fires an alert)"),
            // Loop status for the watch's IOB/COB and loop ring; null when not sent.
            (loopStatus?.insulinOnBoard.map { Self.rounded($0, scale: 1) } ?? NSNull(), loopStatus?.insulinOnBoard != nil ? "insulin on board (U)" : "insulin on board" + Self.notSent(insulinAndCarbs: true, settings: settings)),
            (loopStatus?.carbsOnBoard.map { Self.rounded($0, scale: 0) } ?? NSNull(), loopStatus?.carbsOnBoard != nil ? "carbs on board (g)" : "carbs on board" + Self.notSent(insulinAndCarbs: true, settings: settings)),
            (loopStatus?.lastLoopCompleted.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? NSNull(), loopStatus?.lastLoopCompleted != nil ? "last loop completed (milliseconds since Unix epoch)" : "last loop completed" + Self.notSent(insulinAndCarbs: false, settings: settings)),
            (loopStatus?.isClosedLoop.map { $0 ? 1 : 0 } ?? NSNull(), loopStatus?.isClosedLoop.map { $0 ? "closed loop" : "open loop" } ?? "closed or open loop" + Self.notSent(insulinAndCarbs: false, settings: settings)),
            (statusLine ?? NSNull(), Self.statusLineDescription(statusLine, settings: settings)),
        ]
        let message = fields.map(\.value)

        guard JSONSerialization.isValidJSONObject(message),
              let encoded = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes),
              let data = String(data: encoded, encoding: .utf8)
        else {
            return nil
        }

        self.data = data
        self.lastLoopCompleted = loopStatus?.lastLoopCompleted
        self.coreData = (try? JSONSerialization.data(withJSONObject: Array(message.prefix(10)))).flatMap { String(data: $0, encoding: .utf8) } ?? data
        self.latestDate = latest.date
        self.readingCount = history.count
        self.hostAlertState = hostAlertState
        self.alertEvent = alertEvent

        let time = DateFormatter.localizedString(from: latest.date, dateStyle: .none, timeStyle: .medium)
        let roundedDelta = Self.rounded(delta, for: unit)
        // The headline reads like the phone shows glucose (7.0 mmol/L, not the wire's 7).
        let digits = unit == .millimolesPerLiter ? "%.1f" : "%.0f"
        let deltaText = (roundedDelta.doubleValue > 0 ? "+" : "") + String(format: digits, roundedDelta.doubleValue)
        self.logSummary = "\(String(format: digits, values[values.count - 1].doubleValue)) \(unitName) \(Self.trendArrows[direction]) \(deltaText) at \(time)"
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
        case is NSNull:
            return "null"
        default:
            return String(describing: value)
        }
    }

    /// The host's active glucose alert carried in `DATA` index 8: 0 none, 1 low,
    /// 2 urgent low, 3 high, 4 predicted low; negative while the user's Watch
    /// Alarms switch is off (the watch colours its ring but doesn't buzz).
    static func alertStateName(_ state: Int) -> String {
        let names = [0: "none", 1: "low", 2: "urgent low", 3: "high", 4: "predicted low"]
        guard let name = names[abs(state)] else { return "unknown (\(state))" }
        return state < 0 ? name + ", Watch Alarms is off" : name
    }

    /// Rounds to the watchface's display precision: one decimal for mmol/L, whole mg/dL.
    ///
    /// `NSDecimalNumber` serializes exactly ("7.9"), whereas a `Double` would
    /// carry binary noise into the JSON ("7.9000000000000004").
    private static func rounded(_ value: Double, for unit: LupedUnit) -> NSDecimalNumber {
        rounded(value, scale: unit == .millimolesPerLiter ? 1 : 0)
    }

    private static func rounded(_ value: Double, scale: Int16) -> NSDecimalNumber {
        let behavior = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: scale,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        return NSDecimalNumber(value: value).rounding(accordingToBehavior: behavior)
    }

    /// The newest `limit` readings, oldest first, at least `graphSpacing` apart,
    /// counted back from the latest reading so the newest value is always current.
    static func graphReadings(_ readings: [LupedReading], limit: Int) -> [LupedReading] {
        var kept: [LupedReading] = []
        for reading in readings.sorted(by: { $0.date > $1.date }) {
            if let newer = kept.last, newer.date.timeIntervalSince(reading.date) < graphSpacing {
                continue
            }
            kept.append(reading)
            if kept.count == limit {
                break
            }
        }
        return kept.reversed()
    }

    /// The reading before the latest in the thinned history (about 5 minutes
    /// earlier), if it is recent enough to compare against.
    private static func previousReading(in readings: [LupedReading]) -> LupedReading? {
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
