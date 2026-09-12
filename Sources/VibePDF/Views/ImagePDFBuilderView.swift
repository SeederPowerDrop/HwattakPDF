// SPDX-License-Identifier: MPL-2.0

import SwiftUI

enum ImagePDFBuilderContent {
    static let sceneID = "image-pdf-builder"
}

struct ImagePDFBuilderView: View {
    @StateObject private var model = ImagePDFAssemblyModel()
    @Environment(\.colorScheme) private var colorScheme
    @State private var pageSelection: ImagePDFPageSelection?
    @State private var ocrEnabled = false
    @State private var koreanEnabled = true
    @State private var englishEnabled = true
    @State private var japaneseEnabled = true
    @State private var processingProfile = PDFProcessingProfile.stability
    @State private var estimateSources: [PDFConversionEstimateSource] = []
    @State private var stabilityEstimate: PDFConversionEstimate?
    @State private var speedEstimate: PDFConversionEstimate?

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                pageList
                    .frame(minWidth: 480, idealWidth: 620)
                settings
                    .frame(minWidth: 310, idealWidth: 350, maxWidth: 390)
            }
            Divider()
            footer
        }
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .sheet(item: $pageSelection) { selection in
            PDFPageSelectionSheet(selection: selection) { indexes in
                model.addPDFPages(from: selection, indexes: indexes)
                pageSelection = nil
            } onCancel: {
                pageSelection = nil
            }
        }
        .alert(
            L10n.string("builder.error.title"),
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button(L10n.string("action.close")) { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "")
        }
        .onAppear(perform: refreshEstimateSources)
        .onChange(of: model.items) { _, _ in refreshEstimateSources() }
        .onChange(of: ocrEnabled) { _, _ in refreshEstimates() }
        .onChange(of: koreanEnabled) { _, _ in refreshEstimates() }
        .onChange(of: englishEnabled) { _, _ in refreshEstimates() }
        .onChange(of: japaneseEnabled) { _, _ in refreshEstimates() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 46, height: 46)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("builder.title"))
                    .font(.title2.bold())
                Text(L10n.string("builder.subtitle"))
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Label(L10n.string("builder.local_badge"), systemImage: "lock.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.success)
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
        .background(.regularMaterial)
    }

    private var pageList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button {
                    model.addImages(
                        WorkspaceFilePanels.chooseImages(allowsMultipleSelection: true)
                    )
                } label: {
                    Label(L10n.string("builder.add_images"), systemImage: "photo.on.rectangle.angled")
                }
                Button {
                    model.addHTMLFiles(
                        WorkspaceFilePanels.chooseHTMLFiles(allowsMultipleSelection: true)
                    )
                } label: {
                    Label(
                        L10n.string("builder.add_html"),
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
                Button(action: choosePDF) {
                    Label(L10n.string("builder.add_pdf"), systemImage: "doc.badge.plus")
                }
                Button(action: model.addBlankPage) {
                    Label(L10n.string("builder.add_blank"), systemImage: "doc")
                }
                Spacer()
                Button(role: .destructive, action: model.removeAll) {
                    Label(L10n.string("action.clear"), systemImage: "trash")
                }
                .disabled(model.items.isEmpty || model.isProcessing)
            }
            .buttonStyle(.bordered)
            .disabled(model.isProcessing)
            .padding(14)

            Divider()

            if model.items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string("builder.empty.title"), systemImage: "square.stack.3d.up.slash")
                } description: {
                    Text(L10n.string("builder.empty.detail"))
                }
            } else {
                List {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 30)
                            Image(systemName: item.systemImage)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(theme.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer()
                            Button { model.move(item.id, by: -1) } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == 0 || model.isProcessing)
                            Button { model.move(item.id, by: 1) } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index + 1 == model.items.count || model.isProcessing)
                            Button(role: .destructive) { model.remove(item.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isProcessing)
                        }
                        .padding(.vertical, 5)
                    }
                    .onMove(perform: model.move)
                }
                .disabled(model.isProcessing)
            }
        }
        .background(theme.panel)
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L10n.string("builder.profile.title"), systemImage: "speedometer")
                        .font(.headline)
                    profileCard(.stability, estimate: stabilityEstimate)
                    profileCard(.speed, estimate: speedEstimate)
                    if let estimate = stabilityEstimate, estimate.inputByteCount > 0 {
                        HStack {
                            Text(L10n.string("builder.estimate.input"))
                            Spacer()
                            Text(PDFConversionEstimate.format(bytes: estimate.inputByteCount))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    }
                    Text(L10n.string("builder.estimate.note"))
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(15)
                .vibePDFCard(theme)
                .disabled(model.isProcessing)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $ocrEnabled) {
                        Label(L10n.string("builder.ocr.toggle"), systemImage: "text.viewfinder")
                            .font(.headline)
                    }
                    Text(L10n.string("builder.ocr.detail"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(15)
                .vibePDFCard(theme)
                .disabled(model.isProcessing)

                if ocrEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.string("builder.ocr.languages"))
                            .font(.headline)
                        Toggle("한국어", isOn: $koreanEnabled)
                        Toggle("English", isOn: $englishEnabled)
                        Toggle("日本語", isOn: $japaneseEnabled)
                        Text(
                            "\(Int(processingProfile.recommendedOCRDPI)) DPI · "
                                + L10n.string(processingProfile.titleLocalizationKey)
                        )
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(15)
                    .vibePDFCard(theme)
                    .disabled(model.isProcessing)
                }

                if model.isProcessing || model.progress > 0 {
                    VStack(alignment: .leading, spacing: 9) {
                        ProgressView(value: model.progress)
                        Text(model.status)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(15)
                    .vibePDFCard(theme)
                }

                if model.recognizedText?.isEmpty == false {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.string("builder.ocr.result"))
                            .font(.headline)
                        HStack {
                            Button(L10n.string("builder.ocr.copy")) {
                                model.copyRecognizedText()
                            }
                            Button(L10n.string("builder.ocr.save_text")) {
                                saveRecognizedText()
                            }
                        }
                    }
                    .padding(15)
                    .vibePDFCard(theme)
                }

                if let duration = model.actualDuration {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.string("builder.result.actual"))
                                .font(.headline)
                            Spacer()
                            if let profile = model.actualProfile {
                                Text(L10n.string(profile.titleLocalizationKey))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        HStack {
                            Label(L10n.string("builder.result.time"), systemImage: "clock")
                            Spacer()
                            Text(PDFConversionEstimate.format(duration: duration))
                                .monospacedDigit()
                        }
                        if let bytes = model.actualOutputByteCount {
                            HStack {
                                Label(L10n.string("builder.result.size"), systemImage: "externaldrive")
                                Spacer()
                                Text(PDFConversionEstimate.format(bytes: bytes))
                                    .monospacedDigit()
                            }
                        }
                        if model.actualUsedOCR {
                            Label(L10n.string("builder.ocr.toggle"), systemImage: "text.viewfinder")
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .font(.caption)
                    .padding(15)
                    .vibePDFCard(theme)
                }

                if model.items.contains(where: { item in
                    if case .html = item.source { return true }
                    return false
                }) {
                    Label(
                        L10n.string("builder.html.network_note"),
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
        .background(theme.canvas)
    }

    private var footer: some View {
        HStack {
            Text(model.status)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            Spacer()
            if model.canCancel {
                Button(L10n.string("action.cancel"), action: model.cancelExport)
            }
            Button {
                exportPDF()
            } label: {
                Label(L10n.string("builder.export"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                !model.canExport
                    || (ocrEnabled && !koreanEnabled && !englishEnabled && !japaneseEnabled)
            )
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(.regularMaterial)
    }

    private func choosePDF() {
        guard let url = WorkspaceFilePanels.choosePDFs(allowsMultipleSelection: false).first else {
            return
        }
        do {
            pageSelection = try model.preparePDFSelection(url)
        } catch {
            model.presentedError = error.localizedDescription
        }
    }

    private func exportPDF() {
        guard let destination = WorkspaceFilePanels.chooseSavePDF(
            suggestedName: L10n.string("builder.default_name"),
            title: L10n.string("builder.export_title")
        ) else { return }
        var configuration: OCRConfiguration?
        if ocrEnabled {
            var value = OCRConfiguration()
            value.languages = [
                koreanEnabled ? "ko-KR" : nil,
                englishEnabled ? "en-US" : nil,
                japaneseEnabled ? "ja-JP" : nil,
            ].compactMap { $0 }
            value.skipPagesWithText = true
            configuration = processingProfile.applying(to: value)
        }
        model.startExport(
            to: destination,
            ocrConfiguration: configuration,
            profile: processingProfile
        )
    }

    private func saveRecognizedText() {
        guard let destination = WorkspaceFilePanels.chooseSaveText(
            suggestedName: L10n.string("builder.text_default_name")
        ) else { return }
        model.saveRecognizedText(to: destination)
    }

    private var enabledOCRLanguageCount: Int {
        [koreanEnabled, englishEnabled, japaneseEnabled].filter { $0 }.count
    }

    private func refreshEstimates() {
        stabilityEstimate = PDFConversionEstimator.estimate(
            sources: estimateSources,
            profile: .stability,
            ocrEnabled: ocrEnabled,
            ocrLanguageCount: enabledOCRLanguageCount
        )
        speedEstimate = PDFConversionEstimator.estimate(
            sources: estimateSources,
            profile: .speed,
            ocrEnabled: ocrEnabled,
            ocrLanguageCount: enabledOCRLanguageCount
        )
    }

    private func refreshEstimateSources() {
        estimateSources = PDFConversionEstimator.sources(from: model.items)
        refreshEstimates()
    }

    private func profileCard(
        _ profile: PDFProcessingProfile,
        estimate: PDFConversionEstimate?
    ) -> some View {
        Button {
            processingProfile = profile
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Image(
                        systemName: processingProfile == profile
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .foregroundStyle(
                        processingProfile == profile ? theme.accent : theme.secondaryText
                    )
                    Text(L10n.string(profile.titleLocalizationKey))
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if let estimate {
                        Text(L10n.string(estimate.confidence.localizationKey))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Text(L10n.string(profile.detailLocalizationKey))
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let estimate {
                    HStack(spacing: 12) {
                        estimateValue(
                            label: L10n.string("builder.estimate.time"),
                            value: estimate.formattedDuration,
                            systemImage: "clock"
                        )
                        estimateValue(
                            label: L10n.string("builder.estimate.output"),
                            value: estimate.formattedOutputSize,
                            systemImage: "doc"
                        )
                    }
                    Text(L10n.format("builder.estimate.pages", estimate.pageCount))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.dropHighlight.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        processingProfile == profile ? theme.accent : theme.border,
                        lineWidth: processingProfile == profile ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isProcessing)
        .accessibilityAddTraits(processingProfile == profile ? .isSelected : [])
    }

    private func estimateValue(
        label: String,
        value: String,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PDFPageSelectionSheet: View {
    let selection: ImagePDFPageSelection
    let onAdd: (Set<Int>) -> Void
    let onCancel: () -> Void

    @State private var selectedPages: Set<Int>

    init(
        selection: ImagePDFPageSelection,
        onAdd: @escaping (Set<Int>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.selection = selection
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selectedPages = State(initialValue: Set(0..<selection.pageCount))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("builder.pdf_picker.title"))
                        .font(.title3.bold())
                    Text(selection.url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(L10n.format("builder.pdf_picker.selected", selectedPages.count, selection.pageCount))
                    .font(.caption.monospacedDigit())
            }
            .padding(18)
            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 10)], spacing: 10) {
                    ForEach(0..<selection.pageCount, id: \.self) { index in
                        Button {
                            if selectedPages.contains(index) {
                                selectedPages.remove(index)
                            } else {
                                selectedPages.insert(index)
                            }
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: selectedPages.contains(index) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        selectedPages.contains(index)
                                            ? Color.accentColor
                                            : Color.secondary
                                    )
                                Text(L10n.format("builder.pdf_picker.page", index + 1))
                                    .font(.caption.monospacedDigit())
                            }
                            .frame(maxWidth: .infinity, minHeight: 62)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }

            Divider()
            HStack {
                Button(L10n.string("builder.pdf_picker.all")) {
                    selectedPages = Set(0..<selection.pageCount)
                }
                Button(L10n.string("builder.pdf_picker.none")) {
                    selectedPages.removeAll()
                }
                Spacer()
                Button(L10n.string("action.cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("builder.pdf_picker.add")) {
                    onAdd(selectedPages)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPages.isEmpty)
            }
            .padding(18)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 540, idealHeight: 650)
    }
}
