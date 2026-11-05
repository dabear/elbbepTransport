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
        case .carbs(let grams?, let absorption):
            record(.fromWatch, String(format: "Watch asked to add %g g of %@carbs%@ (COMMAND %@)", grams, absorption.map { "\($0.rawValue) " } ?? "", confirmed, command))
            carbsRequested?(grams, absorption, requestedAt)
        case .override(let action?):
            handlePresetRequest(action, kind: "preset", callback: overrideRequested, request: request, confirmed: confirmed, requestedAt: requestedAt, command: command)
        case .tempTarget(let action?):
            handlePresetRequest(action, kind: "temp target", callback: tempTargetRequested, request: request, confirmed: confirmed, requestedAt: requestedAt, command: command)
        case .recommend(let grams?, let absorption):
            record(.fromWatch, String(format: "Watch asked what bolus %@ would recommend with %g g of %@carbs (COMMAND %@)", hostName, grams, absorption.map { "\($0.rawValue) " } ?? "", command))
            guard let bolusRecommendationRequested else {
                record(.error, "Bolus recommendation request ignored: this plugin doesn't answer them")
                sendBolusRecommendationRefusal(grams: grams, outcome: "ignored", reason: nil)
                return
            }
            bolusRecommendationRequested(grams, absorption)
        case .presets:
            record(.fromWatch, "Luped Remote asked for \(hostName)'s presets (COMMAND \(command))")
            sendPresets()
        case .recommend(nil, _):
            // Answered as RECOMMEND, not RESULT: only Luped Remote asks, and waits for it.
            record(.error, "Watch asked for a bolus recommendation without valid carbs (COMMAND \(command))")
            queueRecommendation(":failed:\(LupedResultReason.invalidAmount.rawValue)")
        case .mute(nil), .carbs(nil, _), .override(nil), .tempTarget(nil):
            record(.error, "Watch request without a valid \(request.action == "mute" ? "duration" : request.action == "carbs" ? "amount" : "preset") ignored (COMMAND \(command))")
            sendResult("\(request.action):failed", reason: .invalidAmount)
        }
    }

    private func handlePresetRequest(
        _ watchAction: LupedPresetAction,
        kind: String,
        callback: ((LupedPresetAction, Date?) -> Void)?,
        request: LupedWatchRequest,
        confirmed: String,
        requestedAt: Date?,
        command: String
    ) {
        // A preset id the watch couldn't carry as is came as a token
        // (LupedPreset.watchID): map it back to the host's id.
        var action = watchAction
        if case .start(let id) = watchAction, id.hasPrefix(LupedPreset.tokenPrefix) {
            let presets = (request.action == "override" ? latestSnapshot?.overridePresets : latestSnapshot?.tempTargetPresets) ?? []
            if let preset = presets.first(where: { $0.watchID == id }) {
                action = .start(preset.id)
            } else {
                record(.error, "Watch asked for \(kind) \(id), which matches none of the host's current \(kind)s")
            }
        }
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
