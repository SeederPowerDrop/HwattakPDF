// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Configuration and progress surface for Apple Vision OCR.
///
/// The sheet owns only draft options. `PDFWorkspaceState` owns the running
/// task, cancellation, checkpoint and export state so closing this sheet does
/// not accidentally cancel a long document. Completed results can become an
/// undoable edit of the current document or a separately saved searchable copy.
struct OCRSheet: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let onExport: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var configuration = OCRConfiguration()
    @State private var pageScope: OCRPageScope = .all
    @State private var pageInput = ""
    @State private var languages: [OCRRecognitionLanguage] = []
    @State private var languageQuery = ""
    @State private var languageLoadError: String?
    @State private var hasLoadedLanguages = false
    @State private var confirmsApply = false
    @State private var completionMessage: String?
    @State private var hasAppliedResult = false

    private var theme: HwattakPDFTheme {
        HwattakPDFTheme(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            documentSummary

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    progressCard
                    pageSelectionCard
                        .disabled(controlsAreBusy)
                    languageCard
                        .disabled(controlsAreBusy)
                    qualityCard
                        .disabled(controlsAreBusy)
                    privacyCard
                }
                .padding(22)
            }

            actionBar
        }
        .frame(minWidth: 650, idealWidth: 700, maxWidth: 760, minHeight: 650, idealHeight: 700)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .interactiveDismissDisabled(workspace.isWritingOCRResult)
        .onAppear {
            configuration = workspace.ocrConfiguration
            restorePageSelection()
            loadLanguages()
        }
        .onChange(of: configuration) { _, _ in
            clearCompletionMessage()
        }
        .onChange(of: pageScope) { _, _ in clearCompletionMessage() }
        .onChange(of: pageInput) { _, _ in clearCompletionMessage() }
        .onChange(of: workspace.currentPageIndex) { _, _ in
            if pageScope == .current && !controlsAreBusy { clearCompletionMessage() }
        }
        .confirmationDialog(
            L10n.string("ocr.apply.confirm.title"),
            isPresented: $confirmsApply,
            titleVisibility: .visible
        ) {
            Button(L10n.string("ocr.result.apply")) {
                Task { @MainActor in
                    if await workspace.applySearchableOCRToCurrentDocument() {
                        hasAppliedResult = true
                        completionMessage = workspace.statusMessage
                    }
                }
            }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("ocr.apply.confirm.message"))
        }
    }

    private var controlsAreBusy: Bool {
        workspace.ocrState.isActivelyProcessing || workspace.isWritingOCRResult
    }

    private var canUseDisplayedResult: Bool {
        workspace.canUseCompletedOCRResult && draftConfiguration == workspace.ocrConfiguration
    }

    private var pageSelection: Result<[Int]?, Error> {
        Result {
            try OCRPageSelection.resolve(
                scope: pageScope,
                input: pageInput,
                currentPageIndex: workspace.currentPageIndex,
                pageCount: workspace.pageCount
            )
        }
    }

    private var draftConfiguration: OCRConfiguration? {
        guard case let .success(pageIndexes) = pageSelection else { return nil }
        var draft = configuration
        draft.pageIndexes = pageIndexes
        return draft
    }

    private var selectedPageSummary: String? {
        if controlsAreBusy {
            return pageSummary(workspace.ocrConfiguration.pageIndexes)
        }
        guard case let .success(pageIndexes) = pageSelection else { return nil }
        return pageSummary(pageIndexes)
    }

    private func pageSummary(_ pageIndexes: [Int]?) -> String {
        guard let pageIndexes else {
            return L10n.format("ocr.pages.all_summary", workspace.pageCount)
        }
        return L10n.format(
            "ocr.pages.selected",
            OCRPageSelection.compactDescription(pageIndexes),
            pageIndexes.count
        )
    }

    private var documentSummary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(theme.accent)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(L10n.string("ocr.document.title"))
                    Spacer()
                    Text(L10n.format("ocr.document.pages", workspace.pageCount))
                    Text("·")
                    Text(L10n.format("ocr.document.current_page", workspace.currentPageIndex + 1))
                }
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                Text(workspace.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(workspace.documentURL?.deletingLastPathComponent().path
                     ?? L10n.string("ocr.document.unsaved"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(workspace.documentURL?.path ?? workspace.displayName)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(theme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 42, height: 42)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("로컬 OCR"))
                    .font(.title2.weight(.semibold))
                Text(L10n.string("스캔 문서를 검색하고 선택할 수 있는 PDF로 변환"))
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()
            Label(L10n.string("Apple Vision · 오프라인"), systemImage: "lock.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.success)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(theme.success.opacity(0.11), in: Capsule())
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(theme.success)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("ocr.privacy.title"))
                        .font(.callout.weight(.semibold))
                    Text(L10n.string("ocr.privacy.summary"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DisclosureGroup {
                Text(L10n.string("ocr.privacy.storage_detail"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                Text(L10n.string("ocr.privacy.storage_title"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }

            Divider()
            Label(
                L10n.string("ocr.export.note"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(theme.warning)
            .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup {
                Text(L10n.string("ocr.export.detail"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                Text(L10n.string("ocr.export.detail_title"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(16)
        .hwattakPDFCard(theme)
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("인식 언어", caption: "ocr.languages.help")
            if let languageLoadError {
                Text(L10n.string("ocr.languages.failed"))
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .help(languageLoadError)
                Button(L10n.string("action.retry"), action: loadLanguages)
            } else if !hasLoadedLanguages {
                ProgressView(L10n.string("ocr.languages.loading"))
            } else {
                HStack {
                    TextField(L10n.string("ocr.languages.search"), text: $languageQuery)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.string("ocr.languages.search"))
                    Text(L10n.format("ocr.languages.selected", configuration.languages.count))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize()
                }
                let matchingLanguages = languages.filter { $0.matches(query: languageQuery) }
                let visibleLanguages = matchingLanguages.filter { configuration.languages.contains($0.id) }
                    + matchingLanguages.filter { !configuration.languages.contains($0.id) }
                if visibleLanguages.isEmpty {
                    Text(L10n.string("ocr.languages.empty"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 8)], spacing: 8) {
                            ForEach(visibleLanguages) { language in
                                languageButton(language)
                            }
                        }
                        .padding(2)
                    }
                    .frame(height: min(190, CGFloat((visibleLanguages.count + 2) / 3) * 62))
                }
                if configuration.languages.isEmpty {
                    Text(L10n.string("ocr.languages.required"))
                        .font(.caption)
                        .foregroundStyle(theme.warning)
                }
            }
        }
        .padding(16)
        .hwattakPDFCard(theme)
    }

    private var pageSelectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("ocr.pages.title", caption: "ocr.pages.help")
            Picker(L10n.string("ocr.pages.title"), selection: $pageScope) {
                Text(L10n.string("ocr.pages.all")).tag(OCRPageScope.all)
                Text(L10n.string("ocr.pages.current")).tag(OCRPageScope.current)
                Text(L10n.string("ocr.pages.custom")).tag(OCRPageScope.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(L10n.string("ocr.pages.title"))

            if pageScope == .custom {
                TextField(L10n.string("ocr.pages.input"), text: $pageInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.string("ocr.pages.custom"))
                    .accessibilityHint(L10n.string("ocr.pages.input"))
            }

            if case let .failure(error) = pageSelection {
                Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let selectedPageSummary {
                Text(selectedPageSummary)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .hwattakPDFCard(theme)
    }

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("품질과 처리 방식", caption: "속도와 인식 정확도를 조절합니다")

            VStack(spacing: 10) {
                settingToggle(
                    "텍스트가 있는 페이지 건너뛰기",
                    caption: "ocr.skip_existing.help",
                    isOn: $configuration.skipPagesWithText
                )
                Divider()
                settingToggle(
                    "언어 교정 사용",
                    caption: "문맥을 이용해 인식된 단어의 정확도를 높입니다.",
                    isOn: $configuration.useLanguageCorrection
                )
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.string("렌더링 해상도"))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(Int(configuration.renderDPI)) DPI")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(theme.dropHighlight, in: Capsule())
                }
                Slider(value: $configuration.renderDPI, in: 150...320, step: 10)
                    .accessibilityLabel(L10n.string("렌더링 해상도"))
                    .accessibilityValue("\(Int(configuration.renderDPI)) DPI")
                    .accessibilityHint(L10n.string("값이 높을수록 인식은 정밀하지만 처리 시간이 늘어납니다."))
                HStack {
                    Text(L10n.string("빠르게"))
                    Spacer()
                    Text(L10n.string("정밀하게"))
                }
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(16)
        .hwattakPDFCard(theme)
    }

    private var progressCard: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(theme.dropHighlight)
                Image(systemName: progressIcon)
                    .foregroundStyle(theme.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text(progressTitle)
                    .font(.callout.weight(.semibold))
                if workspace.isWritingOCRResult {
                    ProgressView().controlSize(.small)
                } else if let fraction = workspace.ocrState.fraction {
                    ProgressView(value: fraction)
                        .tint(theme.accent)
                }
                Text(progressMessage)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let selectedPageSummary {
                    Text(selectedPageSummary)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if canUseDisplayedResult {
                    Text(L10n.string("ocr.result.apply_detail"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    Text(L10n.string("ocr.export.note"))
                        .font(.caption)
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(14)
        .hwattakPDFCard(theme)
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Button(L10n.string("닫기")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(workspace.isWritingOCRResult)
            Spacer()

            if workspace.isWritingOCRResult {
                ProgressView().controlSize(.small)
                Text(writingProgressMessage)
                    .font(.caption)
            } else if case .running = workspace.ocrState {
                Button(L10n.string("중단")) { workspace.cancelOCR() }
            } else if case .cancelling = workspace.ocrState {
                Button(L10n.string("중단 중…")) {}
                    .disabled(true)
            } else {
                if canUseDisplayedResult {
                    Button(L10n.string("ocr.result.apply")) { confirmsApply = true }
                    Button {
                        Task { @MainActor in
                            if await onExport() {
                                completionMessage = workspace.statusMessage
                            }
                        }
                    } label: {
                        Label(L10n.string("ocr.result.save_copy"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(action: startOCR) {
                        Label(L10n.string("OCR 시작 / 재개"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftConfiguration == nil || configuration.languages.isEmpty || !hasLoadedLanguages || languageLoadError != nil)
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 68)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var progressIcon: String {
        if completionMessage != nil || canUseDisplayedResult { return "checkmark.circle.fill" }
        switch workspace.ocrState {
        case .running, .cancelling:
            return "ellipsis"
        default:
            return "text.viewfinder"
        }
    }

    private var writingProgressMessage: String {
        L10n.string(workspace.isExportingOCR ? "ocr.progress.saving" : "ocr.progress.applying")
    }

    private var progressTitle: String {
        if workspace.isWritingOCRResult { return writingProgressMessage }
        if hasAppliedResult { return L10n.string("history.ocr_apply") }
        return workspace.ocrState.label
    }

    private var progressMessage: String {
        if workspace.isWritingOCRResult { return writingProgressMessage }
        if let completionMessage { return completionMessage }
        switch workspace.ocrState {
        case .running, .cancelling:
            return L10n.string("ocr.progress.running")
        case .finished:
            if draftConfiguration != workspace.ocrConfiguration {
                return L10n.string("ocr.settings.changed")
            }
            return L10n.string(canUseDisplayedResult ? "ocr.result.ready" : "error.ocr_result_changed")
        case .failed:
            return L10n.string("ocr.progress.failed")
        case .idle:
            return L10n.string("설정을 확인한 뒤 OCR을 시작하세요.")
        }
    }

    private func sectionTitle(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string(title)).font(.headline)
            Text(L10n.string(caption))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func languageButton(_ language: OCRRecognitionLanguage) -> some View {
        let isSelected = configuration.languages.contains(language.id)
        return Button {
            if isSelected {
                configuration.languages.removeAll { $0 == language.id }
            } else {
                configuration.languages.append(language.id)
            }
            completionMessage = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.localizedName)
                        .font(.callout.weight(.medium))
                    if language.nativeName != language.localizedName {
                        Text(language.nativeName)
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? theme.dropHighlight : theme.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? theme.accent.opacity(0.35) : theme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("\(language.localizedName) · \(language.nativeName) (\(language.id))")
        .accessibilityLabel(language.localizedName)
        .accessibilityValue(L10n.string(isSelected ? "toggle.on" : "toggle.off"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func settingToggle(
        _ title: String,
        caption: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(title)).font(.callout.weight(.medium))
                Text(L10n.string(caption))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(L10n.string(title))
                .accessibilityValue(
                    isOn.wrappedValue ? L10n.string("toggle.on") : L10n.string("toggle.off")
                )
                .accessibilityHint(L10n.string(caption))
        }
    }

    private func loadLanguages() {
        do {
            languages = try OCRRecognitionLanguage.supportedLanguages(quality: configuration.recognitionQuality)
            guard !languages.isEmpty else {
                languageLoadError = L10n.string("error.ocr_no_supported_language")
                return
            }
            configuration.languages = OCRRecognitionLanguage.initialSelection(
                preferred: configuration.languages,
                available: languages
            )
            languageLoadError = nil
            hasLoadedLanguages = true
        } catch {
            languageLoadError = error.localizedDescription
        }
    }

    private func startOCR() {
        guard let draftConfiguration else { return }
        configuration = draftConfiguration
        clearCompletionMessage()
        workspace.startOCR(configuration: draftConfiguration)
    }

    private func restorePageSelection() {
        guard let pageIndexes = configuration.pageIndexes else {
            pageScope = .all
            pageInput = ""
            return
        }
        pageInput = OCRPageSelection.compactDescription(pageIndexes)
        pageScope = pageIndexes == [workspace.currentPageIndex] ? .current : .custom
    }

    private func clearCompletionMessage() {
        completionMessage = nil
        hasAppliedResult = false
    }
}
