import CoreBluetooth
import XCTest
@testable import ElbbepTransport

/// When the peripheral manager asks iOS for restoration.
final class PebbleRestorationTests: XCTestCase {
    private let appUUID = UUID(uuidString: "0B9E3F43-3C4D-4E2A-9F7B-6C1D2E3F4A5B")!

    func testHostWithPeripheralBackgroundModeRestores() {
        let options = PebbleTransport.peripheralManagerOptions(appUUID: appUUID, backgroundModes: ["bluetooth-central", "bluetooth-peripheral"])
        XCTAssertEqual(options[CBPeripheralManagerOptionRestoreIdentifierKey] as? String, "elbbep.ppogatt.0b9e3f43-3c4d-4e2a-9f7b-6c1d2e3f4a5b")
    }

    /// iOS throws for restoration without the mode: a test runner, or a host without it.
    func testProcessWithoutPeripheralBackgroundModeDoesNotRestore() {
        XCTAssertTrue(PebbleTransport.peripheralManagerOptions(appUUID: appUUID, backgroundModes: []).isEmpty)
        XCTAssertTrue(PebbleTransport.peripheralManagerOptions(appUUID: appUUID, backgroundModes: ["bluetooth-central"]).isEmpty)
    }
}
