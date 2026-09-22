// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

struct PluginActionContext: Equatable {
    let documentName: String?
    let pageNumber: Int?
    let pageCount: Int?
    let selectedText: String?
    let currentPageText: String?

    init(
        documentName: String?,
        pageNumber: Int?,
        pageCount: Int?,
        selectedText: String?,
        currentPageText: String? = nil
    ) {
        self.documentName = documentName
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.selectedText = selectedText
        self.currentPageText = currentPageText
    }
}

struct PluginExternalURLDisclosure: Equatable {
    let includesDocumentMetadata: Bool
    let includesSelectedText: Bool
}

enum PluginActionEffect: Equatable {
    case executedDocumentCommand(PluginDocumentCommand.Kind)
    case showedText
    case copiedText
    case openedURL(URL)
    case openedPanel(PluginPanelRequest)
}

struct PluginActionRenderer {
    private enum RenderSegment {
        case literal(Range<String.Index>)
        case replacement(String)
    }

    private struct Replacement {
        let token: String
        let value: String
        let characterCount: Int
        let utf8ByteCount: Int
        let utf16CodeUnitCount: Int
    }

    private struct RenderPlan {
        let segments: [RenderSegment]
    }

    private static let unreservedURLCharacters = CharacterSet.alphanumerics.union(
        CharacterSet(charactersIn: "-._~")
    )

    func render(
        action: PluginActionManifest,
        context: PluginActionContext
    ) throws -> String {
        if action.requiredCapabilities.contains(.selectedText) {
            guard
                let selectedText = context.selectedText?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                !selectedText.isEmpty
            else {
                throw PluginSystemError.actionUnavailable(
                    L10n.string(
                        "plugins.error.selection_required",
                        defaultValue: "먼저 PDF에서 텍스트를 선택하세요."
                    )
                )
            }
        }

        if action.requiredCapabilities.contains(.documentMetadata) {
            guard
                let documentName = context.documentName,
                let pageNumber = context.pageNumber,
                let pageCount = context.pageCount
            else {
                throw PluginSystemError.actionUnavailable(
                    L10n.string(
                        "plugins.error.open_document_required",
                        defaultValue: "먼저 PDF 문서를 여세요."
                    )
                )
            }
            guard pageNumber > 0, pageCount > 0, pageNumber <= pageCount else {
                throw PluginSystemError.actionUnavailable("document page metadata is invalid")
            }
            return try renderBounded(
                action: action,
                replacements: [
                    "{{document.name.urlEncoded}}": percentEncoded(documentName),
                    "{{document.name}}": documentName,
                    "{{page.number}}": String(pageNumber),
                    "{{document.pageCount}}": String(pageCount),
                    "{{page.text.urlEncoded}}": percentEncoded(context.currentPageText ?? ""),
                    "{{page.text}}": context.currentPageText ?? "",
                    "{{selection.urlEncoded}}": percentEncoded(context.selectedText ?? ""),
                    "{{selection}}": context.selectedText ?? ""
                ]
            )
        }

        return try renderBounded(
            action: action,
            replacements: [
                "{{selection.urlEncoded}}": percentEncoded(context.selectedText ?? ""),
                "{{selection}}": context.selectedText ?? "",
                "{{document.name.urlEncoded}}": "",
                "{{document.name}}": "",
                "{{page.number}}": "",
                "{{document.pageCount}}": "",
                "{{page.text.urlEncoded}}": percentEncoded(context.currentPageText ?? ""),
                "{{page.text}}": context.currentPageText ?? ""
            ]
        )
    }

    func validatedExternalURL(from rendered: String) throws -> URL {
        guard
            rendered.utf8.count <= HwattakPluginLimits.maximumExternalURLUTF8Bytes,
            let url = URL(string: rendered),
            url.scheme?.lowercased() == "https",
            AIEndpointPolicy.isValidExternalWebURL(url)
        else {
            throw PluginSystemError.externalURLRejected
        }
        return url
    }

    func validatedPanelURL(
        from rendered: String,
        kind: PluginPanelKind
    ) throws -> URL {
        let url = try validatedExternalURL(from: rendered)
        let scope: PluginWebNavigationScope
        switch kind {
        case .youtube:
            scope = .youtube
        case .browser:
            scope = .publicWeb
        case .translation:
            return url
        }
        guard PluginWebURLPolicy.allows(url, scope: scope) else {
            throw PluginSystemError.externalURLRejected
        }
        return url
    }

    private func renderBounded(
        action: PluginActionManifest,
        replacements: [String: String]
    ) throws -> String {
        let plan = try makeRenderPlan(
            template: action.template,
            replacements: replacements,
            budget: HwattakPluginLimits.renderedTextBudget
        )

        // The complete projected size has already been accepted, but use the
        // bounded accumulator as a second line of defence. In particular, no
        // oversized intermediate String is ever assembled before this point.
        var accumulator = EncodedTextAccumulator(
            budget: HwattakPluginLimits.renderedTextBudget
        )
        for segment in plan.segments {
            let piece: String
            switch segment {
            case .literal(let range):
                piece = String(action.template[range])
            case .replacement(let value):
                piece = value
            }
            guard accumulator.append(piece) else {
                throw outputLimitError
            }
        }
        return accumulator.text
    }

    /// Scans only the original template, matching the longest allowed token at
    /// each position. Replacement values become opaque output segments and are
    /// never scanned as template syntax. The complete encoded size projection
    /// is validated before any output String is assembled.
    private func makeRenderPlan(
        template: String,
        replacements: [String: String],
        budget: EncodedTextBudget
    ) throws -> RenderPlan {
        let orderedReplacements = replacements.map { token, value in
            Replacement(
                token: token,
                value: value,
                characterCount: value.count,
                utf8ByteCount: value.utf8.count,
                utf16CodeUnitCount: value.utf16.count
            )
        }.sorted { lhs, rhs in
            if lhs.token.count != rhs.token.count {
                return lhs.token.count > rhs.token.count
            }
            return lhs.token < rhs.token
        }

        var segments: [RenderSegment] = []
        var projectedCharacters = 0
        var projectedUTF8Bytes = 0
        var projectedUTF16Units = 0
        var cursor = template.startIndex
        var literalStart = cursor

        func addProjectedCounts(
            characters: Int,
            utf8Bytes: Int,
            utf16Units: Int
        ) throws {
            guard
                let nextCharacters = projectedCount(
                    base: projectedCharacters,
                    added: characters,
                    maximum: budget.maximumCharacters
                ),
                let nextUTF8Bytes = projectedCount(
                    base: projectedUTF8Bytes,
                    added: utf8Bytes,
                    maximum: budget.maximumUTF8Bytes
                ),
                let nextUTF16Units = projectedCount(
                    base: projectedUTF16Units,
                    added: utf16Units,
                    maximum: budget.maximumUTF16CodeUnits
                )
            else {
                throw outputLimitError
            }
            projectedCharacters = nextCharacters
            projectedUTF8Bytes = nextUTF8Bytes
            projectedUTF16Units = nextUTF16Units
        }

        func appendLiteral(upTo end: String.Index) throws {
            guard literalStart < end else { return }
            let range = literalStart..<end
            let literal = template[range]
            try addProjectedCounts(
                characters: literal.count,
                utf8Bytes: literal.utf8.count,
                utf16Units: literal.utf16.count
            )
            segments.append(.literal(range))
        }

        while cursor < template.endIndex {
            let suffix = template[cursor...]
            if suffix.hasPrefix("{{") {
                try appendLiteral(upTo: cursor)
                guard
                    let replacement = orderedReplacements.first(where: {
                        suffix.hasPrefix($0.token)
                    })
                else {
                    throw PluginSystemError.actionFailed(
                        "an unresolved template token remains"
                    )
                }
                try addProjectedCounts(
                    characters: replacement.characterCount,
                    utf8Bytes: replacement.utf8ByteCount,
                    utf16Units: replacement.utf16CodeUnitCount
                )
                segments.append(.replacement(replacement.value))
                cursor = template.index(
                    cursor,
                    offsetBy: replacement.token.count
                )
                literalStart = cursor
            } else if suffix.hasPrefix("}}") {
                throw PluginSystemError.actionFailed(
                    "an unresolved template token remains"
                )
            } else {
                cursor = template.index(after: cursor)
            }
        }
        try appendLiteral(upTo: template.endIndex)
        return RenderPlan(segments: segments)
    }

    private func projectedCount(
        base: Int,
        added: Int,
        maximum: Int
    ) -> Int? {
        guard added >= 0 else { return nil }
        let (projected, overflow) = base.addingReportingOverflow(added)
        guard !overflow, projected <= maximum else { return nil }
        return projected
    }

    private var outputLimitError: PluginSystemError {
        PluginSystemError.actionFailed(
            L10n.string(
                "plugins.error.output_limit",
                defaultValue: "플러그인 결과가 안전한 크기 제한을 초과했습니다."
            )
        )
    }

    private func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.unreservedURLCharacters) ?? ""
    }
}

@MainActor
struct PluginRuntimeEnvironment {
    let showText: (_ title: String, _ text: String) -> Void
    let writeClipboard: (_ text: String) -> Bool
    let approveExternalURL: (
        _ pluginName: String,
        _ url: URL,
        _ disclosure: PluginExternalURLDisclosure
    ) -> Bool
    let openExternalURL: (_ url: URL) -> Bool
    let approvePanelURL: (
        _ pluginName: String,
        _ url: URL,
        _ kind: PluginPanelKind
    ) -> Bool

    init(
        showText: @escaping (_ title: String, _ text: String) -> Void,
        writeClipboard: @escaping (_ text: String) -> Bool,
        approveExternalURL: @escaping (
            _ pluginName: String,
            _ url: URL,
            _ disclosure: PluginExternalURLDisclosure
        ) -> Bool,
        openExternalURL: @escaping (_ url: URL) -> Bool,
        approvePanelURL: ((String, URL, PluginPanelKind) -> Bool)? = nil
    ) {
        self.showText = showText
        self.writeClipboard = writeClipboard
        self.approveExternalURL = approveExternalURL
        self.openExternalURL = openExternalURL
        self.approvePanelURL = approvePanelURL ?? { pluginName, url, _ in
            approveExternalURL(
                pluginName,
                url,
                PluginExternalURLDisclosure(
                    includesDocumentMetadata: false,
                    includesSelectedText: false
                )
            )
        }
    }

    static let live = PluginRuntimeEnvironment(
        showText: { title, text in
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = text
            alert.addButton(withTitle: L10n.string("action.close", defaultValue: "닫기"))
            alert.runModal()
        },
        writeClipboard: { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        },
        approveExternalURL: { pluginName, url, disclosure in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string(
                "plugins.external_url.title",
                defaultValue: "외부 링크를 열까요?"
            )
            let origin = PluginWebURLPolicy.originDescription(for: url)
            var shared: [String] = []
            if disclosure.includesSelectedText {
                shared.append(
                    L10n.string(
                        "plugins.external_url.selection",
                        defaultValue: "선택한 텍스트"
                    )
                )
            }
            if disclosure.includesDocumentMetadata {
                shared.append(
                    L10n.string(
                        "plugins.external_url.metadata",
                        defaultValue: "문서 이름·페이지 정보"
                    )
                )
            }
            let disclosureText = shared.isEmpty
                ? L10n.string(
                    "plugins.external_url.no_document_data",
                    defaultValue: "PDF 데이터는 포함되지 않습니다."
                )
                : L10n.format("plugins.external_url.includes", shared.joined(separator: ", "))
            alert.informativeText = L10n.format(
                "plugins.external_url.message",
                pluginName,
                origin,
                disclosureText
            )
            alert.addButton(withTitle: L10n.string("action.open", defaultValue: "열기"))
            alert.addButton(withTitle: L10n.string("action.cancel", defaultValue: "취소"))
            return alert.runModal() == .alertFirstButtonReturn
        },
        openExternalURL: { NSWorkspace.shared.open($0) },
        approvePanelURL: { pluginName, url, kind in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string(
                "plugins.panel.consent.title",
                defaultValue: "앱 안에서 외부 사이트를 열까요?"
            )
            let destination = kind == .youtube
                ? L10n.string(
                    "plugins.panel.consent.destination.youtube",
                    defaultValue: "YouTube"
                )
                : L10n.string(
                    "plugins.panel.consent.destination.web",
                    defaultValue: "웹사이트"
                )
            alert.informativeText = L10n.format(
                "plugins.panel.consent.message",
                pluginName,
                PluginWebURLPolicy.originDescription(for: url),
                destination
            )
            alert.addButton(withTitle: L10n.string("action.open", defaultValue: "열기"))
            alert.addButton(withTitle: L10n.string("action.cancel", defaultValue: "취소"))
            return alert.runModal() == .alertFirstButtonReturn
        }
    )
}

@MainActor
enum PluginDocumentTextAccess {
    /// Plug-in permissions authorize the action, not access to a protected PDF.
    /// Keep this check free of text extraction so menus and execution can share
    /// it without reading the document during view updates.
    static func validate(
        for action: PluginActionManifest,
        workspace: PDFWorkspaceState
    ) throws {
        let readsSelection = action.requiredCapabilities.contains(.selectedText)
        guard readsSelection || action.needsCurrentPageText else { return }
        guard workspace.allows(.copyAndPaste) else {
            throw PluginSystemError.actionUnavailable(
                L10n.string(
                    "plugins.error.pdf_copying_not_allowed",
                    defaultValue: "이 PDF의 현재 권한으로는 플러그인에 텍스트를 전달할 수 없습니다."
                )
            )
        }
        if readsSelection {
            guard let document = workspace.document,
                  let selection = workspace.currentSelection,
                  !selection.pages.isEmpty,
                  selection.pages.allSatisfy({ page in
                      let index = document.index(for: page)
                      return index != NSNotFound && document.page(at: index) === page
                  }) else {
                throw PluginSystemError.actionUnavailable(
                    L10n.string(
                        "plugins.error.selection_required",
                        defaultValue: "먼저 PDF에서 텍스트를 선택하세요."
                    )
                )
            }
        }
    }
}

@MainActor
struct PluginActionRunner {
    let renderer: PluginActionRenderer
    let environment: PluginRuntimeEnvironment

    init(renderer: PluginActionRenderer = PluginActionRenderer()) {
        self.renderer = renderer
        environment = .live
    }

    init(
        renderer: PluginActionRenderer = PluginActionRenderer(),
        environment: PluginRuntimeEnvironment
    ) {
        self.renderer = renderer
        self.environment = environment
    }

    @discardableResult
    func run(
        plugin: InstalledPlugin,
        action: PluginActionManifest,
        workspace: PDFWorkspaceState?
    ) throws -> PluginActionEffect {
        guard plugin.isEnabled else {
            throw PluginSystemError.actionUnavailable(
                L10n.string(
                    "plugins.error.disabled",
                    defaultValue: "비활성화된 플러그인입니다."
                )
            )
        }
        guard plugin.manifest.actions.contains(action) else {
            throw PluginSystemError.actionFailed("action is not owned by this plug-in")
        }
        guard Set(plugin.manifest.capabilities).isSuperset(of: action.requiredCapabilities) else {
            throw PluginSystemError.actionFailed("declared permissions do not cover this action")
        }
        if action.output == .translatePanel {
            guard let workspace, workspace.allows(.translation) else {
                throw PluginSystemError.actionUnavailable(
                    L10n.string(
                        "plugins.error.translation_mode",
                        defaultValue: "번역 패널은 보기 또는 학습 모드에서 사용할 수 있습니다."
                    )
                )
            }
        }

        if action.output == .documentCommand {
            guard plugin.manifest.schemaVersion >= 3, let command = action.command, let workspace else {
                throw PluginSystemError.actionUnavailable("document command requires schema 3 and an open PDF")
            }
            try command.apply(to: workspace)
            return .executedDocumentCommand(command.kind)
        }
        let context = try snapshotContext(for: action, workspace: workspace)
        let rendered = try renderer.render(action: action, context: context)
        let localizedPluginName = BundledPluginPresentation.displayName(
            for: plugin.manifest
        )
        let localizedActionTitle = BundledPluginPresentation.actionTitle(
            action,
            in: plugin.manifest
        )
        let effect: PluginActionEffect
        switch action.output {
        case .documentCommand:
            throw PluginSystemError.actionUnavailable("missing document command")
        case .showText:
            environment.showText(localizedActionTitle, rendered)
            effect = .showedText
        case .copyText:
            guard environment.writeClipboard(rendered) else {
                throw PluginSystemError.actionFailed("the pasteboard rejected the text")
            }
            effect = .copiedText
        case .openURL:
            let url = try renderer.validatedExternalURL(from: rendered)
            let disclosure = PluginExternalURLDisclosure(
                includesDocumentMetadata: action.requiredCapabilities.contains(.documentMetadata),
                includesSelectedText: action.requiredCapabilities.contains(.selectedText)
            )
            guard environment.approveExternalURL(
                localizedPluginName,
                url,
                disclosure
            ) else {
                throw PluginSystemError.externalURLCancelled
            }
            guard environment.openExternalURL(url) else {
                throw PluginSystemError.actionFailed("macOS could not open the URL")
            }
            effect = .openedURL(url)
        case .translatePanel:
            guard let workspace else {
                throw PluginSystemError.actionUnavailable(
                    L10n.string(
                        "plugins.error.open_document_required",
                        defaultValue: "먼저 PDF 문서를 여세요."
                    )
                )
            }
            let request = PluginPanelRequest(
                pluginIdentifier: plugin.manifest.identifier,
                manifestDigest: plugin.manifestDigest,
                documentRevision: workspace.revision,
                pluginName: localizedPluginName,
                actionID: action.id,
                title: localizedActionTitle,
                kind: .translation,
                sourceText: rendered,
                includesSelectedText: action.needsSelection,
                includesCurrentPageText: action.needsCurrentPageText
            )
            workspace.pluginPanelRequest = request
            effect = .openedPanel(request)
        case .youtubePanel, .browserPanel:
            guard let workspace else {
                throw PluginSystemError.actionUnavailable(
                    L10n.string(
                        "plugins.error.open_document_required",
                        defaultValue: "먼저 PDF 문서를 여세요."
                    )
                )
            }
            let kind: PluginPanelKind = action.output == .youtubePanel ? .youtube : .browser
            let url = try renderer.validatedPanelURL(from: rendered, kind: kind)
            guard environment.approvePanelURL(
                localizedPluginName,
                url,
                kind
            ) else {
                throw PluginSystemError.externalURLCancelled
            }
            let request = PluginPanelRequest(
                pluginIdentifier: plugin.manifest.identifier,
                manifestDigest: plugin.manifestDigest,
                documentRevision: workspace.revision,
                pluginName: localizedPluginName,
                actionID: action.id,
                title: localizedActionTitle,
                kind: kind,
                initialURL: url
            )
            workspace.pluginPanelRequest = request
            effect = .openedPanel(request)
        }

        workspace?.statusMessage = L10n.format(
            "plugins.status.action_completed",
            localizedActionTitle
        )
        return effect
    }

    private func snapshotContext(
        for action: PluginActionManifest,
        workspace: PDFWorkspaceState?
    ) throws -> PluginActionContext {
        guard action.needsOpenDocument else {
            return PluginActionContext(
                documentName: nil,
                pageNumber: nil,
                pageCount: nil,
                selectedText: nil,
                currentPageText: nil
            )
        }
        guard let workspace, workspace.document != nil, workspace.pageCount > 0 else {
            throw PluginSystemError.actionUnavailable(
                L10n.string(
                    "plugins.error.open_document_required",
                    defaultValue: "먼저 PDF 문서를 여세요."
                )
            )
        }
        try PluginDocumentTextAccess.validate(for: action, workspace: workspace)
        let selectedText: String?
        if action.needsSelection {
            let bounded = PDFShareNote.boundedExcerpt(from: workspace.currentSelection)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bounded.isEmpty else {
                throw PluginSystemError.actionUnavailable(
                    L10n.string(
                        "plugins.error.selection_required",
                        defaultValue: "먼저 PDF에서 텍스트를 선택하세요."
                    )
                )
            }
            selectedText = bounded
        } else {
            selectedText = nil
        }
        let currentPageText: String?
        if action.needsCurrentPageText {
            let pageIndex = min(max(0, workspace.currentPageIndex), workspace.pageCount - 1)
            let rawText = workspace.document?.page(at: pageIndex)?.string ?? ""
            let limited = EncodedTextLimiter.limit(
                rawText,
                budget: HwattakPluginLimits.renderedTextBudget
            )
            guard !limited.wasTruncated else {
                throw PluginSystemError.actionFailed(
                    L10n.string(
                        "plugins.error.output_limit",
                        defaultValue: "플러그인 결과가 안전한 크기 제한을 초과했습니다."
                    )
                )
            }
            let trimmed = limited.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw PluginSystemError.actionUnavailable(
                    L10n.string(
                        "plugins.error.current_page_text_required",
                        defaultValue: "현재 페이지에서 번역할 텍스트를 찾지 못했습니다. 스캔 문서라면 먼저 OCR을 실행하세요."
                    )
                )
            }
            currentPageText = trimmed
        } else {
            currentPageText = nil
        }
        let boundedName = EncodedTextLimiter.limit(
            workspace.displayName,
            budget: EncodedTextBudget(maximumCharacters: 512, maximumUTF8Bytes: 2_048)
        ).text
        return PluginActionContext(
            documentName: boundedName,
            pageNumber: min(max(0, workspace.currentPageIndex), workspace.pageCount - 1) + 1,
            pageCount: workspace.pageCount,
            selectedText: selectedText,
            currentPageText: currentPageText
        )
    }
}
