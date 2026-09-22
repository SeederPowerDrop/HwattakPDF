// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Hard ceilings for the first HwattakPDF plug-in API.
///
/// V1 plug-ins are declarative manifests, not executable bundles. Keeping every
/// value bounded lets the host validate and retain a complete registry without
/// creating an unbounded memory or CPU surface at launch.
enum HwattakPluginLimits {
    /// Schema 1 remains readable so existing declarative text plug-ins keep
    /// working. Schema 2 adds only host-owned companion panels; plug-ins still
    /// cannot ship or execute code.
    static let legacyManifestSchemaVersion = 1
    static let manifestSchemaVersion = 3
    static let supportedManifestSchemaVersions: Set<Int> = [
        legacyManifestSchemaVersion,
        2,
        manifestSchemaVersion
    ]
    static let installationRecordSchemaVersion = 1
    static let maximumInstalledPluginCount = 32
    static let maximumActionsPerPlugin = 24
    static let maximumPackageFileCount = 5
    static let maximumPackageBytes = 2 * 1_024 * 1_024
    static let maximumManifestBytes = 128 * 1_024
    static let maximumAuxiliaryFileBytes = 1 * 1_024 * 1_024
    static let maximumTemplateUTF8Bytes = 16 * 1_024
    static let maximumRenderedCharacters = 16_000
    static let maximumRenderedUTF8Bytes = 64 * 1_024
    static let maximumExternalURLUTF8Bytes = 4 * 1_024

    static let renderedTextBudget = EncodedTextBudget(
        maximumCharacters: maximumRenderedCharacters,
        maximumUTF8Bytes: maximumRenderedUTF8Bytes,
        maximumUTF16CodeUnits: maximumRenderedCharacters * 8
    )
}

enum PluginCapability: String, CaseIterable, Codable, Hashable, Identifiable {
    case annotationWrite
    case toolControl
    case workspaceNavigation
    case documentMetadata
    case selectedText
    case currentPageText
    case clipboardWrite
    case externalURL
    case translationService
    case youtubeContent
    case embeddedWebBrowser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .annotationWrite: L10n.string("plugins.permission.annotation_write")
        case .toolControl: L10n.string("plugins.permission.tool_control")
        case .workspaceNavigation: L10n.string("plugins.permission.workspace_navigation")
        case .documentMetadata:
            L10n.string(
                "plugins.permission.document_metadata",
                defaultValue: "문서 이름·페이지 정보 읽기"
            )
        case .selectedText:
            L10n.string(
                "plugins.permission.selected_text",
                defaultValue: "사용자가 선택한 텍스트 읽기"
            )
        case .currentPageText:
            L10n.string(
                "plugins.permission.current_page_text",
                defaultValue: "현재 페이지의 텍스트 읽기"
            )
        case .clipboardWrite:
            L10n.string(
                "plugins.permission.clipboard",
                defaultValue: "클립보드에 텍스트 쓰기"
            )
        case .externalURL:
            L10n.string(
                "plugins.permission.external_url",
                defaultValue: "확인 후 외부 HTTPS 링크 열기"
            )
        case .translationService:
            L10n.string(
                "plugins.permission.translation_service",
                defaultValue: "확인한 텍스트를 외부 번역 서비스와 사용"
            )
        case .youtubeContent:
            L10n.string(
                "plugins.permission.youtube_content",
                defaultValue: "임시 패널에서 YouTube 검색·재생"
            )
        case .embeddedWebBrowser:
            L10n.string(
                "plugins.permission.embedded_browser",
                defaultValue: "임시 패널에서 임의의 공개 HTTPS 웹사이트 열기"
            )
        }
    }
}

enum PluginActionOutput: String, Codable, Equatable {
    case documentCommand
    /// Shows bounded, host-rendered text in a standard dialog.
    case showText
    /// Writes bounded plain text to the general pasteboard.
    case copyText
    /// Opens a public HTTPS URL only after a per-invocation host confirmation.
    case openURL
    /// Prepares bounded PDF text for a host-owned translation companion.
    case translatePanel
    /// Opens a YouTube-only study companion owned and filtered by the host.
    case youtubePanel
    /// Opens a public-HTTPS browser companion owned and filtered by the host.
    case browserPanel
}

enum PluginPanelKind: String, Equatable {
    case translation
    case youtube
    case browser

    var systemImage: String {
        switch self {
        case .translation: "character.bubble"
        case .youtube: "play.rectangle"
        case .browser: "globe"
        }
    }
}

/// Immutable, bounded values passed from the declarative action runner to the
/// host-owned UI. No PDFKit object or plug-in code crosses this boundary.
struct PluginPanelRequest: Identifiable, Equatable {
    let id: UUID
    let pluginIdentifier: String
    let manifestDigest: String
    let documentRevision: UUID
    let pluginName: String
    let actionID: String
    let title: String
    let kind: PluginPanelKind
    let initialURL: URL?
    let sourceText: String?
    let includesSelectedText: Bool
    let includesCurrentPageText: Bool

    init(
        id: UUID = UUID(),
        pluginIdentifier: String,
        manifestDigest: String,
        documentRevision: UUID,
        pluginName: String,
        actionID: String,
        title: String,
        kind: PluginPanelKind,
        initialURL: URL? = nil,
        sourceText: String? = nil,
        includesSelectedText: Bool = false,
        includesCurrentPageText: Bool = false
    ) {
        self.id = id
        self.pluginIdentifier = pluginIdentifier
        self.manifestDigest = manifestDigest
        self.documentRevision = documentRevision
        self.pluginName = pluginName
        self.actionID = actionID
        self.title = title
        self.kind = kind
        self.initialURL = initialURL
        self.sourceText = sourceText
        self.includesSelectedText = includesSelectedText
        self.includesCurrentPageText = includesCurrentPageText
    }
}

struct PluginActionManifest: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let output: PluginActionOutput
    let template: String
    var command: PluginDocumentCommand? = nil
}

struct PluginManifest: Codable, Equatable {
    let schemaVersion: Int
    let identifier: String
    let displayName: String
    let version: String
    let author: String
    let description: String
    let minimumHostVersion: String?
    let capabilities: [PluginCapability]
    let actions: [PluginActionManifest]
}

/// The three privileged panel manifests are immutable app resources, so their
/// human-facing copy can use the host's existing ten-language catalog without
/// adding executable localization files to an untrusted package format.
enum BundledPluginPresentation {
    private enum OfficialPluginKind {
        case translation
        case youtube
        case browser
    }

    static func displayName(for manifest: PluginManifest) -> String {
        switch officialPluginKind(for: manifest) {
        case .translation:
            L10n.string(
                "plugins.bundled.translation.name",
                defaultValue: manifest.displayName
            )
        case .youtube:
            L10n.string(
                "plugins.bundled.youtube.name",
                defaultValue: manifest.displayName
            )
        case .browser:
            L10n.string(
                "plugins.bundled.browser.name",
                defaultValue: manifest.displayName
            )
        case nil:
            manifest.displayName
        }
    }

    static func description(for manifest: PluginManifest) -> String {
        switch officialPluginKind(for: manifest) {
        case .translation:
            L10n.string(
                "plugins.bundled.translation.description",
                defaultValue: manifest.description
            )
        case .youtube:
            L10n.string(
                "plugins.bundled.youtube.description",
                defaultValue: manifest.description
            )
        case .browser:
            L10n.string(
                "plugins.bundled.browser.description",
                defaultValue: manifest.description
            )
        case nil:
            manifest.description
        }
    }

    static func actionTitle(
        _ action: PluginActionManifest,
        in manifest: PluginManifest
    ) -> String {
        let key = actionLocalizationKey(action, in: manifest, suffix: "title")
        return key.map { L10n.string($0, defaultValue: action.title) } ?? action.title
    }

    static func actionDescription(
        _ action: PluginActionManifest,
        in manifest: PluginManifest
    ) -> String? {
        guard let fallback = action.description else { return nil }
        let key = actionLocalizationKey(action, in: manifest, suffix: "description")
        return key.map { L10n.string($0, defaultValue: fallback) } ?? fallback
    }

    private static func actionLocalizationKey(
        _ action: PluginActionManifest,
        in manifest: PluginManifest,
        suffix: String
    ) -> String? {
        // Never apply first-party wording from an identifier alone. In
        // addition to PluginManager's exact bundled-digest gate, require the
        // complete expected schema/action/capability shape and an action that
        // actually belongs to that manifest.
        guard manifest.actions.contains(action) else { return nil }
        return switch (officialPluginKind(for: manifest), action.id) {
        case (.translation, "translate-selection"):
            "plugins.bundled.translation.selection.\(suffix)"
        case (.translation, "translate-current-page"):
            "plugins.bundled.translation.page.\(suffix)"
        case (.youtube, "open-youtube-study"):
            "plugins.bundled.youtube.open.\(suffix)"
        case (.browser, "open-web-browser"):
            "plugins.bundled.browser.open.\(suffix)"
        default:
            nil
        }
    }

    /// Semantic signature for first-party presentation. Package trust itself
    /// is enforced with the exact raw manifest digest in `PluginManager`; this
    /// second check prevents an untrusted schema/action shape from inheriting
    /// official localized copy merely by claiming a known identifier.
    private static func officialPluginKind(
        for manifest: PluginManifest
    ) -> OfficialPluginKind? {
        guard
            manifest.schemaVersion == 2,
            manifest.version == "1.0.0",
            manifest.minimumHostVersion == "0.8.0",
            manifest.author == "HwattakPDF"
        else {
            return nil
        }

        switch manifest.identifier {
        case "dev.hwattakpdf.plugins.translation-companion":
            let expectedCapabilities: Set<PluginCapability> = [
                .selectedText,
                .currentPageText,
                .clipboardWrite,
                .translationService
            ]
            guard
                manifest.capabilities.count == expectedCapabilities.count,
                Set(manifest.capabilities) == expectedCapabilities,
                manifest.actions.count == 2,
                actionShape(
                    manifest.actions[0],
                    id: "translate-selection",
                    output: .translatePanel,
                    template: "{{selection}}"
                ),
                actionShape(
                    manifest.actions[1],
                    id: "translate-current-page",
                    output: .translatePanel,
                    template: "{{page.text}}"
                )
            else { return nil }
            return .translation
        case "dev.hwattakpdf.plugins.youtube-study":
            guard
                manifest.capabilities.count == 1,
                Set(manifest.capabilities) == [.youtubeContent],
                manifest.actions.count == 1,
                actionShape(
                    manifest.actions[0],
                    id: "open-youtube-study",
                    output: .youtubePanel,
                    template: "https://www.youtube.com/"
                )
            else { return nil }
            return .youtube
        case "dev.hwattakpdf.plugins.web-browser":
            guard
                manifest.capabilities.count == 1,
                Set(manifest.capabilities) == [.embeddedWebBrowser],
                manifest.actions.count == 1,
                actionShape(
                    manifest.actions[0],
                    id: "open-web-browser",
                    output: .browserPanel,
                    template: "https://www.google.com/"
                )
            else { return nil }
            return .browser
        default:
            return nil
        }
    }

    private static func actionShape(
        _ action: PluginActionManifest,
        id: String,
        output: PluginActionOutput,
        template: String
    ) -> Bool {
        action.id == id && action.output == output && action.template == template
    }
}

struct PluginSemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let parsed = parts.compactMap { part -> Int? in
            guard
                !part.isEmpty,
                part.allSatisfy(\.isNumber),
                (part.count == 1 || part.first != "0"),
                let number = Int(part),
                number <= 999_999
            else { return nil }
            return number
        }
        guard parsed.count == 3 else { return nil }
        major = parsed[0]
        minor = parsed[1]
        patch = parsed[2]
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: PluginSemanticVersion, rhs: PluginSemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

enum PluginHost {
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.8.0"
    }
}

struct PluginPackageInspection: Identifiable {
    var id: String { "\(manifest.identifier)-\(manifestDigest)" }

    let sourceURL: URL
    let manifest: PluginManifest
    let manifestDigest: String
    let fileCount: Int
    let totalBytes: Int
    /// Validated package bytes captured while the security-scoped source is
    /// open. Installation writes these exact bytes, eliminating a source-file
    /// time-of-check/time-of-use gap.
    let filePayloads: [String: Data]
}

struct InstalledPlugin: Identifiable, Equatable {
    var id: String { manifest.identifier }

    let manifest: PluginManifest
    let installURL: URL
    let manifestDigest: String
    let installedAt: Date
    var isEnabled: Bool
}

struct PluginLoadIssue: Identifiable, Equatable {
    let id = UUID()
    let packageName: String
    let message: String
}

struct PluginInstallationRecord: Codable, Equatable {
    let schemaVersion: Int
    let manifestSHA256: String
    let installedAt: Date
}

enum PluginSystemError: LocalizedError {
    case invalidPackage(String)
    case invalidManifest(String)
    case incompatibleHost(required: String, current: String)
    case packageAlreadyInstalled(String)
    case packageChanged
    case pluginLimitReached(Int)
    case pluginNotFound(String)
    case installationFailed(String)
    case actionUnavailable(String)
    case actionFailed(String)
    case externalURLRejected
    case externalURLCancelled

    var errorDescription: String? {
        switch self {
        case let .invalidPackage(detail):
            L10n.format("plugins.error.invalid_package", detail)
        case let .invalidManifest(detail):
            L10n.format("plugins.error.invalid_manifest", detail)
        case let .incompatibleHost(required, current):
            L10n.format("plugins.error.incompatible", required, current)
        case let .packageAlreadyInstalled(name):
            L10n.format("plugins.error.already_installed", name)
        case .packageChanged:
            L10n.string(
                "plugins.error.package_changed",
                defaultValue: "검토 후 플러그인 패키지가 변경되었습니다. 다시 선택해 주세요."
            )
        case let .pluginLimitReached(limit):
            L10n.format("plugins.error.limit", limit)
        case let .pluginNotFound(identifier):
            L10n.format("plugins.error.not_found", identifier)
        case let .installationFailed(detail):
            L10n.format("plugins.error.install_failed", detail)
        case let .actionUnavailable(detail):
            L10n.format("plugins.error.action_unavailable", detail)
        case let .actionFailed(detail):
            L10n.format("plugins.error.action_failed", detail)
        case .externalURLRejected:
            L10n.string(
                "plugins.error.external_url_rejected",
                defaultValue: "공개 HTTPS 주소가 아니어서 링크를 열지 않았습니다."
            )
        case .externalURLCancelled:
            L10n.string(
                "plugins.error.external_url_cancelled",
                defaultValue: "외부 링크 열기를 취소했습니다."
            )
        }
    }
}

extension PluginActionManifest {
    var requiredCapabilities: Set<PluginCapability> {
        var result: Set<PluginCapability> = []
        if template.contains("{{selection}}")
            || template.contains("{{selection.urlEncoded}}")
        {
            result.insert(.selectedText)
        }
        if template.contains("{{document.name}}")
            || template.contains("{{document.name.urlEncoded}}")
            || template.contains("{{page.number}}")
            || template.contains("{{document.pageCount}}")
        {
            result.insert(.documentMetadata)
        }
        if template.contains("{{page.text}}")
            || template.contains("{{page.text.urlEncoded}}")
        {
            result.insert(.currentPageText)
        }
        switch output {
        case .documentCommand:
            if let command { result.insert(command.capability) }
        case .showText:
            break
        case .copyText:
            result.insert(.clipboardWrite)
        case .openURL:
            result.insert(.externalURL)
        case .translatePanel:
            // ChatGPT and Claude do not expose a stable URL-prefill contract.
            // The host copies a reviewed prompt before opening their page.
            result.formUnion([.clipboardWrite, .translationService])
        case .youtubePanel:
            result.insert(.youtubeContent)
        case .browserPanel:
            result.insert(.embeddedWebBrowser)
        }
        return result
    }

    var needsOpenDocument: Bool {
        switch output {
        case .documentCommand, .translatePanel, .youtubePanel, .browserPanel:
            return true
        case .showText, .copyText, .openURL:
            return !requiredCapabilities.isDisjoint(
                with: [.documentMetadata, .selectedText, .currentPageText]
            )
        }
    }

    var needsSelection: Bool {
        requiredCapabilities.contains(.selectedText) || command?.needsSelection == true
    }

    var needsCurrentPageText: Bool {
        requiredCapabilities.contains(.currentPageText)
    }
}
