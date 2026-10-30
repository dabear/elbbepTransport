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

    public init(readings: [LupedReading], storedSampleCount: Int, unit: LupedUnit, hostAlertState: Int = 0, hostAlertReason: String? = nil, alertEvent: Int = 0, loopStatus: LupedLoopStatus? = nil, therapy: LupedTherapy? = nil) {
        self.readings = readings
        self.storedSampleCount = storedSampleCount
        self.unit = unit
        self.hostAlertState = hostAlertState
        self.hostAlertReason = hostAlertReason
        self.alertEvent = alertEvent
        self.loopStatus = loopStatus
        self.therapy = therapy
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
