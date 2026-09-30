// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum PageTranslationEngine: String, CaseIterable, Identifiable {
    case system, externalAI, localPack
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.string("translation.engine.system", defaultValue: "macOS 번역")
        case .externalAI: L10n.string("translation.engine.ai", defaultValue: "외부 AI")
        case .localPack: L10n.string("translation.engine.local", defaultValue: "로컬 언어팩")
        }
    }
}

private struct PageTranslationConsent: Identifiable {
    let id = UUID()
    let input: PageTranslationInput
    let configuration: AIProviderConfiguration
}

private struct PageTranslationPackUpdate {
    var installed: [LocalTranslationPack]? = nil
    var available: [LocalTranslationPack]? = nil
    var message: String? = nil
}

@MainActor
struct PageTranslationPanel: View {
    let request: PluginPanelRequest
    @ObservedObject private var providerSettings = AIProviderSettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var engine = PageTranslationEngine.system
    @State private var sourceLanguage = ""
    @State private var targetLanguage: String
    @State private var sourceText: String
    @State private var showingSource: Bool
    @State private var includesSourceInExport = true
    @State private var result: PageTranslationResult?
    @State private var resultID: UUID?
    @State private var pendingConsent: PageTranslationConsent?
    @State private var appleJob: ApplePageTranslationJob?
    @State private var activeID: UUID?
    @State private var translationTask: Task<Void, Never>?
    @State private var statusMessage: String?
    @State private var isVisible = false
    @State private var showsPackManager = false
    @State private var showsSetup = false
    @State private var packs: [LocalTranslationPack] = []
    @State private var installedPacks: [LocalTranslationPack] = []
    @State private var packTask: Task<Void, Never>?
    @State private var packOperationID: UUID?
    @State private var packMessage: String?
    @AppStorage("translation.local.endpoint") private var localEndpoint = "http://127.0.0.1:17862"

    init(request: PluginPanelRequest, preferences: PluginPreferences) {
        self.request = request
        let target = preferences.translationTargetLanguageCode == PluginPreferences.followAppLanguageCode
            ? L10n.currentLanguage.locale.language.languageCode?.identifier ?? "ko"
            : preferences.translationTargetLanguageCode
        _targetLanguage = State(initialValue: target)
        _sourceText = State(initialValue: request.sourceText ?? "")
        _showingSource = State(initialValue: preferences.translationShowsSource)
    }

    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }
    private var isBusy: Bool { activeID != nil }
    private var selectedConfiguration: AIProviderConfiguration { providerSettings.selectedConfiguration }
    private var languageCodes: [String] {
        Array(Set(["ko", "en", "ja", "zh-CN", "zh", "fr", "de", "es", "pt", "vi", "ar", "it", "ru", "uk", "nl", "pl", "tr", "hi", "id", "th", targetLanguage]
            + packs.flatMap { [$0.sourceLanguage, $0.targetLanguage] }
            + installedPacks.flatMap { [$0.sourceLanguage, $0.targetLanguage] })).sorted {
                languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
            }
    }
    private var canTranslate: Bool {
        guard !isBusy, !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if engine == .system { if #unavailable(macOS 15.0) { return false } }
        if engine == .localPack {
            return localLanguageCode(sourceLanguage) != localLanguageCode(targetLanguage)
        }
        return sourceLanguage != targetLanguage
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                engineDetails
                sourceEditor
                translateControls
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                }
                if let result { translatedContent(result) }
            }
            .padding(12)
        }
        .background(theme.canvas)
        .overlay(alignment: .bottomTrailing) {
            if #available(macOS 15.0, *), let appleJob {
                ApplePageTranslationBridge(job: appleJob, onCompletion: finishTranslation)
                    .id(appleJob.id)
            }
        }
        .sheet(item: $pendingConsent) { consent in
            PageTranslationConsentSheet(consent: consent, onCancel: { pendingConsent = nil }) {
                confirmTransmission(consent)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            invalidateTranslation()
            cancelPackOperation()
        }
        .onChange(of: sourceText) { _, _ in invalidateTranslation() }
        .onChange(of: sourceLanguage) { _, _ in invalidateTranslation() }
        .onChange(of: targetLanguage) { _, _ in invalidateTranslation() }
        .onChange(of: engine) { _, engine in
            invalidateTranslation()
            if engine == .localPack, sourceLanguage.isEmpty { sourceLanguage = "en" }
        }
        .onChange(of: selectedConfiguration) { _, _ in invalidateTranslation() }
        .onChange(of: localEndpoint) { _, _ in
            invalidateTranslation()
            cancelPackOperation()
            packs = []
            installedPacks = []
            packMessage = nil
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.string("translation.engine.label", defaultValue: "번역 엔진"), selection: $engine) {
                ForEach(PageTranslationEngine.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                Picker(L10n.string("translation.language.source", defaultValue: "원문 언어"), selection: $sourceLanguage) {
                    if engine != .localPack {
                        Text(L10n.string("translation.language.auto", defaultValue: "자동 감지")).tag("")
                    }
                    ForEach(languageCodes, id: \.self) { Text(languageName($0)).tag($0) }
                }
                Image(systemName: "arrow.right").foregroundStyle(theme.secondaryText)
                Picker(L10n.string("translation.language.target", defaultValue: "번역 언어"), selection: $targetLanguage) {
                    ForEach(languageCodes, id: \.self) { Text(languageName($0)).tag($0) }
                }
            }
            .labelsHidden()
            Text(L10n.string("translation.output.description", defaultValue: "문단을 나란히 검토하고, 읽기 좋은 새 PDF·HTML로 저장합니다. 원본 페이지의 그림과 배치는 재현하지 않습니다."))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var engineDetails: some View {
        switch engine {
        case .system:
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("translation.system.description", defaultValue: "Apple의 기기 내 번역을 사용합니다. 필요한 언어가 없으면 macOS에서 다운로드를 안내합니다."))
                if #unavailable(macOS 15.0) {
                    Text(L10n.string("translation.system.requires_macos15", defaultValue: "문단별 번역과 내보내기는 macOS 15 이상에서 지원됩니다. 현재 버전에서는 외부 AI·로컬 언어팩을 이용하세요."))
                    if #available(macOS 14.4, *) { AppleLegacyTranslationButton(text: sourceText) }
                }
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
        case .externalAI:
            VStack(alignment: .leading, spacing: 7) {
                Picker(L10n.string("translation.ai.provider", defaultValue: "AI 공급자"), selection: $providerSettings.selectedProvider) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                Text("\(selectedConfiguration.baseURL.host ?? "") · \(selectedConfiguration.model)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(L10n.string("translation.ai.description", defaultValue: "앱 설정의 AI 모델과 Keychain API 키를 사용합니다. 번역을 누르면 전송할 원문과 목적지를 먼저 확인합니다."))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                if selectedConfiguration.requiresAPIKey && !providerSettings.hasAPIKey(for: selectedConfiguration.kind) {
                    Text(L10n.string("translation.ai.key_missing", defaultValue: "이 공급자의 API 키가 없습니다. 앱 설정 → AI에서 등록하세요."))
                        .font(.caption).foregroundStyle(theme.warning)
                }
                SettingsLink { Text(L10n.string("translation.ai.open_settings", defaultValue: "AI 설정 열기")) }
                    .controlSize(.small)
            }
        case .localPack:
            localPackControls
        }
    }

    private var sourceEditor: some View {
        DisclosureGroup(isExpanded: $showingSource) {
            TextEditor(text: $sourceText)
                .font(.system(size: 12))
                .frame(minHeight: 100, maxHeight: 190)
                .padding(5)
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(L10n.string("translation.source.edit_note", defaultValue: "번역에 사용할 원문을 수정할 수 있습니다. 스캔 페이지에 텍스트가 없다면 먼저 OCR을 실행하세요."))
                .font(.caption2).foregroundStyle(theme.secondaryText)
        } label: {
            HStack {
                Text(L10n.string("translation.source.title", defaultValue: "번역할 원문"))
                Spacer()
                Text(sourceText.count.formatted()).foregroundStyle(theme.secondaryText)
            }
            .font(.caption.weight(.medium))
        }
    }

    private var translateControls: some View {
        HStack {
            Button(action: prepareTranslation) {
                Label(L10n.string("translation.action.translate", defaultValue: "페이지 번역"), systemImage: "character.bubble")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canTranslate)
            if isBusy {
                ProgressView().controlSize(.small)
                Button(L10n.string("action.cancel", defaultValue: "취소")) {
                    cancelTranslation()
                    statusMessage = L10n.string("translation.status.cancelled", defaultValue: "번역을 취소했습니다.")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func translatedContent(_ result: PageTranslationResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text(L10n.string("translation.result.title", defaultValue: "번역 결과"))
                .font(.headline)
            HStack(spacing: 8) {
                Button(L10n.string("translation.action.copy", defaultValue: "번역 복사")) { copy(result.translatedText) }
                Menu(L10n.string("translation.action.export", defaultValue: "파일로 저장")) {
                    Button(L10n.string("translation.action.export_pdf", defaultValue: "PDF 저장")) { export(result, asPDF: true) }
                    Button(L10n.string("translation.action.export_html", defaultValue: "HTML 저장")) { export(result, asPDF: false) }
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            Toggle(L10n.string("translation.export.include_source", defaultValue: "저장할 파일에 원문 포함"), isOn: $includesSourceInExport)
                .font(.caption)
            ForEach(result.blocks, id: \.id) { block in
                VStack(alignment: .leading, spacing: 8) {
                    Text(block.source)
                        .font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                    Divider()
                    Text(block.translated)
                        .font(.system(size: 14)).lineSpacing(4)
                        .foregroundStyle(theme.primaryText)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var localPackControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("translation.local.description", defaultValue: "Argos 공개 언어팩으로 이 Mac에서 번역합니다. 언어팩 설치 후에는 인터넷 없이 사용할 수 있습니다."))
                .font(.caption).foregroundStyle(theme.secondaryText)
            DisclosureGroup(L10n.string("translation.local.manage", defaultValue: "로컬 연결 및 언어팩 관리"), isExpanded: $showsPackManager) {
                VStack(alignment: .leading, spacing: 9) {
                    TextField(L10n.string("translation.local.endpoint", defaultValue: "로컬 번역 서버 주소"), text: $localEndpoint)
                        .textFieldStyle(.roundedBorder)
                    Text(L10n.string("translation.local.loopback", defaultValue: "127.0.0.1 주소만 허용합니다. PDF 원문은 이 Mac의 번역 도우미로만 전달됩니다."))
                        .font(.caption2).foregroundStyle(theme.secondaryText)
                    HStack {
                        Button(L10n.string("translation.local.check", defaultValue: "연결·설치 확인")) { refreshInstalledPacks() }
                        Button(L10n.string("translation.local.catalog", defaultValue: "온라인 언어팩 목록")) { refreshPackCatalog() }
                    }
                    HStack {
                        Button(L10n.string("translation.local.import", defaultValue: "언어팩 파일 가져오기")) { importLanguagePack() }
                        if packOperationID != nil {
                            ProgressView().controlSize(.small)
                            Button(L10n.string("action.cancel", defaultValue: "취소")) { cancelPackOperation() }
                        }
                    }
                    if let packMessage {
                        Text(packMessage).font(.caption).textSelection(.enabled)
                    }
                    if !installedPacks.isEmpty {
                        Text(L10n.string("translation.local.installed", defaultValue: "설치된 언어팩"))
                            .font(.caption.weight(.semibold))
                        ForEach(installedPacks) { pack in
                            Text("\(pack.sourceName) → \(pack.targetName) · \(pack.version)")
                                .font(.caption)
                        }
                    }
                    if !packs.isEmpty {
                        Text(L10n.string("translation.local.available", defaultValue: "선택한 언어의 공개 언어팩"))
                            .font(.caption.weight(.semibold))
                        let matching = matchingPacks
                        ForEach(matching.prefix(40)) { pack in
                            HStack {
                                Text("\(pack.sourceName) → \(pack.targetName)").font(.caption)
                                Spacer(minLength: 3)
                                Button(L10n.string("translation.local.install", defaultValue: "다운로드")) { installLanguagePack(pack) }
                                    .disabled(packOperationID != nil)
                            }
                        }
                        Text(L10n.string("translation.local.download_notice", defaultValue: "다운로드는 공개 Argos 배포 서버에 연결하며 디스크 공간을 사용합니다. 문서 원문은 전송하지 않습니다."))
                            .font(.caption2).foregroundStyle(theme.secondaryText)
                    }
                    DisclosureGroup(L10n.string("translation.local.setup", defaultValue: "처음 사용: 번역 도우미 설치"), isExpanded: $showsSetup) {
                        if let launcher = LocalTranslationService.bundledLauncherURL {
                            Button(L10n.string("translation.local.reveal_setup", defaultValue: "설치·실행 도우미를 Finder에서 보기")) {
                                NSWorkspace.shared.activateFileViewerSelecting([launcher])
                            }
                        }
                        Text(L10n.string("translation.local.setup_description", defaultValue: "Python 3가 설치된 Mac에서 아래 명령을 터미널에 실행하세요. 별도 환경에 Argos를 설치하고 로컬 도우미를 시작합니다. 사용 중에는 터미널을 열어 두세요."))
                            .font(.caption).foregroundStyle(theme.secondaryText)
                        if let setupCommand {
                            Text(setupCommand).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            Button(L10n.string("translation.local.copy_setup", defaultValue: "설치 명령 복사")) { copy(setupCommand) }
                        } else {
                            Text(L10n.string("translation.local.worker_missing", defaultValue: "번역 도우미 리소스를 찾을 수 없습니다. 앱을 다시 설치해 주세요."))
                                .font(.caption)
                        }
                    }
                }
                .padding(.top, 7)
                .controlSize(.small)
            }
            .font(.caption.weight(.medium))
        }
    }

    private var setupCommand: String? {
        guard let worker = LocalTranslationService.bundledWorkerURL else { return nil }
        let quotedPath = "'" + worker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        python3 -m venv "$HOME/.hwattakpdf-translation"
        "$HOME/.hwattakpdf-translation/bin/python" -m pip install argostranslate
        "$HOME/.hwattakpdf-translation/bin/python" \(quotedPath) --serve
        """
    }

    private func prepareTranslation() {
        do {
            let input = PageTranslationInput(
                sourceText: sourceText,
                sourceLanguageCode: sourceLanguage.isEmpty ? nil : sourceLanguage,
                targetLanguageCode: targetLanguage
            )
            let blocks = try input.blocks()
            guard canTranslate else { return }
            statusMessage = nil
            switch engine {
            case .externalAI:
                pendingConsent = PageTranslationConsent(input: input, configuration: selectedConfiguration)
            case .system:
                if #available(macOS 15.0, *) {
                    let id = beginTranslation()
                    appleJob = ApplePageTranslationJob(id: id, input: input, blocks: blocks)
                }
            case .localPack:
                let configuration = try localConfiguration()
                let id = beginTranslation()
                translationTask = Task {
                    do {
                        let translated = try await LocalTranslationService.translate(
                            texts: blocks.map(\.source),
                            sourceLanguage: localLanguageCode(input.sourceLanguageCode ?? ""),
                            targetLanguage: localLanguageCode(input.targetLanguageCode), configuration: configuration
                        )
                        try Task.checkCancellation()
                        guard translated.count == blocks.count else { throw PageTranslationUIError.incomplete }
                        let result = PageTranslationResult(
                            blocks: zip(blocks, translated).map { TranslatedPageBlock(id: $0.0.id, source: $0.0.source, translated: $0.1) },
                            sourceLanguageCode: input.sourceLanguageCode,
                            targetLanguageCode: input.targetLanguageCode,
                            engineTitle: PageTranslationEngine.localPack.title
                        )
                        finishTranslation(id, .success(result))
                    } catch is CancellationError {} catch { finishTranslation(id, .failure(error)) }
                }
            }
        } catch { statusMessage = error.localizedDescription }
    }

    private func confirmTransmission(_ consent: PageTranslationConsent) {
        guard pendingConsent?.id == consent.id, isVisible,
              consent.configuration == selectedConfiguration,
              consent.input.sourceText == sourceText,
              consent.input.targetLanguageCode == targetLanguage,
              consent.input.sourceLanguageCode == (sourceLanguage.isEmpty ? nil : sourceLanguage)
        else { pendingConsent = nil; return }
        pendingConsent = nil
        let id = beginTranslation()
        translationTask = Task {
            do {
                let result = try await PageTranslationService().translate(consent.input, using: consent.configuration)
                try Task.checkCancellation()
                finishTranslation(id, .success(result))
            } catch is CancellationError {} catch { finishTranslation(id, .failure(error)) }
        }
    }

    private func beginTranslation() -> UUID {
        cancelTranslation()
        result = nil
        resultID = nil
        statusMessage = nil
        let id = UUID()
        activeID = id
        return id
    }

    private func finishTranslation(_ id: UUID, _ completion: Result<PageTranslationResult, Error>) {
        guard isVisible, activeID == id else { return }
        activeID = nil
        translationTask = nil
        appleJob = nil
        switch completion {
        case .success(let value): result = value; resultID = id
        case .failure(let error): statusMessage = error.localizedDescription
        }
    }

    private func cancelTranslation() {
        activeID = nil
        translationTask?.cancel()
        translationTask = nil
        appleJob = nil
    }

    private func invalidateTranslation() {
        cancelTranslation()
        pendingConsent = nil
        result = nil
        resultID = nil
        statusMessage = nil
    }

    private func localConfiguration() throws -> LocalTranslationConfiguration {
        guard let url = URL(string: localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              LocalTranslationService.isValidEndpoint(url) else {
            throw PageTranslationUIError.invalidLocalAddress
        }
        return LocalTranslationConfiguration(baseURL: url)
    }

    private func refreshInstalledPacks() {
        runPackOperation { configuration in
            let loaded = try await LocalTranslationService.installedPacks(configuration: configuration)
            return PageTranslationPackUpdate(installed: loaded, message: L10n.string("translation.local.connected", defaultValue: "로컬 번역 도우미에 연결했습니다. 필요한 언어팩을 설치하고 원문·번역 언어를 선택하세요."))
        }
    }

    private func refreshPackCatalog() {
        runPackOperation { configuration in
            let loaded = try await LocalTranslationService.availablePacks(configuration: configuration)
            return PageTranslationPackUpdate(available: loaded)
        }
    }

    private func installLanguagePack(_ pack: LocalTranslationPack) {
        runPackOperation { configuration in
            try await LocalTranslationService.installPack(pack, configuration: configuration)
            try Task.checkCancellation()
            let loaded = try await LocalTranslationService.installedPacks(configuration: configuration)
            return PageTranslationPackUpdate(installed: loaded, message: L10n.string("translation.local.installed_success", defaultValue: "언어팩을 설치했습니다. 이제 로컬 번역을 실행할 수 있습니다."))
        }
    }

    private func importLanguagePack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "argosmodel") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = L10n.string("translation.local.import", defaultValue: "언어팩 파일 가져오기")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runPackOperation { configuration in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try await LocalTranslationService.importPack(at: url, configuration: configuration)
            try Task.checkCancellation()
            let loaded = try await LocalTranslationService.installedPacks(configuration: configuration)
            return PageTranslationPackUpdate(installed: loaded, message: L10n.string("translation.local.installed_success", defaultValue: "언어팩을 설치했습니다. 이제 로컬 번역을 실행할 수 있습니다."))
        }
    }

    private func runPackOperation(_ operation: @escaping @MainActor (LocalTranslationConfiguration) async throws -> PageTranslationPackUpdate) {
        cancelPackOperation()
        do {
            let configuration = try localConfiguration()
            let id = UUID()
            packOperationID = id
            packMessage = nil
            packTask = Task {
                do {
                    let update = try await operation(configuration)
                    try Task.checkCancellation()
                    guard isVisible, packOperationID == id else { return }
                    if let loaded = update.installed { installedPacks = loaded }
                    if let loaded = update.available { packs = loaded }
                    packMessage = update.message
                } catch is CancellationError {} catch {
                    if isVisible, packOperationID == id { packMessage = error.localizedDescription }
                }
                guard isVisible, packOperationID == id else { return }
                packOperationID = nil
                packTask = nil
            }
        } catch { packMessage = error.localizedDescription }
    }

    private func cancelPackOperation() {
        packOperationID = nil
        packTask?.cancel()
        packTask = nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(text, forType: .string) {
            statusMessage = L10n.string("translation.error.clipboard", defaultValue: "클립보드에 복사하지 못했습니다.")
        }
    }

    private func export(_ result: PageTranslationResult, asPDF: Bool) {
        guard let expectedID = resultID else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = asPDF ? [.pdf] : [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = asPDF ? "Translation.pdf" : "Translation.html"
        guard panel.runModal() == .OK, let url = panel.url,
              isVisible, resultID == expectedID else { return }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard !PageTranslationExportPolicy.replacesSource(url, sourceURL: request.sourceDocumentURL) else {
                throw PageTranslationUIError.sourceOverwrite
            }
            let data: Data
            if asPDF {
                data = try PageTranslationExporter.pdfData(result, title: request.title, includeSource: includesSourceInExport)
            } else {
                data = Data(PageTranslationExporter.html(result, title: request.title, includeSource: includesSourceInExport).utf8)
            }
            try data.write(to: url, options: .atomic)
            statusMessage = L10n.string("translation.export.saved", defaultValue: "번역 파일을 저장했습니다.")
        } catch { statusMessage = error.localizedDescription }
    }

    private func languageName(_ code: String) -> String {
        L10n.currentLanguage.locale.localizedString(forIdentifier: code) ?? code
    }

    private func localLanguageCode(_ code: String) -> String {
        // Argos uses the base code for these Simplified Chinese aliases.
        ["zh-CN", "zh-Hans", "zh-Hans-CN"].contains(code) ? "zh" : code
    }

    private var matchingPacks: [LocalTranslationPack] {
        let source = localLanguageCode(sourceLanguage)
        let target = localLanguageCode(targetLanguage)
        return packs.filter { $0.sourceLanguage == source || $0.targetLanguage == target }
            .sorted { first, second in
                let firstDirect = first.sourceLanguage == source && first.targetLanguage == target
                let secondDirect = second.sourceLanguage == source && second.targetLanguage == target
                if firstDirect != secondDirect { return firstDirect }
                return first.id < second.id
            }
    }
}

@MainActor
private struct PageTranslationConsentSheet: View {
    let consent: PageTranslationConsent
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("translation.consent.title", defaultValue: "이 원문을 AI에 전송할까요?"))
                .font(.title3.weight(.semibold))
            Text("\(consent.configuration.name) · \(consent.configuration.model)")
                .font(.headline)
            Text(consent.configuration.baseURL.absoluteString)
                .font(.caption.monospaced()).textSelection(.enabled)
            Text(L10n.string("translation.consent.detail", defaultValue: "아래 원문과 번역 지시문을 선택한 AI 공급자에게 보냅니다. API 이용 요금이 발생할 수 있습니다. 웹 검색과 MCP 도구는 사용하지 않습니다."))
                .font(.callout)
            HStack {
                Text(consent.input.sourceLanguageCode ?? L10n.string("translation.language.auto", defaultValue: "자동 감지"))
                Image(systemName: "arrow.right")
                Text(consent.input.targetLanguageCode)
                Spacer()
                Text(consent.input.sourceText.count.formatted())
            }
            .font(.caption)
            ScrollView {
                Text(consent.input.sourceText)
                    .font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 170, maxHeight: 280)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(L10n.string("action.cancel", defaultValue: "취소"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("translation.consent.send", defaultValue: "이 원문 전송 및 번역"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 530)
    }
}

private enum PageTranslationUIError: LocalizedError {
    case invalidLocalAddress
    case incomplete
    case sourceOverwrite
    var errorDescription: String? {
        switch self {
        case .invalidLocalAddress: L10n.string("translation.local.invalid_address", defaultValue: "로컬 서버 주소를 확인하세요. 예: http://127.0.0.1:17862")
        case .incomplete: L10n.string("translation.error.local_incomplete", defaultValue: "로컬 번역에서 일부 문단이 누락되었습니다. 다시 시도해 주세요.")
        case .sourceOverwrite: L10n.string("translation.export.source_overwrite", defaultValue: "원본 PDF를 덮어쓸 수 없습니다. 번역 사본을 다른 이름이나 위치에 저장하세요.")
        }
    }
}

enum PageTranslationExportPolicy {
    static func replacesSource(_ destination: URL, sourceURL: URL?) -> Bool {
        guard let sourceURL else { return false }
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        if source == target { return true }
        // Two paths may point to the same hard-linked inode.
        if let sourceID = try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
           let targetID = try? target.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject {
            return sourceID.isEqual(targetID)
        }
        return false
    }
}
