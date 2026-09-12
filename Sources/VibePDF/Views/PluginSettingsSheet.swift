// SPDX-License-Identifier: MPL-2.0

import SwiftUI

@MainActor
struct PluginSettingsSheet: View {
    @ObservedObject var manager: PluginManager
    let plugin: InstalledPlugin
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: PluginPreferences
    @State private var draftEnabled: Bool
    @State private var errorMessage: String?

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }
    private var configurationKind: PluginConfigurationKind {
        manager.configurationKind(for: plugin)
    }
    private var currentPlugin: InstalledPlugin {
        manager.installedPlugins.first(where: { $0.id == plugin.id }) ?? plugin
    }

    init(
        manager: PluginManager,
        plugin: InstalledPlugin,
        onDismiss: @escaping () -> Void
    ) {
        self.manager = manager
        self.plugin = plugin
        self.onDismiss = onDismiss
        _draft = State(initialValue: manager.preferences(for: plugin.id))
        _draftEnabled = State(initialValue: plugin.isEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    generalSection
                    pluginOptionsSection
                    permissionsSection
                    actionsSection
                    informationSection
                }
                .padding(22)
            }

            Divider().overlay(theme.border)
            footer
        }
        .frame(
            minWidth: 660,
            idealWidth: 660,
            maxWidth: 660,
            minHeight: 580,
            idealHeight: 680
        )
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .alert(
            L10n.string("plugins.error.title", defaultValue: "플러그인 오류"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L10n.string("action.close", defaultValue: "닫기"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: pluginSystemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 42, height: 42)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(BundledPluginPresentation.displayName(for: plugin.manifest))
                    .font(.title3.weight(.semibold))
                Text(
                    L10n.string(
                        "plugins.settings",
                        defaultValue: "플러그인 설정"
                    )
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help(L10n.string("action.close", defaultValue: "닫기"))
            .accessibilityLabel(L10n.string("action.close", defaultValue: "닫기"))
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
        .background(theme.panel)
    }

    private var generalSection: some View {
        settingsCard(
            title: L10n.string(
                "settings.general",
                defaultValue: "일반"
            )
        ) {
            settingRow(
                title: L10n.string("plugins.enabled", defaultValue: "활성화"),
                detail: L10n.string(
                    "plugins.settings.enabled_detail",
                    defaultValue: "플러그인 메뉴에서 이 플러그인의 작업을 사용할 수 있습니다."
                )
            ) {
                Toggle("", isOn: $draftEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(L10n.string("plugins.enabled", defaultValue: "활성화"))
            }
        }
    }

    @ViewBuilder
    private var pluginOptionsSection: some View {
        switch configurationKind {
        case .translation:
            settingsCard(
                title: L10n.string(
                    "plugins.settings.options",
                    defaultValue: "플러그인 옵션"
                )
            ) {
                settingRow(
                    title: L10n.string(
                        "plugins.settings.translation_provider",
                        defaultValue: "기본 번역 서비스"
                    ),
                    detail: L10n.string(
                        "plugins.settings.translation_provider_detail",
                        defaultValue: "새 번역 패널을 열 때 먼저 선택할 서비스를 정합니다."
                    )
                ) {
                    Picker("", selection: $draft.translationProvider) {
                        ForEach(PluginTranslationProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .accessibilityLabel(L10n.string(
                        "plugins.settings.translation_provider",
                        defaultValue: "기본 번역 서비스"
                    ))
                }

                cardDivider

                settingRow(
                    title: L10n.string(
                        "plugins.settings.translation_language",
                        defaultValue: "기본 번역 언어"
                    ),
                    detail: L10n.string(
                        "plugins.settings.translation_language_detail",
                        defaultValue: "앱 언어를 따르거나 자주 사용하는 언어를 고정합니다."
                    )
                ) {
                    Picker("", selection: $draft.translationTargetLanguageCode) {
                        ForEach(translationLanguageChoices, id: \.code) { choice in
                            Text(choice.title).tag(choice.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .accessibilityLabel(L10n.string(
                        "plugins.settings.translation_language",
                        defaultValue: "기본 번역 언어"
                    ))
                }

                cardDivider

                settingRow(
                    title: L10n.string(
                        "plugins.settings.translation_source",
                        defaultValue: "원문을 펼쳐서 시작"
                    ),
                    detail: L10n.string(
                        "plugins.settings.translation_source_detail",
                        defaultValue: "외부로 보내기 전에 PDF 원문을 바로 검토할 수 있습니다."
                    )
                ) {
                    Toggle("", isOn: $draft.translationShowsSource)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel(L10n.string(
                            "plugins.settings.translation_source",
                            defaultValue: "원문을 펼쳐서 시작"
                        ))
                }
            }

        case .youtube:
            settingsCard(
                title: L10n.string(
                    "plugins.settings.options",
                    defaultValue: "플러그인 옵션"
                )
            ) {
                settingRow(
                    title: L10n.string(
                        "plugins.settings.youtube_start_page",
                        defaultValue: "YouTube 시작 페이지 자동 열기"
                    ),
                    detail: L10n.string(
                        "plugins.settings.youtube_start_page_detail",
                        defaultValue: "끄면 네트워크 연결 없이 빈 검색 패널로 시작합니다."
                    )
                ) {
                    Toggle("", isOn: $draft.youtubeLoadsStartPage)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel(L10n.string(
                            "plugins.settings.youtube_start_page",
                            defaultValue: "YouTube 시작 페이지 자동 열기"
                        ))
                }

                cardDivider
                lockedSecurityRow(
                    L10n.string(
                        "plugins.settings.youtube_security",
                        defaultValue: "개인정보 보호 강화 재생·임시 세션·외부 링크 확인은 항상 적용됩니다."
                    )
                )
            }

        case .browser:
            settingsCard(
                title: L10n.string(
                    "plugins.settings.options",
                    defaultValue: "플러그인 옵션"
                )
            ) {
                settingRow(
                    title: L10n.string(
                        "plugins.settings.search_engine",
                        defaultValue: "기본 검색 엔진"
                    ),
                    detail: L10n.string(
                        "plugins.settings.search_engine_detail",
                        defaultValue: "주소창에 검색어를 입력했을 때 사용할 서비스를 정합니다."
                    )
                ) {
                    Picker("", selection: $draft.browserSearchEngine) {
                        ForEach(PluginWebSearchEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .accessibilityLabel(L10n.string(
                        "plugins.settings.search_engine",
                        defaultValue: "기본 검색 엔진"
                    ))
                }

                cardDivider

                settingRow(
                    title: L10n.string(
                        "plugins.settings.browser_start_page",
                        defaultValue: "검색 시작 페이지 자동 열기"
                    ),
                    detail: L10n.string(
                        "plugins.settings.browser_start_page_detail",
                        defaultValue: "끄면 네트워크 연결 없이 빈 주소 패널로 시작합니다."
                    )
                ) {
                    Toggle("", isOn: $draft.browserLoadsStartPage)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel(L10n.string(
                            "plugins.settings.browser_start_page",
                            defaultValue: "검색 시작 페이지 자동 열기"
                        ))
                }

                cardDivider
                lockedSecurityRow(
                    L10n.string(
                        "plugins.settings.browser_security",
                        defaultValue: "공개 HTTPS 제한·임시 세션·업로드와 다운로드 차단은 항상 적용됩니다."
                    )
                )
            }

        case .generic:
            settingsCard(
                title: L10n.string(
                    "plugins.settings.options",
                    defaultValue: "플러그인 옵션"
                )
            ) {
                Label(
                    L10n.string(
                        "plugins.settings.no_custom_options",
                        defaultValue: "이 플러그인은 별도의 옵션을 제공하지 않습니다. 활성 상태와 권한은 이 화면에서 관리할 수 있습니다."
                    ),
                    systemImage: "slider.horizontal.3"
                )
                .font(.callout)
                .foregroundStyle(theme.secondaryText)
                .padding(.vertical, 2)
            }
        }
    }

    private var permissionsSection: some View {
        settingsCard(
            title: L10n.string("plugins.permissions.title", defaultValue: "허용 권한")
        ) {
            if plugin.manifest.capabilities.isEmpty {
                Label(
                    L10n.string("plugins.permissions.none", defaultValue: "문서 권한 없음"),
                    systemImage: "lock.fill"
                )
                .font(.callout)
            } else {
                ForEach(Array(plugin.manifest.capabilities.enumerated()), id: \.element.id) {
                    index, capability in
                    if index > 0 { cardDivider }
                    Label(capability.title, systemImage: capabilitySystemImage(capability))
                        .font(.callout)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    private var actionsSection: some View {
        settingsCard(
            title: L10n.string(
                "plugins.settings.actions",
                defaultValue: "제공하는 작업"
            )
        ) {
            ForEach(Array(plugin.manifest.actions.enumerated()), id: \.element.id) {
                index, action in
                if index > 0 { cardDivider }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: actionSystemImage(action.output))
                        .foregroundStyle(theme.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BundledPluginPresentation.actionTitle(action, in: plugin.manifest))
                            .font(.callout.weight(.medium))
                        if let description = BundledPluginPresentation.actionDescription(
                            action,
                            in: plugin.manifest
                        ) {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var informationSection: some View {
        settingsCard(
            title: L10n.string(
                "plugins.settings.information",
                defaultValue: "플러그인 정보"
            )
        ) {
            informationRow(
                L10n.string("plugins.settings.version", defaultValue: "버전"),
                value: plugin.manifest.version
            )
            cardDivider
            informationRow(
                L10n.string("plugins.settings.author", defaultValue: "제작자"),
                value: plugin.manifest.author
            )
            cardDivider
            informationRow(
                L10n.string("plugins.settings.identifier", defaultValue: "식별자"),
                value: plugin.manifest.identifier,
                monospaced: true
            )
            cardDivider
            HStack {
                Text(L10n.string("plugins.settings.installed", defaultValue: "설치일"))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Text(plugin.installedAt, style: .date)
            }
            .font(.caption)
        }
    }

    private var footer: some View {
        HStack {
            Button(
                L10n.string(
                    "plugins.settings.reset",
                    defaultValue: "기본값으로 재설정"
                )
            ) {
                draft = .default
            }
            .disabled(draft == .default)

            Spacer()

            Button(L10n.string("action.cancel", defaultValue: "취소"), action: onDismiss)
            Button(L10n.string("action.save", defaultValue: "저장"), action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
        .background(theme.panel)
    }

    private func settingsCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.border.opacity(0.8), lineWidth: 1)
            }
        }
    }

    private func settingRow<Control: View>(
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
    }

    private var cardDivider: some View {
        Divider().overlay(theme.border.opacity(0.8))
    }

    private func lockedSecurityRow(_ text: String) -> some View {
        Label(text, systemImage: "lock.shield.fill")
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func informationRow(
        _ title: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(theme.secondaryText)
            Spacer()
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    private var translationLanguageChoices: [(code: String, title: String)] {
        let followApp = (
            code: PluginPreferences.followAppLanguageCode,
            title: L10n.string(
                "plugins.settings.follow_app_language",
                defaultValue: "앱 언어 따르기"
            )
        )
        let fixed = PluginPreferences.supportedTranslationLanguageCodes
            .filter { $0 != PluginPreferences.followAppLanguageCode }
            .sorted { first, second in
                localizedLanguageName(first).localizedStandardCompare(
                    localizedLanguageName(second)
                ) == .orderedAscending
            }
            .map { (code: $0, title: localizedLanguageName($0)) }
        return [followApp] + fixed
    }

    private func localizedLanguageName(_ code: String) -> String {
        L10n.currentLanguage.locale.localizedString(forLanguageCode: code)
            ?? (code == "zh-CN"
                ? L10n.currentLanguage.locale.localizedString(forLanguageCode: "zh")
                : nil)
            ?? code
    }

    private var pluginSystemImage: String {
        switch configurationKind {
        case .translation: "character.bubble"
        case .youtube: "play.rectangle"
        case .browser: "globe"
        case .generic: "puzzlepiece.extension"
        }
    }

    private func capabilitySystemImage(_ capability: PluginCapability) -> String {
        switch capability {
        case .annotationWrite: "highlighter"
        case .toolControl: "pencil.tip"
        case .workspaceNavigation: "arrow.left.arrow.right"
        case .documentMetadata: "doc.text.magnifyingglass"
        case .selectedText: "text.cursor"
        case .currentPageText: "doc.text"
        case .clipboardWrite: "clipboard"
        case .externalURL: "safari"
        case .translationService: "character.bubble"
        case .youtubeContent: "play.rectangle"
        case .embeddedWebBrowser: "globe"
        }
    }

    private func actionSystemImage(_ output: PluginActionOutput) -> String {
        switch output {
        case .showText: "doc.plaintext"
        case .copyText: "clipboard"
        case .openURL: "arrow.up.right.square"
        case .translatePanel: "character.bubble"
        case .youtubePanel: "play.rectangle"
        case .browserPanel: "globe"
        case .documentCommand: "pencil.and.outline"
        }
    }

    private func save() {
        do {
            if currentPlugin.isEnabled != draftEnabled {
                try manager.setEnabled(draftEnabled, identifier: plugin.id)
            }
            try manager.setPreferences(draft, identifier: plugin.id)
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
