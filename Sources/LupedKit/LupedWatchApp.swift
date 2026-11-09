import Foundation

/// The watch apps LupedKit serves, each over its own watch session.
///
/// PebbleOS opens a session for every PPoGATT service the phone publishes and
/// keeps them all open, but only the running app takes pushes: the others
/// reject them (NACK). The watch runs one app at a time, so LupedKit sends to
/// the one it last heard from.
public enum LupedWatchApp: Equatable, Hashable {
    case watchface
    case remote

    /// The app's name in the communication log.
    public var name: String {
        switch self {
        case .watchface: "the watchface"
        case .remote: "Luped Remote"
        }
    }

    /// The prefix of the app's lines in the communication log.
    var logLabel: String {
        switch self {
        case .watchface: "Watchface"
        case .remote: "Luped Remote"
        }
    }

    var other: LupedWatchApp {
        self == .watchface ? .remote : .watchface
    }
}

/// Which app to send to.
enum LupedRouting {
    /// The app to send to once `opened`'s session opens: the current one while
    /// its session is open, otherwise the newly opened one.
    static func foreground(afterOpening opened: LupedWatchApp, current: LupedWatchApp, openSessions: Set<LupedWatchApp>) -> LupedWatchApp {
        openSessions.contains(current) ? current : opened
    }

    /// After `app` rejected a push: the other app if its session is open and it
    /// hasn't rejected one since an app last accepted or sent something, else
    /// `nil` (back off and retry).
    static func next(afterRejectionBy app: LupedWatchApp, rejected: Set<LupedWatchApp>, openSessions: Set<LupedWatchApp>) -> LupedWatchApp? {
        let other = app.other
        return openSessions.contains(other) && !rejected.contains(other) ? other : nil
    }
}

/// When to publish the watch apps' services again while a Pebble stays connected
/// to the iPhone without opening them.
///
/// Seen in the field: the watch dropped both services at once while staying
/// connected to the phone, and found them again only when the app restarted and
/// published them anew. So the services are published again, all together as a
/// restart does, only in that case: a session that still works is never touched.
enum LupedRepublish {
    /// The wait before checking again after the first attempt; it doubles with
    /// each attempt, up to `maximumCheckDelay`.
    static let firstCheckDelay: TimeInterval = 90
    static let maximumCheckDelay: TimeInterval = 1800

    /// Whether to publish every enabled transport's service again: a Pebble is
    /// connected to this iPhone, and no enabled transport has its watch. A
    /// transport that is off doesn't count; with none on, there is nothing to publish.
    static func shouldRepublish(transports: [(isEnabled: Bool, hasWatch: Bool)], pebbleConnected: Bool) -> Bool {
        let enabled = transports.filter { $0.isEnabled }
        return pebbleConnected && !enabled.isEmpty && enabled.allSatisfy { !$0.hasWatch }
    }

    /// The wait before checking again after the `attempts`th attempt.
    static func checkDelay(afterAttempts attempts: Int) -> TimeInterval {
        min(firstCheckDelay * pow(2, Double(max(attempts - 1, 0))), maximumCheckDelay)
    }
}
