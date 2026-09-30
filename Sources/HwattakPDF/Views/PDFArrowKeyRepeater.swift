// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine

/// Owns a held navigation key independently of macOS's keyboard-repeat rate.
/// The caller keeps ownership of focus, document identity, and page semantics.
@MainActor
final class PDFArrowKeyRepeater: ObservableObject {
    @Published private(set) var isRepeating = false
    var currentModifiers: NSEvent.ModifierFlags { heldModifiers }

    private let speedProvider: () -> PDFKeyboardNavigationSpeed
    private let windowIsActive: @MainActor (NSWindow) -> Bool
    private var heldKeyCode: UInt16?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private weak var heldWindow: NSWindow?
    private var navigationAction: (() -> Bool)?
    private var repeatTimer: Timer?
    private var eventMonitor: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var generation: UInt64 = 0

    init(
        speedProvider: @escaping () -> PDFKeyboardNavigationSpeed = { .savedValue },
        windowIsActive: @escaping @MainActor (NSWindow) -> Bool = { $0.isKeyWindow && NSApp.isActive }
    ) {
        self.speedProvider = speedProvider
        self.windowIsActive = windowIsActive
    }

    deinit {
        repeatTimer?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    static func accepts(modifiers: NSEvent.ModifierFlags) -> Bool {
        speedMultiplier(for: modifiers) != nil
    }

    static func speedMultiplier(for modifiers: NSEvent.ModifierFlags) -> Double? {
        // Option arrows retain PDFKit's page navigation and native text-editing
        // shortcuts. The new base is 1.8× faster; Shift reaches 4× the old pace.
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        if modifiers.contains(.shift) { return 4 / 1.8 }
        return 1
    }

    static func effectiveRepeatInterval(
        speed: PDFKeyboardNavigationSpeed,
        modifiers: NSEvent.ModifierFlags
    ) -> TimeInterval? {
        speedMultiplier(for: modifiers).map { speed.repeatInterval / $0 }
    }

    static func effectiveInitialDelay(
        speed: PDFKeyboardNavigationSpeed,
        modifiers: NSEvent.ModifierFlags
    ) -> TimeInterval? {
        speedMultiplier(for: modifiers).map { speed.initialDelay / $0 }
    }

    @discardableResult
    func handleKeyDown(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool,
        window: NSWindow?,
        action: @escaping () -> Bool
    ) -> Bool {
        // Reject shortcut modifiers before swallowing an OS-generated repeat.
        guard (123...126).contains(keyCode), Self.accepts(modifiers: modifiers) else {
            stop()
            return false
        }
        if isRepeat {
            if heldKeyCode == keyCode, heldWindow === window {
                updateModifiers(modifiers)
            } else {
                stop()
            }
            // A repeat arriving after cancellation cannot start a new hold.
            return true
        }

        stop()
        let initialGeneration = generation
        guard action() else { return false }
        // The immediate step can synchronously change modes or lose focus.
        // Respect cancellation requested by that callback before installing a hold.
        guard generation == initialGeneration else { return true }
        // Offscreen callers can make a single step without installing global
        // observers or starting a hold that could outlive its UI destination.
        guard let window, windowIsActive(window) else { return true }
        heldKeyCode = keyCode
        heldModifiers = modifiers
        heldWindow = window
        navigationAction = action
        isRepeating = true
        installObservers(for: window)
        scheduleRepeat(after: Self.effectiveInitialDelay(speed: speedProvider(), modifiers: modifiers)!)
        return true
    }

    @discardableResult
    func handleKeyUp(keyCode: UInt16) -> Bool {
        guard heldKeyCode == keyCode else { return false }
        stop()
        return true
    }

    func stop() {
        generation &+= 1
        repeatTimer?.invalidate()
        repeatTimer = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        heldKeyCode = nil
        heldModifiers = []
        heldWindow = nil
        navigationAction = nil
        if isRepeating { isRepeating = false }
    }

    /// Shared production/test seam: tests advance a hold without wall-clock waits.
    func performScheduledRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        guard heldKeyCode != nil, let window = heldWindow,
              windowIsActive(window), let action = navigationAction else {
            stop()
            return
        }
        let currentGeneration = generation
        guard action() else {
            stop()
            return
        }
        // A callback can change focus/layout and cancel the hold synchronously.
        guard generation == currentGeneration, isRepeating,
              let interval = Self.effectiveRepeatInterval(
                speed: speedProvider(), modifiers: heldModifiers
              ) else { return }
        scheduleRepeat(after: interval)
    }

    /// Monitors only exist while a navigation hold is active. Ordinary input
    /// stays in the responder chain; duplicate native repeats are consumed.
    func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        guard let keyCode = heldKeyCode else { return event }
        switch event.type {
        case .keyUp:
            _ = handleKeyUp(keyCode: event.keyCode)
        case .keyDown:
            guard event.window === heldWindow, event.keyCode == keyCode,
                  Self.accepts(modifiers: event.modifierFlags), event.isARepeat else {
                stop()
                return event
            }
            updateModifiers(event.modifierFlags)
            return nil
        case .flagsChanged:
            guard Self.accepts(modifiers: event.modifierFlags) else {
                stop()
                return event
            }
            updateModifiers(event.modifierFlags)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            stop()
        default:
            break
        }
        return event
    }

    private func updateModifiers(_ modifiers: NSEvent.ModifierFlags) {
        let relevant = modifiers.intersection([.command, .control, .shift, .option])
        guard relevant != heldModifiers.intersection([.command, .control, .shift, .option]) else { return }
        heldModifiers = modifiers
        guard let interval = Self.effectiveRepeatInterval(speed: speedProvider(), modifiers: modifiers) else {
            stop()
            return
        }
        scheduleRepeat(after: interval)
    }

    private func scheduleRepeat(after interval: TimeInterval) {
        repeatTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.performScheduledRepeat() }
        }
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installObservers(for window: NSWindow) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitoredEvent(event)
        }
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didMiniaturizeNotification
        ] {
            notificationObservers.append(center.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
        }
    }
}
