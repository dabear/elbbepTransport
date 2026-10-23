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
        // unitsFlag, timestamp, fullScreen, hostAlertLevel]. No thresholds travel;
        // the trailing 0 is the host-issued alert level.
        XCTAssertEqual(payload.data, "[1,110,10,4,[100,110],0,\(timestamp),0,0]")
        XCTAssertEqual(payload.readingCount, 2)
    }

    // The full-screen ring has no graph: the history is sent empty, while the
    // current value, delta and trend still come from the full readings.
    func testFullScreenSendsNoHistory() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110], trend: .fortyFiveUp), unit: .milligramsPerDeciliter, fullScreen: true))
        let timestamp = Int64(start.addingTimeInterval(300).timeIntervalSince1970 * 1_000)
        XCTAssertEqual(payload.data, "[1,110,10,4,[],0,\(timestamp),1,0]")
        XCTAssertEqual(payload.readingCount, 0)
    }

    // The reason only annotates the log; the wire array is unchanged.
    func testHostAlertReasonIsLoggedNotSent() throws {
        let plain = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertLevel: 0))
        let annotated = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertLevel: 0, hostAlertReason: "no active alerts from Loop"))
        XCTAssertEqual(annotated.data, plain.data)
        let last = try XCTUnwrap(annotated.logDetails.components(separatedBy: "\n").dropLast().last)
        XCTAssertTrue(last.hasSuffix("host-issued alert level: none (no active alerts from Loop)"), last)
    }

    func testHostAlertLevelIsLastField() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, fullScreen: false, hostAlertLevel: 2))
        XCTAssertTrue(payload.data.hasSuffix(",2]"), payload.data)
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
}

final class LupedAlarmStatusTests: XCTestCase {
    // The host issues the alerts (DATA index 10) and applies its own mute, so the
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
