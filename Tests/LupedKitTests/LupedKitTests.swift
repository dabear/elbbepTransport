import XCTest
@testable import LupedKit

final class LupedPayloadTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func readings(_ values: [Double], trend: LupedTrend? = nil) -> [LupedReading] {
        values.enumerated().map { index, mgdl in
            LupedReading(date: start.addingTimeInterval(Double(index) * 300), milligramsPerDeciliter: mgdl, trend: trend)
        }
    }

    private let alarms = LupedAlarmSettings(
        urgentLowMgDL: 55, lowMgDL: 70, highMgDL: 180, enabledMask: 7,
        urgentLowRepeat: 300, lowRepeat: 900, highRepeat: LupedAlarmSettings.oncePerEpisode
    )

    func testNoReadingsMakesNoPayload() {
        XCTAssertNil(LupedPayload(readings: [], unit: .milligramsPerDeciliter, alarms: alarms, fullScreen: false))
    }

    func testMilligramsPayload() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110], trend: .fortyFiveUp), unit: .milligramsPerDeciliter, alarms: alarms, fullScreen: true))
        let timestamp = Int64(start.addingTimeInterval(300).timeIntervalSince1970 * 1_000)
        // Trailing 0 is the host-issued alert level (index 15), none by default.
        XCTAssertEqual(payload.data, "[1,110,10,4,[100,110],0,55,70,180,7,15,1440,\(timestamp),1,5,0]")
        XCTAssertEqual(payload.readingCount, 2)
    }

    func testHostAlertLevelIsLastField() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110]), unit: .milligramsPerDeciliter, alarms: alarms, fullScreen: false, hostAlertLevel: 2))
        XCTAssertTrue(payload.data.hasSuffix(",2]"), payload.data)
    }

    func testLogSummaryAndDecodedDetails() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 110], trend: .fortyFiveUp), unit: .milligramsPerDeciliter, alarms: alarms, fullScreen: true))
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
            "4: [100, 110] glucose history (2 readings)",
            "5: 0 mg/dL display",
            "6: 55 urgent-low threshold (mg/dL)",
            "7: 70 low threshold (mg/dL)",
            "8: 180 high threshold (mg/dL)",
            "9: 7 watch alarms urgent low, low, high",
            "10: 15 low repeat interval (minutes)",
            "11: 1440 high repeat interval (minutes)",
            "12: \(timestamp) timestamp (milliseconds since Unix epoch)",
            "13: 1 full-screen ring",
            "14: 5 urgent-low repeat interval (minutes)",
            "15: 0 host-issued alert level: none",
        ])
    }

    func testMillimolesRoundToOneDecimal() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings([122.5]), unit: .millimolesPerLiter, alarms: alarms, fullScreen: false))
        // 122.5 mg/dL = 6.8 mmol/L; thresholds 55/70/180 = 3.1/3.9/10.0.
        XCTAssertTrue(payload.data.hasPrefix("[1,6.8,0,3,[6.8],1,3.1,3.9,10,7,"), payload.data)
    }

    func testTrendFallsBackToRate() throws {
        // +30 mg/dL in 5 minutes is 6 mg/dL/min: DoubleUp.
        let payload = try XCTUnwrap(LupedPayload(readings: readings([100, 130]), unit: .milligramsPerDeciliter, alarms: alarms, fullScreen: false))
        XCTAssertTrue(payload.data.hasPrefix("[1,130,30,6,"), payload.data)
    }

    func testKeepsTwelveNewestReadings() throws {
        let payload = try XCTUnwrap(LupedPayload(readings: readings(Array(stride(from: 100.0, to: 115.0, by: 1))), unit: .milligramsPerDeciliter, alarms: alarms, fullScreen: false))
        XCTAssertEqual(payload.readingCount, 12)
        XCTAssertTrue(payload.data.contains("[103,104,105,106,107,108,109,110,111,112,113,114]"), payload.data)
    }
}

final class LupedAlarmTests: XCTestCase {
    private let configuration = LupedAlertConfiguration(
        urgentLowMgDL: 55, lowMgDL: 70, highMgDL: 180,
        urgentLowEnabled: true, lowEnabled: true, highEnabled: false,
        urgentLowRepeat: 300, lowRepeat: nil, highRepeat: 1_800
    )

    func testMaskFollowsEnabledZones() {
        let state = LupedAlertState(configuration: configuration, hostAlertsActive: true, hostMuteEnd: nil)
        let alarms = LupedAlarmSettings(state, watchAlarmsEnabled: true, followHostMute: true)
        XCTAssertEqual(alarms.enabledMask, LupedAlarmSettings.urgentLowBit | LupedAlarmSettings.lowBit)
        XCTAssertEqual(alarms.lowRepeat, LupedAlarmSettings.oncePerEpisode)
        XCTAssertNil(alarms.mutedUntil)
        XCTAssertEqual(LupedAlarmSettings.status(alarms, alerts: state, watchAlarmsEnabled: true, hostName: "Loop"), "Watch alarms on")
    }

    func testFollowedMuteSendsZeroMaskUntilItEnds() {
        let end = Date().addingTimeInterval(1_800)
        let state = LupedAlertState(configuration: configuration, hostAlertsActive: true, hostMuteEnd: end)
        let alarms = LupedAlarmSettings(state, watchAlarmsEnabled: true, followHostMute: true)
        XCTAssertEqual(alarms.enabledMask, 0)
        XCTAssertEqual(alarms.mutedUntil, end)
        XCTAssertTrue(LupedAlarmSettings.status(alarms, alerts: state, watchAlarmsEnabled: true, hostName: "Trio").hasSuffix(": Trio's alerts are muted"))
    }

    func testIgnoredMuteKeepsAlarmsOn() {
        let state = LupedAlertState(configuration: configuration, hostAlertsActive: true, hostMuteEnd: Date().addingTimeInterval(600))
        let alarms = LupedAlarmSettings(state, watchAlarmsEnabled: true, followHostMute: false)
        XCTAssertEqual(alarms.enabledMask, 3)
        XCTAssertTrue(LupedAlarmSettings.status(alarms, alerts: state, watchAlarmsEnabled: true, hostName: "Loop").hasSuffix("but Follow Loop Alert Mute is turned off"))
    }

    func testOffReasons() {
        let cgmAlerts = LupedAlertState(configuration: configuration, hostAlertsActive: false, hostMuteEnd: nil)
        XCTAssertEqual(LupedAlarmSettings(cgmAlerts, watchAlarmsEnabled: true, followHostMute: true).enabledMask, 0)
        XCTAssertEqual(
            LupedAlarmSettings.status(.disabled, alerts: cgmAlerts, watchAlarmsEnabled: true, hostName: "Loop"),
            "Watch alarms off: Loop leaves glucose alerts to the CGM's own alerts"
        )
        let watchOff = LupedAlertState(configuration: configuration, hostAlertsActive: true, hostMuteEnd: nil)
        XCTAssertEqual(LupedAlarmSettings(watchOff, watchAlarmsEnabled: false, followHostMute: true).enabledMask, 0)
        XCTAssertEqual(LupedAlarmSettings.status(.disabled, alerts: watchOff, watchAlarmsEnabled: false, hostName: "Loop"), "Watch alarms off: Watch Alarms is turned off")
        let none = LupedAlertState(configuration: nil, hostAlertsActive: true, hostMuteEnd: nil)
        XCTAssertEqual(LupedAlarmSettings(none, watchAlarmsEnabled: true, followHostMute: true), .disabled)
        XCTAssertEqual(LupedAlarmSettings.status(.disabled, alerts: none, watchAlarmsEnabled: true, hostName: "Trio"), "Watch alarms off: Trio's glucose alert settings are not available")
    }
}

final class LupedSettingsTests: XCTestCase {
    func testRawValueRoundTrips() {
        let settings = LupedSettings(isEnabled: true, watchfaceUUID: UUID(), alarmsEnabled: false, followAlertMute: false, fullScreen: true)
        XCTAssertEqual(LupedSettings(rawValue: settings.rawValue), settings)
    }

    func testMissingKeysUseDefaults() {
        XCTAssertEqual(LupedSettings(rawValue: [:]), LupedSettings())
        XCTAssertEqual(LupedSettings(rawValue: [UserDefaults.lupedPebbleWatchfaceUUIDKey: "not a uuid"]).watchfaceUUID, LupedSettings.defaultWatchfaceUUID)
    }
}
