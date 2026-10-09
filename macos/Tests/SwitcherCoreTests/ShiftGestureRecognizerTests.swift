import Testing
@testable import SwitcherCore

@Suite("Shift gesture recognizer")
struct ShiftGestureRecognizerTests {
    @Test func singleTapSwitchesAtDeadline() {
        var recognizer = ShiftGestureRecognizer(doubleTapInterval: 0.28)

        #expect(recognizer.shiftChanged(side: .left, isDown: true, at: 1.00) == [])
        #expect(recognizer.shiftChanged(side: .left, isDown: false, at: 1.05) == [
            .scheduleSingle(deadline: 1.33)
        ])
        #expect(recognizer.singleTapDeadlineReached(at: 1.32) == [])
        #expect(recognizer.singleTapDeadlineReached(at: 1.33) == [.switchLayout])
    }

    @Test func normalKeyFlushesPendingSwitchBeforeTyping() {
        var recognizer = ShiftGestureRecognizer(doubleTapInterval: 0.28)
        _ = recognizer.shiftChanged(side: .left, isDown: true, at: 1.00)
        _ = recognizer.shiftChanged(side: .left, isDown: false, at: 1.05)

        #expect(recognizer.nonShiftKeyDown(at: 1.10) == [
            .cancelScheduledSingle, .switchLayout
        ])
        #expect(recognizer.singleTapDeadlineReached(at: 2.00) == [])
    }

    @Test func doubleTapCancelsSingleAndConverts() {
        var recognizer = ShiftGestureRecognizer(doubleTapInterval: 0.28)
        _ = recognizer.shiftChanged(side: .left, isDown: true, at: 1.00)
        _ = recognizer.shiftChanged(side: .left, isDown: false, at: 1.05)

        #expect(recognizer.shiftChanged(side: .left, isDown: true, at: 1.18) == [
            .cancelScheduledSingle
        ])
        #expect(recognizer.shiftChanged(side: .left, isDown: false, at: 1.23) == [
            .convertLastWord
        ])
    }

    @Test func bothShiftsDoNotDisableAutomaticCorrection() {
        var recognizer = ShiftGestureRecognizer()

        #expect(recognizer.shiftChanged(side: .left, isDown: true, at: 1.00) == [])
        #expect(recognizer.shiftChanged(side: .right, isDown: true, at: 1.03) == [])
        #expect(recognizer.shiftChanged(side: .right, isDown: false, at: 1.10) == [])
        #expect(recognizer.shiftChanged(side: .left, isDown: false, at: 1.12) == [])
        #expect(recognizer.singleTapDeadlineReached(at: 2.00) == [])
    }

    @Test func rightShiftTapStillSwitchesLayout() {
        var recognizer = ShiftGestureRecognizer()

        #expect(recognizer.shiftChanged(side: .right, isDown: true, at: 1.00) == [])
        #expect(recognizer.shiftChanged(side: .right, isDown: false, at: 1.05) == [
            .scheduleSingle(deadline: 1.33)
        ])
        #expect(recognizer.singleTapDeadlineReached(at: 1.33) == [.switchLayout])
    }

    @Test func shiftUsedForCapitalizationDoesNothing() {
        var recognizer = ShiftGestureRecognizer()

        _ = recognizer.shiftChanged(side: .left, isDown: true, at: 1.00)
        #expect(recognizer.nonShiftKeyDown(at: 1.04) == [])
        #expect(recognizer.shiftChanged(side: .left, isDown: false, at: 1.09) == [])
        #expect(recognizer.singleTapDeadlineReached(at: 2.00) == [])
    }

    @Test func secondPressUsedForCapitalizationFlushesFirstTap() {
        var recognizer = ShiftGestureRecognizer()
        _ = recognizer.shiftChanged(side: .left, isDown: true, at: 1.00)
        _ = recognizer.shiftChanged(side: .left, isDown: false, at: 1.05)
        _ = recognizer.shiftChanged(side: .left, isDown: true, at: 1.15)

        #expect(recognizer.nonShiftKeyDown(at: 1.18) == [
            .cancelScheduledSingle, .switchLayout
        ])
        #expect(recognizer.shiftChanged(side: .left, isDown: false, at: 1.22) == [])
    }
}
