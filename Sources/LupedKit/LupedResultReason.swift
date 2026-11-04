import Foundation

/// Why a watch request wasn't done: the optional third field of `RESULT`,
/// `<action>:<outcome>:<reason>`, such as `carbs:refused:too soon`.
///
/// Watches that know only `<action>:<outcome>` read the first two fields and
/// ignore it (Luped 0.1.23, Luped Remote 0.1.0); a watch that shows the whole
/// answer as text still reads naturally. The raw values are what the watch
/// shows, so they are short, lowercase and never contain `:`.
public enum LupedResultReason: String, CaseIterable, Equatable {
    /// The host's user hasn't allowed this action from the watch.
    case notAllowed = "not allowed"
    /// Too soon after the last one of its kind (the host's rate limit).
    case tooSoon = "too soon"
    /// More than the host's maximum for one request.
    case overMaximum = "over max"
    /// A bolus above the host's recommendation.
    case overRecommendation = "over recommended"
    /// The host's daily total for watch requests is reached.
    case dailyLimit = "daily limit"
    /// Confirmed on the watch too long ago (or the watch's clock is off).
    case tooOld = "too old"
    /// The host has no recent glucose, or its state changed since the watch's data.
    case noRecentGlucose = "no recent glucose"
    /// The host has no preset by that name.
    case noSuchPreset = "no such preset"
    /// The host is still delivering an earlier bolus.
    case inProgress = "in progress"
    /// The amount isn't a valid one.
    case invalidAmount = "invalid amount"
    /// Signed with a key the phone no longer has (the app restarted since).
    case oldKey = "old key"
    /// The signature or sequence didn't check out.
    case notVerified = "not verified"

    /// `result` with this reason as its third field. An `ok` result gets none:
    /// watches buzz "done" only for answers ending in `:ok`.
    func appended(to result: String) -> String {
        result.hasSuffix(":ok") ? result : "\(result):\(rawValue)"
    }
}
