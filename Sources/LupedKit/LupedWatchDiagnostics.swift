import Foundation

/// Luped's diagnostics snapshot (`DIAGNOSTICS`, format version 2).
public struct LupedWatchDiagnostics {
    public let receivedAt: Date
    public let battery: Int?
    public let countingSince: Date?
    public let readingsReceived: Int?
    public let refreshRequests: Int?
    public let staleTransitions: Int?
    public let phoneDisconnects: Int?
    public let phoneDisconnectedSeconds: Int?

    public init?(json: String, receivedAt: Date = Date()) {
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any],
              (values.first as? NSNumber)?.intValue == 2
        else {
            return nil
        }
        func int(_ index: Int) -> Int? {
            index < values.count ? (values[index] as? NSNumber)?.intValue : nil
        }
        self.receivedAt = receivedAt
        battery = int(2)
        countingSince = int(3).map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
        readingsReceived = int(13)
        refreshRequests = int(14)
        staleTransitions = int(31)
        phoneDisconnects = int(34)
        phoneDisconnectedSeconds = int(35).map { $0 / 1_000 }
    }
}

extension LupedWatchDiagnostics {
    /// What each `DIAGNOSTICS` field means, in the order the watchface's
    /// `diagnosticsSnapshot()` builds it (format version 2), for the communication log.
    static let fieldDescriptions = [
        "format version",
        "watch clock (ms since Unix epoch)",
        "battery (%)",
        "counting since (ms since Unix epoch)",
        "watchface start ID",
        "full redraws",
        "full redraw time, total (ms)",
        "slowest full redraw (ms)",
        "minute redraws",
        "minute redraw time, total (ms)",
        "slowest minute redraw (ms)",
        "render failures",
        "render retries",
        "DATA messages received",
        "refresh requests sent",
        "refresh requests deferred",
        "unused (always 0)",
        "unused (always 0)",
        "unused (always 0)",
        "messages received",
        "bytes received",
        "messages sent",
        "bytes sent",
        "refresh responses",
        "refresh response time, total (ms)",
        "slowest refresh response (ms)",
        "pixels redrawn",
        "late minute events",
        "minute event lateness, total (ms)",
        "worst minute event lateness (ms)",
        "refresh responses by latency (≤250, ≤500, ≤1000, ≤2000, ≤5000, ≤10000, ≤20000 ms, slower)",
        "stale transitions (latest reading turned 15 min old)",
        "no-data buzzes",
        "oldest reading age while stale (ms)",
        "phone disconnects",
        "phone disconnected time, total (ms)",
        "longest phone disconnect (ms)",
        "phone disconnected now (1 = yes)",
        "system pop-ups over the watchface (notifications, alarms, calls)",
        "recent host-alert buzzes (listed below)",
        "alert events while Watch Alarms was off (not buzzed)",
    ]

    /// Index of Luped's recent host-alert buzzes: up to 5 of
    /// `[alert event, alert level, start (watch ms), outcome]`.
    static let buzzesIndex = 39

    /// The raw `DIAGNOSTICS` JSON decoded one field per line, like the `DATA`
    /// decode. Falls back to the raw text when it isn't a version-2 array.
    static func logDecode(json: String) -> String {
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any],
              (values.first as? NSNumber)?.intValue == 2
        else {
            return json
        }
        let fields: [(value: Any, description: String)] = values.enumerated().map { index, value in
            let shown: Any
            if index == buzzesIndex, let buzzes = value as? [Any] {
                shown = "\(buzzes.count)"
            } else if let number = value as? NSNumber {
                shown = number.int64Value
            } else if let list = value as? [Any] {
                shown = "[" + list.map { ($0 as? NSNumber)?.stringValue ?? "\($0)" }.joined(separator: ", ") + "]"
            } else {
                shown = "\(value)"
            }
            return (shown, index < fieldDescriptions.count ? fieldDescriptions[index] : "unknown")
        }
        let buzzes = (values.count > buzzesIndex ? values[buzzesIndex] as? [[NSNumber]] : nil) ?? []
        return ([LupedPayload.decodeTable(fields)] + buzzes.map(describeBuzz)).joined(separator: "\n")
    }

    /// Checks the alert fires the watch acknowledged against its buzz records.
    /// A fire with no record means the watchface never tried to buzz; one with
    /// a record that still went unfelt points at PebbleOS (see `describeBuzz`).
    /// Only fires since the diagnostics window started, older than 10 s, and
    /// (when the 5-record list is full) not older than its oldest record count.
    static func buzzCheck(json: String, delivered: [LupedDeliveredAlert], receivedAt: Date) -> (missing: [LupedDeliveredAlert], message: String)? {
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any],
              (values.first as? NSNumber)?.intValue == 2,
              values.count > buzzesIndex,
              let buzzes = values[buzzesIndex] as? [[NSNumber]]
        else {
            return nil
        }
        var since = ((values[3] as? NSNumber)?.doubleValue).map { Date(timeIntervalSince1970: $0 / 1_000) } ?? .distantPast
        if buzzes.count >= 5, let oldest = buzzes.first, oldest.count > 2 {
            since = max(since, Date(timeIntervalSince1970: oldest[2].doubleValue / 1_000 - 2))
        }
        let checked = delivered.filter { $0.deliveredAt >= since && $0.deliveredAt <= receivedAt.addingTimeInterval(-10) }
        guard !checked.isEmpty else {
            return nil
        }
        let buzzed = Set(buzzes.compactMap { $0.first?.intValue })
        let missing = checked.filter { !buzzed.contains($0.event) }
        guard !missing.isEmpty else {
            return ([], "Buzz check: the watch has a buzz record for each of the \(checked.count) alert fires it acknowledged")
        }
        let lines = missing.map { alert in
            let time = DateFormatter.localizedString(from: alert.deliveredAt, dateStyle: .none, timeStyle: .medium)
            return "Alert event \(alert.event) (\(LupedPayload.alertStateName(alert.level))), acknowledged at \(time), has no buzz record: the watchface didn't try to buzz. It may have just started, since the first event after a start is only recorded."
        }
        return (missing, "Buzz check:\n" + lines.joined(separator: "\n"))
    }

    /// One line per host-alert buzz. PebbleOS drops an app's vibration while
    /// another one plays and cancels it when a system pop-up closes, without
    /// telling the app, so the watch records whether a pop-up covered the
    /// watchface during the 4.7 s buzz.
    static func describeBuzz(_ buzz: [NSNumber]) -> String {
        guard buzz.count >= 4 else {
            return "Buzz: \(buzz)"
        }
        let started = Date(timeIntervalSince1970: buzz[2].doubleValue / 1_000)
        let time = DateFormatter.localizedString(from: started, dateStyle: .none, timeStyle: .medium)
        let level = LupedPayload.alertStateName(buzz[1].intValue)
        let outcome: String
        switch buzz[3].intValue {
        case -2:
            outcome = "the watchface's buzz call failed with an error, so it did not buzz"
        case ..<0:
            outcome = "nothing covered the watchface during the buzz"
        case 0:
            outcome = "a pop-up already covered the watchface, so PebbleOS may have dropped the buzz"
        case let ms:
            outcome = "a pop-up covered the watchface \(ms) ms in, so PebbleOS may have cut the buzz short"
        }
        return "Buzz for alert event \(buzz[0]) (\(level)) at \(time): \(outcome)"
    }
}

/// An alert fire the watch acknowledged: a changed alert event at a level above 0.
struct LupedDeliveredAlert: Equatable {
    let event: Int
    let level: Int
    let deliveredAt: Date
}
