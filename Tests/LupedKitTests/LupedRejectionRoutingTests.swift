import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// Which app gets a message after a rejection. Seen in the field (Trio,
/// 2026-11-09): right after a reconnect the watchface accepted a reading, then
/// rejected the bolus key a second later while busy. The phone moved to Luped
/// Remote, which wasn't running and never answered, retried only Luped Remote,
/// and paused: the watchface's reading went stale ("ERR").
@MainActor
final class LupedRejectionRoutingTests: XCTestCase {
    /// A rejection right after the app accepted a message: busy, not closed. The
    /// phone stays and sends it again; a second rejection then moves on.
    func testARejectionRightAfterAnAcceptedMessageIsRetriedOnTheSameApp() async throws {
        let (transport, watchface, remote) = try await connectedTransport()
        // The watchface takes the reading (#0)...
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 0, message: [])
        // ...then rejects the next message, a RESULT (#1), a second later.
        transport.sendResult("mute:ok")
        XCTAssertEqual(count("#1 RESULT mute:ok", in: transport), 1)
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 1, message: [])

        XCTAssertEqual(transport.foreground, .watchface, "a busy watchface's rejection moved the phone to Luped Remote")
        XCTAssertEqual(count("the watchface rejected a message", in: transport), 1, "busy, not closed")
        // Sent to the watchface again shortly.
        try await Task.sleep(nanoseconds: UInt64((LupedRouting.busyRetryDelay + 0.5) * 1_000_000_000))
        XCTAssertEqual(count("#2 RESULT mute:ok", in: transport), 1, "the RESULT wasn't sent to the watchface again")

        // Rejected once more: now the watchface counts as closed and Luped Remote gets it.
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 2, message: [])
        XCTAssertEqual(transport.foreground, .remote)
        _ = remote
    }

    /// After a rejection moved the phone to Luped Remote, Luped Remote gives no
    /// reply at all: the watchface gets the reading again instead of the phone
    /// retrying the silent app until it pauses.
    func testASilentAppAfterARejectionSendsThePhoneBack() async throws {
        let (transport, watchface, _) = try await connectedTransport()
        // The watchface rejects the reading (#0) without having accepted anything.
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 0, message: [])
        XCTAssertEqual(transport.foreground, .remote)
        XCTAssertEqual(count("#0 DATA", in: transport), 2, "the reading went to Luped Remote")

        // Luped Remote never answers.
        try await Task.sleep(nanoseconds: UInt64((PebbleAppMessage.ackTimeout + 0.5) * 1_000_000_000))
        XCTAssertEqual(count("#0 no reply within", in: transport), 1)
        XCTAssertEqual(transport.foreground, .watchface, "the phone kept retrying the silent Luped Remote")
        XCTAssertEqual(count("#1 DATA", in: transport), 1, "the watchface didn't get the reading again")

        // The watchface rejects again: the silent remote counts as rejected, so the
        // phone stays on the watchface and backs off instead of taking turns.
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 1, message: [])
        XCTAssertEqual(transport.foreground, .watchface)
        XCTAssertEqual(count("Retrying in 30 s", in: transport), 1)
    }

    /// Send Now after the phone moved to Luped Remote: the watchface gets the
    /// reading (seen in the field: Send Now went to a Luped Remote that wasn't
    /// running while the watch showed ERR).
    func testSendNowGoesToTheWatchfaceFirst() async throws {
        let (transport, watchface, _) = try await connectedTransport()
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 0, message: [])
        XCTAssertEqual(transport.foreground, .remote)

        transport.sendNow()
        XCTAssertEqual(transport.foreground, .watchface)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(count("#1 DATA", in: transport), 1, "Send Now didn't send the reading to the watchface")
    }

    func testBusyMeansAcceptedOrSentWithinTheWindow() {
        let now = Date()
        XCTAssertFalse(LupedRouting.isBusy(rejectedAt: now, lastHeard: nil))
        XCTAssertTrue(LupedRouting.isBusy(rejectedAt: now, lastHeard: now.addingTimeInterval(-1)))
        XCTAssertFalse(LupedRouting.isBusy(rejectedAt: now, lastHeard: now.addingTimeInterval(-LupedRouting.busyWindow)))
    }

    /// Both sessions open and the reading sent to the watchface as #0.
    private func connectedTransport() async throws -> (LupedTransport, PebbleTransport, PebbleTransport) {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true, remoteEnabled: true))
        let readingDate = Date()
        transport.snapshotProvider = {
            LupedSnapshot(readings: [LupedReading(date: readingDate, milligramsPerDeciliter: 120, trend: .flat)], storedSampleCount: 1, unit: .milligramsPerDeciliter)
        }
        let watchface = transport.watchfaceTransport
        let remote = transport.remoteTransport
        for session in [watchface, remote] {
            session.handlePacket([2]) // PPoGATT reset request
            session.handlePacket([3]) // PPoGATT reset complete
            XCTAssertTrue(session.isSessionOpen)
        }
        await transport.refresh()
        transport.sendIfNeeded(force: true)
        return (transport, watchface, remote)
    }

    private func count(_ text: String, in transport: LupedTransport) -> Int {
        transport.communicationLog.entries.filter { $0.message.contains(text) && !$0.message.contains("dropped") }.count
    }
}
