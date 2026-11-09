import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// Find my Pebble goes to whichever Luped app is running: the phone tries the
/// one it sends to, and the other one after a rejection.
@MainActor
final class LupedFindPebbleTests: XCTestCase {
    func testGoesToTheRemoteWhenTheWatchfaceRejectsIt() async throws {
        let (transport, watchface, remote) = await makeTransport()

        transport.findPebble()
        XCTAssertEqual(count("#1 COMMAND findpebble:60 to the watchface", in: transport), 1)

        // Rejected right after the watchface took the reading: busy, so it gets it again.
        try await rejectTwice(transport, watchface)
        // Rejected again: the watchface isn't running; the remote gets the reading first, then the request.
        XCTAssertEqual(transport.status.foreground, .remote)
        transport.pebbleTransport(remote, didReceiveReply: true, transactionID: 0, message: [])
        XCTAssertEqual(count("#1 COMMAND findpebble:60 to Luped Remote", in: transport), 1)

        transport.pebbleTransport(remote, didReceiveReply: true, transactionID: 1, message: [])
        XCTAssertEqual(count("Luped Remote took Find my Pebble", in: transport), 1)
        XCTAssertEqual(transport.status.findNote, "The watch is buzzing for a minute. Press a button on it to stop.")
    }

    func testSaysSoWhenNeitherAppIsRunning() async throws {
        let (transport, watchface, remote) = await makeTransport()

        transport.findPebble(seconds: 30)
        try await rejectTwice(transport, watchface)
        // Luped Remote rejects the reading too.
        transport.pebbleTransport(remote, didReceiveReply: false, transactionID: 0, message: [])

        XCTAssertEqual(transport.status.findNote, "Open Luped on the watch, then try again.")
        XCTAssertEqual(count("#1 COMMAND findpebble:30 to the watchface", in: transport), 1)
        XCTAssertEqual(count("#2 COMMAND findpebble:30 to the watchface", in: transport), 1, "sent again once: busy, then closed")
        XCTAssertEqual(count("#1 COMMAND findpebble:30 to Luped Remote", in: transport), 0, "not sent to Luped Remote, which rejected the reading")
    }

    /// The watchface rejects Find my Pebble (#1) right after taking the reading,
    /// gets it again shortly (#2), and rejects that too.
    private func rejectTwice(_ transport: LupedTransport, _ watchface: PebbleTransport) async throws {
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 1, message: [])
        XCTAssertEqual(transport.status.foreground, .watchface, "busy, not closed")
        try await Task.sleep(nanoseconds: UInt64((LupedRouting.busyRetryDelay + 0.5) * 1_000_000_000))
        XCTAssertEqual(count("#2 COMMAND findpebble", in: transport), 1)
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 2, message: [])
    }

    /// Both sessions open, and the watchface acknowledged the reading (#0).
    private func makeTransport() async -> (LupedTransport, PebbleTransport, PebbleTransport) {
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
        }
        await transport.refresh()
        transport.sendIfNeeded(force: true)
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 0, message: [])
        return (transport, watchface, remote)
    }

    private func count(_ text: String, in transport: LupedTransport) -> Int {
        transport.communicationLog.entries.filter { $0.message.hasPrefix(text) }.count
    }
}
