import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// Luped Remote asks for the host's presets (`presets`, answered on `PRESETS`)
/// to start or end one; `DATA` has none.
final class LupedPresetTests: XCTestCase {
    private let readings = [LupedReading(date: Date(timeIntervalSince1970: 1_800_000_000), milligramsPerDeciliter: 120, trend: .flat)]
    private let overrides = [
        LupedPreset(id: "A1", name: "Running", isActive: true),
        LupedPreset(id: "B2", name: "Sick day", isActive: false),
    ]

    private func fields(_ payload: LupedPayload?) throws -> [Any] {
        let data = try XCTUnwrap(payload?.data.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
    }

    /// Both sessions open, Luped Remote running, the host's snapshot read.
    @MainActor
    private func remoteRunning(overrides: [LupedPreset]?, tempTargets: [LupedPreset]?) async -> LupedTransport {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true, remoteEnabled: true))
        transport.snapshotProvider = { [readings] in
            LupedSnapshot(readings: readings, storedSampleCount: 1, unit: .milligramsPerDeciliter, overridePresets: overrides, tempTargetPresets: tempTargets)
        }
        for session in [transport.watchfaceTransport, transport.remoteTransport] {
            session.handlePacket([2])
            session.handlePacket([3])
        }
        await transport.refresh()
        receive("", on: transport, tuples: [PebbleAppMessage.alloyReadyKey: AppMessageTuple(type: PebbleAppMessage.tupleUnsigned, value: [1])])
        transport.pebbleTransport(transport.remoteTransport, didReceiveReply: true, transactionID: 0, message: [])
        return transport
    }

    @MainActor
    private func receive(_ command: String, on transport: LupedTransport, tuples: [UInt32: AppMessageTuple]? = nil) {
        let value = ArraySlice(Array(command.utf8) + [0])
        transport.pebbleTransport(transport.remoteTransport, didReceive: tuples ?? [LupedMessageKey.command: AppMessageTuple(type: PebbleAppMessage.tupleCString, value: value)], message: Array(repeating: 0, count: 20))
    }

    @MainActor
    private func sentPresets(_ transport: LupedTransport) -> [String] {
        transport.communicationLog.entries.filter { $0.kind == .toWatch && $0.message.contains("PRESETS") }.map(\.message)
    }

    @MainActor
    func testLoopsPresetsWithoutTempTargets() async throws {
        let transport = await remoteRunning(overrides: overrides, tempTargets: nil)
        receive("presets@\(Int(Date().timeIntervalSince1970))", on: transport)
        XCTAssertEqual(sentPresets(transport), [#"#1 PRESETS [[["A1","Running",1],["B2","Sick day",0]],null]"#])
    }

    @MainActor
    func testTriosTempTargetsReachLupedRemote() async throws {
        let transport = await remoteRunning(overrides: [], tempTargets: [LupedPreset(id: "T1", name: "Exercise", isActive: false)])
        receive("presets", on: transport)
        XCTAssertEqual(sentPresets(transport), [#"#1 PRESETS [[],[["T1","Exercise",0]]]"#])
    }

    func testDataIsUnchanged() throws {
        let watchface = try fields(LupedPayload(readings: readings, unit: .milligramsPerDeciliter, fullScreen: false, hostName: "Loop"))
        XCTAssertEqual(watchface.count, 16, "no presets in DATA; Luped Remote asks for them")
        let remote = try fields(LupedPayload(readings: readings, unit: .milligramsPerDeciliter, fullScreen: false, hostName: "Loop", remote: true))
        XCTAssertEqual(remote.count, 17, "Luped Remote also gets whether to ask for carb absorption")
    }

    // MARK: - Carb absorption

    func testRemoteIsToldWhetherTheHostUsesCarbAbsorption() throws {
        let loop = try fields(LupedPayload(readings: readings, unit: .milligramsPerDeciliter, fullScreen: false, hostName: "Loop", remote: true))
        XCTAssertEqual(loop[16] as? Int, 1)
        let trio = try fields(LupedPayload(readings: readings, unit: .milligramsPerDeciliter, fullScreen: false, hostName: "Trio", remote: true, usesCarbAbsorption: false))
        XCTAssertEqual(trio[16] as? Int, 0)
    }

    /// Index 16 stays at 16 when the host's name is unknown.
    func testCarbAbsorptionKeepsItsIndexWithoutAHostName() throws {
        let values = try fields(LupedPayload(readings: readings, unit: .milligramsPerDeciliter, fullScreen: false, remote: true, usesCarbAbsorption: false))
        XCTAssertEqual(values.count, 17)
        XCTAssertTrue(values[15] is NSNull)
        XCTAssertEqual(values[16] as? Int, 0)
    }

    func testWatchfaceGetsNoCarbAbsorptionField() throws {
        let values = try fields(LupedPayload(readings: readings, unit: .milligramsPerDeciliter, fullScreen: false, hostName: "Trio", usesCarbAbsorption: false))
        XCTAssertEqual(values.count, 16)
    }

    @MainActor
    func testTheSnapshotDecidesWhatRemoteIsTold() throws {
        let transport = LupedTransport(hostName: "Trio", settings: LupedSettings(isEnabled: true, remoteEnabled: true))
        let snapshot = LupedSnapshot(readings: readings, storedSampleCount: readings.count, unit: .milligramsPerDeciliter, usesCarbAbsorption: false)
        XCTAssertEqual(try fields(transport.payload(from: snapshot, for: .remote))[16] as? Int, 0)
        XCTAssertEqual(try fields(transport.payload(from: snapshot, for: .watchface)).count, 16)
    }

    func testAtMostSixteenPresetsWithFallbackNames() throws {
        let many = (1...20).map { LupedPreset(id: "p\($0)", name: $0 == 3 ? "🔥" : "P\($0)", isActive: false) }
        let list = try XCTUnwrap(LupedPreset.watchList(many) as? [[Any]])
        XCTAssertEqual(list.count, LupedPreset.maximumCount)
        XCTAssertEqual(list[2][1] as? String, "Preset 3")
        XCTAssertTrue(LupedPreset.watchList(nil) is NSNull)
    }

    // MARK: - Names and ids the watch can handle

    func testNamesTheWatchCanDraw() {
        func name(_ text: String) -> String { LupedPreset.watchName(text, fallback: "Preset 1") }
        XCTAssertEqual(name("Sick \"day\" \\ 2"), "Sick \"day\" \\ 2", "quotes and backslashes are only escaped by JSON")
        XCTAssertEqual(name("Line\nbreak\tand  spaces "), "Line break and spaces")
        XCTAssertEqual(name("🏃 Running"), "Running")
        XCTAssertEqual(name("Run 👨‍👩‍👧 fast ❤️"), "Run fast")
        XCTAssertEqual(name("🏃‍♀️🔥"), "Preset 1", "nothing drawable left")
        XCTAssertEqual(name("Søvn på hytta"), "Søvn på hytta")
        XCTAssertEqual(name("Cafe\u{301} au lait"), "Café au lait")
        XCTAssertEqual(name("zero\u{200B}width\u{FEFF}"), "zerowidth")
        let long = name(String(repeating: "abcdefghij", count: 5))
        XCTAssertEqual(long.count, LupedPreset.maximumNameLength)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testIdsTheWatchCanSendBack() {
        let uuid = "4F3A1C2E-9B7D-4E1A-8C5F-2D6B0A9E7F13"
        XCTAssertEqual(LupedPreset(id: uuid, name: "x", isActive: false).watchID, uuid)
        for unsafe in ["a:b", "x@y", "has space", "hash#1", "line\nbreak", "", String(repeating: "a", count: 65), "émoji🏃"] {
            let token = LupedPreset(id: unsafe, name: "x", isActive: false).watchID
            XCTAssertTrue(token.range(of: "^~[0-9a-f]{12}$", options: .regularExpression) != nil, "\(unsafe) -> \(token)")
        }
        XCTAssertEqual(LupedPreset(id: "a:b", name: "x", isActive: false).watchID, LupedPreset(id: "a:b", name: "y", isActive: true).watchID, "stable for the same id")
    }

    @MainActor
    func testATokenFromTheWatchStartsTheRightPreset() async throws {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true, remoteEnabled: true))
        let odd = LupedPreset(id: "odd:id@1", name: "Odd", isActive: false)
        transport.snapshotProvider = { [readings] in
            LupedSnapshot(readings: readings, storedSampleCount: 1, unit: .milligramsPerDeciliter, overridePresets: [odd])
        }
        await transport.refresh()
        var started: [LupedPresetAction] = []
        transport.overrideRequested = { action, _ in started.append(action) }
        let command = "override:\(odd.watchID)@\(Int(Date().timeIntervalSince1970))"
        let value = ArraySlice(Array(command.utf8) + [0])
        transport.pebbleTransport(transport.remoteTransport, didReceive: [LupedMessageKey.command: AppMessageTuple(type: PebbleAppMessage.tupleCString, value: value)], message: Array(repeating: 0, count: 20))
        XCTAssertEqual(started, [.start("odd:id@1")])
    }

    /// `mute:cancel` reaches the host as a mute of 0 minutes, which ends it.
    @MainActor
    func testEndingTheMute() async throws {
        let transport = await remoteRunning(overrides: nil, tempTargets: nil)
        var durations: [TimeInterval] = []
        transport.alertMuteRequested = { duration, _ in durations.append(duration) }
        receive("mute:60@\(Int(Date().timeIntervalSince1970))", on: transport)
        receive("mute:cancel@\(Int(Date().timeIntervalSince1970))", on: transport)
        XCTAssertEqual(durations, [3600, 0])
        XCTAssertTrue(transport.communicationLog.entries.contains { $0.message.hasPrefix("Watch asked to end the mute of Host alerts") })
    }
}
