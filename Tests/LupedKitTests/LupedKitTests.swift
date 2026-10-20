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
        XCTAssertEqual(payload.data, "[1,110,10,4,[100,110],0,55,70,180,7,15,1440,\(timestamp),1,5]")
        XCTAssertEqual(payload.readingCount, 2)
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
