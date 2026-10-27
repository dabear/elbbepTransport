import XCTest
@testable import ElbbepTransport

/// What the transport logs while its service waits for the watch.
final class PebbleWatchProbeTests: XCTestCase {
    func testNoPebbleConnected() {
        let line = PebbleWatchProbe.diagnosis(.init(pebbleConnected: false, offersReversed: false), minutes: 2)
        XCTAssertTrue(line.hasPrefix("No watch session for 2 min, and no Pebble is connected to this iPhone."), line)
        XCTAssertFalse(line.contains("Reversed"), line)
    }

    /// A connected Pebble that never opens our service points at reversed PPoGATT.
    func testConnectedPebbleSuggestsReversedPPoG() {
        let line = PebbleWatchProbe.diagnosis(.init(pebbleConnected: true, offersReversed: false), minutes: 5)
        XCTAssertTrue(line.contains("a Pebble is connected to this iPhone"), line)
        XCTAssertTrue(line.contains("turn off the debug setting \u{201C}Reversed PPoG\u{201D}"), line)
        XCTAssertFalse(line.contains("The watch offers reversed PPoGATT"), line)
    }

    func testReversedCapableWatchIsNamed() {
        let line = PebbleWatchProbe.diagnosis(.init(pebbleConnected: true, offersReversed: true), minutes: 5)
        XCTAssertTrue(line.contains("The watch offers reversed PPoGATT"), line)
    }

    /// The transport logs again only when the reason changes, not as minutes pass.
    func testDiagnosisKeyIgnoresMinutes() {
        let result = PebbleWatchProbe.Result(pebbleConnected: true, offersReversed: true)
        XCTAssertNotEqual(PebbleWatchProbe.diagnosis(result, minutes: 2), PebbleWatchProbe.diagnosis(result, minutes: 7))
        XCTAssertEqual(PebbleWatchProbe.diagnosis(result, minutes: 0), PebbleWatchProbe.diagnosis(result, minutes: 0))
    }
}
