import CryptoKit
import Foundation

/// The glucose and alert state a host app supplies for the next Luped payload.
public struct LupedSnapshot {
    /// Recent CGM readings; user-entered and display-only values excluded.
    public var readings: [LupedReading]
    /// How many samples the host read, for the log when none are usable.
    public var storedSampleCount: Int
    public var unit: LupedUnit
    /// The host's active glucose alert: 0 none, 1 low, 2 urgent low, 3 high,
    /// 4 predicted low; negative while Watch Alarms is off. The host evaluates its
    /// own alerts; the watch colours its ring from this and buzzes when it's
    /// positive and the alert event changes. It has no thresholds of its own.
    public var hostAlertState: Int
    /// Why the state is what it is, for the communication log only: the active
    /// alerts behind a non-zero level, or why it is 0. Not sent to the watch.
    public var hostAlertReason: String?
    /// Changes each time the host fires a glucose alert, including repeats of an
    /// alert that is still active, so the watch buzzes in step with the host.
    /// Persist it across launches so a restart can't land on the value the watch
    /// last saw; any value works as long as it changes on every fire.
    public var alertEvent: Int
    /// What the host's loop is doing, for the watch's IOB/COB and loop ring;
    /// `nil` when the host doesn't provide it.
    public var loopStatus: LupedLoopStatus?
    /// The host's therapy values for a phone-formatted status line; `nil`
    /// when the host doesn't provide them.
    public var therapy: LupedTherapy?
    /// The host's override presets, for Luped Remote to start one; `nil` when
    /// the host sends none.
    public var overridePresets: [LupedPreset]?
    /// The host's temp target presets; `nil` for hosts without temp targets
    /// (Loop), so Luped Remote offers none.
    public var tempTargetPresets: [LupedPreset]?

    public init(readings: [LupedReading], storedSampleCount: Int, unit: LupedUnit, hostAlertState: Int = 0, hostAlertReason: String? = nil, alertEvent: Int = 0, loopStatus: LupedLoopStatus? = nil, therapy: LupedTherapy? = nil, overridePresets: [LupedPreset]? = nil, tempTargetPresets: [LupedPreset]? = nil) {
        self.readings = readings
        self.storedSampleCount = storedSampleCount
        self.unit = unit
        self.hostAlertState = hostAlertState
        self.hostAlertReason = hostAlertReason
        self.alertEvent = alertEvent
        self.loopStatus = loopStatus
        self.therapy = therapy
        self.overridePresets = overridePresets
        self.tempTargetPresets = tempTargetPresets
    }
}

/// A preset the watch can start: the host's identifier, which the watch sends
/// back (`override:<id>`), its name, and whether it is running now.
public struct LupedPreset: Equatable, Sendable {
    public var id: String
    public var name: String
    public var isActive: Bool

    public init(id: String, name: String, isActive: Bool) {
        self.id = id
        self.name = name
        self.isActive = isActive
    }

    /// At most this many presets of a kind go to the watch, each name at most
    /// `maximumNameLength` characters.
    static let maximumCount = 16
    static let maximumNameLength = 32
    static let tokenPrefix = "~"

    /// The id the watch sends back: the host's own when it is plain (letters,
    /// digits, `.`, `_`, `-`, at most 64), so it can't break `override:<id>@<time>`;
    /// otherwise `~` and 12 hex digits of its SHA-256, mapped back on request.
    var watchID: String {
        if id.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil {
            return id
        }
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self.tokenPrefix + digest.prefix(12)
    }

    /// The presets as Luped Remote gets them: `[[id, name, running], …]`, at most
    /// `maximumCount`, with ids it can send back and names it can draw; null
    /// when the host has none of that kind.
    static func watchList(_ presets: [LupedPreset]?) -> Any {
        presets.map {
            $0.prefix(maximumCount).enumerated().map { index, preset in
                [preset.watchID, watchName(preset.name, fallback: "Preset \(index + 1)"), preset.isActive ? 1 : 0] as [Any]
            }
        } ?? NSNull()
    }

    /// The name as the watch can draw it: no control or invisible characters,
    /// emoji or other symbols (the watch fonts have none), whitespace collapsed,
    /// at most `maximumNameLength` characters; `fallback` when nothing is left.
    static func watchName(_ name: String, fallback: String) -> String {
        var kept = String.UnicodeScalarView()
        // Precomposed first, so an accent typed as a separate mark stays (é, not e).
        for scalar in name.precomposedStringWithCanonicalMapping.unicodeScalars {
            let properties = scalar.properties
            // Line breaks and tabs separate words: a space, before control
            // characters are dropped.
            if properties.isWhitespace {
                kept.append(" ")
                continue
            }
            switch properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .otherSymbol, .nonspacingMark, .enclosingMark:
                continue
            default:
                break
            }
            if scalar.value > 0xFFFF || (properties.isEmojiPresentation && scalar.value > 0x7F) {
                continue
            }
            kept.append(scalar)
        }
        let collapsed = String(kept).split(separator: " ").joined(separator: " ")
        let short = collapsed.count > maximumNameLength ? String(collapsed.prefix(maximumNameLength - 1)).trimmingCharacters(in: .whitespaces) + "…" : collapsed
        return short.isEmpty ? fallback : short
    }
}

/// The host's therapy values in mg/dL (glucose, ISF per U) and U/h (basal).
/// Any value may be unknown.
public struct LupedTherapy: Equatable {
    public var tempBasalRate: Double?
    public var scheduledBasalRate: Double?
    public var insulinSensitivity: Double?
    public var eventualGlucose: Double?
    public var correctionRange: ClosedRange<Double>?

    public init(tempBasalRate: Double? = nil, scheduledBasalRate: Double? = nil, insulinSensitivity: Double? = nil, eventualGlucose: Double? = nil, correctionRange: ClosedRange<Double>? = nil) {
        self.tempBasalRate = tempBasalRate
        self.scheduledBasalRate = scheduledBasalRate
        self.insulinSensitivity = insulinSensitivity
        self.eventualGlucose = eventualGlucose
        self.correctionRange = correctionRange
    }
}

/// The host's loop for the watch: insulin and carbs on board, when the loop
/// last completed and whether it is closed. Any value may be unknown.
public struct LupedLoopStatus: Equatable {
    public var insulinOnBoard: Double?
    public var carbsOnBoard: Double?
    public var lastLoopCompleted: Date?
    public var isClosedLoop: Bool?

    public init(insulinOnBoard: Double? = nil, carbsOnBoard: Double? = nil, lastLoopCompleted: Date? = nil, isClosedLoop: Bool? = nil) {
        self.insulinOnBoard = insulinOnBoard
        self.carbsOnBoard = carbsOnBoard
        self.lastLoopCompleted = lastLoopCompleted
        self.isClosedLoop = isClosedLoop
    }
}
