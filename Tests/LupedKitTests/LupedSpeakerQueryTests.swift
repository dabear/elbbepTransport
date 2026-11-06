import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// `asksForSpeaker`: a host that doesn't know whether the watch has a speaker
/// asks the watchface (`COMMAND speaker`) once per session, after it
/// acknowledges a reading; the watch answers with its speaker report.
@MainActor
final class LupedSpeakerQueryTests: XCTestCase {
    func testAsksOnceAfterTheWatchfaceTakesAReading() async {
        let (transport, watchface) = await makeTransport(asksForSpeaker: true)
        XCTAssertEqual(count("#1 COMMAND speaker: asking", in: transport), 1)

        // The question is acknowledged and the next reading delivered: not asked again.
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 1, message: [])
        transport.sendIfNeeded(force: true)
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: lastSentID(transport), message: [])
        XCTAssertEqual(count("COMMAND speaker: asking", in: transport), 1)
    }

    func testDoesNotAskUnlessTheHostWantsIt() async {
        let (transport, _) = await makeTransport(asksForSpeaker: false)
        XCTAssertEqual(count("COMMAND speaker: asking", in: transport), 0)
    }

    func testAsksAgainInANewSessionWhileStillUnknown() async {
        let (transport, watchface) = await makeTransport(asksForSpeaker: true)
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 1, message: [])

        // The watch's session resets (out of range, Loop restarted): asked again.
        watchface.handlePacket([2])
        watchface.handlePacket([3])
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: lastSentID(transport), message: [])
        XCTAssertEqual(count("COMMAND speaker: asking", in: transport), 2)
    }

    func testTheSpeakerReportEndsTheQuestions() async {
        let (transport, watchface) = await makeTransport(asksForSpeaker: true)
        var reports: [Bool] = []
        transport.speakerDidReport = { reports.append($0) }
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 1, message: [])
        receive(command: "speaker:on", from: watchface, on: transport)
        XCTAssertEqual(reports, [false])
        XCTAssertFalse(transport.asksForSpeaker)

        watchface.handlePacket([2])
        watchface.handlePacket([3])
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: lastSentID(transport), message: [])
        XCTAssertEqual(count("COMMAND speaker: asking", in: transport), 1, "known now: not asked in the new session")
    }

    // MARK: - Helpers

    /// The watchface's session open, and its reading (#0) acknowledged.
    private func makeTransport(asksForSpeaker: Bool) async -> (LupedTransport, PebbleTransport) {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true))
        transport.asksForSpeaker = asksForSpeaker
        let readingDate = Date()
        transport.snapshotProvider = {
            LupedSnapshot(readings: [LupedReading(date: readingDate, milligramsPerDeciliter: 120, trend: .flat)], storedSampleCount: 1, unit: .milligramsPerDeciliter)
        }
        let watchface = transport.watchfaceTransport
        watchface.handlePacket([2]) // PPoGATT reset request
        watchface.handlePacket([3]) // PPoGATT reset complete
        await transport.refresh()
        transport.sendIfNeeded(force: true)
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 0, message: [])
        return (transport, watchface)
    }

    private func receive(command: String, from source: PebbleTransport, on transport: LupedTransport) {
        let value = ArraySlice(Array(command.utf8) + [0])
        transport.pebbleTransport(source, didReceive: [LupedMessageKey.command: AppMessageTuple(type: PebbleAppMessage.tupleCString, value: value)], message: Array(repeating: 0, count: 20))
    }

    /// The transaction id of the last message sent to the watch.
    private func lastSentID(_ transport: LupedTransport) -> UInt8 {
        let last = transport.communicationLog.entries.last { $0.kind == .toWatch && $0.message.hasPrefix("#") }
        let digits = last?.message.dropFirst().prefix { $0.isNumber } ?? ""
        return UInt8(digits) ?? 0
    }

    private func count(_ text: String, in transport: LupedTransport) -> Int {
        transport.communicationLog.entries.filter { $0.message.contains(text) }.count
    }
}
