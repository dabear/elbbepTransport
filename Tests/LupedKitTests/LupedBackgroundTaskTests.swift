import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// `beginBackgroundTask`: a delayed send holds a background task until it has
/// sent, so iOS doesn't suspend the host while it waits for the loop result.
@MainActor
final class LupedBackgroundTaskTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var snapshot: LupedSnapshot!
    private var events: [String] = []

    func testHeldWhileWaitingAndSwappedWithoutAGap() async {
        let transport = await deliveredFirstReading()

        // A new reading the loop hasn't run on yet: wait for the loop result.
        snapshot = snapshot(readings: 2, lastLoop: start)
        await transport.refresh()
        XCTAssertEqual(events, ["begin 1"])

        // The loop result: a new wait for its dose; the next task begins before the first ends.
        snapshot = snapshot(readings: 2, lastLoop: start.addingTimeInterval(301))
        await transport.refresh()
        XCTAssertEqual(events, ["begin 1", "begin 2", "end 1"])

        // An alert goes at once: the wait ends, and so does its task.
        snapshot = snapshot(readings: 2, lastLoop: start.addingTimeInterval(301), alert: 2)
        await transport.refresh()
        XCTAssertEqual(events, ["begin 1", "begin 2", "end 1", "end 2"])
    }

    func testEndedOnceTheDelayedSendHasSent() async throws {
        let transport = await deliveredFirstReading()

        // Only the loop status changed: collected for `followUpWindow`, then sent.
        snapshot = snapshot(readings: 1, lastLoop: start, insulinOnBoard: 2.5)
        await transport.refresh()
        XCTAssertEqual(events, ["begin 1"])
        try await Task.sleep(nanoseconds: UInt64((LupedDelivery.followUpWindow + 0.5) * 1_000_000_000))
        XCTAssertEqual(events, ["begin 1", "end 1"])
        XCTAssertTrue(transport.communicationLog.entries.contains { $0.kind == .toWatch && $0.message.hasPrefix("#1 DATA") }, "sent before the task ended")
    }

    // MARK: - Helpers

    /// The watchface's session open and its first reading (#0) acknowledged,
    /// with a host that hands out numbered background tasks.
    private func deliveredFirstReading() async -> LupedTransport {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true))
        var next = 0
        transport.beginBackgroundTask = { [unowned self] _ in
            next += 1
            let id = next
            events.append("begin \(id)")
            return { [unowned self] in events.append("end \(id)") }
        }
        snapshot = snapshot(readings: 1, lastLoop: start)
        transport.snapshotProvider = { [unowned self] in snapshot }
        let watchface = transport.watchfaceTransport
        watchface.handlePacket([2]) // PPoGATT reset request
        watchface.handlePacket([3]) // PPoGATT reset complete
        await transport.refresh()
        transport.sendIfNeeded(force: true)
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 0, message: [])
        XCTAssertEqual(events, [], "the first reading goes at once")
        return transport
    }

    private func snapshot(readings: Int, lastLoop: Date, insulinOnBoard: Double = 1.2, alert: Int = 0) -> LupedSnapshot {
        let values = (0..<readings).map { LupedReading(date: start.addingTimeInterval(Double($0) * 300), milligramsPerDeciliter: 120 + Double($0), trend: .flat) }
        let loop = LupedLoopStatus(insulinOnBoard: insulinOnBoard, carbsOnBoard: 10, lastLoopCompleted: lastLoop, isClosedLoop: true)
        return LupedSnapshot(readings: values, storedSampleCount: readings, unit: .milligramsPerDeciliter, hostAlertState: alert, alertEvent: alert > 0 ? 7 : 0, loopStatus: loop)
    }
}
