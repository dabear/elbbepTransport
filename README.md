# elbbepTransport

This package has two libraries:

- `ElbbepTransport` lets an iOS app talk to one JS-free Pebble watch app or
  watchface directly over Bluetooth, next to the Pebble app.
- `LupedKit` builds on it to drive the Luped CGM watchface from any iOS
  diabetes app, such as Loop or Trio. The host app supplies plain readings and
  alert state; LupedKit owns the payload, delivery, commands, status and log.

## ElbbepTransport

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
- To serve several watch apps, create one `PebbleTransport` per app UUID: each
  publishes its own service with its own `CBPeripheralManager`. The watch opens
  and keeps a session for every one of them, but only the running app accepts
  pushes; the others NACK them.
- PebbleOS routes a JS-free app's messages to the session published for its
  UUID.
- Alloy disables a watchface's outbox whenever a non-system session opens or
  closes, until the watchface restarts or receives a message after starting.

## LupedKit

`LupedTransport` sends a host app's CGM readings, glucose alerts and loop status
to Luped and keeps the plugin's state: link status, delivery and retries, watch
diagnostics, and a communication log.

Luped's own settings (watchface, Luped Remote, Watch Alarms, layout, status
line, Last Loop) are a `LupedSettings` value that the host persists: keep `settings.rawValue` in
the plugin's saved state, create the transport with
`LupedTransport(hostName:settings:)`, and assign `luped.settings` to apply a
change. `hostNeedsLoopStatus` and `needsTherapy` say what the current settings
need from the host.

The host app adapts its own types:

```swift
import LupedKit

let luped = LupedTransport(hostName: "Loop", settings: savedSettings)
luped.diagnosticLog = { kind, message in /* host logging */ }
luped.snapshotProvider = {
    LupedSnapshot(
        readings: recentCGMReadings.map {
            LupedReading(date: $0.date, milligramsPerDeciliter: $0.mgdl, trend: $0.lupedTrend)
        },
        storedSampleCount: recentCGMReadings.count,
        unit: usesMmol ? .millimolesPerLiter : .milligramsPerDeciliter,
        // The host's active glucose alert: 0 none, 1 low, 2 urgent low, 3 high,
        // 4 predicted low; negative while Watch Alarms is off.
        hostAlertState: currentGlucoseAlertState,
        // Advance on every alert fire, including repeats; persist across launches.
        alertEvent: savedAlertEvent,
        loopStatus: LupedLoopStatus(insulinOnBoard: iob, carbsOnBoard: cob, lastLoopCompleted: lastLoop, isClosedLoop: closedLoop)
    )
}
luped.start()

// On every new reading, loop result, or alert the host issues or clears:
Task { await luped.refresh() }
```

Glucose alerts are host-issued: the host evaluates its own alerts and passes the
most important active glucose alert as `hostAlertState`, plus an `alertEvent`
that changes each time it fires one (the first fire and every repeat). The watch
buzzes when the alert event changes while the state is above 0, so it repeats in
step with the host and stops when the user acknowledges on the phone. It colours
its ring from the state (red for lows, amber for high) and has no thresholds of
its own.

LupedKit also serves Luped Remote (`LupedSettings.remoteUUID`, by default `defaultRemoteUUID`), a watchapp that
shows the same reading and sends the watchface's requests from its buttons. It
gets a session of its own while `remoteEnabled` is on (off by default: it is a
separate watchapp the user installs). The watch
runs one of the two at a time, so LupedKit sends to the app that last started
or sent something (`foreground`), and to the other one after the first rejects a
push. Both apps' requests reach the same callbacks; each app run gets its own
bolus key; a `RESULT` goes to whichever app is running when it is sent, so the
watchface shows the answer to a request the remote sent before it closed.
`status.remoteLastSeen` is when Luped Remote last sent something (it does when
it starts): its session opens whether or not it is installed, so only this says
it is.
The remote always gets IOB, COB and the loop's status, whatever the watchface
shows, and no graph history. `status.remoteLink` and `status.foreground` show the remote's session and where
messages go; watch diagnostics come from the watchface only.

`sendResult(_:reason:)` answers a watch request (`RESULT`, `<action>:<outcome>`),
and with a `LupedResultReason` says why it wasn't done as a third field
(`carbs:refused:too soon`). Watches read the first two fields, so older ones
are unaffected; Luped Remote 0.1.1 shows the reason. An `ok` answer never gets
one.

Carbs from the watch may say how fast they are absorbed (`fast`, `medium` or
`slow`, `LupedCarbAbsorption`), after the grams of `carbs:`, `recommend:` and a
signed bolus (whose signature then covers it); `carbsRequested`,
`bolusRequested` and `bolusRecommendationRequested` pass it on, `nil` when the
watch didn't say.

Luped Remote asks for the host's presets with `COMMAND presets`; LupedKit
answers on the `PRESETS` key (10007, to Luped Remote only) from the latest
snapshot (`LupedSnapshot.overridePresets` and `tempTargetPresets`):
`[overrides, temp targets]`, each `[[id, name, running], …]` or `null` for a kind
the host doesn't have (Loop: temp targets). `DATA` carries no presets. At most 16
per kind; names are cleaned for the watch fonts (no control or invisible
characters, emoji or symbols, at most 32 characters) and only shown; ids go back
unchanged in `override:<id>` / `temptarget:<id>`, or as a `~` token (12 hex digits
of SHA-256) when they aren't plain, which LupedKit maps back to the host's id.

`bolusRecommendationRequested` is called when Luped Remote asks what bolus the
host would recommend with the carbs the user is about to add
(`COMMAND recommend:<grams>`, 0 for none), before a bolus is picked; nothing is
to be added or delivered. Answer with `sendBolusRecommendation(grams:units:maximumBolus:)`
or `sendBolusRecommendationRefusal(grams:outcome:reason:)`; the answer goes on
the `RECOMMEND` key (10006) to Luped Remote only, and is dropped once it has
closed. Without a handler the request is answered `ignored`.

The Luped watchface, Luped Remote and their `DATA` protocol live in
[LupedPebbleWatchFace](https://github.com/dabear/LupedPebbleWatchFace)
(`variants/luped/PROTOCOL.md`).

## Tests

```sh
swift test
```

## License

MIT; see [LICENSE](LICENSE).
