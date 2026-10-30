import CryptoKit
import Foundation

/// A signed bolus request from the watch:
/// `<action>:<units>[:<grams>]@<confirmedAt>#<sid>.<seq>.<mac>`, where the
/// action is `signedbolus` or `signedforcedbolus`. Every field is kept as the
/// raw text the watch sent, so the MAC is checked over exactly what was signed.
struct LupedSignedBolus: Equatable {
    static let actions: Set<String> = ["signedbolus", "signedforcedbolus"]

    let action: String
    let unitsText: String
    let gramsText: String?
    let confirmedAtText: String
    let sessionID: String
    let sequence: Int
    let mac: [UInt8]

    var forced: Bool { action == "signedforcedbolus" }
    var units: Double { Double(unitsText)! }
    var grams: Double? { gramsText.map { Double($0)! } }
    var confirmedAt: Date { Date(timeIntervalSince1970: TimeInterval(Int(confirmedAtText)!)) }

    /// The signed text: `v1|<sid>|<seq>|<confirmedAt>|<action>|<units>|<grams or empty>`.
    var canonical: String {
        LupedBolusAuth.canonical(sessionID: sessionID, sequence: sequence, confirmedAt: confirmedAtText, action: action, units: unitsText, grams: gramsText)
    }

    /// Whether the command names a signed bolus at all; `init` then says whether it is well formed.
    static func isSigned(_ command: String) -> Bool {
        command.split(separator: ":", maxSplits: 1).first.map { actions.contains(String($0)) } ?? false
    }

    /// `nil` unless every field has exactly the allowed form: units with at most
    /// two decimals and above 0, whole grams 1–999, a positive confirmation time,
    /// a 16-hex-digit session, a sequence from 1, and a 32-hex-digit MAC.
    init?(command: String) {
        let signature = command.split(separator: "#", omittingEmptySubsequences: false)
        guard signature.count == 2 else { return nil }
        let timed = signature[0].split(separator: "@", omittingEmptySubsequences: false)
        guard timed.count == 2 else { return nil }
        let request = timed[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let auth = signature[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard request.count == 2 || request.count == 3, auth.count == 3,
              Self.actions.contains(request[0]),
              Self.matches(request[1], #"(0|[1-9][0-9]?)(\.[0-9]{1,2})?"#), let units = Double(request[1]), units > 0,
              request.count == 2 || Self.matches(request[2], "[1-9][0-9]{0,2}"),
              Self.matches(String(timed[1]), "[1-9][0-9]{0,11}"),
              Self.matches(auth[0], "[0-9a-f]{16}"),
              Self.matches(auth[1], "[1-9][0-9]{0,8}"), let sequence = Int(auth[1]),
              let mac = LupedBolusAuth.bytes(hex: auth[2]), mac.count == LupedBolusAuth.macLength
        else { return nil }
        action = request[0]
        unitsText = request[1]
        gramsText = request.count == 3 ? request[2] : nil
        confirmedAtText = String(timed[1])
        sessionID = auth[0]
        self.sequence = sequence
        self.mac = mac
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "^\(pattern)$", options: .regularExpression) != nil
    }
}

/// Authenticates the watch's bolus requests for one watchface run. The phone
/// hands the watch a random session key (`COMMAND auth:v1:<sid>:<key>`) over the
/// encrypted link; the watch keeps it in memory only and signs each bolus with
/// HMAC-SHA256, truncated to 16 bytes. A request reaches the host only once:
/// a resend of a handled request gets its stored results back, and a new
/// session (watchface restart or reconnect) makes every older request invalid.
/// This proves the request is unchanged and comes from the watchface run that
/// got this session's key; it says nothing about who is wearing the watch, and
/// an app installed under the same UUID would get the key too. The host's own
/// bolus checks always still apply.
struct LupedBolusAuth {
    static let macLength = 16
    /// How old a request may be when it arrives.
    static let maximumAge: TimeInterval = 30
    /// How far ahead of the phone's clock the watch's confirmation may be.
    static let maximumClockSkew: TimeInterval = 5
    /// Handled requests whose results are kept for resends.
    static let storedResultCount = 5

    enum Verdict: Equatable {
        /// New and valid: pass it to the host.
        case accept(LupedSignedBolus)
        /// Already handled: send these results again; don't pass it on.
        case resend([String])
        /// Still being handled: its results follow.
        case inProgress
        case refuse(String)
    }

    struct Session {
        let id: String
        let key: SymmetricKey
        /// Whether the watch acknowledged the key.
        var keyDelivered = false
        var lastSequence = 0
        /// The request being handled, with the results it has produced so far.
        var open: (sequence: Int, wantsCarbs: Bool, results: [String])?
        var results: [(sequence: Int, results: [String])] = []
    }

    private(set) var session: Session?

    /// Starts a session with a new random key; returns the `COMMAND` that hands it to the watch.
    mutating func newSession() -> String {
        let id = (0..<8).map { _ in UInt8.random(in: .min ... .max) }
        return newSession(id: Self.hex(id), key: SymmetricKey(size: .bits256))
    }

    mutating func newSession(id: String, key: SymmetricKey) -> String {
        session = Session(id: id, key: key)
        return "auth:v1:\(id):\(key.withUnsafeBytes { Self.hex(Array($0)) })"
    }

    /// Forgets the key: no request is accepted until the next session.
    mutating func endSession() {
        session = nil
    }

    /// The watch acknowledged the key for session `id` (ignored if a newer session replaced it).
    mutating func keyDelivered(session id: String) {
        guard session?.id == id else { return }
        session?.keyDelivered = true
    }

    /// The request that was passed on but has no bolus result yet, if any.
    var unansweredSequence: Int? { session?.open?.sequence }

    /// Why the watch may hold no valid key, for the log of a refused request:
    /// empty when the current key reached the watch.
    func keyNote(issuingKeys: Bool) -> String {
        guard issuingKeys else {
            return "; no key is issued: remote bolus is off for this watch"
        }
        guard let session else {
            return "; no key yet: there is no watch session"
        }
        return session.keyDelivered ? "" : "; the watch hasn't acknowledged the key for session \(session.id)"
    }

    mutating func verify(_ request: LupedSignedBolus, now: Date) -> Verdict {
        guard var session else {
            return .refuse("no bolus session yet (the watch has no key)")
        }
        guard request.sessionID == session.id else {
            return .refuse("signed for another session (\(request.sessionID)); the current one is \(session.id)")
        }
        let expected = Array(HMAC<SHA256>.authenticationCode(for: Data(request.canonical.utf8), using: session.key).prefix(Self.macLength))
        // Constant time: every byte is compared whatever the first difference.
        guard zip(expected, request.mac).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            return .refuse("signature doesn't match")
        }
        if let stored = session.results.first(where: { $0.sequence == request.sequence }) {
            return .resend(stored.results)
        }
        if session.open?.sequence == request.sequence {
            return .inProgress
        }
        guard request.sequence > session.lastSequence else {
            return .refuse("sequence \(request.sequence) is not after \(session.lastSequence)")
        }
        let age = now.timeIntervalSince(request.confirmedAt)
        guard age <= Self.maximumAge else {
            return .refuse(String(format: "confirmed %.0f s ago, more than %.0f s", age, Self.maximumAge))
        }
        guard -age <= Self.maximumClockSkew else {
            return .refuse(String(format: "confirmed %.0f s in the future", -age))
        }
        session.lastSequence = request.sequence
        session.open = (request.sequence, request.gramsText != nil, [])
        self.session = session
        return .accept(request)
    }

    /// Notes a result going to the watch. Results for the open request (its
    /// bolus, and its carbs if it had any) are stored for resends; the bolus
    /// result closes it.
    mutating func record(result: String) {
        guard var session, var open = session.open else { return }
        let action = result.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let isBolus = LupedSignedBolus.actions.contains(action)
        guard isBolus || (open.wantsCarbs && action == "carbs") else { return }
        open.results.append(result)
        if isBolus {
            session.results.append((open.sequence, open.results))
            session.results = Array(session.results.suffix(Self.storedResultCount))
            session.open = nil
        } else {
            session.open = open
        }
        self.session = session
    }

    static func canonical(sessionID: String, sequence: Int, confirmedAt: String, action: String, units: String, grams: String?) -> String {
        "v1|\(sessionID)|\(sequence)|\(confirmedAt)|\(action)|\(units)|\(grams ?? "")"
    }

    /// The watch's side, for tests: the MAC to send for `canonical`.
    static func mac(_ canonical: String, key: SymmetricKey) -> String {
        hex(Array(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key).prefix(macLength)))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex only; `nil` for anything else.
    static func bytes(hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: digits.count, by: 2) {
            guard let high = nibble(digits[i]), let low = nibble(digits[i + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}
