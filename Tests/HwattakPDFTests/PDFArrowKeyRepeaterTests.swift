// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFArrowKeyRepeaterTests: XCTestCase {
    func testSavedSpeedFallsBackAndRestoresAllSupportedChoices() {
        let defaults = UserDefaults.standard
        let key = PDFKeyboardNavigationSpeed.defaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        XCTAssertEqual(PDFKeyboardNavigationSpeed.savedValue, .normal)
        defaults.set("unknown-speed", forKey: key)
        XCTAssertEqual(PDFKeyboardNavigationSpeed.savedValue, .normal)
        for speed in PDFKeyboardNavigationSpeed.allCases {
            defaults.set(speed.rawValue, forKey: key)
            XCTAssertEqual(PDFKeyboardNavigationSpeed.savedValue, speed)
        }
    }

    func testSpeedAndModifiersProduceOrderedFiniteRepeatIntervals() throws {
        var previous = TimeInterval.infinity
        for speed in PDFKeyboardNavigationSpeed.allCases {
            let regular = try XCTUnwrap(PDFArrowKeyRepeater.effectiveRepeatInterval(speed: speed, modifiers: []))
            let faster = try XCTUnwrap(PDFArrowKeyRepeater.effectiveRepeatInterval(speed: speed, modifiers: .shift))
            XCTAssertGreaterThan(regular, 0)
            XCTAssertLessThan(regular, previous)
            XCTAssertEqual(faster, regular * 1.8 / 4, accuracy: 0.000001)
            XCTAssertEqual(
                PDFArrowKeyRepeater.effectiveInitialDelay(speed: speed, modifiers: .shift),
                speed.initialDelay / (4 / 1.8)
            )
            previous = regular
        }
        XCTAssertTrue(PDFArrowKeyRepeater.accepts(modifiers: [.numericPad, .function, .capsLock]))
        for flags: NSEvent.ModifierFlags in [
            .command, .control, .option, [.command, .shift], [.control, .option], [.shift, .option]
        ] {
            XCTAssertFalse(PDFArrowKeyRepeater.accepts(modifiers: flags))
            XCTAssertNil(PDFArrowKeyRepeater.effectiveRepeatInterval(speed: .normal, modifiers: flags))
        }
    }

    func testNormalAndShiftSpeedMatchRequestedIncreaseFromPreviousNormalSpeed() throws {
        let previousInterval = 0.09
        let normal = try XCTUnwrap(PDFArrowKeyRepeater.effectiveRepeatInterval(speed: .normal, modifiers: []))
        let shift = try XCTUnwrap(PDFArrowKeyRepeater.effectiveRepeatInterval(speed: .normal, modifiers: .shift))
        XCTAssertEqual(previousInterval / normal, 1.8, accuracy: 0.000001)
        XCTAssertEqual(previousInterval / shift, 4, accuracy: 0.000001)
        XCTAssertEqual(normal, 0.05, accuracy: 0.000001)
        XCTAssertEqual(shift, 0.0225, accuracy: 0.000001)
    }

    func testSwiftUIKeyAndModifierMappingPreservesShortcutBoundaries() {
        XCTAssertEqual(PDFArrowKeyNavigationModifier.keyCode(for: .leftArrow), 123)
        XCTAssertEqual(PDFArrowKeyNavigationModifier.keyCode(for: .rightArrow), 124)
        XCTAssertEqual(PDFArrowKeyNavigationModifier.keyCode(for: .downArrow), 125)
        XCTAssertEqual(PDFArrowKeyNavigationModifier.keyCode(for: .upArrow), 126)
        XCTAssertNil(PDFArrowKeyNavigationModifier.keyCode(for: .pageDown))
        XCTAssertNil(PDFArrowKeyNavigationModifier.keyCode(for: "a"))
        for modifier: EventModifiers in [.command, .control, .option, [.command, .shift], [.shift, .option]] {
            XCTAssertFalse(PDFArrowKeyRepeater.accepts(
                modifiers: PDFArrowKeyNavigationModifier.nativeModifiers(modifier)
            ))
        }
        XCTAssertEqual(PDFArrowKeyNavigationModifier.nativeModifiers(.shift), .shift)
        XCTAssertEqual(PDFArrowKeyNavigationModifier.nativeModifiers(.option), .option)
    }

    func testOffscreenPressIsImmediateWithoutStartingARepeatTimer() {
        let repeater = PDFArrowKeyRepeater()
        var steps = 0
        XCTAssertTrue(repeater.handleKeyDown(keyCode: 125, modifiers: [], isRepeat: false, window: nil) {
            steps += 1
            return true
        })
        XCTAssertEqual(steps, 1)
        XCTAssertFalse(repeater.isRepeating)
        repeater.performScheduledRepeat()
        XCTAssertEqual(steps, 1)
    }

    func testHeldKeyUsesItsOwnTicksAndConsumesDuplicateSystemRepeats() {
        let window = makeWindow()
        let repeater = makeRepeater()
        defer { repeater.stop() }
        var steps = 0
        XCTAssertTrue(repeater.handleKeyDown(keyCode: 125, modifiers: [], isRepeat: false, window: window) {
            steps += 1
            return true
        })
        XCTAssertEqual(steps, 1)
        XCTAssertTrue(repeater.isRepeating)
        // Offscreen windows have windowNumber 0, so synthetic NSEvents cannot
        // resolve their window identity. Exercise the equivalent repeat entry
        // point directly instead of weakening the monitor's window boundary.
        XCTAssertTrue(repeater.handleKeyDown(keyCode: 125, modifiers: [], isRepeat: true, window: window) {
            steps += 1
            return true
        })
        XCTAssertEqual(steps, 1)
        repeater.performScheduledRepeat()
        repeater.performScheduledRepeat()
        XCTAssertEqual(steps, 3)

        XCTAssertFalse(repeater.handleKeyUp(keyCode: 124))
        XCTAssertTrue(repeater.isRepeating)
        XCTAssertTrue(repeater.handleKeyUp(keyCode: 125))
        repeater.performScheduledRepeat()
        XCTAssertEqual(steps, 3)
        XCTAssertFalse(repeater.isRepeating)
    }

    func testIndependentPressesRemainImmediateEvenAtTheSlowestSpeed() {
        let window = makeWindow()
        let repeater = makeRepeater(speed: .slow)
        defer { repeater.stop() }
        var steps = 0
        for _ in 0..<3 {
            XCTAssertTrue(repeater.handleKeyDown(keyCode: 124, modifiers: [], isRepeat: false, window: window) {
                steps += 1
                return true
            })
            _ = repeater.handleKeyUp(keyCode: 124)
        }
        XCTAssertEqual(steps, 3)
    }

    func testBlockedModifierOnARepeatCancelsBeforeDuplicateRepeatHandling() {
        let window = makeWindow()
        let repeater = makeRepeater()
        var steps = 0
        _ = repeater.handleKeyDown(keyCode: 124, modifiers: [], isRepeat: false, window: window) {
            steps += 1
            return true
        }
        XCTAssertFalse(repeater.handleKeyDown(keyCode: 124, modifiers: .command, isRepeat: true, window: window) {
            steps += 1
            return true
        })
        repeater.performScheduledRepeat()
        XCTAssertEqual(steps, 1)
        XCTAssertFalse(repeater.isRepeating)
    }

    func testModifierChangesKeepTheHoldWithoutAnExtraImmediateStep() throws {
        let window = makeWindow()
        let repeater = makeRepeater()
        defer { repeater.stop() }
        var steps = 0
        _ = repeater.handleKeyDown(keyCode: 126, modifiers: [], isRepeat: false, window: window) {
            steps += 1
            return true
        }
        for flags: NSEvent.ModifierFlags in [.shift, []] {
            _ = repeater.handleMonitoredEvent(try keyEvent(.flagsChanged, code: 56, window: window, modifiers: flags))
            XCTAssertTrue(repeater.isRepeating)
            XCTAssertEqual(steps, 1)
        }
        _ = repeater.handleMonitoredEvent(try keyEvent(.flagsChanged, code: 55, window: window, modifiers: .command))
        XCTAssertFalse(repeater.isRepeating)
        XCTAssertEqual(steps, 1)
    }

    func testOptionPressAndSystemRepeatYieldWithoutInvokingNavigation() {
        let window = makeWindow()
        let repeater = makeRepeater()
        for isRepeat in [false, true] {
            var steps = 0
            XCTAssertFalse(repeater.handleKeyDown(
                keyCode: 125, modifiers: .option, isRepeat: isRepeat, window: window
            ) {
                steps += 1
                return true
            })
            repeater.performScheduledRepeat()
            XCTAssertEqual(steps, 0)
            XCTAssertFalse(repeater.isRepeating)
        }
    }

    func testAddingOptionDuringAHoldCancelsImmediatelyAndPreservesTheEvent() throws {
        let window = makeWindow()
        let repeater = makeRepeater()
        var steps = 0
        _ = repeater.handleKeyDown(keyCode: 125, modifiers: [], isRepeat: false, window: window) {
            steps += 1
            return true
        }
        let option = try keyEvent(.flagsChanged, code: 58, window: window, modifiers: .option)
        XCTAssertTrue(repeater.handleMonitoredEvent(option) === option)
        XCTAssertFalse(repeater.isRepeating)
        repeater.performScheduledRepeat()
        XCTAssertEqual(steps, 1)
        let nativeRepeat = try keyEvent(.keyDown, code: 125, window: window, modifiers: .option, repeats: true)
        XCTAssertTrue(repeater.handleMonitoredEvent(nativeRepeat) === nativeRepeat)
    }

    func testOtherKeyAndKeyUpCancelTheActiveHold() throws {
        let window = makeWindow()
        for (type, keyCode) in [(NSEvent.EventType.keyDown, UInt16(0)), (.keyUp, UInt16(123))] {
            let repeater = makeRepeater()
            var steps = 0
            _ = repeater.handleKeyDown(keyCode: 123, modifiers: [], isRepeat: false, window: window) {
                steps += 1
                return true
            }
            _ = repeater.handleMonitoredEvent(try keyEvent(type, code: keyCode, window: window))
            repeater.performScheduledRepeat()
            XCTAssertFalse(repeater.isRepeating)
            XCTAssertEqual(steps, 1)
        }
    }

    func testActionCanYieldWhenASpeedModifierIsAddedDuringAHold() throws {
        let window = makeWindow()
        for modifier: NSEvent.ModifierFlags in [.shift] {
            let repeater = makeRepeater()
            var successfulSteps = 0
            _ = repeater.handleKeyDown(keyCode: 125, modifiers: [], isRepeat: false, window: window) { [weak repeater] in
                guard let repeater,
                      repeater.currentModifiers.intersection([.shift, .option]).isEmpty else { return false }
                successfulSteps += 1
                return true
            }
            XCTAssertEqual(successfulSteps, 1)
            _ = repeater.handleMonitoredEvent(try keyEvent(
                .flagsChanged, code: 56, window: window, modifiers: modifier
            ))
            XCTAssertEqual(repeater.currentModifiers, modifier)
            repeater.performScheduledRepeat()
            XCTAssertEqual(successfulSteps, 1)
            XCTAssertFalse(repeater.isRepeating)
            XCTAssertTrue(repeater.currentModifiers.isEmpty)
        }
    }

    func testWindowAndAppLifecycleNotificationsStopHeldNavigation() {
        let window = makeWindow()
        for name in [
            NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didMiniaturizeNotification,
            NSApplication.didResignActiveNotification
        ] {
            let repeater = makeRepeater()
            var steps = 0
            _ = repeater.handleKeyDown(keyCode: 125, modifiers: [], isRepeat: false, window: window) {
                steps += 1
                return true
            }
            NotificationCenter.default.post(name: name, object: window)
            repeater.performScheduledRepeat()
            XCTAssertFalse(repeater.isRepeating)
            XCTAssertEqual(steps, 1)
        }
    }

    func testLosingFocusOrTheCallerRejectingItsDestinationStopsBeforeFurtherTicks() {
        let window = makeWindow()
        var active = true
        let repeater = PDFArrowKeyRepeater(windowIsActive: { _ in active })
        var steps = 0
        _ = repeater.handleKeyDown(keyCode: 125, modifiers: [], isRepeat: false, window: window) {
            steps += 1
            return true
        }
        active = false
        repeater.performScheduledRepeat()
        XCTAssertEqual(steps, 1)
        XCTAssertFalse(repeater.isRepeating)

        active = true
        var validDestination = true
        _ = repeater.handleKeyDown(keyCode: 125, modifiers: [], isRepeat: false, window: window) {
            guard validDestination else { return false }
            steps += 1
            return true
        }
        validDestination = false
        repeater.performScheduledRepeat()
        XCTAssertEqual(steps, 2)
        XCTAssertFalse(repeater.isRepeating)
    }

    func testCancelledHoldCannotRestartFromAQueuedSystemRepeat() {
        let window = makeWindow()
        let repeater = makeRepeater()
        var steps = 0
        _ = repeater.handleKeyDown(keyCode: 124, modifiers: [], isRepeat: true, window: window) {
            steps += 1
            return true
        }
        XCTAssertEqual(steps, 0)
        XCTAssertFalse(repeater.isRepeating)
    }

    func testSystemRepeatCannotReplaceTheOriginalDestinationAction() {
        let window = makeWindow()
        let repeater = makeRepeater()
        defer { repeater.stop() }
        var originalSteps = 0
        var replacementSteps = 0
        _ = repeater.handleKeyDown(keyCode: 124, modifiers: [], isRepeat: false, window: window) {
            originalSteps += 1
            return true
        }
        _ = repeater.handleKeyDown(keyCode: 124, modifiers: .shift, isRepeat: true, window: window) {
            replacementSteps += 1
            return true
        }
        repeater.performScheduledRepeat()
        XCTAssertEqual(originalSteps, 2)
        XCTAssertEqual(replacementSteps, 0)
    }

    func testCancellationDuringTheImmediateStepDoesNotStartAHold() {
        let window = makeWindow()
        let repeater = makeRepeater()
        var steps = 0
        XCTAssertTrue(repeater.handleKeyDown(keyCode: 124, modifiers: [], isRepeat: false, window: window) { [weak repeater] in
            steps += 1
            repeater?.stop()
            return true
        })
        repeater.performScheduledRepeat()
        XCTAssertEqual(steps, 1)
        XCTAssertFalse(repeater.isRepeating)
    }

    func testCancellationFromInsideTheCallbackDoesNotRearmATimer() {
        let window = makeWindow()
        let repeater = makeRepeater()
        var steps = 0
        _ = repeater.handleKeyDown(keyCode: 124, modifiers: [], isRepeat: false, window: window) { [weak repeater] in
            steps += 1
            if steps > 1 { repeater?.stop() }
            return true
        }
        repeater.performScheduledRepeat()
        XCTAssertEqual(steps, 2)
        XCTAssertFalse(repeater.isRepeating)
        repeater.performScheduledRepeat()
        XCTAssertEqual(steps, 2)
    }

    func testObserversAndTimersDoNotKeepTheControllerAlive() {
        let window = makeWindow()
        var repeater: PDFArrowKeyRepeater? = makeRepeater()
        weak var weakRepeater = repeater
        _ = repeater?.handleKeyDown(keyCode: 125, modifiers: [], isRepeat: false, window: window) { true }
        repeater = nil
        XCTAssertNil(weakRepeater)
    }

    private func makeRepeater(speed: PDFKeyboardNavigationSpeed = .normal) -> PDFArrowKeyRepeater {
        PDFArrowKeyRepeater(speedProvider: { speed }, windowIsActive: { _ in true })
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [], backing: .buffered, defer: false)
    }

    private func keyEvent(
        _ type: NSEvent.EventType,
        code: UInt16,
        window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [],
        repeats: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: modifiers,
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: repeats, keyCode: code
        ))
    }
}
