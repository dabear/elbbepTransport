import Foundation

/// When the user confirmed a watch command, from an optional suffix the watch
/// adds to `COMMAND`: `<command>@<confirmedAt>`, whole seconds since 1970 by the
/// watch's clock, which the Pebble app keeps in step with the phone's. A resent
/// command keeps its `confirmedAt`, so it ages like the original.
public struct LupedCommandTiming: Equatable {
    public let confirmedAt: Date

    /// `nil` when the command has no suffix, or one that isn't a positive whole number.
    public init?(command: String) {
        guard let at = command.lastIndex(of: "@"),
              let seconds = Int(command[command.index(after: at)...]), seconds > 0
        else { return nil }
        confirmedAt = Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// The command without its timing suffix.
    public static func stripped(_ command: String) -> String {
        command.lastIndex(of: "@").map { String(command[..<$0]) } ?? command
    }
}

/// An unsigned dosing request from the watch: `carbs:<grams>`, with `nil` when
/// the amount is missing, not a number, or not above zero. Boluses are only
/// ever signed (`LupedSignedBolus`).
enum LupedWatchRequest: Equatable {
    case carbs(Double?)

    init?(command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let amount = parts.count == 2 ? Double(parts[1]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } : nil
        guard parts[0] == "carbs" else { return nil }
        self = .carbs(amount)
    }

    var action: String { "carbs" }
}
