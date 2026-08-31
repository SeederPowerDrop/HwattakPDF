// SPDX-License-Identifier: MPL-2.0

import Foundation

enum PluginConfigurationKind: Equatable {
    case translation
    case youtube
    case browser
    case generic
}

enum PluginTranslationProvider: String, CaseIterable, Identifiable {
    case google
    case chatGPT
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google:
            L10n.string("plugins.translation.provider.google", defaultValue: "Google 번역")
        case .chatGPT:
            "ChatGPT"
        case .claude:
            "Claude"
        }
    }

    var homeURL: URL {
        switch self {
        case .google: URL(string: "https://translate.google.com/")!
        case .chatGPT: URL(string: "https://chatgpt.com/")!
        case .claude: URL(string: "https://claude.ai/new")!
        }
    }

    var allowedHosts: Set<String> {
        switch self {
        case .google:
            ["translate.google.com"]
        case .chatGPT:
            ["chatgpt.com", "auth.openai.com"]
        case .claude:
            ["claude.ai"]
        }
    }
}

enum PluginWebSearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckDuckGo
    case bing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        }
    }

    var homeURL: URL {
        switch self {
        case .google: URL(string: "https://www.google.com/")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com/")!
        case .bing: URL(string: "https://www.bing.com/")!
        }
    }

    var searchURL: URL {
        switch self {
        case .google: URL(string: "https://www.google.com/search")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com/")!
        case .bing: URL(string: "https://www.bing.com/search")!
        }
    }

    var queryItemName: String { "q" }
}

/// Host-owned preferences for declarative plug-ins. This deliberately lives
/// outside manifest.json: community packages cannot declare arbitrary controls
/// or use settings to weaken the host's consent, navigation, or WebKit policy.
struct PluginPreferences: Codable, Equatable {
    static let maximumPersistedBytes = 64 * 1_024
    static let followAppLanguageCode = "app"
    static let supportedTranslationLanguageCodes: Set<String> = [
        followAppLanguageCode,
        "ko", "en", "ja", "zh-CN", "fr", "de", "es", "pt", "vi", "ar"
    ]
    static let `default` = PluginPreferences()

    var translationProvider: PluginTranslationProvider
    var translationTargetLanguageCode: String
    var translationShowsSource: Bool
    var youtubeLoadsStartPage: Bool
    var browserSearchEngine: PluginWebSearchEngine
    var browserLoadsStartPage: Bool

    init(
        translationProvider: PluginTranslationProvider = .google,
        translationTargetLanguageCode: String = followAppLanguageCode,
        translationShowsSource: Bool = true,
        youtubeLoadsStartPage: Bool = true,
        browserSearchEngine: PluginWebSearchEngine = .google,
        browserLoadsStartPage: Bool = true
    ) {
        self.translationProvider = translationProvider
        self.translationTargetLanguageCode = Self.supportedTranslationLanguageCodes.contains(
            translationTargetLanguageCode
        ) ? translationTargetLanguageCode : Self.followAppLanguageCode
        self.translationShowsSource = translationShowsSource
        self.youtubeLoadsStartPage = youtubeLoadsStartPage
        self.browserSearchEngine = browserSearchEngine
        self.browserLoadsStartPage = browserLoadsStartPage
    }

    private enum CodingKeys: String, CodingKey {
        case translationProvider
        case translationTargetLanguageCode
        case translationShowsSource
        case youtubeLoadsStartPage
        case browserSearchEngine
        case browserLoadsStartPage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let providerRaw = try? values.decode(String.self, forKey: .translationProvider)
        let languageCode = (try? values.decode(
            String.self,
            forKey: .translationTargetLanguageCode
        )) ?? Self.followAppLanguageCode
        let searchEngineRaw = try? values.decode(String.self, forKey: .browserSearchEngine)
        self.init(
            translationProvider: providerRaw.flatMap(PluginTranslationProvider.init(rawValue:))
                ?? .google,
            translationTargetLanguageCode: languageCode,
            translationShowsSource: (try? values.decode(
                Bool.self,
                forKey: .translationShowsSource
            )) ?? true,
            youtubeLoadsStartPage: (try? values.decode(
                Bool.self,
                forKey: .youtubeLoadsStartPage
            )) ?? true,
            browserSearchEngine: searchEngineRaw.flatMap(PluginWebSearchEngine.init(rawValue:))
                ?? .google,
            browserLoadsStartPage: (try? values.decode(
                Bool.self,
                forKey: .browserLoadsStartPage
            )) ?? true
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(translationProvider.rawValue, forKey: .translationProvider)
        try values.encode(
            translationTargetLanguageCode,
            forKey: .translationTargetLanguageCode
        )
        try values.encode(translationShowsSource, forKey: .translationShowsSource)
        try values.encode(youtubeLoadsStartPage, forKey: .youtubeLoadsStartPage)
        try values.encode(browserSearchEngine.rawValue, forKey: .browserSearchEngine)
        try values.encode(browserLoadsStartPage, forKey: .browserLoadsStartPage)
    }
}

enum PluginManagerSearch {
    static func matches(_ manifest: PluginManifest, query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return [
            BundledPluginPresentation.displayName(for: manifest),
            BundledPluginPresentation.description(for: manifest),
            manifest.displayName,
            manifest.description,
            manifest.author,
            manifest.identifier,
            manifest.version
        ].contains { value in
            value.localizedCaseInsensitiveContains(normalized)
        }
    }
}
