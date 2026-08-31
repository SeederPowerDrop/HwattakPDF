// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// An AppKit-backed signature canvas that keeps raw trackpad touches available
/// to SwiftUI without requiring a click or Force Touch.
struct SignatureCaptureView: NSViewRepresentable {
    @Binding var strokes: [SignatureStroke]
    @Binding var isTrackpadCaptureActive: Bool
    var settings: SignatureSettings
    var onCanvasSizeChange: (CGSize) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            strokes: $strokes,
            isTrackpadCaptureActive: $isTrackpadCaptureActive,
            onCanvasSizeChange: onCanvasSizeChange
        )
    }

    func makeNSView(context: Context) -> SignatureCanvasNSView {
        let canvas = SignatureCanvasNSView()
        canvas.settings = settings
        canvas.replaceStrokes(with: strokes)
        canvas.onStrokesChange = { [weak coordinator = context.coordinator] updatedStrokes in
            coordinator?.setStrokes(updatedStrokes)
        }
        canvas.onCanvasSizeChange = { [weak coordinator = context.coordinator] size in
            coordinator?.setCanvasSize(size)
        }
        canvas.onTrackpadCaptureEnd = { [weak coordinator = context.coordinator] in
            coordinator?.endTrackpadCapture()
        }
        canvas.setTrackpadCaptureActive(isTrackpadCaptureActive)
        return canvas
    }

    func updateNSView(_ nsView: SignatureCanvasNSView, context: Context) {
        context.coordinator.update(
            strokes: $strokes,
            isTrackpadCaptureActive: $isTrackpadCaptureActive,
            onCanvasSizeChange: onCanvasSizeChange
        )
        nsView.settings = settings
        nsView.setTrackpadCaptureActive(isTrackpadCaptureActive)
        nsView.replaceStrokes(with: strokes)
    }

    static func dismantleNSView(_ nsView: SignatureCanvasNSView, coordinator: Coordinator) {
        nsView.prepareForRemoval()
    }

    @MainActor
    final class Coordinator {
        private var strokes: Binding<[SignatureStroke]>
        private var isTrackpadCaptureActive: Binding<Bool>
        private var onCanvasSizeChange: (CGSize) -> Void
        private var reportedCanvasSize = CGSize.zero

        init(
            strokes: Binding<[SignatureStroke]>,
            isTrackpadCaptureActive: Binding<Bool>,
            onCanvasSizeChange: @escaping (CGSize) -> Void
        ) {
            self.strokes = strokes
            self.isTrackpadCaptureActive = isTrackpadCaptureActive
            self.onCanvasSizeChange = onCanvasSizeChange
        }

        func update(
            strokes: Binding<[SignatureStroke]>,
            isTrackpadCaptureActive: Binding<Bool>,
            onCanvasSizeChange: @escaping (CGSize) -> Void
        ) {
            self.strokes = strokes
            self.isTrackpadCaptureActive = isTrackpadCaptureActive
            self.onCanvasSizeChange = onCanvasSizeChange
        }

        func setStrokes(_ newValue: [SignatureStroke]) {
            guard strokes.wrappedValue != newValue else { return }
            strokes.wrappedValue = newValue
        }

        func endTrackpadCapture() {
            guard isTrackpadCaptureActive.wrappedValue else { return }
            isTrackpadCaptureActive.wrappedValue = false
        }

        func setCanvasSize(_ newValue: CGSize) {
            guard
                newValue.width > 0,
                newValue.height > 0,
                newValue != reportedCanvasSize
            else { return }
            reportedCanvasSize = newValue

            // `layout()` can run while SwiftUI is updating this representable.
            // Deferring the binding-facing callback avoids a state mutation in
            // the middle of that update pass.
            DispatchQueue.main.async { [weak self] in
                self?.onCanvasSizeChange(newValue)
            }
        }
    }
}

// MARK: - AppKit input surface

final class SignatureCanvasNSView: NSView {
    var settings = SignatureSettings() {
        didSet { needsDisplay = true }
    }

    var onStrokesChange: (([SignatureStroke]) -> Void)?
    var onCanvasSizeChange: ((CGSize) -> Void)?
    var onTrackpadCaptureEnd: (() -> Void)?

    private(set) var strokes: [SignatureStroke] = []
    private(set) var isTrackpadCaptureActive = false

    private enum InputSource {
        case touch
        case mouse
    }

    private var inputSource: InputSource?
    private var activeStrokeIndex: Int?
    private var activeTouchIdentity: (any NSObjectProtocol & NSCopying)?
    private var lastCanvasPoint: CGPoint?
    private var lastPressure: CGFloat = 0.5
    private var lastReportedSize = CGSize.zero
    private var cursorIsDetached = false
    private var isRejectingMultitouchSequence = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureInput()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInput()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if cursorIsDetached {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        onCanvasSizeChange?(size)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, isTrackpadCaptureActive else { return }
        beginTrackpadCapture()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopTrackpadCapture(notifyOwner: false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func replaceStrokes(with newValue: [SignatureStroke]) {
        guard strokes != newValue else { return }

        // An event callback updates SwiftUI synchronously, so equal values are
        // normally fed back immediately. Avoid replacing an in-flight stroke
        // with an older external snapshot.
        guard activeStrokeIndex == nil else { return }
        strokes = newValue
        needsDisplay = true
    }

    func setTrackpadCaptureActive(_ isActive: Bool) {
        if isActive {
            guard !isTrackpadCaptureActive else { return }
            isTrackpadCaptureActive = true
            beginTrackpadCapture()
        } else {
            stopTrackpadCapture(notifyOwner: false)
        }
    }

    func prepareForRemoval() {
        onStrokesChange = nil
        onCanvasSizeChange = nil
        onTrackpadCaptureEnd = nil
        stopTrackpadCapture(notifyOwner: false)
        // Signature input is sensitive. Drop both completed strokes and every
        // in-progress reference as soon as AppKit removes the canvas. Swift
        // does not guarantee byte-level zeroization, but this prevents the
        // view hierarchy from extending the plaintext vector's lifetime.
        strokes.removeAll(keepingCapacity: false)
        inputSource = nil
        activeStrokeIndex = nil
        activeTouchIdentity = nil
        lastCanvasPoint = nil
        lastPressure = 0.5
        isRejectingMultitouchSequence = false
        needsDisplay = true
    }

    // MARK: Trackpad touches

    override func touchesBegan(with event: NSEvent) {
        guard isTrackpadCaptureActive else {
            super.touchesBegan(with: event)
            return
        }
        let touches = indirectTouches(in: event, phase: .touching)
        guard touches.count == 1, !isRejectingMultitouchSequence else {
            rejectCurrentMultitouchSequence()
            return
        }
        guard inputSource == nil, let touch = touches.first else { return }

        inputSource = .touch
        activeTouchIdentity = touch.identity
        let devicePoint = touch.normalizedPosition
        let canvasPoint = canvasPoint(forNormalizedPoint: devicePoint)
        lastCanvasPoint = canvasPoint
        // Indirect touch events use a stable fallback pressure so merely
        // touching and moving a finger is enough to draw.
        lastPressure = max(settings.minimumPressure, 0.5)
        beginStroke(at: canvasPoint, pressure: lastPressure, timestamp: event.timestamp)
    }

    override func touchesMoved(with event: NSEvent) {
        guard !isRejectingMultitouchSequence else { return }
        guard isTrackpadCaptureActive, inputSource == .touch else {
            super.touchesMoved(with: event)
            return
        }
        guard let touch = activeTouch(in: event, phase: .moved) ?? activeTouch(in: event, phase: .touching) else {
            return
        }

        let devicePoint = touch.normalizedPosition
        let canvasPoint = canvasPoint(forNormalizedPoint: devicePoint)
        lastCanvasPoint = canvasPoint
        lastPressure = max(settings.minimumPressure, lastPressure)
        appendPoint(canvasPoint, pressure: lastPressure, timestamp: event.timestamp)
    }

    override func touchesEnded(with event: NSEvent) {
        if isRejectingMultitouchSequence {
            if indirectTouches(in: event, phase: .touching).isEmpty {
                isRejectingMultitouchSequence = false
            }
            return
        }
        guard isTrackpadCaptureActive, inputSource == .touch else {
            super.touchesEnded(with: event)
            return
        }
        guard activeTouch(in: event, phase: .ended) != nil else { return }
        finishStroke(timestamp: event.timestamp)
    }

    override func touchesCancelled(with event: NSEvent) {
        if isRejectingMultitouchSequence {
            isRejectingMultitouchSequence = false
            return
        }
        guard isTrackpadCaptureActive, inputSource == .touch else {
            super.touchesCancelled(with: event)
            return
        }
        finishStroke(timestamp: event.timestamp)
    }

    // MARK: Mouse / pen fallback

    override func mouseDown(with event: NSEvent) {
        if isTrackpadCaptureActive {
            stopTrackpadCapture(notifyOwner: true, timestamp: event.timestamp)
            return
        }
        guard inputSource == nil else { return }
        window?.makeFirstResponder(self)
        inputSource = .mouse

        let devicePoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = clampedToCanvas(devicePoint)
        lastCanvasPoint = canvasPoint
        lastPressure = rawPressure(from: event, fallback: 0.5)
        beginStroke(at: canvasPoint, pressure: lastPressure, timestamp: event.timestamp)
    }

    override func mouseDragged(with event: NSEvent) {
        guard inputSource == .mouse else { return }
        let devicePoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = clampedToCanvas(devicePoint)
        lastCanvasPoint = canvasPoint
        lastPressure = rawPressure(from: event, fallback: lastPressure)
        appendPoint(canvasPoint, pressure: lastPressure, timestamp: event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        guard inputSource == .mouse else { return }
        let devicePoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = clampedToCanvas(devicePoint)
        lastCanvasPoint = canvasPoint
        lastPressure = rawPressure(from: event, fallback: lastPressure)
        appendPoint(canvasPoint, pressure: lastPressure, timestamp: event.timestamp, force: true)
        finishStroke(timestamp: event.timestamp)
    }

    override func pressureChange(with event: NSEvent) {
        // Indirect trackpad touches intentionally use a fixed fallback
        // pressure. A light touch is sufficient; Force Touch is never a
        // prerequisite for starting or continuing a signature stroke.
        guard inputSource == .mouse else { return }
        let pressure = rawPressure(from: event, fallback: lastPressure)
        guard abs(pressure - lastPressure) > 0.005 else { return }
        lastPressure = pressure
        updateLastPointPressure(pressure, timestamp: event.timestamp)
    }

    override func keyDown(with event: NSEvent) {
        guard isTrackpadCaptureActive else {
            super.keyDown(with: event)
            return
        }
        stopTrackpadCapture(notifyOwner: true, timestamp: event.timestamp)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 9, yRadius: 9)
        NSColor.separatorColor.withAlphaComponent(0.72).setStroke()
        outline.lineWidth = 1.5
        outline.stroke()

        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.shouldAntialias = true
        settings.color.setStroke()
        settings.color.setFill()

        for stroke in strokes where !stroke.points.isEmpty {
            draw(stroke: stroke)
        }
        context.restoreGraphicsState()
    }

    private func draw(stroke: SignatureStroke) {
        let points = SignatureStrokePipeline.displayPoints(
            stroke.points,
            settings: settings,
            canvasSize: bounds.size
        )
        guard let first = points.first else { return }

        if points.count == 1 {
            let diameter = SignatureStrokePipeline.width(
                pressure: first.pressure,
                velocity: 0,
                settings: settings
            )
            let dot = CGRect(
                x: first.x - diameter / 2,
                y: first.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            NSBezierPath(ovalIn: dot).fill()
            return
        }

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let deltaTime = max(1.0 / 240.0, current.timestamp - previous.timestamp)
            let velocity = hypot(current.x - previous.x, current.y - previous.y) / deltaTime
            let lineWidth = SignatureStrokePipeline.width(
                pressure: (previous.pressure + current.pressure) / 2,
                velocity: velocity,
                settings: settings
            )

            let path = NSBezierPath()
            path.move(to: previous.cgPoint)
            path.line(to: current.cgPoint)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    // MARK: Stroke storage

    private func beginStroke(at point: CGPoint, pressure: CGFloat, timestamp: TimeInterval) {
        let point = SignaturePoint(
            x: point.x,
            y: point.y,
            pressure: pressure,
            timestamp: timestamp
        )
        strokes.append(SignatureStroke(points: [point]))
        activeStrokeIndex = strokes.indices.last
        emitChange()
    }

    private func appendPoint(
        _ point: CGPoint,
        pressure: CGFloat,
        timestamp: TimeInterval,
        force: Bool = false
    ) {
        guard
            let index = activeStrokeIndex,
            strokes.indices.contains(index),
            let previous = strokes[index].points.last
        else { return }

        let distance = hypot(point.x - previous.x, point.y - previous.y)
        let elapsed = timestamp - previous.timestamp
        guard force || distance >= 0.35 || elapsed >= 0.025 else {
            if abs(previous.pressure - pressure) > 0.01 {
                updateLastPointPressure(pressure, timestamp: timestamp)
            }
            return
        }

        strokes[index].points.append(
            SignaturePoint(x: point.x, y: point.y, pressure: pressure, timestamp: timestamp)
        )
        emitChange()
    }

    private func updateLastPointPressure(_ pressure: CGFloat, timestamp: TimeInterval) {
        guard
            let index = activeStrokeIndex,
            strokes.indices.contains(index),
            !strokes[index].points.isEmpty
        else { return }

        let pointIndex = strokes[index].points.index(before: strokes[index].points.endIndex)
        strokes[index].points[pointIndex].pressure = pressure
        strokes[index].points[pointIndex].timestamp = max(
            strokes[index].points[pointIndex].timestamp,
            timestamp
        )
        emitChange()
    }

    private func finishStroke(timestamp: TimeInterval) {
        if
            let point = lastCanvasPoint,
            let index = activeStrokeIndex,
            strokes.indices.contains(index),
            let previous = strokes[index].points.last,
            hypot(point.x - previous.x, point.y - previous.y) > 0.1
        {
            strokes[index].points.append(
                SignaturePoint(x: point.x, y: point.y, pressure: lastPressure, timestamp: timestamp)
            )
            emitChange()
        }

        inputSource = nil
        activeStrokeIndex = nil
        activeTouchIdentity = nil
        lastCanvasPoint = nil
        lastPressure = 0.5
    }

    private func emitChange() {
        needsDisplay = true
        onStrokesChange?(strokes)
    }

    // MARK: Input conversion

    private func configureInput() {
        wantsLayer = true
        allowedTouchTypes = [.indirect]
        // A gently placed signing finger can initially be classified as a
        // resting touch. Include it so contact, rather than pressure, starts
        // the stroke. Only one identity is tracked at a time below.
        wantsRestingTouches = true
    }

    private func indirectTouches(in event: NSEvent, phase: NSTouch.Phase) -> [NSTouch] {
        event.touches(matching: phase, in: self).filter {
            $0.type == .indirect
        }
    }

    private func activeTouch(in event: NSEvent, phase: NSTouch.Phase) -> NSTouch? {
        guard let activeTouchIdentity else { return nil }
        return event.touches(matching: phase, in: self).first {
            $0.type == .indirect && activeTouchIdentity.isEqual($0.identity)
        }
    }

    private func rejectCurrentMultitouchSequence() {
        isRejectingMultitouchSequence = true
        guard
            inputSource == .touch,
            let index = activeStrokeIndex,
            strokes.indices.contains(index)
        else {
            finishStroke(timestamp: ProcessInfo.processInfo.systemUptime)
            return
        }

        strokes.remove(at: index)
        finishStroke(timestamp: ProcessInfo.processInfo.systemUptime)
        emitChange()
    }

    // MARK: Trackpad capture lifecycle

    private func beginTrackpadCapture() {
        guard isTrackpadCaptureActive, window != nil else { return }
        window?.makeFirstResponder(self)

        // Retry on every activation. macOS can reconnect the cursor when the
        // app deactivates, even if a previous cleanup attempt reported an
        // error.
        cursorIsDetached = CGAssociateMouseAndMouseCursorPosition(0) == .success

        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captureContextDidDeactivate(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(captureContextDidDeactivate(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
    }

    private func stopTrackpadCapture(
        notifyOwner: Bool,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let wasActive = isTrackpadCaptureActive
        let shouldRestoreCursor = cursorIsDetached || (wasActive && window != nil)

        if inputSource == .touch {
            let strokeIndex = activeStrokeIndex
            finishStroke(timestamp: timestamp)
            removeStrokeIfItIsOnlyAnExitTap(at: strokeIndex)
        }

        isTrackpadCaptureActive = false
        isRejectingMultitouchSequence = false
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)

        if shouldRestoreCursor {
            let cursorReconnectFailed = CGAssociateMouseAndMouseCursorPosition(1) != .success
            cursorIsDetached = cursorReconnectFailed
        }

        if notifyOwner, wasActive {
            onTrackpadCaptureEnd?()
        }
    }

    private func removeStrokeIfItIsOnlyAnExitTap(at index: Int?) {
        guard
            let index,
            strokes.indices.contains(index),
            let first = strokes[index].points.first
        else { return }

        let hasMovement = strokes[index].points.dropFirst().contains {
            hypot($0.x - first.x, $0.y - first.y) > 0.5
        }
        guard !hasMovement else { return }
        strokes.remove(at: index)
        emitChange()
    }

    @objc private func captureContextDidDeactivate(_ notification: Notification) {
        stopTrackpadCapture(notifyOwner: true)
    }

    private func canvasPoint(forNormalizedPoint point: CGPoint) -> CGPoint {
        let drawingBounds = bounds.insetBy(dx: 7, dy: 7)
        return CGPoint(
            x: drawingBounds.minX + point.x * drawingBounds.width,
            y: drawingBounds.minY + point.y * drawingBounds.height
        )
    }

    private func clampedToCanvas(_ point: CGPoint) -> CGPoint {
        let drawingBounds = bounds.insetBy(dx: 7, dy: 7)
        return CGPoint(
            x: SignatureStrokePipeline.clamp(point.x, drawingBounds.minX, drawingBounds.maxX),
            y: SignatureStrokePipeline.clamp(point.y, drawingBounds.minY, drawingBounds.maxY)
        )
    }

    private func rawPressure(from event: NSEvent, fallback: CGFloat) -> CGFloat {
        guard Self.eventMayContainPressure(event) else {
            return SignatureStrokePipeline.clamp(fallback, 0, 1)
        }
        let reported = CGFloat(event.pressure)
        guard reported.isFinite, reported > 0.001 else {
            return SignatureStrokePipeline.clamp(fallback, 0, 1)
        }
        return SignatureStrokePipeline.clamp(reported, 0, 1)
    }

    private static func eventMayContainPressure(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp,
             .tabletPoint, .pressure:
            return true
        default:
            return false
        }
    }
}

// MARK: - Shared preview/export processing

/// Keeps the on-canvas preview and the signature committed to PDF visually
/// consistent. The PDF layer already applies pressure sensitivity and the
/// configured min/max widths, so finalization bakes in smoothing and velocity
/// attenuation while preserving that renderer's pressure response.
enum SignatureStrokePipeline {
    static func finalizedStrokes(
        _ strokes: [SignatureStroke],
        settings: SignatureSettings,
        canvasSize: CGSize
    ) -> [SignatureStroke] {
        strokes.compactMap { stroke in
            let smoothed = displayPoints(
                stroke.points,
                settings: settings,
                canvasSize: canvasSize
            )
            guard !smoothed.isEmpty else { return nil }

            var result: [SignaturePoint] = []
            result.reserveCapacity(smoothed.count)
            for (index, point) in smoothed.enumerated() {
                let velocity: CGFloat
                if index == 0 {
                    velocity = 0
                } else {
                    let previous = smoothed[index - 1]
                    let elapsed = max(1.0 / 240.0, point.timestamp - previous.timestamp)
                    velocity = hypot(point.x - previous.x, point.y - previous.y) / elapsed
                }

                var finalized = point
                finalized.pressure = finalizedPressure(
                    rawPressure: point.pressure,
                    velocity: velocity,
                    settings: settings
                )
                result.append(finalized)
            }
            return SignatureStroke(id: stroke.id, points: result)
        }
    }

    static func displayPoints(
        _ points: [SignaturePoint],
        settings: SignatureSettings,
        canvasSize: CGSize
    ) -> [SignaturePoint] {
        let adjusted = movementAdjustedPoints(
            points,
            sensitivity: settings.movementSensitivity,
            canvasSize: canvasSize
        )
        return smoothedPoints(adjusted, smoothing: settings.smoothing)
    }

    private static func movementAdjustedPoints(
        _ points: [SignaturePoint],
        sensitivity: CGFloat,
        canvasSize: CGSize
    ) -> [SignaturePoint] {
        guard let anchor = points.first else { return [] }
        let scale = clamp(sensitivity, 0.1, 4)
        let minimumX: CGFloat = 7
        let minimumY: CGFloat = 7
        let maximumX = max(minimumX, canvasSize.width - 7)
        let maximumY = max(minimumY, canvasSize.height - 7)

        return points.map { point in
            var adjusted = point
            adjusted.x = clamp(
                anchor.x + (point.x - anchor.x) * scale,
                minimumX,
                maximumX
            )
            adjusted.y = clamp(
                anchor.y + (point.y - anchor.y) * scale,
                minimumY,
                maximumY
            )
            return adjusted
        }
    }

    static func smoothedPoints(
        _ points: [SignaturePoint],
        smoothing: CGFloat
    ) -> [SignaturePoint] {
        guard points.count > 2 else { return points }
        let amount = clamp(smoothing, 0, 0.98)
        guard amount > 0.001 else { return points }

        var filtered = points
        let passes = 1 + Int((amount * 2).rounded(.down))
        let neighborWeight = amount * 0.32

        for _ in 0..<passes {
            var next = filtered
            for index in 1..<(filtered.count - 1) {
                let previous = filtered[index - 1]
                let current = filtered[index]
                let following = filtered[index + 1]
                next[index].x = current.x * (1 - neighborWeight * 2)
                    + (previous.x + following.x) * neighborWeight
                next[index].y = current.y * (1 - neighborWeight * 2)
                    + (previous.y + following.y) * neighborWeight
            }
            filtered = next
        }

        // Catmull-Rom interpolation removes visible corners between filtered
        // event samples. Blend with the linear segment so the slider genuinely
        // ranges from raw input to a fully rounded signature.
        var interpolated = [filtered[0]]
        for index in 0..<(filtered.count - 1) {
            let p0 = filtered[max(0, index - 1)]
            let p1 = filtered[index]
            let p2 = filtered[index + 1]
            let p3 = filtered[min(filtered.count - 1, index + 2)]
            let distance = hypot(p2.x - p1.x, p2.y - p1.y)
            let steps = max(1, min(5, Int(ceil(distance / 5))))

            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let linearX = p1.x + (p2.x - p1.x) * t
                let linearY = p1.y + (p2.y - p1.y) * t
                let curveX = catmullRom(p0.x, p1.x, p2.x, p3.x, t: t)
                let curveY = catmullRom(p0.y, p1.y, p2.y, p3.y, t: t)
                let pressure = p1.pressure + (p2.pressure - p1.pressure) * t
                let timestamp = p1.timestamp + (p2.timestamp - p1.timestamp) * TimeInterval(t)
                interpolated.append(
                    SignaturePoint(
                        x: linearX + (curveX - linearX) * amount,
                        y: linearY + (curveY - linearY) * amount,
                        pressure: pressure,
                        timestamp: timestamp
                    )
                )
            }
        }
        return interpolated
    }

    static func width(
        pressure: CGFloat,
        velocity: CGFloat,
        settings: SignatureSettings
    ) -> CGFloat {
        let minimumWidth = max(0.1, min(settings.minimumWidth, settings.maximumWidth))
        let maximumWidth = max(minimumWidth, max(settings.minimumWidth, settings.maximumWidth))
        let sensitivity = max(0.05, settings.pressureSensitivity)
        let effectivePressure = finalizedPressure(
            rawPressure: pressure,
            velocity: velocity,
            settings: settings
        )
        let response = pow(effectivePressure, sensitivity)
        return minimumWidth + (maximumWidth - minimumWidth) * response
    }

    private static func finalizedPressure(
        rawPressure: CGFloat,
        velocity: CGFloat,
        settings: SignatureSettings
    ) -> CGFloat {
        let floor = clamp(settings.minimumPressure, 0, 1)
        let basePressure = max(floor, clamp(rawPressure, 0, 1))
        let influence = clamp(settings.velocityInfluence, 0, 1)
        let normalizedVelocity = clamp(velocity / 1_400, 0, 1)
        let attenuation = max(0.08, 1 - influence * normalizedVelocity)
        let sensitivity = max(0.05, settings.pressureSensitivity)

        // The downstream PDF renderer raises pressure to `sensitivity`.
        // Taking its inverse here makes velocity attenuation match the preview.
        return clamp(basePressure * pow(attenuation, 1 / sensitivity), 0, 1)
    }

    private static func catmullRom(
        _ p0: CGFloat,
        _ p1: CGFloat,
        _ p2: CGFloat,
        _ p3: CGFloat,
        t: CGFloat
    ) -> CGFloat {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            2 * p1
                + (-p0 + p2) * t
                + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                + (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
