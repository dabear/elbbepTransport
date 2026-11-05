import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// A command's 10 s reply timeout ends with the command: each app's session
/// numbers its own messages, so after the phone moves from the watchface to
/// Luped Remote, the watchface's timeout must not clear the remote's command
/// with the same transaction ID.
@MainActor
final class LupedCommandTimeoutTests: XCTestCase {
    func testStaleTimeoutFromPreviousAppClearsTheNewAppsCommand() async throws {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true))
        let readingDate = Date()
        transport.snapshotProvider = {
            LupedSnapshot(readings: [LupedReading(date: readingDate, milligramsPerDeciliter: 120, trend: .flat)], storedSampleCount: 1, unit: .milligramsPerDeciliter)
        }
        let watchface = transport.watchfaceTransport
        let remote = transport.remoteTransport

        // Both sessions open, as the watch opens one per published service.
        for session in [watchface, remote] {
            session.handlePacket([2]) // PPoGATT reset request
            session.handlePacket([3]) // PPoGATT reset complete
            XCTAssertTrue(session.isSessionOpen)
        }

        // The watchface gets the reading (#0) and acknowledges it.
        await transport.refresh()
        transport.sendIfNeeded(force: true)
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 0, message: [])

        // A RESULT goes to the watchface as #1; its 10 s reply timer starts now.
        let start = Date()
        transport.sendResult("mute:ok")
        XCTAssertEqual(count("#1 RESULT mute:ok", in: transport), 1)

        // 3 s later Luped Remote starts: the phone moves to it, drops the
        // watchface's unanswered #1 and re-queues the RESULT.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let ready = AppMessageTuple(type: PebbleAppMessage.tupleUnsigned, value: [1])
        transport.pebbleTransport(remote, didReceive: [PebbleAppMessage.alloyReadyKey: ready], message: Array(repeating: 0, count: 20))

        // The remote's own numbering: the reading is its #0, then the RESULT is its #1.
        transport.pebbleTransport(remote, didReceiveReply: true, transactionID: 0, message: [])
        XCTAssertEqual(count("#1 RESULT mute:ok", in: transport), 2, "the RESULT went to Luped Remote as its #1")
        let remoteSentAt = Date()

        // Wait past the watchface timer's 10 s, but well inside the remote command's own 10 s.
        try await Task.sleep(nanoseconds: UInt64((10.5 - Date().timeIntervalSince(start)) * 1_000_000_000))
        let elapsedForRemote = Date().timeIntervalSince(remoteSentAt)
        XCTAssertLessThan(elapsedForRemote, 9, "the remote's command hasn't reached its own timeout yet")

        // Luped Remote answers its #1 now, in time.
        transport.pebbleTransport(remote, didReceiveReply: true, transactionID: 1, message: [])

        let timedOut = count("#1 no reply within 10 s", in: transport)
        let ackIgnored = count("#1 ACK matches no message in flight; ignored", in: transport)
        XCTAssertEqual(timedOut, 0, "a stale watchface timer timed out the remote's command")
        XCTAssertEqual(ackIgnored, 0, "the remote's in-time ACK was ignored")
    }

    private func count(_ text: String, in transport: LupedTransport) -> Int {
        transport.communicationLog.entries.filter { $0.message.hasPrefix(text) && !$0.message.contains("dropped") }.count
    }
}
