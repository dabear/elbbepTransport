import XCTest
@testable import LupedKit

final class LupedPayloadTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func readings(_ values: [Double], trend: LupedTrend? = nil) -> [LupedReading] {
        values.enumerated().map { index, mgdl in
            LupedReading(date: start.addingTimeInterval(Double(index) * 300), milligramsPerDeciliter: mgdl, trend: trend)
        }
    }

    func testNoReadingsMakesNoPayload() {
        XCTAssertNil(LupedPayload(readings: [], unit: .milligramsPerDeciliter, fullScreen: false))
    }

    func testMilligramsPayload() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110], trend: .fortyFiveUp), unit: .milligramsPerDeciliter, fullScreen: false))
        let timestamp = Int64(start.addingTimeInterval(300).timeIntervalSince1970 * 1_000)
        // Minimal Luped protocol: [version, glucose, delta, trend, history,
        // unitsFlag, timestamp, fullScreen, hostAlertState, alertEvent, iob, cob,
        // lastLoop, closedLoop, statusLine]. No thresholds travel; the zeros are
        // the alert level and event, and the rest is null when the host sends none.
        XCTAssertEqual(payload.data, "[1,110,10,4,[100,110],0,\(timestamp),0,0,0,null,null,null,null,null]")
        XCTAssertEqual(payload.readingCount, 2)
    }

    // Large Glucose has no graph: the history is sent empty, while the
    // current value, delta and trend still come from the full readings.
    // Loop status: IOB to one decimal (so it changes about once a reading, not
    // every minute), whole grams of COB, the last loop in ms
    // since the epoch and the closed-loop flag.
    func testLoopStatusFields() throws {
        let lastLoop = start.addingTimeInterval(240)
        let status = LupedLoopStatus(insulinOnBoard: 1.234, carbsOnBoard: 12.6, lastLoopCompleted: lastLoop, isClosedLoop: false)
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, loopStatus: status))
        XCTAssertTrue(payload.data.hasSuffix(",1.2,13,\(Int64(lastLoop.timeIntervalSince1970 * 1_000)),0,null]"), payload.data)
        XCTAssertTrue(payload.logDetails.contains("open loop"), payload.logDetails)
    }

    // The status line is formatted on the phone in the display unit; IOB and
    // COB are left to the watch (null), as is a choice the host has no data for.
    func testStatusLineChoices() throws {
        let therapy = LupedTherapy(tempBasalRate: 0.45, scheduledBasalRate: 0.8, insulinSensitivity: 45, eventualGlucose: 110, correctionRange: 100...110)
        XCTAssertNil(LupedPayload.statusLine(.iobAndCob, therapy: therapy, unit: .milligramsPerDeciliter))
        // Only ISF & target is split ("ISF\ttarget") around the watch's glucose ring.
        XCTAssertEqual(LupedPayload.statusLine(.tempBasal, therapy: therapy, unit: .milligramsPerDeciliter), "Temp 0.45 U/h")
        XCTAssertEqual(LupedPayload.statusLine(.tempBasal, therapy: LupedTherapy(scheduledBasalRate: 0.8), unit: .milligramsPerDeciliter), "Basal 0.80 U/h")
        XCTAssertEqual(LupedPayload.statusLine(.eventualGlucose, therapy: therapy, unit: .millimolesPerLiter), "Eventual 6.1")
        XCTAssertEqual(LupedPayload.statusLine(.sensitivityAndTarget, therapy: therapy, unit: .milligramsPerDeciliter), "ISF 45\t100–110")
        XCTAssertEqual(LupedPayload.statusLine(.sensitivityAndTarget, therapy: therapy, unit: .millimolesPerLiter), "ISF 2.5\t5.6–6.1")
        XCTAssertEqual(LupedPayload.statusLine(.sensitivityAndTarget, therapy: LupedTherapy(insulinSensitivity: 45), unit: .milligramsPerDeciliter), "ISF 45\t")
        XCTAssertNil(LupedPayload.statusLine(.eventualGlucose, therapy: nil, unit: .milligramsPerDeciliter))

        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, statusLine: "ISF 45\t100–110"))
        XCTAssertTrue(payload.data.hasSuffix(",\"ISF 45\\t100–110\"]"), payload.data)
    }

    func testFullScreenSendsNoHistory() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110], trend: .fortyFiveUp), unit: .milligramsPerDeciliter, fullScreen: true))
        let timestamp = Int64(start.addingTimeInterval(300).timeIntervalSince1970 * 1_000)
        XCTAssertEqual(payload.data, "[1,110,10,4,[],0,\(timestamp),1,0,0,null,null,null,null,null]")
        XCTAssertEqual(payload.readingCount, 0)
    }

    // The reason only annotates the log; the wire array is unchanged.
    func testHostAlertReasonIsLoggedNotSent() throws {
        let plain = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertState: 0))
        let annotated = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertState: 0, hostAlertReason: "no active alerts from Loop"))
        XCTAssertEqual(annotated.data, plain.data)
        let levelLine = try XCTUnwrap(annotated.logDetails.components(separatedBy: "\n").first { $0.contains("host alert:") })
        XCTAssertTrue(levelLine.hasSuffix("host alert: none (no active alerts from Loop)"), levelLine)
    }

    // The host alert level (index 8) is followed by the alert event (index 9),
    // then the loop status (indexes 10-13).
    func testAlertLevelAndEventAreIndexes8And9() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertState: 2, alertEvent: 417))
        XCTAssertTrue(payload.data.hasSuffix(",2,417,null,null,null,null,null]"), payload.data)
    }

    // A repeat of an active alert keeps the level but changes the event, so the
    // DATA differs and is sent (not skipped as already delivered).
    func testRepeatFireChangesData() throws {
        let first = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertState: 3, alertEvent: 7))
        let repeated = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertState: 3, alertEvent: 8))
        XCTAssertNotEqual(first.data, repeated.data)
        XCTAssertNil(LupedDelivery.unchangedData(repeated.data, delivered: first.data, inFlight: nil))
    }

    func testLogSummaryAndDecodedDetails() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110], trend: .fortyFiveUp), unit: .milligramsPerDeciliter, fullScreen: true))
        XCTAssertTrue(payload.logSummary.hasPrefix("110 mg/dL ↗ +10 at "), payload.logSummary)

        let timestamp = Int64(start.addingTimeInterval(300).timeIntervalSince1970 * 1_000)
        let lines = payload.logDetails.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "raw [")
        XCTAssertEqual(lines.last, "]")

        // Collapse the alignment padding so each decoded field can be compared.
        let decoded = lines.dropFirst().dropLast().map { $0.split(separator: " ").joined(separator: " ") }
        XCTAssertEqual(decoded, [
            "0: 1 protocol version",
            "1: 110 current glucose (mg/dL)",
            "2: 10 delta (mg/dL)",
            "3: 4 trend code ↗",
            "4: [] glucose history (not sent: Large Glucose has no graph)",
            "5: 0 mg/dL display",
            "6: \(timestamp) timestamp (milliseconds since Unix epoch)",
            "7: 1 layout: Large Glucose",
            "8: 0 host alert: none",
            "9: 0 alert event (changes each time the host fires an alert)",
            "10: null insulin on board (not provided by the host)",
            "11: null carbs on board (not provided by the host)",
            "12: null last loop completed (not provided by the host)",
            "13: null closed or open loop (not provided by the host)",
            "14: null status line: IOB and COB, formatted on the watch",
        ])
    }

    // The communication-log decode must always line up with the raw wire array:
    // one decoded line per element, each tagged with its zero-based wire index.
    func testDecodeAlwaysMatchesWire() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110], trend: .fortyFiveUp), unit: .milligramsPerDeciliter, fullScreen: true, hostAlertState: 3))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.data.utf8)) as? [Any])
        let body = payload.logDetails.components(separatedBy: "\n").dropFirst().dropLast()
        XCTAssertEqual(body.count, wire.count, "decoded line count must equal wire element count")
        for (index, line) in body.enumerated() {
            XCTAssertTrue(line.trimmingCharacters(in: .whitespaces).hasPrefix("\(index):"), "line \(index): \(line)")
        }
    }

    func testMillimolesRoundToOneDecimal() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([122.5]), unit: .millimolesPerLiter, fullScreen: false))
        // 122.5 mg/dL = 6.8 mmol/L; no thresholds travel in the minimal protocol.
        XCTAssertTrue(payload.data.hasPrefix("[1,6.8,0,3,[6.8],1,"), payload.data)
    }

    // The wire sends 7 for 7.0 mmol/L, but the log headline shows it the way the phone does.
    func testLogSummaryKeepsMillimolesDecimal() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([129.7, 126.1]), unit: .millimolesPerLiter, fullScreen: false))
        XCTAssertTrue(payload.data.hasPrefix("[1,7,-0.2,"), payload.data)
        XCTAssertTrue(payload.logSummary.hasPrefix("7.0 mmol/L "), payload.logSummary)
        XCTAssertTrue(payload.logSummary.contains(" -0.2 at "), payload.logSummary)
    }

    func testTrendFallsBackToRate() throws {
        // +30 mg/dL in 5 minutes is 6 mg/dL/min: DoubleUp.
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 130]), unit: .milligramsPerDeciliter, fullScreen: false))
        XCTAssertTrue(payload.data.hasPrefix("[1,130,30,6,"), payload.data)
    }

    func testKeepsTwelveNewestReadings() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings(Array(stride(from: 100.0, to: 115.0, by: 1))), unit: .milligramsPerDeciliter, fullScreen: false))
        XCTAssertEqual(payload.readingCount, 12)
        XCTAssertTrue(payload.data.contains("[103,104,105,106,107,108,109,110,111,112,113,114]"), payload.data)
    }

    // A 1-minute CGM: the graph still covers an hour (one value every 5 minutes,
    // newest last), and the delta compares against the reading 5 minutes earlier.
    func testOneMinuteReadingsAreThinnedToFiveMinutes() throws {
        let minuteReadings = (0..<90).map { minute in
            LupedReading(date: start.addingTimeInterval(Double(minute) * 60 + Double(minute % 3)), milligramsPerDeciliter: 100 + Double(minute), trend: nil)
        }
        let payload = try XCTUnwrap(LupedPayload(readings: minuteReadings, unit: .milligramsPerDeciliter, fullScreen: false))
        XCTAssertEqual(payload.readingCount, 12)
        XCTAssertTrue(payload.data.hasPrefix("[1,189,5,"), payload.data)
        XCTAssertTrue(payload.data.contains("[134,139,144,149,154,159,164,169,174,179,184,189]"), payload.data)
    }

    // A 5-minute CGM whose readings arrive a few seconds early keeps every reading.
    func testJitteredFiveMinuteReadingsAreAllKept() {
        let jittered = (0..<12).map { index in
            LupedReading(date: start.addingTimeInterval(Double(index) * 295), milligramsPerDeciliter: 100 + Double(index), trend: nil)
        }
        XCTAssertEqual(LupedPayload.graphReadings(jittered.shuffled(), limit: 12), jittered)
    }
}

final class LupedSettingsTests: XCTestCase {
    func testRawValueRoundTrips() {
        let settings = LupedSettings(isEnabled: true, watchfaceUUID: UUID(), alarmsEnabled: false, fullScreen: true)
        XCTAssertEqual(LupedSettings(rawValue: settings.rawValue), settings)
    }

    // The status line choice survives a round trip and defaults to IOB and COB.
    func testStatusLineRoundTrips() {
        XCTAssertEqual(LupedSettings().statusLine, .iobAndCob)
        XCTAssertEqual(LupedSettings(rawValue: LupedSettings(statusLine: .eventualGlucose).rawValue).statusLine, .eventualGlucose)
        XCTAssertEqual(LupedSettings(rawValue: ["lupedPebbleStatusLine": "unknown"]).statusLine, .iobAndCob)
    }

    func testMissingKeysUseDefaults() {
        XCTAssertEqual(LupedSettings(rawValue: [:]), LupedSettings())
        XCTAssertEqual(LupedSettings(rawValue: ["lupedPebbleWatchfaceUUID": "not a uuid"]).watchfaceUUID, LupedSettings.defaultWatchfaceUUID)
    }
}

final class LupedDeliveryTests: XCTestCase {
    func testNewDataIsSent() {
        XCTAssertNil(LupedDelivery.unchangedData("[1,110]", delivered: "[1,100]", inFlight: nil))
        XCTAssertNil(LupedDelivery.unchangedData("[1,110]", delivered: nil, inFlight: nil), "nothing delivered yet in this session")
    }

    func testDataTheWatchAlreadyHasIsSkipped() {
        XCTAssertEqual(LupedDelivery.unchangedData("[1,110]", delivered: "[1,110]", inFlight: nil), .delivered)
    }

    // A second host refresh while the same message is still awaiting its ACK
    // must not queue a back-to-back duplicate.
    func testDataAlreadyInFlightIsSkipped() {
        XCTAssertEqual(LupedDelivery.unchangedData("[1,110]", delivered: "[1,100]", inFlight: "[1,110]"), .inFlight)
    }

    // A RESULT that was in flight when the watchface restarted goes out again;
    // a diagnostics request is dropped.
    func testOnlyResultsAreResentAfterAWatchfaceRestart() {
        XCTAssertEqual(LupedDelivery.resultToResend(afterRestart: "RESULT carbs:ok"), "carbs:ok")
        XCTAssertNil(LupedDelivery.resultToResend(afterRestart: "COMMAND diagnostics"))
    }

    func testAChangedAlertLevelIsSent() {
        XCTAssertNil(LupedDelivery.unchangedData("[1,110,0,3,[],0,1,0,2]", delivered: "[1,110,0,3,[],0,1,0,0]", inFlight: nil))
    }
}

final class LupedWatchRequestTests: XCTestCase {
    // The watch chooses the amount; anything that isn't a positive number is
    // kept as a request without an amount, so it can be answered "failed".
    func testParsesAmounts() {
        XCTAssertEqual(LupedWatchRequest(command: "bolus:0.1"), .bolus(0.1, forced: false))
        XCTAssertEqual(LupedWatchRequest(command: "forcedbolus:1.25"), .bolus(1.25, forced: true))
        XCTAssertEqual(LupedWatchRequest(command: "carbs:77"), .carbs(77))
        XCTAssertEqual(LupedWatchRequest(command: "carbs"), .carbs(nil))
        XCTAssertEqual(LupedWatchRequest(command: "bolus:-1"), .bolus(nil, forced: false))
        XCTAssertEqual(LupedWatchRequest(command: "bolus:abc"), .bolus(nil, forced: false))
        XCTAssertNil(LupedWatchRequest(command: "refresh"))
        XCTAssertNil(LupedWatchRequest(command: "mute:30"))
        XCTAssertEqual(LupedWatchRequest(command: "forcedbolus:x")?.action, "forcedbolus")
    }
}

final class LupedWatchDiagnosticsLogTests: XCTestCase {
    // A version-2 snapshot decodes one line per field, with the latency buckets
    // shown inline, and every field has a description.
    func testDiagnosticsDecodeOneLinePerField() throws {
        var values: [Any] = [2, 1_792_957_000_000, 85] + Array(repeating: 0, count: 27)
        values.append([3, 1, 0, 0, 0, 0, 0, 0])  // index 30: latency buckets
        values += Array(repeating: 0, count: 8)
        values.append([])  // index 39: no buzzes
        values.append(0)  // index 40: alert events while Watch Alarms was off
        XCTAssertEqual(values.count, LupedWatchDiagnostics.fieldDescriptions.count)
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: values), encoding: .utf8))

        let lines = LupedWatchDiagnostics.logDecode(json: json).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "raw [")
        XCTAssertEqual(lines.count, values.count + 2)
        let decoded = lines.dropFirst().dropLast().map { $0.split(separator: " ").joined(separator: " ") }
        XCTAssertEqual(decoded[2], "2: 85 battery (%)")
        XCTAssertTrue(decoded[30].hasPrefix("30: [3, 1, 0, 0, 0, 0, 0, 0] refresh responses by latency"), decoded[30])
        XCTAssertFalse(decoded.contains { $0.hasSuffix(" unknown") })
    }

    // Luped's buzz records decode to one line each after the table, naming the
    // pop-up that covered the watchface so a missed buzz can be explained.
    func testBuzzesDecodeBelowTheTable() throws {
        var values: [Any] = [2] + Array(repeating: 0, count: 37) + [1]
        values.append([[6, 3, 1_793_133_000_000, -1], [7, 3, 1_793_134_849_400, 230], [8, 2, 1_793_136_649_400, 0], [9, 3, 1_793_138_449_400, -2]])
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: values), encoding: .utf8))

        let lines = LupedWatchDiagnostics.logDecode(json: json).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, values.count + 2 + 4)
        XCTAssertTrue(lines[lines.count - 1].hasSuffix("the watchface's buzz call failed with an error, so it did not buzz"), lines[lines.count - 1])
        XCTAssertTrue(lines[values.count].hasSuffix("recent host-alert buzzes (listed below)"), lines[values.count])
        XCTAssertTrue(lines[values.count].contains(" 4 "), lines[values.count])
        XCTAssertTrue(lines[lines.count - 4].hasPrefix("Buzz for alert event 6 (high) at "))
        XCTAssertTrue(lines[lines.count - 4].hasSuffix(": nothing covered the watchface during the buzz"))
        XCTAssertTrue(lines[lines.count - 3].hasSuffix("a pop-up covered the watchface 230 ms in, so PebbleOS may have cut the buzz short"))
        XCTAssertTrue(lines[lines.count - 2].hasPrefix("Buzz for alert event 8 (urgent low)"))
        XCTAssertTrue(lines[lines.count - 2].hasSuffix("a pop-up already covered the watchface, so PebbleOS may have dropped the buzz"))
    }

    // Fires the watch acknowledged are checked against its buzz records: one
    // without a record means the watchface never tried to buzz.
    func testBuzzCheckFindsFiresWithoutARecord() throws {
        let now = Date(timeIntervalSince1970: 1_793_140_000)
        var values: [Any] = [2, 0, 0, 1_793_120_000_000] + Array(repeating: 0, count: 34) + [1]
        values.append([[6, 3, 1_793_133_000_000, -1]])
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: values), encoding: .utf8))
        let delivered = [
            LupedDeliveredAlert(event: 5, level: 3, deliveredAt: Date(timeIntervalSince1970: 1_793_110_000)), // before the window
            LupedDeliveredAlert(event: 6, level: 3, deliveredAt: Date(timeIntervalSince1970: 1_793_133_000)),
            LupedDeliveredAlert(event: 7, level: 3, deliveredAt: Date(timeIntervalSince1970: 1_793_134_849)),
            LupedDeliveredAlert(event: 8, level: 3, deliveredAt: now.addingTimeInterval(-2)), // too recent
        ]

        let check = try XCTUnwrap(LupedWatchDiagnostics.buzzCheck(json: json, delivered: delivered, receivedAt: now))
        XCTAssertEqual(check.missing.map(\.event), [7])
        XCTAssertTrue(check.message.contains("Alert event 7 (high)"), check.message)

        let allBuzzed = try XCTUnwrap(LupedWatchDiagnostics.buzzCheck(json: json, delivered: Array(delivered.prefix(2)), receivedAt: now))
        XCTAssertTrue(allBuzzed.missing.isEmpty)
        XCTAssertTrue(allBuzzed.message.hasSuffix("each of the 1 alert fires it acknowledged"), allBuzzed.message)
    }

    func testUnknownDiagnosticsFormatIsLoggedRaw() {
        XCTAssertEqual(LupedWatchDiagnostics.logDecode(json: "[1,2,3]"), "[1,2,3]")
        XCTAssertEqual(LupedWatchDiagnostics.logDecode(json: "not json"), "not json")
    }
}

final class LupedWatchDiagnosticsRestoreTests: XCTestCase {
    // A report saved on an earlier launch keeps its original arrival time, so the
    // settings screen shows how old it is.
    func testRestoredReportKeepsItsArrivalTime() throws {
        let json = "[2,1792957000000,85,1792950000000,1,0,0,0,0,0,0,0,0,12,3]"
        let receivedAt = Date(timeIntervalSince1970: 1_792_957_000)
        let report = try XCTUnwrap(LupedWatchDiagnostics(json: json, receivedAt: receivedAt))
        XCTAssertEqual(report.receivedAt, receivedAt)
        XCTAssertEqual(report.battery, 85)
        XCTAssertEqual(report.readingsReceived, 12)
    }
}

final class LupedStatusLineChoiceTests: XCTestCase {
    private let status = LupedLoopStatus(insulinOnBoard: 1.25, carbsOnBoard: 12, lastLoopCompleted: Date(timeIntervalSince1970: 1_800_000_000), isClosedLoop: true)
    private let readings = [LupedReading(date: Date(timeIntervalSince1970: 1_800_000_000), milligramsPerDeciliter: 110, trend: nil)]

    private func settings(_ line: LupedStatusLine, loopRing: Bool = true) -> LupedSettings {
        LupedSettings(isEnabled: true, statusLine: line, loopRing: loopRing)
    }

    private func decoded(_ settings: LupedSettings, loopStatus: LupedLoopStatus?) throws -> [String] {
        let payload = try XCTUnwrap(LupedPayload(readings: readings, unit: .milligramsPerDeciliter, fullScreen: false, loopStatus: settings.loopStatusToSend(loopStatus), statusLine: nil, settings: settings))
        return payload.logDetails.components(separatedBy: "\n").dropFirst().dropLast().map { $0.split(separator: " ").joined(separator: " ") }
    }

    // None with the loop ring off: nothing requested or sent.
    func testNoneWithoutLoopRingSendsNothing() {
        let off = settings(.none, loopRing: false)
        XCTAssertFalse(off.needsLoopStatus)
        XCTAssertFalse(off.needsTherapy)
        XCTAssertFalse(off.showsLoopRing)
        XCTAssertNil(off.loopStatusToSend(status))
        XCTAssertNil(LupedPayload.statusLine(.none, therapy: LupedTherapy(eventualGlucose: 110), unit: .milligramsPerDeciliter))
    }

    // None keeps the loop ring by default, so the watch still shows when Loop last ran.
    func testNoneKeepsTheLoopRingByDefault() {
        let none = settings(.none)
        XCTAssertTrue(none.showsLoopRing)
        XCTAssertTrue(none.needsLoopStatus)
        let sent = none.loopStatusToSend(status)
        XCTAssertNil(sent?.insulinOnBoard)
        XCTAssertNil(sent?.carbsOnBoard)
        XCTAssertEqual(sent?.lastLoopCompleted, status.lastLoopCompleted)
        XCTAssertEqual(sent?.isClosedLoop, true)
    }

    // A shown line always needs the loop's age (stale dimming), so the ring stays on.
    func testAShownLineForcesTheLoopRing() {
        for line in [LupedStatusLine.iobAndCob, .tempBasal, .eventualGlucose, .sensitivityAndTarget] {
            XCTAssertTrue(settings(line, loopRing: false).showsLoopRing, "\(line)")
            XCTAssertNotNil(settings(line, loopRing: false).loopStatusToSend(status)?.lastLoopCompleted, "\(line)")
        }
    }

    func testIOBAndCOBSendsTheWholeLoopStatus() {
        XCTAssertEqual(settings(.iobAndCob).loopStatusToSend(status), status)
        XCTAssertFalse(settings(.iobAndCob).needsTherapy)
    }

    func testTherapyLinesDropIOBAndCOB() {
        for line in [LupedStatusLine.tempBasal, .eventualGlucose, .sensitivityAndTarget] {
            XCTAssertTrue(settings(line).needsTherapy, "\(line)")
            let sent = settings(line).loopStatusToSend(status)
            XCTAssertNil(sent?.insulinOnBoard)
            XCTAssertNil(sent?.carbsOnBoard)
            XCTAssertEqual(sent?.lastLoopCompleted, status.lastLoopCompleted)
        }
    }

    // The log says why each null field is null.
    func testDecodeExplainsNullFields() throws {
        let off = try decoded(settings(.none, loopRing: false), loopStatus: status)
        XCTAssertEqual(Array(off.suffix(5)), [
            "10: null insulin on board (not sent: Status Line is None)",
            "11: null carbs on board (not sent: Status Line is None)",
            "12: null last loop completed (not sent: Status Line is None and Last Loop is off)",
            "13: null closed or open loop (not sent: Status Line is None and Last Loop is off)",
            "14: null status line: none (Status Line is None)",
        ])
        let ring = try decoded(settings(.none), loopStatus: status)
        XCTAssertEqual(ring[12], "12: 1800000000000 last loop completed (milliseconds since Unix epoch)")
        let missing = try decoded(settings(.iobAndCob), loopStatus: LupedLoopStatus(insulinOnBoard: 1, carbsOnBoard: nil, lastLoopCompleted: nil, isClosedLoop: true))
        XCTAssertEqual(missing[11], "11: null carbs on board (not provided by the host)")
        XCTAssertEqual(missing[12], "12: null last loop completed (not provided by the host)")
        let empty = try decoded(settings(.eventualGlucose), loopStatus: status)
        XCTAssertEqual(empty[14], "14: null status line: empty (the host provided no Eventual Glucose value)")
    }

    func testNonePayloadWithoutLoopRingHasNullStatusFields() throws {
        let off = settings(.none, loopRing: false)
        let payload = try XCTUnwrap(LupedPayload(readings: readings, unit: .milligramsPerDeciliter, fullScreen: false, loopStatus: off.loopStatusToSend(status), statusLine: nil, settings: off))
        XCTAssertTrue(payload.data.hasSuffix(",null,null,null,null,null]"), payload.data)
    }

    // Large Glucose has no status line or loop ring: nothing beyond readings is
    // requested or sent, and the chosen line is kept for when Graph returns.
    func testLargeGlucoseTurnsOffTheStatusLineAndLastLoop() throws {
        for line in LupedStatusLine.allCases {
            var large = settings(line)
            large.fullScreen = true
            XCTAssertEqual(large.shownStatusLine, LupedStatusLine.none, "\(line)")
            XCTAssertFalse(large.showsLoopRing, "\(line)")
            XCTAssertFalse(large.needsLoopStatus, "\(line)")
            XCTAssertFalse(large.needsTherapy, "\(line)")
            XCTAssertNil(large.loopStatusToSend(status), "\(line)")
            XCTAssertEqual(large.statusLine, line, "the choice is kept")
            large.fullScreen = false
            XCTAssertEqual(large, settings(line))
        }
        var large = settings(.iobAndCob)
        large.fullScreen = true
        let payload = try XCTUnwrap(LupedPayload(readings: readings, unit: .milligramsPerDeciliter, fullScreen: true, loopStatus: large.loopStatusToSend(status), statusLine: nil, settings: large))
        let rows = payload.logDetails.components(separatedBy: "\n").dropFirst().dropLast().map { $0.split(separator: " ").joined(separator: " ") }
        XCTAssertEqual(Array(rows.suffix(5)), [
            "10: null insulin on board (not sent: Layout is Large Glucose)",
            "11: null carbs on board (not sent: Layout is Large Glucose)",
            "12: null last loop completed (not sent: Layout is Large Glucose)",
            "13: null closed or open loop (not sent: Layout is Large Glucose)",
            "14: null status line: none (Layout is Large Glucose)",
        ])
    }

    func testStoredSettingsRoundTrip() {
        let stored = settings(.none, loopRing: false)
        let restored = LupedSettings(rawValue: stored.rawValue)
        XCTAssertEqual(restored.statusLine, LupedStatusLine.none)
        XCTAssertFalse(restored.loopRing)
        XCTAssertTrue(LupedSettings(rawValue: [:]).loopRing, "the loop ring defaults to on")
    }
}

final class LupedSendTimingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let loop = LupedLoopStatus(insulinOnBoard: 1.2, carbsOnBoard: 10, lastLoopCompleted: Date(timeIntervalSince1970: 1_799_999_700), isClosedLoop: true)

    private func payload(_ mgdl: [Double], alertLevel: Int = 0, alertEvent: Int = 0, fullScreen: Bool = false, loop: LupedLoopStatus? = nil) -> LupedPayload {
        let readings = mgdl.enumerated().map { LupedReading(date: start.addingTimeInterval(Double($0.offset) * 300), milligramsPerDeciliter: $0.element, trend: nil) }
        return LupedPayload(readings: readings, unit: .milligramsPerDeciliter, fullScreen: fullScreen, hostAlertState: alertLevel, alertEvent: alertEvent, loopStatus: loop)!
    }

    func testFirstMessageGoesNow() {
        XCTAssertEqual(LupedDelivery.timing(new: payload([100]), previous: nil, needsLoopStatus: true), .now)
    }

    // A new reading waits briefly for the loop result, but only if loop status is sent.
    func testNewReadingHoldsOnlyWithLoopStatus() {
        let old = payload([100], loop: loop)
        XCTAssertEqual(LupedDelivery.timing(new: payload([100, 110], loop: loop), previous: old, needsLoopStatus: true), .holdForLoopResult)
        XCTAssertEqual(LupedDelivery.timing(new: payload([100, 110]), previous: payload([100]), needsLoopStatus: false), .now)
    }

    // Once the loop has run on the reading (last loop later than the reading),
    // the reading and its loop result go at once.
    func testNewReadingWithItsLoopResultGoesNow() {
        var ran = loop
        ran.lastLoopCompleted = start.addingTimeInterval(300 + 0.15)
        XCTAssertEqual(LupedDelivery.timing(new: payload([100, 110], loop: ran), previous: payload([100], loop: loop), needsLoopStatus: true), .now)
        XCTAssertEqual(LupedDelivery.newReadingHold, 10)
    }

    // Alerts are never delayed, not even together with a new reading.
    func testAlertChangesGoNow() {
        let old = payload([100], loop: loop)
        XCTAssertEqual(LupedDelivery.timing(new: payload([100, 110], alertLevel: 2, alertEvent: 1, loop: loop), previous: old, needsLoopStatus: true), .now)
        XCTAssertEqual(LupedDelivery.timing(new: payload([100], alertEvent: 1, loop: loop), previous: old, needsLoopStatus: true), .now)
    }

    func testLoopOnlyChangesAreCollected() {
        var newer = loop
        newer.lastLoopCompleted = loop.lastLoopCompleted?.addingTimeInterval(300)
        newer.insulinOnBoard = 1.1
        XCTAssertEqual(LupedDelivery.timing(new: payload([100], loop: newer), previous: payload([100], loop: loop), needsLoopStatus: true), .collectFollowUps)
    }

    func testDisplayChangesGoNow() {
        XCTAssertEqual(LupedDelivery.timing(new: payload([100, 110], fullScreen: true, loop: loop), previous: payload([100, 110], loop: loop), needsLoopStatus: true), .now)
    }
}

final class LupedAlertStateTests: XCTestCase {
    func testStateNames() {
        XCTAssertEqual(LupedPayload.alertStateName(0), "none")
        XCTAssertEqual(LupedPayload.alertStateName(1), "low")
        XCTAssertEqual(LupedPayload.alertStateName(2), "urgent low")
        XCTAssertEqual(LupedPayload.alertStateName(3), "high")
        XCTAssertEqual(LupedPayload.alertStateName(4), "predicted low")
        XCTAssertEqual(LupedPayload.alertStateName(-1), "low, Watch Alarms is off")
    }
}
