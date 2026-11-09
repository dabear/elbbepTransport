import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// What the phone does with a message in flight when the watch session resets
/// before the watch acknowledged it: a RESULT and Find my Pebble go out again
/// in the new session instead of being lost silently.
@MainActor
final class LupedSessionResetTests: XCTestCase {
    func testAResultInFlightAtASessionResetGoesOutAgain() async throws {
        let (transport, watchface) = try await connectedTransport()
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 0, message: [])
        transport.sendResult("mute:ok")
        XCTAssertEqual(count("#1 RESULT mute:ok", in: transport), 1)

        reset(watchface)
        try await acknowledgeReading(on: watchface, of: transport)
        XCTAssertEqual(sent("RESULT mute:ok", in: transport), 2, "the RESULT in flight at the reset was lost")
    }

    func testFindMyPebbleInFlightAtASessionResetGoesOutAgain() async throws {
        let (transport, watchface) = try await connectedTransport()
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 0, message: [])
        transport.findPebble(seconds: 60)
        XCTAssertEqual(sent("COMMAND findpebble:60", in: transport), 1)

        reset(watchface)
        try await acknowledgeReading(on: watchface, of: transport)
        XCTAssertEqual(sent("COMMAND findpebble:60", in: transport), 2, "Find my Pebble in flight at the reset was lost")
    }

    func testABolusDeliveryFailureTellsTheUserToCheckThePump() {
        XCTAssertEqual(LupedResultReason.checkPump.appended(to: "signedbolus:failed"), "signedbolus:failed:check pump")
    }

    // MARK: - Helpers

    private func reset(_ session: PebbleTransport) {
        session.handlePacket([2]) // PPoGATT reset request
        session.handlePacket([3]) // PPoGATT reset complete
        XCTAssertTrue(session.isSessionOpen)
    }

    /// The new session sends the reading first; acknowledging it lets the rest go.
    private func acknowledgeReading(on session: PebbleTransport, of transport: LupedTransport) async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        transport.sendIfNeeded(force: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        for _ in 0..<5 {
            guard let id = lastTransactionID(in: transport) else { break }
            transport.pebbleTransport(session, didReceiveReply: true, transactionID: id, message: [])
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Both sessions open and the reading sent to the watchface as #0.
    private func connectedTransport() async throws -> (LupedTransport, PebbleTransport) {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true, remoteEnabled: true))
        let readingDate = Date()
        transport.snapshotProvider = {
            LupedSnapshot(readings: [LupedReading(date: readingDate, milligramsPerDeciliter: 120, trend: .flat)], storedSampleCount: 1, unit: .milligramsPerDeciliter)
        }
        let watchface = transport.watchfaceTransport
        for session in [watchface, transport.remoteTransport] {
            reset(session)
        }
        await transport.refresh()
        transport.sendIfNeeded(force: true)
        return (transport, watchface)
    }

    /// The transaction ID of the newest message to the watch.
    private func lastTransactionID(in transport: LupedTransport) -> UInt8? {
        for entry in transport.communicationLog.entries.reversed() where entry.kind == .toWatch {
            let digits = entry.message.dropFirst().prefix { $0.isNumber }
            if entry.message.hasPrefix("#"), let id = UInt8(digits) {
                return id
            }
        }
        return nil
    }

    /// Messages sent to the watch containing `text`.
    private func sent(_ text: String, in transport: LupedTransport) -> Int {
        transport.communicationLog.entries.filter { $0.kind == .toWatch && $0.message.contains(text) }.count
    }

    private func count(_ text: String, in transport: LupedTransport) -> Int {
        transport.communicationLog.entries.filter { $0.message.contains(text) && !$0.message.contains("dropped") }.count
    }
}
