import CoreBluetooth

/// Finds out whether a Pebble is connected to this iPhone while no watch has
/// opened our PPoGATT service, to explain a link that stays waiting.
///
/// Only asks Core Bluetooth which peripherals are already connected to the
/// system (by any app, usually the Pebble app); it never scans, connects or
/// advertises, so it cannot disturb the Pebble app's link.
@MainActor
final class PebbleWatchProbe: NSObject, @preconcurrency CBCentralManagerDelegate {
    /// The Pebble pairing service every Pebble exposes.
    static let pairingService = CBUUID(string: "FED9")
    /// Reversed PPoGATT, where the watch hosts the service: V2 (Core Devices
    /// watches) and V1 (Pebble 2 and older).
    static let reversedServices = [
        CBUUID(string: "40000000-328E-0FBB-C642-1AA6699BDADA"),
        CBUUID(string: "30000003-328E-0FBB-C642-1AA6699BDADA"),
    ]

    struct Result: Equatable {
        /// A Pebble is connected to this iPhone.
        var pebbleConnected: Bool
        /// A connected Pebble offers reversed PPoGATT.
        var offersReversed: Bool
    }

    private var central: CBCentralManager?

    /// Creates the central early, since it can only answer once powered on.
    func prepare() {
        guard central == nil else {
            return
        }
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    /// Lets go of Bluetooth when the link is switched off or deleted.
    func release() {
        central?.delegate = nil
        central = nil
    }

    /// `nil` while Bluetooth can't answer yet.
    func check() -> Result? {
        guard let central, central.state == .poweredOn else {
            return nil
        }
        let reversed = central.retrieveConnectedPeripherals(withServices: Self.reversedServices)
        let pebbles = central.retrieveConnectedPeripherals(withServices: [Self.pairingService] + Self.reversedServices)
        return Result(pebbleConnected: !pebbles.isEmpty, offersReversed: !reversed.isEmpty)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    /// The log line for a link that has waited `minutes` with no watch session.
    nonisolated static func diagnosis(_ result: Result, minutes: Int) -> String {
        guard result.pebbleConnected else {
            return String(format: "No watch session for %ld min, and no Pebble is connected to this iPhone. Check that the watch is connected in the Pebble app.", minutes)
        }
        // `offersReversed` is not mentioned: Core Devices watches always offer
        // the reversed services, whatever the Pebble app's debug setting.
        return String(format: "No watch session for %ld min, but a Pebble is connected to this iPhone: the watch does not open this app's service. If it stays that way, close this app from the app switcher and open it again.", minutes)
    }
}
