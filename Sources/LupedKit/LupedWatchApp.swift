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
