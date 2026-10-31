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

/// An unsigned request from the watch, `nil` inside when its argument is
/// missing or invalid: `mute:<minutes>` (above zero), `carbs:<grams>` (above
/// zero), `override:<preset name or id>` or `override:cancel`, and
/// `temptarget:<preset name or id>` or `temptarget:cancel`. Boluses are only
/// ever signed (`LupedSignedBolus`).
enum LupedWatchRequest: Equatable {
    case mute(minutes: Int?)
    case carbs(Double?)
    case override(LupedPresetAction?)
    case tempTarget(LupedPresetAction?)

    init?(command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count == 2 ? parts[1] : nil
        let preset = argument.flatMap { $0 == "cancel" ? LupedPresetAction.cancel : $0.isEmpty ? nil : .start($0) }
        switch parts.first {
        case "mute":
            self = .mute(minutes: argument.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil })
        case "carbs":
            self = .carbs(argument.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
        case "override":
            self = .override(preset)
        case "temptarget":
            self = .tempTarget(preset)
        default:
            return nil
        }
    }

    /// The `<action>` of the request's `RESULT`.
    var action: String {
        switch self {
        case .mute: "mute"
        case .carbs: "carbs"
        case .override: "override"
        case .tempTarget: "temptarget"
        }
    }
}

/// What a watch's `override:` or `temptarget:` request asks for.
public enum LupedPresetAction: Equatable, Sendable {
    /// Start the preset with this name or id.
    case start(String)
    /// End the running one.
    case cancel
}
