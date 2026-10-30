import CryptoKit
import XCTest
@testable import LupedKit

final class LupedBolusAuthTests: XCTestCase {
    private let sessionID = "0123456789abcdef"
    private let key = SymmetricKey(data: Data(0..<32))
    private let now = Date(timeIntervalSince1970: 1_798_000_010)

    private func auth() -> LupedBolusAuth {
        var auth = LupedBolusAuth()
        _ = auth.newSession(id: sessionID, key: key)
        return auth
    }

    /// The command the watch sends, signed with `key` unless `mac` is given.
    private func command(
        _ action: String = "signedbolus", units: String = "1.5", grams: String? = "30",
        confirmedAt: String = "1798000000", session: String? = nil, sequence: Int = 1,
        key: SymmetricKey? = nil, mac: String? = nil
    ) -> String {
        let session = session ?? sessionID
        let canonical = LupedBolusAuth.canonical(sessionID: session, sequence: sequence, confirmedAt: confirmedAt, action: action, units: units, grams: grams)
        let mac = mac ?? LupedBolusAuth.mac(canonical, key: key ?? self.key)
        return "\(action):\(units)\(grams.map { ":\($0)" } ?? "")@\(confirmedAt)#\(session).\(sequence).\(mac)"
    }

    private func verify(_ command: String, with auth: inout LupedBolusAuth, at time: Date? = nil) -> LupedBolusAuth.Verdict? {
        LupedSignedBolus(command: command).map { auth.verify($0, now: time ?? now) }
    }

    private func isRefused(_ verdict: LupedBolusAuth.Verdict?) -> Bool {
        if case .refuse = verdict { return true }
        return false
    }

    // MARK: - HMAC-SHA256

    // RFC 4231 test cases 1, 2 and 6 (a key longer than the block size).
    func testHMACMatchesRFC4231() {
        func hmac(_ key: [UInt8], _ data: String) -> String {
            LupedBolusAuth.hex(Array(HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: SymmetricKey(data: key))))
        }
        XCTAssertEqual(hmac(Array(repeating: 0x0b, count: 20), "Hi There"), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        XCTAssertEqual(hmac(Array("Jefe".utf8), "what do ya want for nothing?"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual(hmac(Array(repeating: 0xaa, count: 131), "Test Using Larger Than Block-Size Key - Hash Key First"), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    // The vector the watch's signing code must reproduce: key 00…1f, truncated to 16 bytes.
    func testSharedVectorForTheWatch() {
        let canonical = LupedBolusAuth.canonical(sessionID: sessionID, sequence: 1, confirmedAt: "1798000000", action: "signedbolus", units: "1.5", grams: "30")
        XCTAssertEqual(canonical, "v1|0123456789abcdef|1|1798000000|signedbolus|1.5|30")
        XCTAssertEqual(LupedBolusAuth.mac(canonical, key: key), "6eb19f16b120d0b9cdb6c36ea5eb56bf")
        XCTAssertEqual(LupedBolusAuth.canonical(sessionID: sessionID, sequence: 2, confirmedAt: "1798000000", action: "signedforcedbolus", units: "0.25", grams: nil), "v1|0123456789abcdef|2|1798000000|signedforcedbolus|0.25|")
    }

    // MARK: - Sessions

    func testTheKeyCommandCarriesTheSessionAndA256BitKey() {
        var auth = LupedBolusAuth()
        let command = auth.newSession()
        let parts = command.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(Array(parts[0...1]), ["auth", "v1"])
        XCTAssertEqual(parts[2], auth.session?.id)
        XCTAssertEqual(LupedBolusAuth.bytes(hex: parts[2])?.count, 8)
        XCTAssertEqual(LupedBolusAuth.bytes(hex: parts[3])?.count, 32)
        XCTAssertNotEqual(auth.newSession(), command, "Each session has a new id and key")
    }

    func testValidRequestIsAcceptedWithItsSignedValues() throws {
        var auth = auth()
        guard case .accept(let request) = verify(command(), with: &auth) else {
            return XCTFail("Not accepted")
        }
        XCTAssertEqual(request.units, 1.5)
        XCTAssertEqual(request.grams, 30)
        XCTAssertFalse(request.forced)
        XCTAssertEqual(request.confirmedAt, Date(timeIntervalSince1970: 1_798_000_000))
        guard case .accept(let plain) = verify(command(grams: nil, sequence: 2), with: &auth) else {
            return XCTFail("Not accepted without carbs")
        }
        XCTAssertNil(plain.grams)
    }

    func testRefusesWithoutAKey() {
        var auth = LupedBolusAuth()
        XCTAssertTrue(isRefused(verify(command(), with: &auth)))
    }

    func testRefusesAnotherSession() {
        var auth = auth()
        XCTAssertTrue(isRefused(verify(command(session: "fedcba9876543210"), with: &auth)))
    }

    func testANewSessionInvalidatesEarlierRequests() {
        var auth = auth()
        let signed = command()
        _ = auth.newSession(id: "fedcba9876543210", key: SymmetricKey(size: .bits256))
        XCTAssertTrue(isRefused(verify(signed, with: &auth)))
        auth.endSession()
        XCTAssertTrue(isRefused(verify(command(session: "fedcba9876543210"), with: &auth)))
    }

    // A refusal's log says why the watch may have no valid key.
    func testKeyNoteSaysWhyTheWatchMayHaveNoKey() {
        var auth = LupedBolusAuth()
        XCTAssertEqual(auth.keyNote(issuingKeys: false), "; no key is issued: remote bolus is off for this watch")
        XCTAssertEqual(auth.keyNote(issuingKeys: true), "; no key yet: there is no watch session")
        _ = auth.newSession(id: sessionID, key: key)
        XCTAssertEqual(auth.keyNote(issuingKeys: true), "; the watch hasn't acknowledged the key for session \(sessionID)")
        auth.keyDelivered(session: "fedcba9876543210")
        XCTAssertFalse(auth.session?.keyDelivered ?? true, "An older session's ACK doesn't count")
        auth.keyDelivered(session: sessionID)
        XCTAssertEqual(auth.keyNote(issuingKeys: true), "")
    }

    func testARequestWithoutABolusResultIsUnanswered() {
        var auth = auth()
        XCTAssertNil(auth.unansweredSequence)
        guard case .accept = verify(command(sequence: 3), with: &auth) else { return XCTFail("Not accepted") }
        XCTAssertEqual(auth.unansweredSequence, 3)
        auth.record(result: "carbs:ok")
        XCTAssertEqual(auth.unansweredSequence, 3, "Carbs alone don't answer it")
        auth.record(result: "signedbolus:ok")
        XCTAssertNil(auth.unansweredSequence)
    }

    // MARK: - Signature

    func testRefusesAWrongSignature() {
        var auth = auth()
        XCTAssertTrue(isRefused(verify(command(mac: String(repeating: "0", count: 32)), with: &auth)))
        XCTAssertTrue(isRefused(verify(command(key: SymmetricKey(size: .bits256)), with: &auth)))
    }

    // Each field is changed after signing: the MAC no longer matches.
    func testRefusesAnyChangeAfterSigning() {
        let original = command()
        let mac = String(original.split(separator: ".").last!)
        for changed in [
            command(units: "2.5", mac: mac),
            command(grams: "60", mac: mac),
            command(grams: nil, mac: mac),
            command(confirmedAt: "1798000005", mac: mac),
            command("signedforcedbolus", mac: mac),
            command(sequence: 2, mac: mac),
        ] {
            var auth = auth()
            XCTAssertTrue(isRefused(verify(changed, with: &auth)), changed)
        }
    }

    // MARK: - Timing

    func testRefusesOldAndFutureRequests() {
        var auth = auth()
        XCTAssertTrue(isRefused(verify(command(sequence: 1), with: &auth, at: Date(timeIntervalSince1970: 1_798_000_031))))
        XCTAssertTrue(isRefused(verify(command(sequence: 2), with: &auth, at: Date(timeIntervalSince1970: 1_797_999_994))))
        guard case .accept = verify(command(sequence: 3), with: &auth, at: Date(timeIntervalSince1970: 1_798_000_030)) else {
            return XCTFail("30 s old is still accepted")
        }
        guard case .accept = verify(command(sequence: 4), with: &auth, at: Date(timeIntervalSince1970: 1_797_999_995)) else {
            return XCTFail("5 s ahead is still accepted")
        }
    }

    // MARK: - Replays

    func testAResendWhileHandledIsInProgressAndAfterwardsGetsTheSameResults() {
        var auth = auth()
        let signed = command()
        guard case .accept = verify(signed, with: &auth) else { return XCTFail("Not accepted") }
        XCTAssertEqual(verify(signed, with: &auth), .inProgress)
        auth.record(result: "mute:ok")
        auth.record(result: "carbs:ok")
        auth.record(result: "signedbolus:ok")
        XCTAssertEqual(verify(signed, with: &auth), .resend(["carbs:ok", "signedbolus:ok"]))
        XCTAssertEqual(verify(signed, with: &auth), .resend(["carbs:ok", "signedbolus:ok"]), "Every resend, never passed on")
    }

    func testCarbResultsCountOnlyForARequestWithCarbs() {
        var auth = auth()
        guard case .accept = verify(command(grams: nil), with: &auth) else { return XCTFail("Not accepted") }
        auth.record(result: "carbs:ok")
        auth.record(result: "signedbolus:refused")
        XCTAssertEqual(verify(command(grams: nil), with: &auth), .resend(["signedbolus:refused"]))
    }

    func testRefusesASequenceThatIsNotNew() {
        var auth = auth()
        guard case .accept = verify(command(sequence: 5), with: &auth) else { return XCTFail("Not accepted") }
        auth.record(result: "signedbolus:ok")
        XCTAssertTrue(isRefused(verify(command(sequence: 3), with: &auth)))
        XCTAssertTrue(isRefused(verify(command(sequence: 4), with: &auth)))
        guard case .accept = verify(command(sequence: 6), with: &auth) else { return XCTFail("The next one is accepted") }
    }

    func testOnlyTheLastFewResultsAreKept() {
        var auth = auth()
        for sequence in 1...6 {
            guard case .accept = verify(command(sequence: sequence), with: &auth) else { return XCTFail("Not accepted") }
            auth.record(result: "signedbolus:ok")
        }
        XCTAssertTrue(isRefused(verify(command(sequence: 1), with: &auth)), "Forgotten, and still never passed on again")
        XCTAssertEqual(verify(command(sequence: 2), with: &auth), .resend(["signedbolus:ok"]))
    }

    // MARK: - Format

    func testRefusesMalformedRequests() {
        let malformed = [
            command(units: "1.555"), command(units: "01.5"), command(units: "100"), command(units: "0"),
            command(units: "0.00"), command(units: ".5"), command(units: "1e1"), command(units: "+1"), command(units: "1,5"),
            command(grams: "0"), command(grams: "1000"), command(grams: "1.5"), command(grams: ""),
            command(confirmedAt: "-1"), command(confirmedAt: "17x"), command(sequence: 0),
            command(session: "0123456789ABCDEF"), command(session: "0123"),
            command(mac: "6EB19F16B120D0B9CDB6C36EA5EB56BF"), command(mac: "6eb19f"),
            "signedbolus:1.5:30@1798000000", "signedbolus:1.5:30#\(sessionID).1.6eb19f16b120d0b9cdb6c36ea5eb56bf",
            "signedbolus:1.5:30:1@1798000000#\(sessionID).1.6eb19f16b120d0b9cdb6c36ea5eb56bf",
            "signedbolus:1.5@1798000000@1#\(sessionID).1.6eb19f16b120d0b9cdb6c36ea5eb56bf",
        ]
        for command in malformed {
            XCTAssertNil(LupedSignedBolus(command: command), command)
            XCTAssertTrue(LupedSignedBolus.isSigned(command), command)
        }
        XCTAssertNotNil(LupedSignedBolus(command: command(units: "0.05")))
        XCTAssertNotNil(LupedSignedBolus(command: command(units: "25")))
        XCTAssertNotNil(LupedSignedBolus(command: command(grams: "999")))
    }

    // MARK: - Forced

    func testForcedIsSignedAndPassedOn() {
        var auth = auth()
        guard case .accept(let request) = verify(command("signedforcedbolus", grams: nil), with: &auth) else {
            return XCTFail("Not accepted")
        }
        XCTAssertTrue(request.forced)
        auth.record(result: "signedforcedbolus:ok")
        XCTAssertEqual(verify(command("signedforcedbolus", grams: nil), with: &auth), .resend(["signedforcedbolus:ok"]))
    }
}
