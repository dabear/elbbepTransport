import XCTest
import CoreBluetooth
@testable import ElbbepTransport

final class AppMessageCodecTests: XCTestCase {
    private let appUUID = UUID(uuidString: "BF32924C-4839-449E-9E56-EE190249ACB2")!

    func testFrameHasBigEndianLengthAndEndpoint() {
        let frame = PebbleTransport.frame(endpoint: 0x0030, payload: Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual([UInt8](frame), [0x00, 0x03, 0x00, 0x30, 0xAA, 0xBB, 0xCC])
    }

    func testPushMessageLayout() {
        let message = [UInt8](PebbleTransport.pushMessage(transactionID: 7, appUUID: appUUID, tuples: [
            (10_003, .uint8(1)),
            (10_001, .cString("[1]")),
        ]))

        XCTAssertEqual(message[0], PebbleAppMessage.push)
        XCTAssertEqual(message[1], 7)
        XCTAssertEqual(Data(message[2..<18]), withUnsafeBytes(of: appUUID.uuid) { Data($0) })
        XCTAssertEqual(message[18], 2)
        // Key 10003 little-endian, unsigned, length 1, value 1.
        XCTAssertEqual(Array(message[19..<27]), [0x13, 0x27, 0x00, 0x00, PebbleAppMessage.tupleUnsigned, 0x01, 0x00, 0x01])
        // Key 10001 little-endian, C string, length 4 including the terminator.
        XCTAssertEqual(Array(message[27..<34]), [0x11, 0x27, 0x00, 0x00, PebbleAppMessage.tupleCString, 0x04, 0x00])
        XCTAssertEqual(Array(message[34...]), Array("[1]".utf8) + [0])
    }

    func testTuplesRoundTrip() throws {
        let message = [UInt8](PebbleTransport.pushMessage(transactionID: 1, appUUID: appUUID, tuples: [
            (10_000, .cString("refresh")),
            (PebbleAppMessage.alloyReadyKey, .uint8(0)),
        ]))

        let tuples = try XCTUnwrap(PebbleTransport.tuples(in: message, appUUID: appUUID))
        XCTAssertEqual(tuples.count, 2)
        XCTAssertEqual(tuples[10_000]?.string, "refresh")
        XCTAssertEqual(tuples[PebbleAppMessage.alloyReadyKey].map { Array($0.value) }, [0])
        XCTAssertNil(tuples[PebbleAppMessage.alloyReadyKey]?.string)
    }

    func testTuplesForAnotherAppAreIgnored() {
        let message = [UInt8](PebbleTransport.pushMessage(transactionID: 1, appUUID: UUID(), tuples: [(10_000, .cString("refresh"))]))
        XCTAssertNil(PebbleTransport.tuples(in: message, appUUID: appUUID))
    }

    func testTruncatedTupleStopsDecoding() throws {
        var message = [UInt8](PebbleTransport.pushMessage(transactionID: 1, appUUID: appUUID, tuples: [(10_000, .cString("refresh"))]))
        message.removeLast(3)
        let tuples = try XCTUnwrap(PebbleTransport.tuples(in: message, appUUID: appUUID))
        XCTAssertTrue(tuples.isEmpty)
    }

    func testHex() {
        XCTAssertEqual(PebbleTransport.hex([0x00, 0xFF, 0x1A]), "00 ff 1a")
    }

    // The log names Core Bluetooth states; the raw value goes in parentheses.
    func testBluetoothStateNames() {
        XCTAssertEqual(PebbleTransport.name(of: .poweredOn), "poweredOn")
        XCTAssertEqual(PebbleTransport.name(of: .poweredOff), "poweredOff")
        XCTAssertEqual(PebbleTransport.name(of: .unauthorized), "unauthorized")
    }

    @MainActor
    func testNewTransportIsOffUntilStarted() {
        let transport = PebbleTransport(isEnabled: false, appUUID: appUUID)
        XCTAssertEqual(transport.link, .off)
        XCTAssertFalse(transport.isSessionOpen)
    }
}
