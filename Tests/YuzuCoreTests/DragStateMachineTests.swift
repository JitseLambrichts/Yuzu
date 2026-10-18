import Foundation
import Testing
@testable import YuzuCore

/// Hulpje dat een reeks metingen afspeelt met een vaste tijdstap.
private struct Driver {
    var machine = DragStateMachine()
    var time: TimeInterval = 0
    var changeCount = 10
    var events: [DragEvent] = []

    mutating func step(button: Bool, modifiers: ModifierSet = [], escape: Bool = false, dt: TimeInterval = 0.016) {
        time += dt
        events += machine.step(InputSnapshot(time: time, primaryButtonDown: button, modifiers: modifiers,
                                             escapeDown: escape, dragChangeCount: changeCount))
    }

    /// Muis omlaag en een drag die het drag-pasteboard verandert.
    mutating func startDrag(modifiers: ModifierSet = []) {
        step(button: false)
        step(button: true, modifiers: modifiers)
        changeCount += 1
        step(button: true, modifiers: modifiers)
    }

    mutating func tap(_ modifiers: ModifierSet, holdSteps: Int = 5) {
        for _ in 0..<holdSteps { step(button: true, modifiers: modifiers) }
        step(button: true)
    }
}

@Suite struct DragStateMachineTests {
    @Test func clickWithoutDragDoesNothing() {
        var driver = Driver()
        driver.step(button: false)
        driver.step(button: true)
        driver.tap(.shift)
        driver.step(button: false)
        #expect(driver.events.isEmpty)
        #expect(driver.machine.phase == .idle)
    }

    @Test func shiftTapDuringDragOpensConvertWheel() {
        var driver = Driver()
        driver.startDrag()
        driver.tap(.shift)
        #expect(driver.events == [.dragStarted, .wheelRequested(.convert)])
        #expect(driver.machine.phase == .wheelOpen(.convert))
    }

    @Test func commandAndControlMapToTheirWheels() {
        var driver = Driver()
        driver.startDrag()
        driver.tap(.command)
        driver.tap(.control)
        #expect(driver.events == [.dragStarted, .wheelRequested(.tools), .wheelRequested(.actions)])
    }

    @Test func dragDetectedEvenWhenChangeCountMovedBeforeFirstButtonPoll() {
        var driver = Driver()
        driver.step(button: false)
        driver.changeCount += 1
        driver.step(button: true)
        #expect(driver.events == [.dragStarted])
    }

    @Test func modifierHeldAtDragStartIsNotATap() {
        var driver = Driver()
        driver.startDrag(modifiers: .shift)
        driver.step(button: true, modifiers: .shift)
        driver.step(button: true)
        #expect(driver.events == [.dragStarted])
        // Daarna werkt een nieuwe tik wel.
        driver.tap(.shift)
        #expect(driver.events.last == .wheelRequested(.convert))
    }

    @Test func holdingShiftOpensWheelOnceAfterDelay() {
        var driver = Driver()
        driver.startDrag()
        for _ in 0..<10 { driver.step(button: true, modifiers: .shift) } // ~0,16 s
        #expect(driver.events == [.dragStarted])
        for _ in 0..<60 { driver.step(button: true, modifiers: .shift) } // tot ~1,1 s
        driver.step(button: true)
        #expect(driver.events == [.dragStarted, .wheelRequested(.convert)])
    }

    @Test func holdingShiftUntilDropStillOpensWheel() {
        // Zoals in de echte log: Shift ingedrukt en vastgehouden tot het loslaten van de muis.
        var driver = Driver()
        driver.startDrag()
        for _ in 0..<40 { driver.step(button: true, modifiers: .shift) }
        driver.step(button: false, modifiers: .shift)
        #expect(driver.events == [.dragStarted, .wheelRequested(.convert), .dragEnded(wheelWasOpen: true)])
    }

    @Test func holdingUnboundCombinationDoesNothing() {
        var driver = Driver()
        driver.startDrag()
        for _ in 0..<60 { driver.step(button: true, modifiers: .option) }
        driver.step(button: true)
        #expect(driver.events == [.dragStarted])
    }

    @Test func chordPressedTogetherOpensItsWheel() {
        var driver = Driver()
        driver.machine.bindings[.tools] = [.shift, .command]
        driver.startDrag()
        for _ in 0..<30 { driver.step(button: true, modifiers: [.shift, .command]) }
        #expect(driver.events == [.dragStarted, .wheelRequested(.tools)])
    }

    @Test func combinationMustMatchExactly() {
        var driver = Driver()
        driver.startDrag()
        driver.tap([.shift, .command])
        #expect(driver.events == [.dragStarted])

        driver.machine.bindings[.tools] = [.shift, .command]
        driver.tap([.shift, .command])
        #expect(driver.events.last == .wheelRequested(.tools))
    }

    @Test func releasingMouseEndsDrag() {
        var driver = Driver()
        driver.startDrag()
        driver.tap(.shift)
        driver.step(button: false)
        #expect(driver.events.last == .dragEnded(wheelWasOpen: true))
        #expect(driver.machine.phase == .idle)
    }

    @Test func escapeCancelsUntilRelease() {
        var driver = Driver()
        driver.startDrag()
        driver.tap(.shift)
        driver.step(button: true, escape: true)
        #expect(driver.events.last == .cancelled)
        driver.tap(.shift)
        #expect(driver.events.last == .cancelled)
        driver.step(button: false)
        #expect(driver.machine.phase == .idle)
    }

    @Test func secondDragAfterIdleWorks() {
        var driver = Driver()
        driver.startDrag()
        driver.step(button: false)
        driver.startDrag()
        driver.tap(.shift)
        #expect(driver.events == [.dragStarted, .dragEnded(wheelWasOpen: false), .dragStarted, .wheelRequested(.convert)])
    }
}
