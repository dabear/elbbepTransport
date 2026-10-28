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
        // unitsFlag, timestamp, fullScreen, hostAlertLevel, alertEvent]. No
        // thresholds travel; the trailing zeros are the alert level and event.
        XCTAssertEqual(payload.data, "[1,110,10,4,[100,110],0,\(timestamp),0,0,0]")
        XCTAssertEqual(payload.readingCount, 2)
    }

    // The full-screen ring has no graph: the history is sent empty, while the
    // current value, delta and trend still come from the full readings.
    func testFullScreenSendsNoHistory() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110], trend: .fortyFiveUp), unit: .milligramsPerDeciliter, fullScreen: true))
        let timestamp = Int64(start.addingTimeInterval(300).timeIntervalSince1970 * 1_000)
        XCTAssertEqual(payload.data, "[1,110,10,4,[],0,\(timestamp),1,0,0]")
        XCTAssertEqual(payload.readingCount, 0)
    }

    // The reason only annotates the log; the wire array is unchanged.
    func testHostAlertReasonIsLoggedNotSent() throws {
        let plain = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertLevel: 0))
        let annotated = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertLevel: 0, hostAlertReason: "no active alerts from Loop"))
        XCTAssertEqual(annotated.data, plain.data)
        let levelLine = try XCTUnwrap(annotated.logDetails.components(separatedBy: "\n").first { $0.contains("host-issued alert level") })
        XCTAssertTrue(levelLine.hasSuffix("host-issued alert level: none (no active alerts from Loop)"), levelLine)
    }

    // The host alert level (index 8) is followed by the alert event (index 9).
    func testAlertLevelAndEventAreTheLastFields() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertLevel: 2, alertEvent: 417))
        XCTAssertTrue(payload.data.hasSuffix(",2,417]"), payload.data)
    }

    // A repeat of an active alert keeps the level but changes the event, so the
    // DATA differs and is sent (not skipped as already delivered).
    func testRepeatFireChangesData() throws {
        let first = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertLevel: 3, alertEvent: 7))
        let repeated = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertLevel: 3, alertEvent: 8))
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
            "4: [] glucose history (not sent: the full-screen ring has no graph)",
            "5: 0 mg/dL display",
            "6: \(timestamp) timestamp (milliseconds since Unix epoch)",
            "7: 1 full-screen ring",
            "8: 0 host-issued alert level: none",
            "9: 0 alert event (changes each time the host fires an alert)",
        ])
    }

    // The communication-log decode must always line up with the raw wire array:
    // one decoded line per element, each tagged with its zero-based wire index.
    func testDecodeAlwaysMatchesWire() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110], trend: .fortyFiveUp), unit: .milligramsPerDeciliter, fullScreen: true, hostAlertLevel: 3))
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

final class LupedAlarmStatusTests: XCTestCase {
    // The host issues the alerts (DATA index 8) and applies its own mute, so the
    // watch-side status reports only the user's Watch Alarms switch.
    func testStatusReflectsWatchAlarmsSwitch() {
        XCTAssertEqual(LupedPayload.watchAlarmStatus(watchAlarmsEnabled: true), "Watch alarms on")
        XCTAssertEqual(LupedPayload.watchAlarmStatus(watchAlarmsEnabled: false), "Watch alarms off: Watch Alarms is turned off")
    }
}

final class LupedSettingsTests: XCTestCase {
    func testRawValueRoundTrips() {
        let settings = LupedSettings(isEnabled: true, watchfaceUUID: UUID(), alarmsEnabled: false, fullScreen: true)
        XCTAssertEqual(LupedSettings(rawValue: settings.rawValue), settings)
    }

    func testMissingKeysUseDefaults() {
        XCTAssertEqual(LupedSettings(rawValue: [:]), LupedSettings())
        XCTAssertEqual(LupedSettings(rawValue: [UserDefaults.lupedPebbleWatchfaceUUIDKey: "not a uuid"]).watchfaceUUID, LupedSettings.defaultWatchfaceUUID)
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

    func testAChangedAlertLevelIsSent() {
        XCTAssertNil(LupedDelivery.unchangedData("[1,110,0,3,[],0,1,0,2]", delivered: "[1,110,0,3,[],0,1,0,0]", inFlight: nil))
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
        values.append([[6, 3, 1_793_133_000_000, -1], [7, 3, 1_793_134_849_400, 230], [8, 2, 1_793_136_649_400, 0]])
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: values), encoding: .utf8))

        let lines = LupedWatchDiagnostics.logDecode(json: json).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, values.count + 2 + 3)
        XCTAssertTrue(lines[values.count].hasSuffix("recent host-alert buzzes (listed below)"), lines[values.count])
        XCTAssertTrue(lines[values.count].contains(" 3 "), lines[values.count])
        XCTAssertTrue(lines[lines.count - 3].hasPrefix("Buzz for alert event 6 (critical) at "))
        XCTAssertTrue(lines[lines.count - 3].hasSuffix(": nothing covered the watchface during the buzz"))
        XCTAssertTrue(lines[lines.count - 2].hasSuffix("a pop-up covered the watchface 230 ms in, so PebbleOS may have cut the buzz short"))
        XCTAssertTrue(lines[lines.count - 1].hasPrefix("Buzz for alert event 8 (warning)"))
        XCTAssertTrue(lines[lines.count - 1].hasSuffix("a pop-up already covered the watchface, so PebbleOS may have dropped the buzz"))
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
        XCTAssertTrue(check.message.contains("Alert event 7 (critical)"), check.message)

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
