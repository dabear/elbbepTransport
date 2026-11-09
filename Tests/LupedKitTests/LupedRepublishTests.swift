import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// The services are published again, all together, only when a Pebble stays
/// connected to the iPhone and no enabled app has its watch session.
final class LupedRepublishTests: XCTestCase {
    func testRepublishesWhenNoEnabledAppHasItsWatch() {
        XCTAssertTrue(LupedRepublish.shouldRepublish(transports: [(true, false), (true, false)], pebbleConnected: true))
    }

    func testAnAppWithItsWatchKeepsBothServices() {
        XCTAssertFalse(LupedRepublish.shouldRepublish(transports: [(true, true), (true, false)], pebbleConnected: true))
        XCTAssertFalse(LupedRepublish.shouldRepublish(transports: [(true, false), (true, true)], pebbleConnected: true))
    }

    func testNothingWithoutAConnectedPebble() {
        XCTAssertFalse(LupedRepublish.shouldRepublish(transports: [(true, false), (true, false)], pebbleConnected: false), "out of range: nothing to find the services")
    }

    /// Luped Remote switched off neither counts nor holds the watchface back.
    func testADisabledAppDoesNotCount() {
        XCTAssertTrue(LupedRepublish.shouldRepublish(transports: [(true, false), (false, false)], pebbleConnected: true))
        XCTAssertFalse(LupedRepublish.shouldRepublish(transports: [(true, true), (false, false)], pebbleConnected: true))
        XCTAssertFalse(LupedRepublish.shouldRepublish(transports: [(false, false), (false, false)], pebbleConnected: true), "nothing on: nothing to publish")
    }

    func testWaitDoublesUpToHalfAnHour() {
        let waits = (1...7).map { LupedRepublish.checkDelay(afterAttempts: $0) }
        XCTAssertEqual(waits, [90, 180, 360, 720, 1440, 1800, 1800])
    }
}

/// LupedTransport leaves a working session alone. (Republishing itself needs
/// Core Bluetooth, so it isn't run here.)
@MainActor
final class LupedRepublishCoordinationTests: XCTestCase {
    func testLupedRemoteWithItsWatchKeepsBothServices() {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true, remoteEnabled: true))
        transport.remoteTransport.handlePacket([2]) // PPoGATT reset request
        transport.remoteTransport.handlePacket([3]) // PPoGATT reset complete

        transport.pebbleTransport(transport.watchfaceTransport, isWaitingWithPebbleConnected: true)

        XCTAssertTrue(transport.remoteTransport.isSessionOpen)
        XCTAssertFalse(transport.communicationLog.entries.contains { $0.message.contains("again") }, "nothing published again")
    }

    func testNoConnectedPebbleRepublishesNothing() {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true, remoteEnabled: true))

        transport.pebbleTransport(transport.watchfaceTransport, isWaitingWithPebbleConnected: false)

        XCTAssertFalse(transport.communicationLog.entries.contains { $0.message.contains("again") })
    }
}
