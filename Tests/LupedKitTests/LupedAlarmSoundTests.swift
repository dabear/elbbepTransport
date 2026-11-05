import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// The alarm sound: offered only for watches that reported a speaker, off by
/// default, and asked for per alarm with a negative alert event (`DATA` 9).
@MainActor
final class LupedAlarmSoundTests: XCTestCase {
    func testSoundsOnlyWhatTheUserChose() {
        var settings = LupedSettings(isEnabled: true, watchHasSpeaker: true)
        XCTAssertFalse(settings.soundsAlarm(hostAlertState: 2), "off by default")

        settings.alarmSound = .urgentLow
        XCTAssertTrue(settings.soundsAlarm(hostAlertState: 2))
        XCTAssertFalse(settings.soundsAlarm(hostAlertState: 1), "low")
        XCTAssertFalse(settings.soundsAlarm(hostAlertState: 3), "high")

        settings.alarmSound = .all
        XCTAssertTrue(settings.soundsAlarm(hostAlertState: 4))
        XCTAssertFalse(settings.soundsAlarm(hostAlertState: 0), "no alert")
        XCTAssertFalse(settings.soundsAlarm(hostAlertState: -2), "Watch Alarms off")

        settings.watchHasSpeaker = false
        XCTAssertFalse(settings.soundsAlarm(hostAlertState: 2), "no speaker reported")
        settings.watchHasSpeaker = true
        settings.alarmsEnabled = false
        XCTAssertFalse(settings.soundsAlarm(hostAlertState: 2), "Watch Alarms off")
    }

    func testSettingIsSavedAndOffForOlderSettings() {
        let settings = LupedSettings(isEnabled: true, alarmSound: .urgentLow, watchHasSpeaker: true)
        XCTAssertEqual(LupedSettings(rawValue: settings.rawValue), settings)
        let older = LupedSettings(rawValue: ["lupedPebbleEnabled": true])
        XCTAssertEqual(older.alarmSound, .off)
        XCTAssertFalse(older.watchHasSpeaker)
    }

    func testAlertEventIsNegativeWhenTheAlarmSounds() throws {
        let settings = LupedSettings(isEnabled: true, alarmSound: .urgentLow, watchHasSpeaker: true)
        XCTAssertEqual(try event(hostAlertState: 2, alertEvent: 7, settings: settings), -7)
        XCTAssertEqual(try event(hostAlertState: 3, alertEvent: 8, settings: settings), 8, "a high isn't sounded with Urgent Low Only")
        XCTAssertEqual(try event(hostAlertState: 0, alertEvent: 0, settings: settings), 0)
        XCTAssertEqual(try event(hostAlertState: 2, alertEvent: 7, settings: LupedSettings(isEnabled: true)), 7, "off by default")
        // A decision kept for the event wins over the current setting.
        XCTAssertEqual(try event(hostAlertState: 2, alertEvent: 7, alertSound: false, settings: settings), 7)
    }

    func testSpeakerReportReachesTheHost() {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true))
        var reports: [Bool] = []
        transport.speakerDidReport = { reports.append($0) }
        for value in ["speaker:on", "speaker:quiet"] {
            let tuple = AppMessageTuple(type: PebbleAppMessage.tupleCString, value: Array(value.utf8) + [0])
            transport.pebbleTransport(transport.watchfaceTransport, didReceive: [LupedMessageKey.command: tuple], message: Array(repeating: 0, count: 20))
        }
        XCTAssertEqual(reports, [false, true])
        XCTAssertEqual(transport.status.speaker?.quietTime, true)
        XCTAssertNil(LupedWatchSpeaker.quietTime(reportedIn: "speaker:loud"))
    }

    private func event(hostAlertState: Int, alertEvent: Int, alertSound: Bool? = nil, settings: LupedSettings) throws -> Int {
        let reading = LupedReading(date: Date(), milligramsPerDeciliter: 50, trend: .flat)
        let payload = try XCTUnwrap(LupedPayload(readings: [reading], unit: .milligramsPerDeciliter, fullScreen: false, hostAlertState: hostAlertState, alertEvent: alertEvent, alertSound: alertSound, settings: settings))
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.data.utf8)) as? [Any])
        return try XCTUnwrap(values[9] as? Int)
    }
}

/// The transport decides once per alert, and only from a snapshot with a level.
@MainActor
final class LupedAlarmSoundDecisionTests: XCTestCase {
    func testEventSeenBeforeItsLevelStillSounds() async throws {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true, alarmSound: .all, watchHasSpeaker: true))
        var level = 0
        transport.snapshotProvider = {
            LupedSnapshot(readings: [LupedReading(date: Date(timeIntervalSince1970: 1_800_000_000), milligramsPerDeciliter: 220, trend: .flat)], storedSampleCount: 1, unit: .milligramsPerDeciliter, hostAlertState: level, alertEvent: 411)
        }
        await transport.refresh()
        level = 3
        await transport.refresh()
        XCTAssertEqual(try event(in: transport), -411)

        // A later settings change doesn't change this alert's event.
        transport.settings.alarmSound = .off
        await transport.refresh()
        XCTAssertEqual(try event(in: transport), -411)
    }

    private func event(in transport: LupedTransport) throws -> Int {
        let data = try XCTUnwrap(transport.latestPayload?.data)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(data.utf8)) as? [Any])
        return try XCTUnwrap(values[9] as? Int)
    }
}
