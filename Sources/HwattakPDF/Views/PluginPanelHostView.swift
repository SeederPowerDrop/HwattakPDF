// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import WebKit

@MainActor
final class PluginWebSessionModel: ObservableObject {
    let scope: PluginWebNavigationScope

    @Published private(set) var currentURL: URL?
    @Published private(set) var pageTitle = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published var message: String?
    @Published var blockedURL: URL?

    private weak var webView: WKWebView?
    private var pendingURL: URL?

    init(scope: PluginWebNavigationScope) {
        self.scope = scope
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        if let pendingURL {
            self.pendingURL = nil
            load(pendingURL)
        }
        synchronize(from: webView)
    }

    func detach(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.stopLoading()
        self.webView = nil
        isLoading = false
    }

    func load(_ url: URL) {
        guard PluginWebURLPolicy.allows(url, scope: scope) else {
            block(url, reason: L10n.string(
                "plugins.panel.blocked_address",
                defaultValue: "주소창이나 상위 페이지에서는 공개 HTTPS 주소만 열 수 있습니다."
            ))
            return
        }
        message = nil
        blockedURL = nil
        currentURL = url
        guard let webView else {
            pendingURL = url
            return
        }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
        if scope == .youtube,
           ["youtube-nocookie.com", "www.youtube-nocookie.com"]
            .contains(url.host?.lowercased() ?? "") {
            // YouTube's embedded-player requirements reject empty referrers in
            // WebViews. Use a fixed app identity and never PDF/user text.
            request.setValue(
                PluginWebURLPolicy.appIdentityReferer().absoluteString,
                forHTTPHeaderField: "Referer"
            )
        }
        webView.load(request)
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }

    func didStart(_ webView: WKWebView) {
        isLoading = true
        synchronize(from: webView)
    }

    func didFinish(_ webView: WKWebView) {
        isLoading = false
        synchronize(from: webView)
    }

    func didFail(_ webView: WKWebView, error: Error) {
        isLoading = false
        synchronize(from: webView)
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        message = error.localizedDescription
    }

    func block(_ url: URL?, reason: String) {
        blockedURL = url
        message = reason
    }

    private func synchronize(from webView: WKWebView) {
        currentURL = webView.url ?? currentURL
        pageTitle = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

struct PluginPanelHostView: View {
    let request: PluginPanelRequest
    let onClose: () -> Void

    @EnvironmentObject private var pluginManager: PluginManager
    @Environment(\.colorScheme) private var colorScheme
    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    private var preferences: PluginPreferences {
        let configurationKind = pluginManager.configurationKind(
            identifier: request.pluginIdentifier,
            manifestDigest: request.manifestDigest
        )
        let matchesTrustedKind: Bool
        switch (request.kind, configurationKind) {
        case (.translation, .translation), (.youtube, .youtube), (.browser, .browser):
            matchesTrustedKind = true
        default:
            matchesTrustedKind = false
        }
        return matchesTrustedKind
            ? pluginManager.preferences(for: request.pluginIdentifier)
            : .default
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: request.kind.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(request.pluginName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(request.title)
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(L10n.string("action.close", defaultValue: "닫기"))
                .accessibilityLabel(L10n.string("action.close", defaultValue: "닫기"))
            }
            .padding(.horizontal, 13)
            .frame(height: 48)
            .background(theme.panel)

            Divider().overlay(theme.border)

            Group {
                switch request.kind {
                case .translation:
                    PluginTranslationPanel(
                        request: request,
                        preferences: preferences
                    )
                case .youtube:
                    PluginBrowserPanel(
                        request: request,
                        mode: .youtube,
                        preferences: preferences
                    )
                case .browser:
                    PluginBrowserPanel(
                        request: request,
                        mode: .browser,
                        preferences: preferences
                    )
                }
            }
            // A new action request must create a fresh panel state even when it
            // has the same kind as the currently visible panel. Otherwise the
            // previous @State source text or WebKit session can survive under a
            // new header and send/display stale user data.
            .id(request.id)
        }
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
    }
}

private enum PluginBrowserPanelMode {
    case youtube
    case browser

    var scope: PluginWebNavigationScope {
        self == .youtube ? .youtube : .publicWeb
    }

    var placeholder: String {
        switch self {
        case .youtube:
            L10n.string(
                "plugins.youtube.search_placeholder",
                defaultValue: "YouTube 검색어 또는 영상 주소"
            )
        case .browser:
            L10n.string(
                "plugins.browser.address_placeholder",
                defaultValue: "검색어 또는 HTTPS 주소"
            )
        }
    }
}

private struct PluginBrowserPanel: View {
    let request: PluginPanelRequest
    let mode: PluginBrowserPanelMode
    let preferences: PluginPreferences

    @StateObject private var session: PluginWebSessionModel
    @State private var address = ""
    @Environment(\.colorScheme) private var colorScheme
    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    init(
        request: PluginPanelRequest,
        mode: PluginBrowserPanelMode,
        preferences: PluginPreferences
    ) {
        self.request = request
        self.mode = mode
        self.preferences = preferences
        _session = StateObject(
            wrappedValue: PluginWebSessionModel(scope: mode.scope)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            browserControls
            if let message = session.message {
                blockedBanner(message)
            }
            SecurePluginWebView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            let loadsStartPage = mode == .youtube
                ? preferences.youtubeLoadsStartPage
                : preferences.browserLoadsStartPage
            guard loadsStartPage else { return }
            let initialURL = mode == .youtube
                ? request.initialURL
                : preferences.browserSearchEngine.homeURL
            if let initialURL {
                address = initialURL.absoluteString
                session.load(
                    mode == .youtube
                        ? (PluginWebURLPolicy.privacyEnhancedYouTubeURL(from: initialURL) ?? initialURL)
                        : initialURL
                )
            }
        }
        .onChange(of: session.currentURL) { _, newValue in
            if let newValue { address = newValue.absoluteString }
        }
        .onDisappear { session.stop() }
    }

    private var browserControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Button(action: session.goBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!session.canGoBack)
                .help(L10n.string("action.back", defaultValue: "뒤로"))
                .accessibilityLabel(L10n.string("action.back", defaultValue: "뒤로"))

                Button(action: session.goForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!session.canGoForward)
                .help(L10n.string("action.forward", defaultValue: "앞으로"))
                .accessibilityLabel(L10n.string("action.forward", defaultValue: "앞으로"))

                Button(action: session.isLoading ? session.stop : session.reload) {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                }
                .help(
                    session.isLoading
                        ? L10n.string("action.stop", defaultValue: "불러오기 중지")
                        : L10n.string("action.reload", defaultValue: "새로 고침")
                )
                .accessibilityLabel(
                    session.isLoading
                        ? L10n.string("action.stop", defaultValue: "불러오기 중지")
                        : L10n.string("action.reload", defaultValue: "새로 고침")
                )

                TextField(mode.placeholder, text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(openAddress)

                Button(action: openAddress) {
                    Image(systemName: mode == .youtube ? "play.fill" : "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(L10n.string("action.open", defaultValue: "열기"))
                .accessibilityLabel(L10n.string("action.open", defaultValue: "열기"))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                Text(
                    mode == .youtube
                        ? L10n.string(
                            "plugins.youtube.privacy",
                            defaultValue: "영상은 가능하면 YouTube 개인정보 보호 강화 모드로 재생됩니다."
                        )
                        : L10n.string(
                            "plugins.browser.privacy",
                            defaultValue: "주소창과 상위 페이지 이동은 공개 HTTPS로 제한합니다. 하위 리소스·fetch·WebSocket·DNS를 막는 추적 방지기나 방화벽은 아닙니다."
                        )
                )
                .lineLimit(2)
                Spacer()
                if let url = session.currentURL,
                   PluginWebURLPolicy.allows(url, scope: .publicWeb) {
                    Button {
                        confirmOpenExternally(url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string(
                        "plugins.panel.open_external",
                        defaultValue: "기본 브라우저에서 열기"
                    ))
                    .accessibilityLabel(L10n.string(
                        "plugins.panel.open_external",
                        defaultValue: "기본 브라우저에서 열기"
                    ))
                }
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)
        }
        .padding(10)
        .background(theme.panel)
        .overlay(alignment: .bottom) {
            if session.isLoading {
                ProgressView().controlSize(.small).padding(.bottom, 2)
            }
        }
    }

    private func blockedBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(theme.warning)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                session.message = nil
                session.blockedURL = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help(L10n.string("plugins.panel.dismiss_message", defaultValue: "메시지 닫기"))
            .accessibilityLabel(L10n.string(
                "plugins.panel.dismiss_message",
                defaultValue: "메시지 닫기"
            ))
        }
        .padding(9)
        .background(theme.card)
    }

    private func openAddress() {
        let destination = mode == .youtube
            ? PluginWebURLPolicy.youtubeDestination(from: address)
            : PluginWebURLPolicy.publicWebDestination(
                from: address,
                searchEngine: preferences.browserSearchEngine
            )
        guard let destination else {
            session.message = L10n.string(
                "plugins.panel.invalid_address",
                defaultValue: "열 수 없는 주소입니다. 공개 HTTPS 주소나 검색어를 입력하세요."
            )
            return
        }
        session.load(destination)
    }

    private func confirmOpenExternally(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string(
            "plugins.external_url.title",
            defaultValue: "외부 링크를 열까요?"
        )
        alert.informativeText = L10n.format(
            "plugins.panel.external_confirmation",
            PluginWebURLPolicy.originDescription(for: url)
        )
        alert.addButton(withTitle: L10n.string("action.open", defaultValue: "열기"))
        alert.addButton(withTitle: L10n.string("action.cancel", defaultValue: "취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = NSWorkspace.shared.open(url)
    }
}

private struct TranslationTarget: Hashable, Identifiable {
    let code: String
    var id: String { code }

    var title: String {
        L10n.currentLanguage.locale.localizedString(forLanguageCode: code)
            ?? fallbackLanguage?.nativeName
            ?? code
    }

    private var fallbackLanguage: AppLanguage? {
        if code == "zh-CN" { return .simplifiedChinese }
        return AppLanguage(rawValue: code)
    }

    static let all: [Self] = [
        .init(code: "ko"),
        .init(code: "en"),
        .init(code: "ja"),
        .init(code: "zh-CN"),
        .init(code: "fr"),
        .init(code: "de"),
        .init(code: "es"),
        .init(code: "pt"),
        .init(code: "vi"),
        .init(code: "ar")
    ]

    static var preferred: Self {
        let desiredCode: String
        switch L10n.currentLanguage {
        case .korean: desiredCode = "ko"
        case .english: desiredCode = "en"
        case .french: desiredCode = "fr"
        case .german: desiredCode = "de"
        case .spanish: desiredCode = "es"
        case .japanese: desiredCode = "ja"
        case .simplifiedChinese: desiredCode = "zh-CN"
        case .arabic: desiredCode = "ar"
        case .portuguese: desiredCode = "pt"
        case .vietnamese: desiredCode = "vi"
        }
        return all.first(where: { $0.code == desiredCode }) ?? all[0]
    }
}

private struct PendingTranslationRequest: Identifiable {
    let id = UUID()
    let provider: PluginTranslationProvider
    let target: TranslationTarget
    let text: String
}

private struct TranslationWebDestination: Identifiable {
    let id = UUID()
    let provider: PluginTranslationProvider
    let url: URL
}

private struct PluginTranslationPanel: View {
    let request: PluginPanelRequest
    let preferences: PluginPreferences

    @State private var provider: PluginTranslationProvider
    @State private var target: TranslationTarget
    @State private var sourceText: String
    @State private var showingSource: Bool
    @State private var pendingTranslation: PendingTranslationRequest?
    @State private var statusMessage: String?
    @State private var webDestination: TranslationWebDestination?
    @Environment(\.colorScheme) private var colorScheme
    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    init(request: PluginPanelRequest, preferences: PluginPreferences) {
        self.request = request
        self.preferences = preferences
        _provider = State(initialValue: preferences.translationProvider)
        _target = State(
            initialValue: TranslationTarget.all.first(where: {
                $0.code == preferences.translationTargetLanguageCode
            }) ?? .preferred
        )
        _sourceText = State(initialValue: request.sourceText ?? "")
        _showingSource = State(initialValue: preferences.translationShowsSource)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    L10n.string("plugins.translation.service_picker", defaultValue: "번역 서비스"),
                    selection: $provider
                ) {
                    ForEach(PluginTranslationProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Picker(
                        L10n.string("plugins.translation.language_picker", defaultValue: "번역 언어"),
                        selection: $target
                    ) {
                        ForEach(TranslationTarget.all) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .labelsHidden()

                    Button {
                        prepareTranslation()
                    } label: {
                        Label(
                            L10n.string("plugins.translation.open", defaultValue: "번역 열기"),
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                DisclosureGroup(isExpanded: $showingSource) {
                    TextEditor(text: $sourceText)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 78, idealHeight: 115, maxHeight: 150)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.border, lineWidth: 1)
                        }
                } label: {
                    HStack {
                        Text(
                            request.includesCurrentPageText
                                ? L10n.string(
                                    "plugins.translation.source.page",
                                    defaultValue: "현재 페이지 텍스트"
                                )
                                : L10n.string(
                                    "plugins.translation.source.selection",
                                    defaultValue: "선택한 문장"
                                )
                        )
                        Spacer()
                        Text(L10n.format("plugins.translation.character_count", sourceText.count))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                Label(
                    L10n.string(
                        "plugins.translation.privacy",
                        defaultValue: "버튼을 누르기 전에는 PDF 텍스트가 외부 서비스로 전송되지 않습니다."
                    ),
                    systemImage: "hand.raised.fill"
                )
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(11)
            .background(theme.panel)

            Divider().overlay(theme.border)

            if let webDestination {
                TranslationWebSurface(destination: webDestination)
                    .id(webDestination.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    L10n.string(
                        "plugins.translation.empty.title",
                        defaultValue: "번역 서비스를 선택하세요"
                    ),
                    systemImage: "character.bubble",
                    description: Text(L10n.string(
                        "plugins.translation.empty.detail",
                        defaultValue: "보낼 내용을 확인한 뒤 ‘번역 열기’를 누르세요."
                    ))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert(
            L10n.string(
                "plugins.translation.consent.title",
                defaultValue: "PDF 텍스트를 외부로 보낼까요?"
            ),
            isPresented: Binding(
                get: { pendingTranslation != nil },
                set: { if !$0 { pendingTranslation = nil } }
            ),
            presenting: pendingTranslation
        ) { pending in
            Button(L10n.string("action.cancel", defaultValue: "취소"), role: .cancel) {
                pendingTranslation = nil
            }
            Button(L10n.format(
                "plugins.translation.consent.open_provider",
                pending.provider.title
            )) {
                pendingTranslation = nil
                open(pending)
            }
        } message: { pending in
            Text(translationDisclosure(for: pending))
        }
    }

    private func prepareTranslation() {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = EncodedTextLimiter.limit(
            trimmed,
            budget: HwattakPluginLimits.renderedTextBudget
        )
        guard !trimmed.isEmpty, !limited.wasTruncated else {
            statusMessage = L10n.string(
                "plugins.translation.error.empty_or_large",
                defaultValue: "번역할 텍스트가 없거나 안전한 크기 제한을 초과했습니다."
            )
            return
        }
        pendingTranslation = PendingTranslationRequest(
            provider: provider,
            target: target,
            text: limited.text
        )
    }

    private func open(_ pending: PendingTranslationRequest) {
        showingSource = false
        switch pending.provider {
        case .google:
            var components = URLComponents(
                url: pending.provider.homeURL,
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "sl", value: "auto"),
                URLQueryItem(name: "tl", value: pending.target.code),
                URLQueryItem(name: "text", value: pending.text),
                URLQueryItem(name: "op", value: "translate")
            ]
            guard let url = components?.url,
                  url.absoluteString.utf8.count <= HwattakPluginLimits.maximumExternalURLUTF8Bytes else {
                showingSource = true
                statusMessage = L10n.string(
                    "plugins.translation.error.google_url_too_long",
                    defaultValue: "현재 텍스트는 Google 번역 주소 제한을 넘습니다. 전체 페이지는 ChatGPT 또는 Claude를 선택해 주세요."
                )
                return
            }
            guard PluginWebURLPolicy.allows(
                url,
                scope: .exactHosts(pending.provider.allowedHosts)
            ) else {
                statusMessage = L10n.string(
                    "plugins.translation.error.google_url",
                    defaultValue: "Google 번역 주소를 만들지 못했습니다."
                )
                return
            }
            statusMessage = L10n.string(
                "plugins.translation.status.google_sent",
                defaultValue: "Google 번역에 확인한 텍스트를 보냈습니다."
            )
            webDestination = TranslationWebDestination(
                provider: pending.provider,
                url: url
            )
        case .chatGPT, .claude:
            let prompt = """
            Translate the following text into \(pending.target.title). Preserve headings, lists, equations, and paragraph breaks. Return only the translation unless a short clarification is essential.

            \(pending.text)
            """
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(prompt, forType: .string) else {
                statusMessage = L10n.string(
                    "plugins.translation.error.clipboard",
                    defaultValue: "번역 프롬프트를 클립보드에 복사하지 못했습니다."
                )
                return
            }
            statusMessage = L10n.format(
                "plugins.translation.status.prompt_copied",
                pending.provider.title
            )
            webDestination = TranslationWebDestination(
                provider: pending.provider,
                url: pending.provider.homeURL
            )
        }
    }

    private func translationDisclosure(for pending: PendingTranslationRequest) -> String {
        let bytes = pending.text.utf8.count
        let host = pending.provider.homeURL.host ?? pending.provider.title
        switch pending.provider {
        case .google:
            return L10n.format(
                "plugins.translation.disclosure.google",
                pending.text.count,
                bytes,
                host
            )
        case .chatGPT, .claude:
            return L10n.format(
                "plugins.translation.disclosure.clipboard",
                pending.text.count,
                bytes,
                host
            )
        }
    }
}

private struct TranslationWebSurface: View {
    let destination: TranslationWebDestination

    @StateObject private var session: PluginWebSessionModel
    @Environment(\.colorScheme) private var colorScheme
    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    init(destination: TranslationWebDestination) {
        self.destination = destination
        _session = StateObject(
            wrappedValue: PluginWebSessionModel(
                scope: .exactHosts(destination.provider.allowedHosts)
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text(destination.provider.title)
                    .fontWeight(.semibold)
                Text(destination.url.host ?? "")
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Spacer()
                if session.isLoading {
                    ProgressView().controlSize(.small)
                }
                if destination.provider != .google {
                    Button {
                        openInDefaultBrowser()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string(
                        "plugins.panel.open_external",
                        defaultValue: "기본 브라우저에서 열기"
                    ))
                    .accessibilityLabel(L10n.string(
                        "plugins.panel.open_external",
                        defaultValue: "기본 브라우저에서 열기"
                    ))
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(theme.panel)

            if let message = session.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.card)
            }

            SecurePluginWebView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { session.load(destination.url) }
        .onDisappear { session.stop() }
    }

    private func openInDefaultBrowser() {
        guard PluginWebURLPolicy.allows(
            destination.url,
            scope: .exactHosts(destination.provider.allowedHosts)
        ) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string(
            "plugins.panel.default_browser.title",
            defaultValue: "기본 브라우저에서 열까요?"
        )
        alert.informativeText = L10n.format(
            "plugins.panel.default_browser.continue",
            PluginWebURLPolicy.originDescription(for: destination.url)
        )
        alert.addButton(withTitle: L10n.string("action.open", defaultValue: "열기"))
        alert.addButton(withTitle: L10n.string("action.cancel", defaultValue: "취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(destination.url)
    }
}

/// `WKUIDelegate.runOpenPanel` blocks file-input controls, but WebKit can also
/// expose local files to page JavaScript through HTML drag-and-drop. Refusing
/// every drag at the native view boundary prevents a PDF intended for the
/// workspace from being handed to an untrusted web page instead.
private final class PluginSecureWKWebView: WKWebView {
    var didRejectDrop: (() -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        didRejectDrop?()
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        false
    }

    func revokeFileDropRegistrations() {
        Self.unregisterDropDestinations(in: self)
    }

    private static func unregisterDropDestinations(in view: NSView) {
        view.unregisterDraggedTypes()
        view.subviews.forEach(unregisterDropDestinations)
    }
}

private struct SecurePluginWebView: NSViewRepresentable {
    typealias NSViewType = PluginSecureWKWebView

    @ObservedObject var session: PluginWebSessionModel

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> PluginSecureWKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        // This fixed host script carries no PDF data and exposes no native
        // bridge. It runs before page handlers, intercepting HTML5 file drops
        // even when WebKit's private content view (rather than WKWebView) is
        // selected as the native dragging destination.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: """
                (() => {
                  const rejectFiles = (event) => {
                    const types = Array.from(event.dataTransfer?.types || []);
                    if (!types.includes('Files')) return;
                    event.preventDefault();
                    event.stopImmediatePropagation();
                    event.dataTransfer.dropEffect = 'none';
                  };
                  for (const type of ['dragenter', 'dragover', 'drop']) {
                    window.addEventListener(type, rejectFiles, true);
                  }
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        let webView = PluginSecureWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.didRejectDrop = {
            session.message = L10n.string(
                "plugins.panel.file_drop_blocked",
                defaultValue: "웹 패널에는 파일을 놓을 수 없습니다. PDF를 열려면 문서 화면이나 사이드바에 놓으세요."
            )
        }
        webView.revokeFileDropRegistrations()
        DispatchQueue.main.async { [weak webView] in
            webView?.revokeFileDropRegistrations()
        }
        session.attach(webView)
        return webView
    }

    func updateNSView(_ webView: PluginSecureWKWebView, context: Context) {
        context.coordinator.session = session
        webView.didRejectDrop = {
            session.message = L10n.string(
                "plugins.panel.file_drop_blocked",
                defaultValue: "웹 패널에는 파일을 놓을 수 없습니다. PDF를 열려면 문서 화면이나 사이드바에 놓으세요."
            )
        }
    }

    static func dismantleNSView(
        _ webView: PluginSecureWKWebView,
        coordinator: Coordinator
    ) {
        coordinator.session.detach(webView)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.didRejectDrop = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var session: PluginWebSessionModel

        init(session: PluginWebSessionModel) {
            self.session = session
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            guard !navigationAction.shouldPerformDownload else {
                session.block(
                    url,
                    reason: L10n.string(
                        "plugins.panel.download_blocked",
                        defaultValue: "다운로드는 플러그인 패널에서 차단됩니다."
                    )
                )
                decisionHandler(.cancel)
                return
            }
            if session.scope == .youtube,
               navigationAction.navigationType == .linkActivated {
                // A real click is the only route allowed to leave the panel.
                // A nil target belongs to createWebViewWith; allow that
                // delegate callback to own the route exactly once. Main-frame
                // and in-frame clicks are cancelled here before host routing.
                if navigationAction.targetFrame == nil {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                handleYouTubeUserLink(url)
                return
            }
            guard PluginWebURLPolicy.allows(url, scope: session.scope) else {
                session.block(
                    url,
                    reason: L10n.string(
                        "plugins.panel.navigation_blocked",
                        defaultValue: "주소창이나 상위 페이지에서 허용되지 않는 주소로 이동해 차단했습니다."
                    )
                )
                decisionHandler(.cancel)
                return
            }
            if session.scope == .youtube,
               navigationAction.targetFrame?.isMainFrame == true,
               let privateURL = PluginWebURLPolicy.privacyEnhancedYouTubeURL(from: url),
               privateURL != url {
                decisionHandler(.cancel)
                session.load(privateURL)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            guard let responseURL = navigationResponse.response.url,
                  PluginWebURLPolicy.allows(responseURL, scope: session.scope) else {
                session.block(
                    navigationResponse.response.url,
                    reason: L10n.string(
                        "plugins.panel.navigation_blocked",
                        defaultValue: "상위 페이지 응답이 허용되지 않은 주소로 이동해 차단했습니다."
                    )
                )
                decisionHandler(.cancel)
                return
            }
            if let httpResponse = navigationResponse.response as? HTTPURLResponse,
               httpResponse.value(forHTTPHeaderField: "Content-Disposition")?
                .localizedCaseInsensitiveContains("attachment") == true {
                session.block(
                    responseURL,
                    reason: L10n.string(
                        "plugins.panel.download_blocked",
                        defaultValue: "파일 다운로드 응답을 차단했습니다."
                    )
                )
                decisionHandler(.cancel)
                return
            }
            if navigationResponse.response.mimeType?.lowercased()
                == "application/octet-stream" {
                session.block(
                    responseURL,
                    reason: L10n.string(
                        "plugins.panel.download_blocked",
                        defaultValue: "바이너리 다운로드 응답을 차단했습니다."
                    )
                )
                decisionHandler(.cancel)
                return
            }
            guard navigationResponse.canShowMIMEType else {
                session.block(
                    navigationResponse.response.url,
                    reason: L10n.string(
                        "plugins.panel.download_blocked",
                        defaultValue: "표시할 수 없는 파일과 다운로드는 플러그인 패널에서 차단됩니다."
                    )
                )
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            (webView as? PluginSecureWKWebView)?.revokeFileDropRegistrations()
            session.didStart(webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            session.didStart(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            (webView as? PluginSecureWKWebView)?.revokeFileDropRegistrations()
            session.didFinish(webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            session.didFail(webView, error: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            session.didFail(webView, error: error)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else {
                return nil
            }
            if navigationAction.shouldPerformDownload {
                session.block(
                    url,
                    reason: L10n.string(
                        "plugins.panel.download_blocked",
                        defaultValue: "다운로드는 플러그인 패널에서 차단됩니다."
                    )
                )
                return nil
            }
            if session.scope == .youtube,
               navigationAction.navigationType == .linkActivated {
                handleYouTubeUserLink(url)
                return nil
            }
            session.block(
                url,
                reason: L10n.string(
                    "plugins.panel.popup_blocked",
                    defaultValue: "새 창 열기는 차단했습니다. 필요하면 현재 주소를 기본 브라우저에서 여세요."
                )
            )
            return nil
        }

        private func handleYouTubeUserLink(_ url: URL) {
            switch PluginWebURLPolicy.youtubeUserLinkRoute(for: url) {
            case let .playInPanel(privateURL):
                session.load(privateURL)
            case let .openExternally(externalURL):
                confirmOpenYouTubeLinkExternally(externalURL)
            case .blocked:
                session.block(
                    url,
                    reason: L10n.string(
                        "plugins.panel.navigation_blocked",
                        defaultValue: "주소창이나 상위 페이지에서 허용되지 않는 주소로 이동해 차단했습니다."
                    )
                )
            }
        }

        private func confirmOpenYouTubeLinkExternally(_ url: URL) {
            guard case .openExternally = PluginWebURLPolicy.youtubeUserLinkRoute(
                for: url
            ) else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string(
                "plugins.external_url.title",
                defaultValue: "외부 링크를 열까요?"
            )
            alert.informativeText = L10n.format(
                "plugins.panel.external_confirmation",
                PluginWebURLPolicy.originDescription(for: url)
            )
            alert.addButton(withTitle: L10n.string("action.open", defaultValue: "열기"))
            alert.addButton(withTitle: L10n.string("action.cancel", defaultValue: "취소"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = NSWorkspace.shared.open(url)
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            session.message = L10n.string(
                "plugins.panel.file_upload_blocked",
                defaultValue: "플러그인 웹 패널에서는 파일 업로드를 허용하지 않습니다."
            )
            completionHandler(nil)
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            session.message = L10n.string(
                "plugins.panel.media_capture_blocked",
                defaultValue: "플러그인 웹 패널에서는 카메라와 마이크를 허용하지 않습니다."
            )
            decisionHandler(.deny)
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (
                URLSession.AuthChallengeDisposition,
                URLCredential?
            ) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            authenticationChallenge challenge: URLAuthenticationChallenge,
            shouldAllowDeprecatedTLS decisionHandler: @escaping (Bool) -> Void
        ) {
            decisionHandler(false)
        }
    }
}
