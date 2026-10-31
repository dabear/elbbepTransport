import Foundation

/// Unsigned requests from the watch (`LupedWatchRequest`): each is logged and
/// passed to the plugin's callback, or answered on `RESULT` when it has no valid
/// argument or the plugin doesn't take it.
extension LupedTransport {
    func handleWatchRequest(_ request: LupedWatchRequest, command: String) {
        let requestedAt = LupedCommandTiming(command: command)?.confirmedAt
        let confirmed = requestedAt.map { String(format: ", confirmed %.0f s ago", Date().timeIntervalSince($0)) } ?? ", without the watch's timing"
        switch request {
        case .mute(let minutes?):
            record(.fromWatch, "Watch asked to mute \(hostName) alerts for \(minutes) min\(confirmed) (COMMAND \(command))")
            alertMuteRequested?(TimeInterval(minutes * 60), requestedAt)
        case .carbs(let grams?):
            record(.fromWatch, String(format: "Watch asked to add %g g of carbs%@ (COMMAND %@)", grams, confirmed, command))
            carbsRequested?(grams, requestedAt)
        case .override(let action?):
            handlePresetRequest(action, kind: "preset", callback: overrideRequested, request: request, confirmed: confirmed, requestedAt: requestedAt, command: command)
        case .tempTarget(let action?):
            handlePresetRequest(action, kind: "temp target", callback: tempTargetRequested, request: request, confirmed: confirmed, requestedAt: requestedAt, command: command)
        case .mute(nil), .carbs(nil), .override(nil), .tempTarget(nil):
            record(.error, "Watch request without a valid \(request.action == "mute" ? "duration" : request.action == "carbs" ? "amount" : "preset") ignored (COMMAND \(command))")
            sendResult("\(request.action):failed")
        }
    }

    private func handlePresetRequest(
        _ action: LupedPresetAction,
        kind: String,
        callback: ((LupedPresetAction, Date?) -> Void)?,
        request: LupedWatchRequest,
        confirmed: String,
        requestedAt: Date?,
        command: String
    ) {
        let asked = switch action {
        case .start(let preset): "start the \(kind) \"\(preset)\""
        case .cancel: "end the running \(kind)"
        }
        guard let callback else {
            record(.error, "Watch asked to \(asked)\(confirmed): ignored, this plugin doesn't take \(kind) requests (COMMAND \(command))")
            sendResult("\(request.action):ignored")
            return
        }
        record(.fromWatch, "Watch asked to \(asked)\(confirmed) (COMMAND \(command))")
        callback(action, requestedAt)
    }
}
