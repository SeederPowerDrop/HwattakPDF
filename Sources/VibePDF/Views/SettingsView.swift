// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// 앱 전체 보기·성능·AI 연결·아이콘 선호를 편집하는 macOS Settings scene이다.
///
/// PDF 내용에 속하는 값은 여기 두지 않는다. API 키 입력은 화면의 임시 @State에
/// 머물다가 저장 시 Keychain store로 넘어가며, UserDefaults에는 공급자 종류·모델·
/// 검증된 endpoint 같은 비밀이 아닌 metadata만 저장한다.
struct SettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var iconManager: AppIconManager
    @ObservedObject var pluginManager: PluginManager
    @EnvironmentObject private var aiSettings: AIProviderSettingsStore

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PDFTabMemorySettings.loadedTabBudgetKey)
    private var loadedPDFTabBudget = PDFTabMemorySettings.defaultLoadedTabBudget
    @AppStorage(PDFWheelZoomModifier.defaultsKey)
    private var wheelZoomModifierValue = PDFWheelZoomModifier.defaultValue.rawValue
    @AppStorage(AppPerformanceSettings.efficientRenderingEnabledKey)
    private var efficientRenderingEnabled = AppPerformanceSettings.defaultEfficientRenderingEnabled
    /// TextField 편집 중인 secret은 영속 model에 실시간 반영하지 않는다.
    @State private var apiKeyDraft = ""
    @State private var baseURLDraft = ""
    @State private var mcpLabelDraft = ""
    @State private var mcpURLDraft = ""
    @State private var aiSettingsMessage: String?

    private var theme: VibePDFTheme {
        VibePDFTheme(colorScheme: colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                languageSection
                pdfInputSection
                aiSection
                pluginSection
                performanceSection
                iconSection
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 560, idealHeight: 620)
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .navigationTitle(L10n.string("settings.title"))
        .onAppear(perform: refreshAIFieldDrafts)
        .onChange(of: aiSettings.selectedProvider) { _, _ in
            refreshAIFieldDrafts()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 46, height: 46)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("settings.title"))
                    .font(.title2.weight(.bold))
                Text(L10n.string("settings.general"))
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private var languageSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(
                    title: L10n.string("settings.language.title"),
                    description: L10n.string("settings.language.description"),
                    systemImage: "globe"
                )

                Picker(L10n.string("settings.language.title"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 300, alignment: .leading)
                .accessibilityLabel(L10n.string("settings.language.title"))
            }
        }
    }

    private var iconSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeader(
                    title: L10n.string("settings.icon.title"),
                    description: L10n.string("settings.icon.description"),
                    systemImage: "app.badge"
                )

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 165, maximum: 205), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(AppIconPreference.allCases) { preference in
                        iconChoice(preference)
                    }
                }

                Label(
                    L10n.string("settings.icon.runtime_notice"),
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pdfInputSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(
                    title: L10n.string(
                        "settings.pdf_input.title",
                        defaultValue: "PDF 보기 조작"
                    ),
                    description: L10n.string(
                        "settings.pdf_input.description",
                        defaultValue: "메인 PDF 화면의 마우스와 트랙패드 조작을 설정합니다."
                    ),
                    systemImage: "cursorarrow.motionlines"
                )

                Picker(
                    L10n.string(
                        "settings.pdf_input.zoom_modifier.label",
                        defaultValue: "스크롤 확대·축소 키"
                    ),
                    selection: $wheelZoomModifierValue
                ) {
                    ForEach(PDFWheelZoomModifier.allCases) { modifier in
                        Text(modifier.title).tag(modifier.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360, alignment: .leading)

                Label(
                    L10n.string(
                        "settings.pdf_input.horizontal_hint",
                        defaultValue: "Shift(⇧)를 누른 채 세로로 스크롤하면 PDF를 좌우로 이동합니다. 원래의 좌우 제스처와 핀치 확대는 그대로 작동합니다."
                    ),
                    systemImage: "arrow.left.and.right"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var performanceSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(
                    title: L10n.string(
                        "settings.performance.title",
                        defaultValue: "성능 및 메모리"
                    ),
                    description: L10n.string(
                        "settings.performance.description",
                        defaultValue: "많은 대용량 PDF를 열 때 활성 탭 주변만 메모리에 유지합니다."
                    ),
                    systemImage: "memorychip"
                )

                Stepper(
                    value: Binding(
                        get: { PDFTabMemorySettings.normalizedBudget(loadedPDFTabBudget) },
                        set: { loadedPDFTabBudget = PDFTabMemorySettings.normalizedBudget($0) }
                    ),
                    in: PDFTabMemorySettings.allowedLoadedTabBudget
                ) {
                    HStack {
                        Text(
                            L10n.string(
                                "settings.performance.loaded_tabs",
                                defaultValue: "메모리에 유지할 PDF 탭"
                            )
                        )
                        Spacer()
                        Text("\(PDFTabMemorySettings.normalizedBudget(loadedPDFTabBudget))")
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                }

                Toggle(
                    L10n.string(
                        "settings.performance.efficient_rendering",
                        defaultValue: "효율적인 렌더링 사용(권장)"
                    ),
                    isOn: $efficientRenderingEnabled
                )

                Text(
                    L10n.string(
                        "settings.performance.efficient_rendering_detail",
                        defaultValue: "썸네일 해상도와 캐시를 안전한 범위로 제한하고 메모리 압력 때 즉시 비워 CPU·GPU·메모리 피크를 낮춥니다. PDF 본문과 저장 품질은 바뀌지 않습니다."
                    )
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                Label(
                    L10n.string(
                        "settings.performance.safety_note",
                        defaultValue: "편집 중이거나 OCR 작업이 있는 탭은 자동으로 보호되며, 잠든 탭은 선택할 때 현재 페이지로 다시 열립니다."
                    ),
                    systemImage: "shield.checkered"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pluginSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(
                    title: L10n.string(
                        "settings.plugins.title",
                        defaultValue: "플러그인"
                    ),
                    description: L10n.string(
                        "settings.plugins.description",
                        defaultValue: "검증된 .hwattakplugin 패키지를 설치하고, 권한과 활성 상태를 관리합니다."
                    ),
                    systemImage: "puzzlepiece.extension"
                )

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            L10n.format(
                                "settings.plugins.installed_count",
                                pluginManager.installedPlugins.count,
                                pluginManager.enabledActionCount
                            )
                        )
                        .font(.callout.weight(.semibold))
                        Text(
                            L10n.string(
                                "settings.plugins.safety_note",
                                defaultValue: "실행 코드와 상주 작업 없이, 사용자가 실행한 제한된 템플릿 액션만 동작합니다."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        openWindow(id: PluginManagerContent.sceneID)
                    } label: {
                        Label(
                            L10n.string("plugins.manage", defaultValue: "플러그인 관리…"),
                            systemImage: "slider.horizontal.3"
                        )
                    }
                }

                Label(
                    L10n.string(
                        "settings.plugins.resource_note",
                        defaultValue: "모든 패키지는 개수·액션·크기·입출력 제한과 코드·GPU 금지를 따릅니다. v1은 직접 네트워크를 사용하지 않으며, 앱 검토본과 일치하는 v2 웹 패널만 표시된 외부 사이트에 임시로 연결할 수 있습니다."
                    ),
                    systemImage: "leaf"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aiSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(
                    title: L10n.string("ai.settings.title", defaultValue: "AI 공급자 및 MCP"),
                    description: L10n.string(
                        "ai.settings.description",
                        defaultValue: "원하는 AI API를 연결합니다. API 키는 설정 파일이 아닌 현재 사용자의 Keychain에 저장됩니다."
                    ),
                    systemImage: "sparkles"
                )

                Picker(
                    L10n.string("ai.settings.provider", defaultValue: "AI 공급자"),
                    selection: $aiSettings.selectedProvider
                ) {
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                Divider()

                labeledAIField(
                    L10n.string("ai.settings.model", defaultValue: "모델"),
                    text: Binding(
                        get: { aiSettings.selectedConfiguration.model },
                        set: { newValue in
                            var configuration = aiSettings.selectedConfiguration
                            configuration.model = newValue
                            aiSettings.updateConfiguration(configuration)
                        }
                    )
                )

                if aiSettings.selectedProvider == .customOpenAICompatible {
                    HStack(alignment: .bottom, spacing: 8) {
                        labeledAIField(
                            L10n.string("ai.settings.base_url", defaultValue: "API 기본 URL"),
                            text: $baseURLDraft
                        )
                        Button(L10n.string("action.apply", defaultValue: "적용")) {
                            commitBaseURL()
                        }
                        .disabled(baseURLDraft.isEmpty)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.string("ai.settings.base_url", defaultValue: "API 기본 URL"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                        Text(aiSettings.selectedConfiguration.baseURL.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Label(
                            L10n.string(
                                "ai.settings.official_endpoint_locked",
                                defaultValue: "공식 공급자 키 보호를 위해 엔드포인트가 고정됩니다. 임의 서버는 OpenAI-compatible 공급자를 사용하세요."
                            ),
                            systemImage: "lock.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.string("ai.settings.api_key", defaultValue: "API 키"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                    HStack(spacing: 8) {
                        SecureField(
                            L10n.string("ai.settings.api_key_placeholder", defaultValue: "새 API 키 입력"),
                            text: $apiKeyDraft
                        )
                        .textFieldStyle(.roundedBorder)

                        Button(L10n.string("action.save", defaultValue: "저장")) {
                            saveAPIKey()
                        }
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if aiSettings.hasAPIKey(for: aiSettings.selectedProvider) {
                            Button(
                                L10n.string("action.delete", defaultValue: "삭제"),
                                role: .destructive,
                                action: deleteAPIKey
                            )
                        }
                    }

                    Label(
                        aiSettings.hasAPIKey(for: aiSettings.selectedProvider)
                            ? L10n.string("ai.settings.key_saved", defaultValue: "Keychain에 안전하게 저장됨")
                            : L10n.string("ai.settings.key_missing", defaultValue: "이 공급자의 API 키가 필요합니다."),
                        systemImage: aiSettings.hasAPIKey(for: aiSettings.selectedProvider)
                            ? "checkmark.shield.fill"
                            : "key"
                    )
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                }

                if aiSettings.selectedConfiguration.capabilities.supportsWebSearch {
                    Toggle(
                        L10n.string("ai.settings.web_search", defaultValue: "공급자의 웹 검색 사용 허용"),
                        isOn: Binding(
                            get: { aiSettings.selectedConfiguration.isWebSearchEnabled },
                            set: { newValue in
                                var configuration = aiSettings.selectedConfiguration
                                configuration.isWebSearchEnabled = newValue
                                aiSettings.updateConfiguration(configuration)
                            }
                        )
                    )
                }

                if aiSettings.selectedConfiguration.capabilities.supportsRemoteMCP {
                    Divider()
                    remoteMCPSettings
                }

                Label(
                    L10n.string(
                        "ai.settings.billing_note",
                        defaultValue: "ChatGPT·Claude·Gemini 구독과 개발자 API 사용량·과금은 별도일 수 있습니다. 문서 전송은 AI 패널에서 매번 확인합니다."
                    ),
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                if let aiSettingsMessage {
                    Text(aiSettingsMessage)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var remoteMCPSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("ai.settings.mcp_title", defaultValue: "원격 MCP 서버"))
                .font(.callout.weight(.semibold))

            ForEach(aiSettings.selectedConfiguration.remoteMCPServers) { server in
                HStack(spacing: 8) {
                    Image(systemName: "network")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.label).font(.caption.weight(.semibold))
                        Text(server.serverURL.absoluteString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        removeMCPServer(server.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 8) {
                TextField(
                    L10n.string("ai.settings.mcp_label", defaultValue: "서버 이름"),
                    text: $mcpLabelDraft
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 150)
                TextField("https://example.com/mcp", text: $mcpURLDraft)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.string("action.add", defaultValue: "추가"), action: addMCPServer)
                    .disabled(mcpLabelDraft.isEmpty || mcpURLDraft.isEmpty)
            }

            Text(
                L10n.string(
                    "ai.settings.mcp_approval_note",
                    defaultValue: "HTTPS 서버만 연결하며, 각 MCP 도구 호출은 내용을 확인하고 승인해야 실행됩니다."
                )
            )
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)
        }
    }

    private func labeledAIField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func refreshAIFieldDrafts() {
        baseURLDraft = aiSettings.selectedConfiguration.baseURL.absoluteString
        apiKeyDraft = ""
        mcpLabelDraft = ""
        mcpURLDraft = ""
        aiSettingsMessage = nil
        aiSettings.refreshAPIKeyAvailability()
    }

    private func commitBaseURL() {
        guard aiSettings.selectedProvider == .customOpenAICompatible else {
            refreshAIFieldDrafts()
            aiSettingsMessage = L10n.string(
                "ai.error.official_endpoint_locked",
                defaultValue: "공식 공급자의 API 주소는 변경할 수 없습니다."
            )
            return
        }
        guard
            let url = URL(string: baseURLDraft),
            AIEndpointPolicy.isValidProviderBaseURL(
                url,
                allowsInsecureLocalhost: false
            )
        else {
            aiSettingsMessage = L10n.string(
                "ai.error.https_url_required",
                defaultValue: "유효한 HTTPS 주소를 입력해 주세요."
            )
            return
        }
        var configuration = aiSettings.selectedConfiguration
        let endpointChanged = AIEndpointPolicy.normalizedEndpoint(
            configuration.baseURL
        ) != AIEndpointPolicy.normalizedEndpoint(url)
        configuration.baseURL = url
        aiSettings.updateConfiguration(configuration)
        baseURLDraft = url.absoluteString
        aiSettingsMessage = aiSettings.lastErrorDescription ?? (endpointChanged
            ? L10n.string(
                "ai.settings.endpoint_changed",
                defaultValue: "새 서버에는 이전 API 키를 재사용하지 않습니다. 이 서버용 키를 다시 저장해 주세요."
            )
            : L10n.string("ai.settings.saved", defaultValue: "AI 설정을 저장했습니다."))
    }

    private func saveAPIKey() {
        do {
            try aiSettings.saveAPIKey(apiKeyDraft, for: aiSettings.selectedProvider)
            apiKeyDraft = ""
            aiSettingsMessage = L10n.string("ai.settings.key_saved", defaultValue: "Keychain에 안전하게 저장됨")
        } catch {
            aiSettingsMessage = error.localizedDescription
        }
    }

    private func deleteAPIKey() {
        do {
            try aiSettings.deleteAPIKey(for: aiSettings.selectedProvider)
            apiKeyDraft = ""
            aiSettingsMessage = L10n.string("ai.settings.key_deleted", defaultValue: "저장된 API 키를 삭제했습니다.")
        } catch {
            aiSettingsMessage = error.localizedDescription
        }
    }

    private func addMCPServer() {
        let label = mcpLabelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIEndpointPolicy.isSafeIdentifier(label) else {
            aiSettingsMessage = L10n.string(
                "ai.error.mcp_label",
                defaultValue: "서버 이름은 1~64자의 문자, 숫자, 밑줄 또는 하이픈만 사용할 수 있습니다."
            )
            return
        }
        guard
            let url = URL(string: mcpURLDraft),
            AIEndpointPolicy.isValidRemoteMCPURL(url)
        else {
            aiSettingsMessage = L10n.string(
                "ai.error.https_url_required",
                defaultValue: "유효한 HTTPS 주소를 입력해 주세요."
            )
            return
        }
        var configuration = aiSettings.selectedConfiguration
        let labelKey = label.lowercased()
        let endpointKey = AIEndpointPolicy.normalizedEndpoint(url)
        guard !configuration.remoteMCPServers.contains(where: {
            $0.label.lowercased() == labelKey
                || AIEndpointPolicy.normalizedEndpoint($0.serverURL) == endpointKey
        }) else {
            aiSettingsMessage = L10n.string("ai.error.duplicate_mcp", defaultValue: "이미 등록된 MCP 서버입니다.")
            return
        }
        configuration.remoteMCPServers.append(
            AIRemoteMCPServer(label: label, serverURL: url)
        )
        aiSettings.updateConfiguration(configuration)
        mcpLabelDraft = ""
        mcpURLDraft = ""
        aiSettingsMessage = L10n.string("ai.settings.saved", defaultValue: "AI 설정을 저장했습니다.")
    }

    private func removeMCPServer(_ id: UUID) {
        var configuration = aiSettings.selectedConfiguration
        configuration.remoteMCPServers.removeAll { $0.id == id }
        aiSettings.updateConfiguration(configuration)
    }

    private func sectionHeader(
        title: String,
        description: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 30, height: 30)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func iconChoice(_ preference: AppIconPreference) -> some View {
        let isSelected = iconManager.selection == preference

        return Button {
            iconManager.select(preference)
        } label: {
            VStack(spacing: 10) {
                Group {
                    if let image = iconManager.image(for: preference) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Image(systemName: preference.fallbackSystemImage)
                            .resizable()
                            .scaledToFit()
                            .padding(20)
                            .foregroundStyle(theme.accent)
                    }
                }
                .scaledToFit()
                .frame(width: 86, height: 86)
                .shadow(color: theme.elevatedShadow, radius: 10, y: 5)

                VStack(spacing: 3) {
                    Text(preference.title)
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text(preference.subtitle)
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label(
                    L10n.string("settings.icon.selected"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.accent)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(!isSelected)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .top)
            .background(
                isSelected ? theme.dropHighlight : theme.card,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? theme.accent : theme.border, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preference.title)
        .accessibilityValue(isSelected ? L10n.string("settings.icon.selected") : "")
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }
    }
}
