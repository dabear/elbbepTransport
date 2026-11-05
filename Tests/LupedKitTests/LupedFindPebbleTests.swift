import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// Find my Pebble goes to whichever Luped app is running: the phone tries the
/// one it sends to, and the other one after a rejection.
@MainActor
final class LupedFindPebbleTests: XCTestCase {
    func testGoesToTheRemoteWhenTheWatchfaceRejectsIt() async {
        let (transport, watchface, remote) = await makeTransport()

        transport.findPebble()
        XCTAssertEqual(count("#1 COMMAND findpebble:60 to the watchface", in: transport), 1)

        // The watchface isn't running: the remote gets the reading first, then the request.
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 1, message: [])
        XCTAssertEqual(transport.status.foreground, .remote)
        transport.pebbleTransport(remote, didReceiveReply: true, transactionID: 0, message: [])
        XCTAssertEqual(count("#1 COMMAND findpebble:60 to Luped Remote", in: transport), 1)

        transport.pebbleTransport(remote, didReceiveReply: true, transactionID: 1, message: [])
        XCTAssertEqual(transport.status.findNote, "Luped Remote is buzzing for 60 s. Press any button on the watch to stop.")
    }

    func testSaysSoWhenNeitherAppIsRunning() async {
        let (transport, watchface, remote) = await makeTransport()

        transport.findPebble(seconds: 30)
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 1, message: [])
        // Luped Remote rejects the reading too.
        transport.pebbleTransport(remote, didReceiveReply: false, transactionID: 0, message: [])

        XCTAssertEqual(transport.status.findNote, "Not delivered: neither Luped CGM nor Luped Remote is running on the watch.")
        XCTAssertEqual(count("#1 COMMAND findpebble", in: transport), 1, "not sent again")
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
