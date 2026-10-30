import Foundation

/// How the communication log describes a payload: the decoded `DATA` table and
/// the reasons a field is empty. The wire encoding is in `LupedPayload.swift`.
extension LupedPayload {
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
}
