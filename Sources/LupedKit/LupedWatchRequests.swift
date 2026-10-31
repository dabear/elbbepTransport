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

/// An unsigned request from the watch: `carbs:<grams>`, with `nil` when the
/// amount is missing, not a number, or not above zero; or
/// `override:<preset name or id>` to start a preset and `override:cancel` to end
/// the running one, with `nil` when the preset is missing. Boluses are only ever
/// signed (`LupedSignedBolus`).
enum LupedWatchRequest: Equatable {
    case carbs(Double?)
    case override(LupedOverrideAction?)

    init?(command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count == 2 ? parts[1] : nil
        switch parts.first {
        case "carbs":
            self = .carbs(argument.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        case "override":
            self = .override(argument.flatMap { $0 == "cancel" ? .cancel : $0.isEmpty ? nil : .start($0) })
        default:
            return nil
        }
    }

    var action: String {
        switch self {
        case .carbs: "carbs"
        case .override: "override"
        }
    }
}

/// What a watch's `override:` request asks for.
public enum LupedOverrideAction: Equatable, Sendable {
    /// Start the preset with this name or id.
    case start(String)
    /// End the running preset.
    case cancel
}
