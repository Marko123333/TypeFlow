import Foundation

/// One physical Shift key. Keeping the side lets the recognizer distinguish a
/// double tap from a press of both Shift keys.
public enum ShiftSide: Hashable, Sendable {
    case left
    case right
}

/// Intent produced by `ShiftGestureRecognizer`. Scheduling is deliberately
/// delegated to the app so this state machine stays deterministic and testable.
public enum ShiftGestureAction: Equatable, Sendable {
    case scheduleSingle(deadline: TimeInterval)
    case cancelScheduledSingle
    case switchLayout
    case convertLastWord
}

/// Resolves Shift gestures without changing the automatic-correction setting:
///
/// - one clean tap: switch the active layout;
/// - two clean taps: convert the last word/selection;
/// - both Shift keys together: no action, so an accidental chord cannot disable correction.
///
/// A single tap is kept pending for a short double-tap window. If a normal key
/// arrives during that window, `nonShiftKeyDown(at:)` emits `.switchLayout`
/// immediately, before the application processes that key. This avoids making
/// fast typists wait for the timer while preserving an unambiguous double tap.
public struct ShiftGestureRecognizer: Sendable {
    public let maximumTapDuration: TimeInterval
    public let doubleTapInterval: TimeInterval

    private var held: Set<ShiftSide> = []
    private var pressStartedAt: TimeInterval?
    private var contaminated = false
    private var chordActive = false
    private var secondTapCandidate = false
    private var pendingSingleDeadline: TimeInterval?

    public init(
        maximumTapDuration: TimeInterval = 0.45,
        doubleTapInterval: TimeInterval = 0.28
    ) {
        self.maximumTapDuration = maximumTapDuration
        self.doubleTapInterval = doubleTapInterval
    }

    public mutating func shiftChanged(
        side: ShiftSide,
        isDown: Bool,
        at timestamp: TimeInterval
    ) -> [ShiftGestureAction] {
        isDown
            ? shiftDown(side: side, at: timestamp)
            : shiftUp(side: side, at: timestamp)
    }

    /// Call for every non-Shift keyDown before forwarding it to the focused app.
    public mutating func nonShiftKeyDown(at timestamp: TimeInterval) -> [ShiftGestureAction] {
        var actions: [ShiftGestureAction] = []

        if pendingSingleDeadline != nil {
            pendingSingleDeadline = nil
            secondTapCandidate = false
            actions.append(.cancelScheduledSingle)
            actions.append(.switchLayout)
        }

        if !held.isEmpty {
            contaminated = true
            secondTapCandidate = false
        }
        return actions
    }

    /// Call when the app-owned timer for `.scheduleSingle` reaches its deadline.
    public mutating func singleTapDeadlineReached(at timestamp: TimeInterval) -> [ShiftGestureAction] {
        guard held.isEmpty,
              let deadline = pendingSingleDeadline,
              timestamp >= deadline else { return [] }
        pendingSingleDeadline = nil
        secondTapCandidate = false
        return [.switchLayout]
    }

    /// Clears transient state. The caller should cancel its scheduled work item
    /// when this returns `.cancelScheduledSingle`.
    public mutating func reset() -> [ShiftGestureAction] {
        let hadPending = pendingSingleDeadline != nil
        held.removeAll()
        pressStartedAt = nil
        contaminated = false
        chordActive = false
        secondTapCandidate = false
        pendingSingleDeadline = nil
        return hadPending ? [.cancelScheduledSingle] : []
    }

    private mutating func shiftDown(side: ShiftSide, at timestamp: TimeInterval) -> [ShiftGestureAction] {
        guard !held.contains(side) else { return [] }
        var actions: [ShiftGestureAction] = []

        // A timer can be delayed by a busy main run loop. Resolve an already
        // expired tap before treating this press as a new gesture.
        if let deadline = pendingSingleDeadline, timestamp > deadline {
            pendingSingleDeadline = nil
            actions.append(.cancelScheduledSingle)
            actions.append(.switchLayout)
        }

        if held.isEmpty {
            pressStartedAt = timestamp
            contaminated = false
            secondTapCandidate = pendingSingleDeadline.map { timestamp <= $0 } ?? false
            if secondTapCandidate {
                // Keep pendingSingleDeadline as evidence until this second tap
                // succeeds or turns into Shift+letter. Only cancel its timer.
                actions.append(.cancelScheduledSingle)
            }
            held.insert(side)
            return actions
        }

        held.insert(side)
        chordActive = true
        contaminated = true
        secondTapCandidate = false
        if pendingSingleDeadline != nil {
            pendingSingleDeadline = nil
            actions.append(.cancelScheduledSingle)
        }
        return actions
    }

    private mutating func shiftUp(side: ShiftSide, at timestamp: TimeInterval) -> [ShiftGestureAction] {
        guard held.remove(side) != nil else { return [] }

        if chordActive {
            if held.isEmpty {
                chordActive = false
                contaminated = false
                pressStartedAt = nil
            }
            return []
        }

        guard held.isEmpty else { return [] }
        defer {
            pressStartedAt = nil
            contaminated = false
        }

        guard !contaminated,
              let started = pressStartedAt,
              timestamp - started <= maximumTapDuration else {
            secondTapCandidate = false
            return []
        }

        if secondTapCandidate {
            secondTapCandidate = false
            pendingSingleDeadline = nil
            return [.convertLastWord]
        }

        let deadline = timestamp + doubleTapInterval
        pendingSingleDeadline = deadline
        return [.scheduleSingle(deadline: deadline)]
    }
}
