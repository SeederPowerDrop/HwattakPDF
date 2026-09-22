// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// 트랙패드/마우스에서 서명을 입력하고 PDF에 적용하는 보안 경계 UI다.
///
/// 캔버스의 획은 적용 전까지 이 sheet의 메모리에만 있으며, 닫힐 때
/// `clearSensitiveInput()`으로 지운다. 사용자가 PDF 적용을 확정한 뒤에만 vector
/// 획을 Keychain 기본 서명으로 저장한다. 저장 실패가 PDF 적용 자체를 되돌리지는
/// 않지만 별도 경고를 보여 두 작업의 성공 여부를 혼동하지 않게 한다.
struct SignatureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// 굵기·스무딩 같은 비밀이 아닌 사용자 설정은 부모와 Binding으로 공유한다.
    @Binding private var settings: SignatureSettings
    private let onCancel: (() -> Void)?
    private let signatureStore: any SecureSignatureStoring
    private let onStorageError: (String) -> Void
    private let onApply: ([SignatureStroke], CGSize) -> Bool

    /// 실제 서명 획은 장기 모델이 아니라 sheet 수명에 한정된 @State다.
    @State private var strokes: [SignatureStroke] = []
    @State private var canvasSize = CGSize.zero
    @State private var isTrackpadCaptureActive = false
    @State private var hasSavedSignature = false
    @State private var hasUnreadableSavedSignature = false
    @State private var didLoadSavedSignature = false
    @State private var savedCanvasSizeAwaitingLayout: CGSize?
    @State private var isReplacingSavedSignature = false
    @State private var isShowingDeleteConfirmation = false
    @State private var storageAlertMessage: String?
    @State private var isAwaitingLegacyCleanup = false
    @State private var didApplyToPDF = false

    private var theme: HwattakPDFTheme {
        HwattakPDFTheme(colorScheme: colorScheme)
    }

    init(
        settings: Binding<SignatureSettings>,
        signatureStore: any SecureSignatureStoring = KeychainSecureSignatureStore.shared,
        onCancel: (() -> Void)? = nil,
        onStorageError: @escaping (String) -> Void = { _ in },
        onApply: @escaping ([SignatureStroke], CGSize) -> Bool
    ) {
        _settings = settings
        self.signatureStore = signatureStore
        self.onCancel = onCancel
        self.onStorageError = onStorageError
        self.onApply = onApply
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                SignatureCaptureView(
                    strokes: $strokes,
                    isTrackpadCaptureActive: $isTrackpadCaptureActive,
                    settings: settings,
                    onCanvasSizeChange: updateCanvasSize
                )

                if isTrackpadCaptureActive {
                    trackpadCaptureStatus
                } else if strokes.isEmpty {
                    trackpadCaptureStartPrompt
                } else {
                    trackpadCaptureResumeControl
                }
            }
            .frame(minHeight: 255, idealHeight: 285)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }
            .shadow(color: theme.elevatedShadow.opacity(0.55), radius: 14, y: 6)
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("서명 입력 영역")

            settingsPanel
                .disabled(isTrackpadCaptureActive || didApplyToPDF)
            actionBar
                .disabled(isTrackpadCaptureActive || didApplyToPDF)
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 680)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .interactiveDismissDisabled(isTrackpadCaptureActive)
        .onDisappear(perform: clearSensitiveInput)
        .onAppear(perform: loadSavedSignatureIfNeeded)
        .confirmationDialog(
            L10n.string("signature.delete_confirmation.title"),
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("signature.delete_saved"), role: .destructive) {
                deleteSavedSignature()
            }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("signature.delete_confirmation.message"))
        }
        .alert(
            L10n.string("signature.storage_alert.title"),
            isPresented: Binding(
                get: { storageAlertMessage != nil },
                set: { if !$0 { storageAlertMessage = nil } }
            )
        ) {
            if hasUnreadableSavedSignature, !hasSavedSignature {
                Button(L10n.string("signature.delete_saved"), role: .destructive) {
                    deleteUnreadableSavedSignature()
                }
            }
            if isAwaitingLegacyCleanup {
                Button(L10n.string("action.retry")) {
                    retryLegacyCleanup()
                }
            }
            Button(L10n.string("action.confirm"), role: .cancel) {
                acknowledgeStorageAlert()
            }
        } message: {
            Text(storageAlertMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "signature")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 42, height: 42)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("트랙패드 서명")
                    .font(.title2.weight(.semibold))
                Text("한 손가락의 가벼운 움직임을 자연스러운 서명으로 변환합니다.")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            if hasSavedSignature {
                Label(
                    L10n.string(
                        isReplacingSavedSignature
                            ? "signature.replacement_badge"
                            : "signature.saved_badge"
                    ),
                    systemImage: isReplacingSavedSignature ? "arrow.triangle.2.circlepath" : "key.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.dropHighlight, in: Capsule())
                .help(L10n.string("signature.saved_security_help"))
            }
            Label(L10n.format("signature.stroke_count", strokes.count), systemImage: "scribble.variable")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.card, in: Capsule())
                .overlay { Capsule().stroke(theme.border, lineWidth: 1) }
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("입력 감도와 선 보정")
                        .font(.headline)
                    Text("변경한 값은 위 미리보기에 즉시 반영됩니다.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Label("실시간 미리보기", systemImage: "bolt.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.accent)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())],
                alignment: .leading,
                spacing: 10
            ) {
                SignatureSettingSlider(
                    title: "이동 감도",
                    value: $settings.movementSensitivity,
                    range: 0.25...3.0,
                    help: "손가락 이동량이 캔버스에서 확대되는 비율입니다."
                )
                SignatureSettingSlider(
                    title: "스무딩",
                    value: $settings.smoothing,
                    range: 0...0.95,
                    help: "손떨림과 꺾인 모서리를 부드럽게 보정합니다."
                )
                SignatureSettingSlider(
                    title: "굵기 반응",
                    value: $settings.pressureSensitivity,
                    range: 0.25...3.0,
                    help: "기본 터치와 지원되는 펜 입력이 선 굵기에 반영되는 곡선입니다."
                )
                SignatureSettingSlider(
                    title: "최소 입력 굵기",
                    value: $settings.minimumPressure,
                    range: 0...0.65,
                    help: "마우스나 펜의 압력이 약해도 선이 이 기준보다 가늘어지지 않게 합니다."
                )
                SignatureSettingSlider(
                    title: "최소 굵기",
                    value: minimumWidthBinding,
                    range: 0.2...6.0,
                    suffix: " pt",
                    help: "가장 가는 선의 굵기입니다."
                )
                SignatureSettingSlider(
                    title: "최대 굵기",
                    value: maximumWidthBinding,
                    range: 1.0...14.0,
                    suffix: " pt",
                    help: "가장 굵은 선의 굵기입니다."
                )
                SignatureSettingSlider(
                    title: "속도 영향",
                    value: $settings.velocityInfluence,
                    range: 0...1.0,
                    help: "빠르게 그은 획을 더 가늘게 표현하는 정도입니다."
                )

                HStack(spacing: 10) {
                    Text("선 색상")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    Spacer(minLength: 8)
                    ColorPicker(
                        "",
                        selection: colorBinding,
                        supportsOpacity: true
                    )
                    .labelsHidden()
                    .accessibilityLabel("서명 선 색상")
                    .accessibilityHint("서명에 사용할 색상과 불투명도를 선택합니다.")
                }
                .help("서명에 사용할 색상과 불투명도를 선택합니다.")
            }
        }
        .padding(16)
        .hwattakPDFCard(theme)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                guard !isTrackpadCaptureActive else { return }
                isTrackpadCaptureActive = false
                strokes.removeAll()
            } label: {
                Label("전체 지우기", systemImage: "trash")
            }
            .disabled(strokes.isEmpty)

            Button {
                guard !isTrackpadCaptureActive else { return }
                isTrackpadCaptureActive = false
                _ = strokes.popLast()
            } label: {
                Label("실행 취소", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(strokes.isEmpty)

            if hasSavedSignature || hasUnreadableSavedSignature {
                Menu {
                    if hasSavedSignature {
                        Button {
                            prepareSavedSignatureReplacement()
                        } label: {
                            Label(
                                L10n.string("signature.replace_saved"),
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        }

                        Divider()
                    }

                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Label(L10n.string("signature.delete_saved"), systemImage: "trash")
                    }
                } label: {
                    Label(L10n.string("signature.manage_saved"), systemImage: "key.fill")
                }
                .help(L10n.string("signature.saved_security_help"))
            }

            Spacer()

            Button("취소") {
                cancel()
            }
            .keyboardShortcut(.cancelAction)

            Button("PDF에 적용") {
                apply()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!hasUsableStroke || didApplyToPDF)
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private var hasUsableStroke: Bool {
        strokes.contains { stroke in
            guard let first = stroke.points.first else { return false }
            return stroke.points.dropFirst().contains {
                hypot($0.x - first.x, $0.y - first.y) > 0.5
            }
        }
    }

    private var trackpadCaptureStartPrompt: some View {
        VStack(spacing: 9) {
            Image(systemName: "hand.draw")
                .font(.system(size: 27, weight: .light))

            Text("트랙패드로 서명")
                .font(.headline)

            Button {
                isTrackpadCaptureActive = true
            } label: {
                Label("트랙패드 입력 시작", systemImage: "hand.tap")
            }
            .buttonStyle(.borderedProminent)

            Text("버튼을 클릭해 손가락을 한 번 뗀 뒤, 다시 가볍게 대고 움직이세요.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("마우스는 캔버스에서 바로 드래그할 수 있습니다.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var trackpadCaptureStatus: some View {
        VStack {
            HStack {
                Label("트랙패드 입력 중", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().stroke(theme.accent.opacity(0.28), lineWidth: 1) }
                Spacer()
            }

            Spacer()

            Text("가볍게 한 손가락으로 그리세요 · 입력을 끝내려면 트랙패드를 클릭하세요.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(14)
        .allowsHitTesting(false)
    }

    private var trackpadCaptureResumeControl: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    isTrackpadCaptureActive = true
                } label: {
                    Label("트랙패드 입력 계속", systemImage: "hand.tap")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(14)
    }

    private var minimumWidthBinding: Binding<CGFloat> {
        Binding(
            get: { settings.minimumWidth },
            set: { settings.minimumWidth = min($0, settings.maximumWidth) }
        )
    }

    private var maximumWidthBinding: Binding<CGFloat> {
        Binding(
            get: { settings.maximumWidth },
            set: { settings.maximumWidth = max($0, settings.minimumWidth) }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: settings.color) },
            set: { settings.color = NSColor($0) }
        )
    }

    private func cancel() {
        guard !isTrackpadCaptureActive else { return }
        isTrackpadCaptureActive = false
        onCancel?()
        dismiss()
    }

    private func apply() {
        guard !isTrackpadCaptureActive else { return }
        isTrackpadCaptureActive = false
        let size = canvasSize == .zero ? CGSize(width: 740, height: 300) : canvasSize
        let finalized = SignatureStrokePipeline.finalizedStrokes(
            strokes,
            settings: settings,
            canvasSize: size
        )
        let outcome = SecureSignatureApplicationWorkflow.applyAndPersist(
            rawStrokes: strokes,
            canvasSize: size,
            store: signatureStore,
            applyToPDF: { onApply(finalized, size) }
        )
        switch outcome {
        case .applicationFailed:
            return
        case .appliedAndSaved:
            didApplyToPDF = true
        case .appliedAndSavedButLegacyCleanupFailed:
            didApplyToPDF = true
            isAwaitingLegacyCleanup = true
            storageAlertMessage = L10n.string("signature.legacy_cleanup_failed")
            return
        case .appliedButStorageFailed:
            didApplyToPDF = true
            onStorageError(L10n.string("signature.save_failed"))
        }
        dismiss()
    }

    private func loadSavedSignatureIfNeeded() {
        guard !didLoadSavedSignature else { return }
        didLoadSavedSignature = true

        do {
            guard let savedSignature = try signatureStore.loadSignature() else { return }
            hasSavedSignature = true
            hasUnreadableSavedSignature = false
            install(savedSignature)
        } catch {
            hasUnreadableSavedSignature = Self.isUnreadableStorageError(error)
            storageAlertMessage = L10n.string("signature.load_failed")
        }
    }

    private func install(_ savedSignature: SavedSignature) {
        let sourceSize = savedSignature.canvasSize
        if canvasSize.width > 0, canvasSize.height > 0 {
            strokes = Self.scaledStrokes(
                savedSignature.strokes,
                from: sourceSize,
                to: canvasSize
            )
            savedCanvasSizeAwaitingLayout = nil
        } else {
            strokes = savedSignature.strokes
            savedCanvasSizeAwaitingLayout = sourceSize
        }
    }

    private func updateCanvasSize(_ newSize: CGSize) {
        guard
            newSize.width.isFinite,
            newSize.height.isFinite,
            Double(newSize.width) >= SavedSignature.minimumCanvasDimension,
            Double(newSize.height) >= SavedSignature.minimumCanvasDimension,
            Double(newSize.width) <= SavedSignature.maximumCanvasDimension,
            Double(newSize.height) <= SavedSignature.maximumCanvasDimension
        else { return }
        if let sourceSize = savedCanvasSizeAwaitingLayout {
            strokes = Self.scaledStrokes(strokes, from: sourceSize, to: newSize)
            savedCanvasSizeAwaitingLayout = nil
        }
        canvasSize = newSize
    }

    private func prepareSavedSignatureReplacement() {
        guard !isTrackpadCaptureActive else { return }
        strokes.removeAll()
        savedCanvasSizeAwaitingLayout = nil
        isReplacingSavedSignature = true
    }

    private func deleteSavedSignature() {
        guard !isTrackpadCaptureActive else { return }
        do {
            try signatureStore.deleteSignature()
            hasSavedSignature = false
            hasUnreadableSavedSignature = false
            isReplacingSavedSignature = false
            isAwaitingLegacyCleanup = false
            savedCanvasSizeAwaitingLayout = nil
            strokes.removeAll(keepingCapacity: false)
            storageAlertMessage = nil
        } catch {
            storageAlertMessage = L10n.string("signature.delete_failed")
        }
    }

    private func deleteUnreadableSavedSignature() {
        storageAlertMessage = nil
        // Let SwiftUI finish dismissing the current alert before presenting a
        // possible delete error from the same state binding.
        DispatchQueue.main.async {
            deleteSavedSignature()
        }
    }

    private func retryLegacyCleanup() {
        storageAlertMessage = nil
        DispatchQueue.main.async {
            do {
                try signatureStore.retryLegacyCleanup()
                isAwaitingLegacyCleanup = false
                dismiss()
            } catch {
                isAwaitingLegacyCleanup = true
                storageAlertMessage = L10n.string("signature.legacy_cleanup_failed")
            }
        }
    }

    private func acknowledgeStorageAlert() {
        storageAlertMessage = nil
        guard isAwaitingLegacyCleanup else { return }
        isAwaitingLegacyCleanup = false
        dismiss()
    }

    private func clearSensitiveInput() {
        isTrackpadCaptureActive = false
        strokes.removeAll(keepingCapacity: false)
        savedCanvasSizeAwaitingLayout = nil
        canvasSize = .zero
    }

    static func isUnreadableStorageError(_ error: Error) -> Bool {
        guard let error = error as? SecureSignatureStoreError else { return false }
        switch error {
        case .invalidPayload, .unsupportedVersion, .payloadTooLarge:
            return true
        case .keychain, .legacyCleanupFailed:
            return false
        }
    }

    static func scaledStrokes(
        _ strokes: [SignatureStroke],
        from sourceSize: CGSize,
        to destinationSize: CGSize
    ) -> [SignatureStroke] {
        guard
            sourceSize.width.isFinite,
            sourceSize.height.isFinite,
            destinationSize.width.isFinite,
            destinationSize.height.isFinite,
            Double(sourceSize.width) >= SavedSignature.minimumCanvasDimension,
            Double(sourceSize.height) >= SavedSignature.minimumCanvasDimension,
            Double(destinationSize.width) >= SavedSignature.minimumCanvasDimension,
            Double(destinationSize.height) >= SavedSignature.minimumCanvasDimension,
            Double(sourceSize.width) <= SavedSignature.maximumCanvasDimension,
            Double(sourceSize.height) <= SavedSignature.maximumCanvasDimension,
            Double(destinationSize.width) <= SavedSignature.maximumCanvasDimension,
            Double(destinationSize.height) <= SavedSignature.maximumCanvasDimension
        else { return [] }

        let scaleX = destinationSize.width / sourceSize.width
        let scaleY = destinationSize.height / sourceSize.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
            return []
        }

        var scaledStrokes: [SignatureStroke] = []
        scaledStrokes.reserveCapacity(strokes.count)
        for stroke in strokes {
            var scaledPoints: [SignaturePoint] = []
            scaledPoints.reserveCapacity(stroke.points.count)
            for point in stroke.points {
                guard
                    point.x.isFinite,
                    point.y.isFinite,
                    point.pressure.isFinite,
                    point.timestamp.isFinite,
                    point.x >= 0,
                    point.y >= 0,
                    point.x <= sourceSize.width,
                    point.y <= sourceSize.height
                else { return [] }
                var scaled = point
                scaled.x *= scaleX
                scaled.y *= scaleY
                guard scaled.x.isFinite, scaled.y.isFinite else { return [] }
                scaledPoints.append(scaled)
            }
            scaledStrokes.append(SignatureStroke(id: stroke.id, points: scaledPoints))
        }
        return scaledStrokes
    }
}

private struct SignatureSettingSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var suffix = ""
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.string(title))
                    .font(.caption.weight(.medium))
                Spacer()
                Text(String(format: "%.2f%@", Double(value), suffix))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: doubleBinding, in: Double(range.lowerBound)...Double(range.upperBound))
                .accessibilityLabel(L10n.string(title))
                .accessibilityValue(String(format: "%.2f%@", Double(value), suffix))
                .accessibilityHint(L10n.string(help))
        }
        .help(L10n.string(help))
    }

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(value) },
            set: { value = CGFloat($0) }
        )
    }
}
