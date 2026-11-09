import XCTest
@testable import ElbbepTransport
@testable import LupedKit

/// Which bolus key an app holds when the phone moves between the two watch apps.
@MainActor
final class LupedBolusKeyRoutingTests: XCTestCase {
    /// Luped Remote holds the key; Send Now moves the phone to the watchface;
    /// the remote then sends a message (a signed bolus, say). It keeps its key,
    /// so what it signed is still accepted (it was refused "old key").
    func testTheAppHoldingTheKeyKeepsItWhenThePhoneComesBack() async throws {
        let (transport, _, remote) = try await remoteRunningWithKey()
        let session = try XCTUnwrap(transport.bolusAuth.session?.id)

        transport.sendNow()
        XCTAssertEqual(transport.foreground, .watchface)
        transport.pebbleTransport(remote, didReceive: [LupedMessageKey.command: Self.text("refresh")], message: Array(repeating: 0, count: 20))

        XCTAssertEqual(transport.foreground, .remote)
        XCTAssertEqual(transport.bolusAuth.session?.id, session, "Luped Remote's key was replaced: its signed request would be refused as old")
        XCTAssertEqual(transport.bolusAuth.session?.keyDelivered, true)
    }

    /// The same app restarting gets a new key: its old run's key is gone.
    func testARestartedAppGetsANewKey() async throws {
        let (transport, _, remote) = try await remoteRunningWithKey()
        let session = try XCTUnwrap(transport.bolusAuth.session?.id)

        transport.sendNow()
        transport.pebbleTransport(remote, didReceive: [PebbleAppMessage.alloyReadyKey: Self.ready], message: Array(repeating: 0, count: 20))

        XCTAssertEqual(transport.foreground, .remote)
        XCTAssertNotEqual(transport.bolusAuth.session?.id, session)
    }

    /// Send Now moved the phone off a running Luped Remote and the watchface
    /// doesn't answer: the remote gets the reading again.
    func testSendNowGoesBackWhenTheWatchfaceIsSilent() async throws {
        let (transport, _, _) = try await remoteRunningWithKey()
        transport.sendNow()
        XCTAssertEqual(transport.foreground, .watchface)
        try await Task.sleep(nanoseconds: UInt64((PebbleAppMessage.ackTimeout + 0.5) * 1_000_000_000))
        XCTAssertEqual(transport.foreground, .remote, "the phone kept retrying a silent watchface")
    }

    /// The watchface rejects its key a second after taking the reading (busy):
    /// the same key goes again, not a new session.
    func testABusyRejectedKeyIsSentAgainUnchanged() async throws {
        let (transport, watchface) = try await watchfaceWithKeyInFlight()
        let session = try XCTUnwrap(transport.bolusAuth.session?.id)
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 1, message: [])
        try await Task.sleep(nanoseconds: UInt64((LupedRouting.busyRetryDelay + 0.5) * 1_000_000_000))
        XCTAssertEqual(count("#2 COMMAND auth (bolus session \(session))", in: transport), 1)
        XCTAssertEqual(transport.bolusAuth.session?.id, session)
    }

    /// Watch boluses are turned off while the key is on its way, and the busy
    /// watchface rejects it: no key goes out (one did, from a new session).
    func testNoKeyAfterBolusesAreTurnedOff() async throws {
        let (transport, watchface) = try await watchfaceWithKeyInFlight()
        transport.issuesBolusKey = false
        transport.pebbleTransport(watchface, didReceiveReply: false, transactionID: 1, message: [])
        try await Task.sleep(nanoseconds: UInt64((LupedRouting.busyRetryDelay + 0.5) * 1_000_000_000))
        XCTAssertNil(transport.bolusAuth.session)
        XCTAssertEqual(count("#2 COMMAND auth", in: transport), 0, "a key went out after boluses were turned off")
    }

    // MARK: - Setup

    private static let ready = AppMessageTuple(type: PebbleAppMessage.tupleUnsigned, value: [1])
    private static func text(_ string: String) -> AppMessageTuple {
        AppMessageTuple(type: PebbleAppMessage.tupleCString, value: Array(string.utf8) + [0])
    }

    private func makeTransport() async throws -> (LupedTransport, PebbleTransport, PebbleTransport) {
        let transport = LupedTransport(hostName: "Host", settings: LupedSettings(isEnabled: true, remoteEnabled: true))
        let readingDate = Date()
        transport.snapshotProvider = {
            LupedSnapshot(readings: [LupedReading(date: readingDate, milligramsPerDeciliter: 120, trend: .flat)], storedSampleCount: 1, unit: .milligramsPerDeciliter)
        }
        for session in [transport.watchfaceTransport, transport.remoteTransport] {
            session.handlePacket([2]) // PPoGATT reset request
            session.handlePacket([3]) // PPoGATT reset complete
            XCTAssertTrue(session.isSessionOpen)
        }
        await transport.refresh()
        return (transport, transport.watchfaceTransport, transport.remoteTransport)
    }

    /// Luped Remote started, took the reading (#0) and its key (#1).
    private func remoteRunningWithKey() async throws -> (LupedTransport, PebbleTransport, PebbleTransport) {
        let (transport, watchface, remote) = try await makeTransport()
        transport.issuesBolusKey = true
        transport.pebbleTransport(remote, didReceive: [PebbleAppMessage.alloyReadyKey: Self.ready], message: Array(repeating: 0, count: 20))
        XCTAssertEqual(transport.foreground, .remote)
        transport.sendIfNeeded(force: true)
        transport.pebbleTransport(remote, didReceiveReply: true, transactionID: 0, message: [])
        transport.pebbleTransport(remote, didReceiveReply: true, transactionID: 1, message: [])
        XCTAssertEqual(transport.bolusAuth.session?.keyDelivered, true)
        XCTAssertEqual(transport.keyHolder, .remote)
        return (transport, watchface, remote)
    }

    /// The watchface took the reading (#0); its key (#1) is on its way.
    private func watchfaceWithKeyInFlight() async throws -> (LupedTransport, PebbleTransport) {
        let (transport, watchface, _) = try await makeTransport()
        transport.issuesBolusKey = true
        transport.sendIfNeeded(force: true)
        transport.pebbleTransport(watchface, didReceiveReply: true, transactionID: 0, message: [])
        XCTAssertEqual(count("#1 COMMAND auth", in: transport), 1)
        return (transport, watchface)
    }

    private func count(_ text: String, in transport: LupedTransport) -> Int {
        transport.communicationLog.entries.filter { $0.message.contains(text) && !$0.message.contains("dropped") }.count
    }
}
