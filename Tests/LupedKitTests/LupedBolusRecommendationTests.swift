import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// Luped Remote's `COMMAND recommend:<grams>` and the phone's `RECOMMEND` answer.
@MainActor
final class LupedBolusRecommendationTests: XCTestCase {
    func testParsesRecommendationRequests() {
        XCTAssertEqual(LupedWatchRequest(command: "recommend:10"), .recommend(grams: 10))
        XCTAssertEqual(LupedWatchRequest(command: "recommend:0"), .recommend(grams: 0))
        XCTAssertEqual(LupedWatchRequest(command: "recommend:12.5"), .recommend(grams: 12.5))
        XCTAssertEqual(LupedWatchRequest(command: "recommend:-5"), .recommend(grams: nil))
        XCTAssertEqual(LupedWatchRequest(command: "recommend:x"), .recommend(grams: nil))
        XCTAssertEqual(LupedWatchRequest(command: "recommend"), .recommend(grams: nil))
        XCTAssertEqual(LupedWatchRequest(command: "recommend:10")?.action, "recommend")
        XCTAssertEqual(LupedWatchRequest(command: "recommend:10:slow"), .recommend(grams: 10, absorption: .slow))
        XCTAssertEqual(LupedWatchRequest(command: "recommend:0:fast"), .recommend(grams: 0, absorption: .fast))
        XCTAssertEqual(LupedWatchRequest(command: "recommend:10:quick"), .recommend(grams: nil))
        XCTAssertEqual(LupedWatchRequest(command: "carbs:30:medium"), .carbs(30, absorption: .medium))
        XCTAssertEqual(LupedWatchRequest(command: "carbs:30"), .carbs(30, absorption: nil))
        XCTAssertEqual(LupedWatchRequest(command: "carbs:30:"), .carbs(nil))
        XCTAssertEqual(LupedWatchRequest(command: "carbs:30:slow:x"), .carbs(nil))
    }

    func testNumbersForTheWatch() {
        XCTAssertEqual(LupedTransport.number(0.45), "0.45")
        XCTAssertEqual(LupedTransport.number(10), "10")
        XCTAssertEqual(LupedTransport.number(0.025), "0.025")
        XCTAssertEqual(LupedTransport.number(1.0004), "1")
        XCTAssertEqual(LupedTransport.number(0), "0")
    }

    func testAnswerGoesToLupedRemote() async throws {
        let transport = try await remoteRunning()
        var asked: [Double] = []
        transport.bolusRecommendationRequested = { grams, _ in
            asked.append(grams)
            transport.sendBolusRecommendation(grams: grams, units: 0.45, maximumBolus: 5)
        }
        receive(command: "recommend:10@\(Int(Date().timeIntervalSince1970))", from: transport.remoteTransport, on: transport)

        XCTAssertEqual(asked, [10])
        XCTAssertEqual(sent(transport), ["#1 RECOMMEND 10:ok:0.45:5"])
    }

    func testIgnoredWithoutAHandler() async throws {
        let transport = try await remoteRunning()
        receive(command: "recommend:0", from: transport.remoteTransport, on: transport)

        XCTAssertEqual(sent(transport), ["#1 RECOMMEND 0:ignored"])
    }

    func testInvalidCarbsAreAnsweredAsRecommend() async throws {
        let transport = try await remoteRunning()
        transport.bolusRecommendationRequested = { _, _ in XCTFail("not passed on") }
        receive(command: "recommend:-1", from: transport.remoteTransport, on: transport)

        XCTAssertEqual(sent(transport), ["#1 RECOMMEND :failed:invalid amount"])
        XCTAssertFalse(transport.communicationLog.entries.contains { $0.message.contains("RESULT") })
    }

    func testAnswerIsDroppedOnceLupedRemoteClosed() async throws {
        let transport = try await remoteRunning()
        var answer: (() -> Void)?
        transport.bolusRecommendationRequested = { grams, _ in
            answer = { transport.sendBolusRecommendation(grams: grams, units: 0.45, maximumBolus: 5) }
        }
        receive(command: "recommend:10", from: transport.remoteTransport, on: transport)
        // The watchface starts again before the host has answered.
        receive(tuples: [PebbleAppMessage.alloyReadyKey: AppMessageTuple(type: PebbleAppMessage.tupleUnsigned, value: [1])], from: transport.watchfaceTransport, on: transport)
        answer?()

        XCTAssertEqual(sent(transport), [])
        XCTAssertTrue(transport.communicationLog.entries.contains { $0.message == "RECOMMEND 10:ok:0.45:5 not sent: Luped Remote is no longer running" })
    }

    // MARK: - Helpers

    /// Both sessions open and Luped Remote running, its reading acknowledged.
    private func remoteRunning() async throws -> LupedTransport {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true))
        let readingDate = Date()
        transport.snapshotProvider = {
            LupedSnapshot(readings: [LupedReading(date: readingDate, milligramsPerDeciliter: 120, trend: .flat)], storedSampleCount: 1, unit: .milligramsPerDeciliter)
        }
        for session in [transport.watchfaceTransport, transport.remoteTransport] {
            session.handlePacket([2]) // PPoGATT reset request
            session.handlePacket([3]) // PPoGATT reset complete
            XCTAssertTrue(session.isSessionOpen)
        }
        await transport.refresh()
        receive(tuples: [PebbleAppMessage.alloyReadyKey: AppMessageTuple(type: PebbleAppMessage.tupleUnsigned, value: [1])], from: transport.remoteTransport, on: transport)
        transport.pebbleTransport(transport.remoteTransport, didReceiveReply: true, transactionID: 0, message: [])
        XCTAssertEqual(transport.foreground, .remote)
        return transport
    }

    private func receive(command: String, from source: PebbleTransport, on transport: LupedTransport) {
        let value = ArraySlice(Array(command.utf8) + [0])
        receive(tuples: [LupedMessageKey.command: AppMessageTuple(type: PebbleAppMessage.tupleCString, value: value)], from: source, on: transport)
    }

    private func receive(tuples: [UInt32: AppMessageTuple], from source: PebbleTransport, on transport: LupedTransport) {
        transport.pebbleTransport(source, didReceive: tuples, message: Array(repeating: 0, count: 20))
    }

    /// The RECOMMEND messages pushed to the watch.
    private func sent(_ transport: LupedTransport) -> [String] {
        transport.communicationLog.entries.filter { $0.kind == .toWatch && $0.message.contains("RECOMMEND") }.map(\.message)
    }
}
