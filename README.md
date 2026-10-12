# elbbepTransport

`ElbbepTransport` is a Swift package that lets an iOS app talk to one JS-free
Pebble watch app or watchface directly over Bluetooth, next to the Pebble app.

The phone publishes its own PebbleOS PPoGATT ("Pebble Protocol over GATT")
service with CoreBluetooth. PebbleOS discovers it on the existing watch
connection, reads the app UUID from its meta characteristic, and opens a
separate session for that app. The legacy PebbleKit iOS SDK is not used: its
discovery does not recognize Core Devices watches (Pebble Time 2, Pebble Round
2, Pebble 2 Duo).

## What it does

- Publishes the PPoGATT service and runs the session: reset handshake, packet
  sequencing, four-packet window, ACKs, retransmission, and self-reset when
  the watch stops acknowledging.
- Frames and dispatches Pebble Protocol messages.
- Answers the phone-version exchange with the 8 KiB AppMessage capability.
  PebbleOS caches it per app UUID and applies it when the app next starts;
  without it a JS-free app's inbox is limited to 144 bytes.
- Acknowledges the app's AppMessage pushes and decodes their tuples.
- Pushes AppMessage dictionaries and reports the watch's ACK or NACK.
- Starts and stops the app over the app run-state endpoint.

What to send, when, and how to retry belongs to your app.

## Usage

```swift
import ElbbepTransport

@MainActor
final class WatchLink: PebbleTransportDelegate {
    let transport = PebbleTransport(isEnabled: true, appUUID: myWatchAppUUID)

    init() {
        transport.delegate = self
        transport.start()
    }

    func send(_ text: String) {
        guard transport.isSessionOpen else { return }
        let id = transport.makeTransactionID()
        transport.push(transactionID: id, tuples: [(10_000, .cString(text))])
    }

    func pebbleTransport(_ transport: PebbleTransport, log kind: PebbleLogKind, _ message: String) { print(message) }
    func pebbleTransportDidChangeLink(_ transport: PebbleTransport) { /* transport.link */ }
    func pebbleTransportSessionDidOpen(_ transport: PebbleTransport) { /* send current state */ }
    func pebbleTransportSessionWillReset(_ transport: PebbleTransport) { /* drop in-flight work */ }
    func pebbleTransport(_ transport: PebbleTransport, didReceive tuples: [UInt32: AppMessageTuple], message: [UInt8]) {}
    func pebbleTransport(_ transport: PebbleTransport, didReceiveReply acknowledged: Bool, transactionID: UInt8, message: [UInt8]) {}
}
```

AppMessage keys are the numeric keys your watch app's build assigns to its
`messageKeys`. Alloy watchfaces send `PebbleAppMessage.alloyReadyKey` on start
and keep their outbox closed until the phone sends any message back.

`reconfigure(isEnabled:appUUID:)` changes the app UUID or turns the link off;
disabling releases Bluetooth entirely.

## Requirements and limits

- iOS 15 or later. The host app needs the `bluetooth-peripheral` background
  mode and a Bluetooth usage description to keep the session in the background.
- The watch must be paired with and connected to the Pebble app.
- Only JS-free watch apps can use this session. PebbleOS routes AppMessages
  from apps with PebbleKit JS enabled to the Pebble app's system session.
- Run one host per app UUID. Two phone apps publishing the same app UUID each
  get a watch session and compete for the app.
- Alloy disables a watchface's outbox whenever a non-system session opens or
  closes, until the watchface restarts or receives a message after starting.

## Tests

```sh
swift test
```
