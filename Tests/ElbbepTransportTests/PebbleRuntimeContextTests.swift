import XCTest
@testable import ElbbepTransport

/// The line logged with every publish of the service.
final class PebbleRuntimeContextTests: XCTestCase {
    func testDescribesAStartInTheBackgroundWhileLocked() {
        XCTAssertEqual(
            PebbleRuntimeContext.describe(appState: "in the background", protectedData: "locked", processAge: 192),
            "app in the background, protected data locked, process started 3 min 12 s ago"
        )
    }

    func testLeavesOutAnUnknownProcessAge() {
        XCTAssertEqual(
            PebbleRuntimeContext.describe(appState: "active", protectedData: "readable", processAge: nil),
            "app active, protected data readable"
        )
    }

    func testDurations() {
        XCTAssertEqual(PebbleRuntimeContext.duration(4.4), "4 s")
        XCTAssertEqual(PebbleRuntimeContext.duration(60), "1 min 0 s")
        XCTAssertEqual(PebbleRuntimeContext.duration(3725), "1 h 2 min")
        XCTAssertEqual(PebbleRuntimeContext.duration(-3), "0 s")
    }

    func testThisProcessStartIsRecentAndInThePast() throws {
        let start = try XCTUnwrap(PebbleRuntimeContext.processStartDate())
        XCTAssertLessThan(start.timeIntervalSinceNow, 0)
        XCTAssertGreaterThan(start.timeIntervalSinceNow, -86_400)
    }
}
