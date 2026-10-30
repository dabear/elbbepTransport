import Foundation

/// Signed boluses: the session key the watch signs with, and the check every
/// signed request passes before the host hears of it (`LupedBolusAuth`). The
/// transport's lifecycle calls in here when a session opens or resets and when
/// the watchface starts.
extension LupedTransport {
    /// Gives the watch a new bolus session key, replacing any earlier one.
    func startBolusSession() {
        noteUnansweredBolus()
        pendingBolusKey = bolusAuth.newSession()
        record(.info, "New bolus session \(bolusAuth.session?.id ?? ""): requests signed with an earlier key are refused")
        sendIfNeeded()
    }

    func endBolusSession() {
        guard bolusAuth.session != nil || pendingBolusKey != nil else { return }
        noteUnansweredBolus()
        record(.info, "Bolus session \(bolusAuth.session?.id ?? "") ended: signed bolus requests are refused until the watch gets a new key")
        bolusAuth.endSession()
        pendingBolusKey = nil
    }

    /// A request passed on without a bolus result yet can't be answered once its
    /// session ends: say so, as the watch won't hear more of it.
    private func noteUnansweredBolus() {
        if let sequence = bolusAuth.unansweredSequence, let id = bolusAuth.session?.id {
            record(.error, "Signed bolus request #\(sequence) (session \(id)) had no result from \(hostName) when its session ended; check \(hostName)'s history before asking again")
        }
    }

    /// The log label of the `COMMAND auth` push for a session.
    static func bolusKeyLabel(_ id: String) -> String {
        "COMMAND auth (bolus session \(id))"
    }

    static func bolusSessionID(inLabel label: String) -> String? {
        let prefix = "COMMAND auth (bolus session "
        guard label.hasPrefix(prefix), label.hasSuffix(")") else { return nil }
        return String(label.dropFirst(prefix.count).dropLast())
    }

    func bolusKeyNotDelivered(_ id: String, _ reason: String) {
        guard bolusAuth.session?.id == id else { return }
        record(.error, "Bolus session \(id) key not delivered (\(reason)): the watch's signed bolus requests are refused until the watchface starts again and gets a new key")
    }

    /// Passes a signed bolus request on once, if `LupedBolusAuth` accepts it; a
    /// resend of a handled one gets its results again.
    func handleSignedBolus(_ command: String) {
        let action = LupedSignedBolus.actions.first { command.hasPrefix($0 + ":") } ?? "signedbolus"
        guard let request = LupedSignedBolus(command: command) else {
            record(.error, "Signed bolus request refused: malformed (COMMAND \(command))")
            queueResult("\(action):refused")
            return
        }
        switch bolusAuth.verify(request, now: Date()) {
        case .accept(let request):
            let carbs = request.grams.map { String(format: " with %g g of carbs", $0) } ?? ""
            let confirmed = String(format: "confirmed %.0f s ago", Date().timeIntervalSince(request.confirmedAt))
            record(.fromWatch, String(format: "Watch asked for a %@ U %@%@, %@, signature valid (session %@, #%d)", request.unitsText, request.forced ? "forced bolus" : "bolus", carbs, confirmed, request.sessionID, request.sequence))
            bolusRequested?(request.units, request.forced, request.grams, request.confirmedAt)
        case .resend(let results):
            record(.info, "Signed bolus request #\(request.sequence) already handled: its result sent again, not passed on")
            results.forEach(queueResult)
        case .inProgress:
            record(.info, "Signed bolus request #\(request.sequence) is still being handled: its result follows")
        case .refuse(let reason):
            record(.error, "Signed bolus request refused: \(reason)\(bolusAuth.keyNote(issuingKeys: issuesBolusKey)) (COMMAND \(command))")
            queueResult("\(action):refused")
        }
    }
}
