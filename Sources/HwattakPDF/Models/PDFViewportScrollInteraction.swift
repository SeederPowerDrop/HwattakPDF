// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// The modifier used for wheel/trackpad-scroll zoom in the main PDF canvas.
/// Option follows Adobe's macOS convention; Command remains available for
/// users who prefer the browser convention or need to avoid an accessibility
/// shortcut assigned to Option.
enum PDFWheelZoomModifier: String, CaseIterable, Identifiable {
    case option
    case command
    case disabled

    static let defaultsKey = "pdf.viewport.wheelZoomModifier"
    static let defaultValue: PDFWheelZoomModifier = .option

    var id: String { rawValue }

    var title: String {
        switch self {
        case .option:
            L10n.string("settings.pdf_input.zoom_modifier.option", defaultValue: "Option (⌥)")
        case .command:
            L10n.string("settings.pdf_input.zoom_modifier.command", defaultValue: "Command (⌘)")
        case .disabled:
            L10n.string("settings.pdf_input.zoom_modifier.disabled", defaultValue: "끄기")
        }
    }
}

struct PDFViewportScrollModifiers: OptionSet, Equatable {
    let rawValue: Int

    static let shift = PDFViewportScrollModifiers(rawValue: 1 << 0)
    static let control = PDFViewportScrollModifiers(rawValue: 1 << 1)
    static let option = PDFViewportScrollModifiers(rawValue: 1 << 2)
    static let command = PDFViewportScrollModifiers(rawValue: 1 << 3)
}

struct PDFViewportScrollInput: Equatable {
    let deltaX: CGFloat
    let deltaY: CGFloat
    let hasPreciseDeltas: Bool
    let modifiers: PDFViewportScrollModifiers
}

enum PDFViewportScrollIntent: Equatable {
    /// Preserve PDFKit/SwiftUI's normal scrolling, native horizontal deltas,
    /// text selection, form controls, annotations, and pinch magnification.
    case native
    /// A multiplicative zoom step. The view applies this around the pointer.
    case zoom(stepFactor: CGFloat)
    /// A content-space horizontal wheel delta. Every event is forwarded to
    /// the same clip view so touch and momentum phases remain continuous.
    case horizontalPan(delta: CGFloat)
}

enum PDFViewportScrollIntentResolver {
    static let mouseWheelLineMultiplier: CGFloat = 12

    static func resolve(
        _ input: PDFViewportScrollInput,
        zoomModifier: PDFWheelZoomModifier
    ) -> PDFViewportScrollIntent {
        guard input.deltaX.isFinite, input.deltaY.isFinite else { return .native }

        // Caps Lock and Fn never enter this compact modifier set. Requiring an
        // exact match makes ambiguous Option+Shift / Command+Shift gestures
        // fall through to AppKit instead of unexpectedly consuming them.
        let expectedZoomModifiers: PDFViewportScrollModifiers?
        switch zoomModifier {
        case .option:
            expectedZoomModifiers = .option
        case .command:
            expectedZoomModifiers = .command
        case .disabled:
            expectedZoomModifiers = nil
        }

        if
            let expectedZoomModifiers,
            input.modifiers == expectedZoomModifiers,
            let factor = zoomStepFactor(
                deltaY: input.deltaY,
                hasPreciseDeltas: input.hasPreciseDeltas
            )
        {
            return .zoom(stepFactor: factor)
        }

        if
            input.modifiers == .shift,
            let delta = horizontalPanDelta(
                deltaX: input.deltaX,
                deltaY: input.deltaY,
                hasPreciseDeltas: input.hasPreciseDeltas
            )
        {
            return .horizontalPan(delta: delta)
        }

        return .native
    }

    static func zoomStepFactor(
        deltaY: CGFloat,
        hasPreciseDeltas: Bool
    ) -> CGFloat? {
        guard deltaY.isFinite, abs(deltaY) > 0.0001 else { return nil }
        let sensitivity: CGFloat = hasPreciseDeltas ? 0.012 : 0.12
        let exponent = min(0.35, max(-0.35, deltaY * sensitivity))
        return exp(exponent)
    }

    static func horizontalPanDelta(
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseDeltas: Bool
    ) -> CGFloat? {
        guard deltaX.isFinite, deltaY.isFinite else { return nil }
        guard abs(deltaX) + abs(deltaY) > 0.0001 else { return nil }
        let multiplier: CGFloat = hasPreciseDeltas ? 1 : mouseWheelLineMultiplier
            // Keep a trackpad's existing horizontal component while mapping
            // the vertical component. Opposing diagonal jitter must not cancel
            // the user's dominant direction to nearly zero.
        let combinedDelta: CGFloat
        if deltaX == 0 {
            combinedDelta = deltaY
        } else if deltaY == 0 {
            combinedDelta = deltaX
        } else if deltaX.sign == deltaY.sign {
            combinedDelta = deltaX + deltaY
        } else {
            combinedDelta = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
        }
        return combinedDelta * multiplier
    }

    static func clampedScale(
        currentScale: CGFloat,
        stepFactor: CGFloat,
        minimumScale: CGFloat,
        maximumScale: CGFloat
    ) -> CGFloat {
        // Match workspace restoration's absolute safety envelope while also
        // respecting a stricter PDFView-specific minimum or maximum.
        let viewMinimum = minimumScale.isFinite ? minimumScale : 0.05
        let viewMaximum = maximumScale.isFinite ? maximumScale : 20
        let lower = min(20, max(0.05, viewMinimum))
        let upper = max(lower, min(20, viewMaximum))
        let current = currentScale.isFinite ? currentScale : lower
        guard stepFactor.isFinite, stepFactor > 0 else {
            return min(upper, max(lower, current))
        }
        return min(upper, max(lower, current * stepFactor))
    }
}

enum PDFViewportModifiedScrollOwner: Equatable {
    case zoom
    case horizontalPan
}

/// Keeps a modified touch gesture owned through its momentum tail even when
/// the user releases the keyboard modifier before lifting their fingers.
struct PDFViewportModifiedScrollGestureLatch: Equatable {
    private(set) var owner: PDFViewportModifiedScrollOwner?
    private(set) var isAwaitingMomentum = false

    mutating func ownerForEvent(
        intent: PDFViewportScrollIntent,
        touchPhasePresent: Bool,
        touchPhaseBegan: Bool,
        momentumPhasePresent: Bool
    ) -> PDFViewportModifiedScrollOwner? {
        if let owner {
            if momentumPhasePresent {
                isAwaitingMomentum = false
                return owner
            }
            if touchPhasePresent, !(isAwaitingMomentum && touchPhaseBegan) {
                return owner
            }
            if !touchPhasePresent {
                reset()
            }
        }

        let newOwner: PDFViewportModifiedScrollOwner?
        switch intent {
        case .zoom:
            newOwner = .zoom
        case .horizontalPan:
            newOwner = .horizontalPan
        case .native:
            newOwner = nil
        }
        owner = newOwner
        isAwaitingMomentum = false
        return newOwner
    }

    mutating func touchEnded() {
        guard owner != nil else { return }
        isAwaitingMomentum = true
    }

    mutating func reset() {
        owner = nil
        isAwaitingMomentum = false
    }
}

struct PDFWheelZoomAccumulator: Equatable {
    private(set) var relativeFactor: CGFloat = 1

    mutating func reset() {
        relativeFactor = 1
    }

    @discardableResult
    mutating func consume(stepFactor: CGFloat) -> CGFloat {
        guard stepFactor.isFinite, stepFactor > 0 else { return relativeFactor }
        relativeFactor = min(4, max(0.25, relativeFactor * stepFactor))
        return relativeFactor
    }
}

/// Keeps non-rendering work off PDFKit's high-frequency native scroll path.
/// The canvas may receive 120 Hz trackpad deltas, while the transient HUD only
/// needs the newest position at a modest cadence. Final viewport persistence is
/// handled separately at the end of live scrolling.
enum PDFLiveScrollReportingPolicy {
    static let minimumInterval: TimeInterval = 1.0 / 30.0
    static let verticalMovementEpsilon: CGFloat = 0.1

    static func deliveryDelay(
        lastDeliveryTime: TimeInterval?,
        currentTime: TimeInterval
    ) -> TimeInterval {
        guard currentTime.isFinite else { return 0 }
        guard
            let lastDeliveryTime,
            lastDeliveryTime.isFinite,
            currentTime >= lastDeliveryTime
        else {
            return 0
        }
        return max(0, minimumInterval - (currentTime - lastDeliveryTime))
    }

    static func hasMeaningfulVerticalMovement(
        from previousOriginY: CGFloat?,
        to currentOriginY: CGFloat
    ) -> Bool {
        guard currentOriginY.isFinite else { return false }
        guard let previousOriginY, previousOriginY.isFinite else { return true }
        return abs(currentOriginY - previousOriginY) >= verticalMovementEpsilon
    }
}
