// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// 현재 PDF의 제한된 텍스트 문맥을 외부 AI 공급자와 대화하는 보조 panel이다.
///
/// 중요한 개인정보 경계는 UI에도 드러난다. 요청마다 전송할 system/history/question/
/// PDF context를 미리 보여 주고 사용자가 동의해야 네트워크 Task를 시작한다. 웹과
/// MCP는 별도 opt-in이며, MCP tool call은 서버 URL과 arguments를 다시 승인해야 한다.
/// 모델 답변은 곧바로 PDF를 수정하지 않고 검토 가능한 자유 텍스트 초안만 만든다.
@MainActor
struct AIAssistantSidebar: View {
    @ObservedObject var viewModel: AIAssistantSessionModel
    @ObservedObject var workspace: PDFWorkspaceState
    @ObservedObject private var providerSettings: AIProviderSettingsStore

    let documentCollection: MultiDocumentWorkspaceState?
    let onOpenRelatedPDF: (PDFRelatedDocumentResult) -> Void
    let onRequestDraftApplication: (String, AIDraftApplicationTarget) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// AppKit owns the actual first-responder state of the bounded editor. A
    /// normal `@State` binding lets the representable report focus changes
    /// back to SwiftUI without accepting text through `TextEditor` first.
    @State private var promptIsFocused = false
    @State private var promptLengthLimitReached = false
    @State private var draftAwaitingConfirmation: AIDraftApplicationRequest?
    @State private var quickControlsVisible = true
    @State private var showingPageSelectionPopover = false
    @State private var pageSelectionDraft: Set<Int> = []

    init(
        viewModel: AIAssistantSessionModel,
        workspace: PDFWorkspaceState,
        documentCollection: MultiDocumentWorkspaceState? = nil,
        providerSettings: AIProviderSettingsStore? = nil,
        onOpenRelatedPDF: @escaping (PDFRelatedDocumentResult) -> Void = { _ in },
        onRequestDraftApplication: @escaping (String, AIDraftApplicationTarget) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.workspace = workspace
        self.documentCollection = documentCollection
        _providerSettings = ObservedObject(wrappedValue: providerSettings ?? .shared)
        self.onOpenRelatedPDF = onOpenRelatedPDF
        self.onRequestDraftApplication = onRequestDraftApplication
        self.onClose = onClose
    }

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }

    private var configuration: AIProviderConfiguration {
        providerSettings.selectedConfiguration
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if quickControlsVisible {
                Rectangle().fill(theme.border).frame(height: 1)
                controls
            }
            Rectangle().fill(theme.border).frame(height: 1)
            conversation
            Rectangle().fill(theme.border).frame(height: 1)
            composer
        }
        .frame(minWidth: 350, idealWidth: 410, maxWidth: 540)
        .background(theme.sidebar)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .sheet(item: $viewModel.pendingConsent) { consent in
            AITransmissionConsentSheet(
                consent: consent,
                theme: theme,
                onCancel: viewModel.cancelPendingConsent,
                onConfirm: viewModel.confirmPendingConsent
            )
        }
        .confirmationDialog(
            L10n.string(
                "ai.draft.apply_confirmation.title",
                defaultValue: "AI 초안을 PDF에 추가할까요?"
            ),
            isPresented: Binding(
                get: { draftAwaitingConfirmation != nil },
                set: { if !$0 { draftAwaitingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                L10n.string(
                    "ai.draft.review_and_apply",
                    defaultValue: "검토 후 텍스트로 추가"
                )
            ) {
                guard let draft = draftAwaitingConfirmation else { return }
                draftAwaitingConfirmation = nil
                onRequestDraftApplication(draft.text, draft.target)
            }
            Button(L10n.string("action.cancel", defaultValue: "취소"), role: .cancel) {
                draftAwaitingConfirmation = nil
            }
        } message: {
            Text(
                L10n.string(
                    "ai.draft.apply_confirmation.message",
                    defaultValue: "추가 전 편집 창에서 내용을 검토할 수 있습니다. 저장을 선택하기 전까지 원본 파일에는 기록되지 않습니다."
                )
            )
        }
        .onAppear {
            providerSettings.refreshAPIKeyAvailability()
            viewModel.normalizeScope(for: workspace)
        }
        .onChange(of: viewModel.scope) { _, newScope in
            guard newScope == .selectedPages else {
                showingPageSelectionPopover = false
                return
            }
            viewModel.normalizeSelectedPageIndices(for: workspace)
            // The summary row enters the hierarchy only after the picker value
            // changes. Present on the next run-loop turn so the popover always
            // has a stable source view, including keyboard Picker changes.
            DispatchQueue.main.async {
                guard viewModel.scope == .selectedPages else { return }
                presentPageSelection()
            }
        }
        .onChange(of: providerSettings.selectedProvider) { _, _ in
            viewModel.providerDidChange()
        }
        .onChange(of: webSearchAvailable) { _, isAvailable in
            if !isAvailable { viewModel.allowsWebSearch = false }
        }
        .onChange(of: mcpAvailable) { _, isAvailable in
            if !isAvailable { viewModel.allowsMCPTools = false }
        }
        .onChange(of: viewModel.messages.count) { previousCount, newCount in
            guard newCount == 0 || newCount > previousCount else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                quickControlsVisible = newCount == 0
            }
        }
        .onChange(of: workspace.documentURL) { _, _ in
            viewModel.documentDidChange()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.ribbon)
                .frame(width: 30, height: 30)
                .background(theme.ribbonSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("ai.title", defaultValue: "PDF AI"))
                    .font(.headline)
                Text(configuration.model)
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if viewModel.isBusy || viewModel.mcpApprovalSession != nil {
                Button {
                    viewModel.cancel()
                } label: {
                    Label(
                        L10n.string("ai.cancel_request", defaultValue: "중단"),
                        systemImage: "stop.circle"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help(L10n.string("ai.cancel_request", defaultValue: "AI 요청 중단"))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    quickControlsVisible.toggle()
                }
            } label: {
                Image(
                    systemName: quickControlsVisible
                        ? "rectangle.compress.vertical"
                        : "rectangle.expand.vertical"
                )
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                quickControlsVisible
                    ? L10n.string("ai.controls.hide", defaultValue: "AI 도구 숨기기")
                    : L10n.string("ai.controls.show", defaultValue: "AI 도구 보기")
            )
            .accessibilityLabel(
                quickControlsVisible
                    ? L10n.string("ai.controls.hide", defaultValue: "AI 도구 숨기기")
                    : L10n.string("ai.controls.show", defaultValue: "AI 도구 보기")
            )
            .accessibilityIdentifier("ai-toggle-quick-controls")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("ai.close", defaultValue: "AI 패널 닫기"))
            .accessibilityLabel(L10n.string("ai.close", defaultValue: "AI 패널 닫기"))
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(theme.panel)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker(
                    L10n.string("ai.provider", defaultValue: "AI 공급자"),
                    selection: $providerSettings.selectedProvider
                ) {
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(L10n.string("ai.provider", defaultValue: "AI 공급자"))
                .accessibilityIdentifier("ai-provider-picker")

                Picker(
                    L10n.string("ai.context_scope", defaultValue: "전송 범위"),
                    selection: $viewModel.scope
                ) {
                    ForEach(AIAssistantScopeOption.allCases) { scope in
                        Label(scope.title, systemImage: scope.systemImage)
                            .tag(scope)
                            .disabled(scope == .selection && !hasTextSelection)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(L10n.string("ai.context_scope", defaultValue: "전송 범위"))
                .accessibilityIdentifier("ai-context-picker")

                optionalToolsMenu
            }

            if viewModel.scope == .selectedPages {
                selectedPagesControl
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 5),
                    count: 4
                ),
                spacing: 5
            ) {
                ForEach(AIQuickAction.generalActions) { action in
                    quickActionButton(action)
                }
            }

            if configuration.requiresAPIKey && !providerSettings.hasAPIKey(for: configuration.kind) {
                HStack(spacing: 7) {
                    Image(systemName: "key.slash")
                    Text(
                        L10n.string(
                            "ai.api_key_required",
                            defaultValue: "이 공급자의 API 키를 설정에서 저장해 주세요."
                        )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 3)
                    SettingsLink {
                        Text(L10n.string("menu.settings", defaultValue: "설정"))
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(theme.warning)
                .padding(7)
                .background(theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(8)
        .background(theme.panel)
    }

    private var optionalToolsMenu: some View {
        Menu {
            Toggle(
                L10n.string("ai.web_search", defaultValue: "웹 검색"),
                isOn: $viewModel.allowsWebSearch
            )
            .disabled(!webSearchAvailable)

            Toggle(
                L10n.string("ai.mcp_tools", defaultValue: "MCP 도구"),
                isOn: $viewModel.allowsMCPTools
            )
            .disabled(!mcpAvailable)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: activeOptionalToolCount == 0 ? "wrench" : "wrench.and.screwdriver.fill")
                Text(L10n.string("ai.optional_tools", defaultValue: "도구"))
                if activeOptionalToolCount > 0 {
                    Text("\(activeOptionalToolCount)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(theme.accent)
                }
            }
            .font(.caption.weight(.semibold))
            .frame(height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(optionalToolsHelp)
        .accessibilityLabel(L10n.string("ai.optional_tools", defaultValue: "선택 도구"))
        .accessibilityValue(optionalToolsAccessibilityValue)
        .accessibilityIdentifier("ai-optional-tools-menu")
    }

    private var selectedPagesControl: some View {
        let selectedIndices = sanitizedSelectedPageIndices
        let isEmpty = selectedIndices.isEmpty

        return HStack(spacing: 7) {
            Image(systemName: isEmpty ? "exclamationmark.triangle.fill" : "square.stack.3d.up.fill")
                .font(.caption)
                .foregroundStyle(isEmpty ? theme.warning : theme.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(
                    isEmpty
                        ? L10n.string(
                            "ai.pages.empty",
                            defaultValue: "페이지를 한 개 이상 선택해 주세요."
                        )
                        : AIPageSelectionSpecification.compactDescription(selectedIndices)
                )
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(isEmpty ? theme.warning : theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

                if !isEmpty {
                    Text(L10n.format("ai.pages.selection_count", selectedIndices.count))
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Spacer(minLength: 4)

            Button {
                presentPageSelection()
            } label: {
                Label(
                    L10n.string("ai.pages.select", defaultValue: "페이지 선택…"),
                    systemImage: "chevron.down"
                )
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("ai-selected-pages-open")
            .popover(isPresented: $showingPageSelectionPopover, arrowEdge: .bottom) {
                AISelectedPagesPopover(
                    workspace: workspace,
                    selection: $pageSelectionDraft,
                    onCancel: {
                        showingPageSelectionPopover = false
                    },
                    onApply: {
                        applyPageSelection()
                    }
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 34)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isEmpty ? theme.warning.opacity(0.8) : theme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.string("ai.pages.summary", defaultValue: "AI에 보낼 페이지")
        )
        .accessibilityValue(selectedPageAccessibilityValue)
        .accessibilityIdentifier("ai-selected-pages-summary")
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if viewModel.messages.isEmpty && viewModel.relatedPDFResults.isEmpty {
                        emptyState
                    }

                    ForEach(viewModel.messages) { message in
                        AIAssistantMessageCard(
                            message: message,
                            theme: theme,
                            onOpenLocalCitation: { citation in
                                workspace.setCurrentPage(citation.pageIndex)
                            },
                            onApplyDraft: {
                                guard let target = message.draftApplicationTarget else {
                                    return
                                }
                                draftAwaitingConfirmation = AIDraftApplicationRequest(
                                    messageID: message.id,
                                    text: message.text,
                                    target: target
                                )
                            }
                        )
                        .id(message.id.uuidString)
                    }

                    if !viewModel.relatedPDFResults.isEmpty {
                        relatedPDFSection
                            .id("ai-related-results")
                    }

                    if let approvalSession = viewModel.mcpApprovalSession {
                        AIMCPApprovalSection(
                            session: approvalSession,
                            decisions: viewModel.mcpApprovalDecisions,
                            isResolving: viewModel.phase == .resolvingMCP,
                            theme: theme,
                            setDecision: viewModel.setMCPDecision,
                            submit: viewModel.submitMCPApprovalDecisions
                        )
                        .id("ai-mcp-approval")
                    }

                    if viewModel.isBusy {
                        HStack(spacing: 9) {
                            ProgressView()
                                .controlSize(.small)
                            Text(viewModel.phase.label)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.vertical, 5)
                        .id("ai-progress")
                    }

                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(theme.warning)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                            .id("ai-error")
                    }
                }
                .padding(9)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.scrollAnchor) { _, anchor in
                guard let anchor else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(anchor, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.accent)
            Text(L10n.string("ai.empty.title", defaultValue: "PDF에 대해 물어보세요"))
                .font(.headline)
            Text(
                L10n.string(
                    "ai.empty.message",
                    defaultValue: "전송할 범위를 직접 고르고 미리보기를 확인한 뒤에만 외부 AI로 보냅니다. 관련 PDF 검색은 Mac 안에서만 처리됩니다."
                )
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
    }

    private var relatedPDFSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                L10n.string("ai.related.local_title", defaultValue: "이 Mac에서 찾은 관련 PDF"),
                systemImage: "internaldrive"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondaryText)

            ForEach(viewModel.relatedPDFResults) { result in
                Button {
                    onOpenRelatedPDF(result)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(result.displayName)
                                .font(.callout.weight(.semibold))
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            if let page = result.matches.first?.pageNumber {
                                Text(L10n.format("ai.related.page", page))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        if let snippet = result.matches.first?.snippet, !snippet.isEmpty {
                            Text(snippet)
                                .font(.caption)
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(3)
                        }
                        Label(
                            L10n.string("ai.related.local_only", defaultValue: "로컬 검색 · 외부 전송 없음"),
                            systemImage: "lock.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(theme.success)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                BoundedPlainTextEditor(
                    text: $viewModel.prompt,
                    isFocused: $promptIsFocused,
                    budget: AIAssistantSessionModel.userPromptBudget,
                    onLengthLimitReached: {
                        promptLengthLimitReached = true
                    }
                )
                    .frame(minHeight: 42, maxHeight: 78)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(promptIsFocused ? theme.accent : theme.border, lineWidth: 1)
                    }
                    .overlay(alignment: .topLeading) {
                        if viewModel.prompt.isEmpty {
                            Text(L10n.string("ai.prompt.placeholder", defaultValue: "이 PDF에 대해 질문하기…"))
                                .font(.callout)
                                .foregroundStyle(theme.secondaryText.opacity(0.8))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(
                        L10n.string(
                            "ai.prompt.placeholder",
                            defaultValue: "이 PDF에 대해 질문하기…"
                        )
                    )

                Button {
                    viewModel.beginRequest(
                        action: nil,
                        workspace: workspace,
                        documentCollection: documentCollection,
                        configuration: configuration,
                        hasAPIKey: providerSettings.hasAPIKey(for: configuration.kind)
                    )
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.chromeText)
                        .frame(width: 34, height: 34)
                        .background(theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSendCustomPrompt)
                .help(sendButtonHelp)
                .accessibilityLabel(L10n.string("ai.send", defaultValue: "검토 후 AI로 보내기"))
                .accessibilityHint(sendButtonHelp)
            }

            if promptLengthLimitReached {
                Label(
                    L10n.format(
                        "inline_text.length_limit",
                        AIAssistantSessionModel.maximumUserPromptCharacters
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(theme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 5) {
                Image(systemName: "hand.raised.fill")
                Text(
                    L10n.string(
                        "ai.external_notice.short",
                        defaultValue: "전송 전 내용과 공급자를 한 번 더 확인합니다."
                    )
                )
                Spacer(minLength: 0)
                Button(L10n.string("ai.clear", defaultValue: "대화 지우기")) {
                    viewModel.clearConversation()
                }
                .buttonStyle(.link)
                .disabled(viewModel.messages.isEmpty && viewModel.relatedPDFResults.isEmpty)
            }
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)
        }
        .padding(9)
        .background(theme.panel)
    }

    private func quickActionButton(_ action: AIQuickAction) -> some View {
        Button {
            viewModel.beginRequest(
                action: action,
                workspace: workspace,
                documentCollection: documentCollection,
                configuration: configuration,
                hasAPIKey: providerSettings.hasAPIKey(for: configuration.kind)
            )
        } label: {
            VStack(spacing: 2) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(action.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!quickActionIsAvailable(action))
        .help(quickActionHelp(action))
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("ai-action-\(action.rawValue)")
    }

    private func quickActionIsAvailable(_ action: AIQuickAction) -> Bool {
        hasValidSelectedPageSelection && AIQuickActionExecutionPolicy.isAvailable(
            action,
            phase: viewModel.phase,
            hasOpenDocument: workspace.hasOpenDocument,
            hasDocumentCollection: documentCollection != nil,
            providerRequiresAPIKey: configuration.requiresAPIKey,
            hasAPIKey: providerSettings.hasAPIKey(for: configuration.kind),
            webSearchAvailable: webSearchAvailable
        )
    }

    private func quickActionHelp(_ action: AIQuickAction) -> String {
        if !hasValidSelectedPageSelection {
            return selectedPagesRequiredHelp
        }
        if action == .webResearch, !webSearchAvailable {
            return webSearchHelp
        }
        if action == .relatedPDFs, documentCollection == nil {
            return L10n.string(
                "ai.related_unavailable.help",
                defaultValue: "열린 PDF 작업 공간에서만 관련 문서를 찾을 수 있습니다."
            )
        }
        if !action.usesLocalRelatedPDFSearch,
           configuration.requiresAPIKey,
           !providerSettings.hasAPIKey(for: configuration.kind) {
            return L10n.string(
                "ai.api_key_required",
                defaultValue: "이 공급자의 API 키를 설정에서 저장해 주세요."
            )
        }
        return action.suggestedPrompt
    }

    private var hasTextSelection: Bool {
        // Rendering the picker must not force PDFKit to materialize a very
        // large selection. The bounded async extractor validates actual text
        // only after the user starts a request.
        workspace.currentSelection != nil
    }

    private var canSendCustomPrompt: Bool {
        viewModel.phase == .idle
            && workspace.hasOpenDocument
            && hasValidSelectedPageSelection
            && (!configuration.requiresAPIKey
                || providerSettings.hasAPIKey(for: configuration.kind))
            && !viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sanitizedSelectedPageIndices: [Int] {
        AIPageSelectionSpecification.sanitized(
            viewModel.selectedPageIndices,
            pageCount: workspace.pageCount
        )
    }

    private var hasValidSelectedPageSelection: Bool {
        guard viewModel.scope == .selectedPages else { return true }
        let rawSelection = viewModel.selectedPageIndices
        let selectedIndices = sanitizedSelectedPageIndices
        return !selectedIndices.isEmpty
            && selectedIndices.count <= AIPageSelectionSpecification.maximumCount
            && rawSelection == Set(selectedIndices)
    }

    private var selectedPagesRequiredHelp: String {
        L10n.string(
            "ai.pages.selection_required_help",
            defaultValue: "AI에 보낼 페이지를 먼저 선택해 주세요."
        )
    }

    private var selectedPageAccessibilityValue: String {
        let selectedIndices = sanitizedSelectedPageIndices
        guard !selectedIndices.isEmpty else { return selectedPagesRequiredHelp }
        return "\(AIPageSelectionSpecification.compactDescription(selectedIndices)), "
            + L10n.format("ai.pages.selection_count", selectedIndices.count)
    }

    private var sendButtonHelp: String {
        guard hasValidSelectedPageSelection else { return selectedPagesRequiredHelp }
        return L10n.string("ai.send", defaultValue: "검토 후 AI로 보내기")
    }

    private func presentPageSelection() {
        viewModel.normalizeSelectedPageIndices(for: workspace)
        pageSelectionDraft = Set(
            AIPageSelectionSpecification.sanitized(
                viewModel.selectedPageIndices,
                pageCount: workspace.pageCount
            )
        )
        showingPageSelectionPopover = true
    }

    private func applyPageSelection() {
        let sanitized = AIPageSelectionSpecification.sanitized(
            pageSelectionDraft,
            pageCount: workspace.pageCount
        )
        guard
            !sanitized.isEmpty,
            sanitized.count <= AIPageSelectionSpecification.maximumCount
        else { return }
        viewModel.selectedPageIndices = Set(sanitized)
        showingPageSelectionPopover = false
    }

    private var activeOptionalToolCount: Int {
        (viewModel.allowsWebSearch ? 1 : 0) + (viewModel.allowsMCPTools ? 1 : 0)
    }

    private var optionalToolsHelp: String {
        [webSearchHelp, mcpHelp].joined(separator: "\n")
    }

    private var optionalToolsAccessibilityValue: String {
        var enabled: [String] = []
        if viewModel.allowsWebSearch {
            enabled.append(L10n.string("ai.web_search", defaultValue: "웹 검색"))
        }
        if viewModel.allowsMCPTools {
            enabled.append(L10n.string("ai.mcp_tools", defaultValue: "MCP 도구"))
        }
        return enabled.isEmpty
            ? L10n.string("ai.optional_tools.none", defaultValue: "사용 안 함")
            : enabled.joined(separator: ", ")
    }

    private var webSearchAvailable: Bool {
        configuration.capabilities.supportsWebSearch && configuration.isWebSearchEnabled
    }

    private var mcpAvailable: Bool {
        configuration.capabilities.supportsRemoteMCP
            && !configuration.remoteMCPServers.isEmpty
    }

    private var webSearchHelp: String {
        webSearchAvailable
            ? L10n.string("ai.web_search.help", defaultValue: "공급자의 웹 검색 도구를 이번 요청에만 허용합니다.")
            : L10n.string("ai.web_search.unavailable", defaultValue: "이 공급자 설정에서는 웹 검색을 사용할 수 없습니다.")
    }

    private var mcpHelp: String {
        mcpAvailable
            ? L10n.string("ai.mcp_tools.help", defaultValue: "MCP 도구 호출은 실행 전에 항상 승인해야 합니다.")
            : L10n.string("ai.mcp_tools.unavailable", defaultValue: "설정에 사용 가능한 원격 MCP 서버가 없습니다.")
    }
}

private struct AISelectedPagesPopover: View {
    @ObservedObject var workspace: PDFWorkspaceState
    @Binding var selection: Set<Int>
    let onCancel: () -> Void
    let onApply: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var rangeFieldIsFocused: Bool
    @State private var rangeDraft = ""
    @State private var rangeError: String?

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }
    private var selectedIndices: [Int] {
        AIPageSelectionSpecification.sanitized(
            selection,
            pageCount: workspace.pageCount
        )
    }
    private var maximumCount: Int { AIPageSelectionSpecification.maximumCount }
    private var canApply: Bool {
        !selectedIndices.isEmpty && selectedIndices.count <= maximumCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            quickSelectionActions
            Divider()
            rangeEntry
            pageNumberGrid
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 370)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .accessibilityIdentifier("ai-page-selection-popover")
        .onAppear(perform: normalizeSelection)
        .onChange(of: workspace.pageCount) { _, _ in
            normalizeSelection()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(
                L10n.string(
                    "ai.pages.popover.title",
                    defaultValue: "AI에 보낼 페이지"
                )
            )
            .font(.headline)

            Spacer(minLength: 6)

            Text(L10n.format("ai.pages.selection_count", selectedIndices.count))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(theme.accent)
            Text(L10n.format("ai.pages.maximum", maximumCount))
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var quickSelectionActions: some View {
        HStack(spacing: 6) {
            Button {
                selection = workspace.pageCount > 0 ? [workspace.currentPageIndex] : []
                rangeError = nil
            } label: {
                Label(
                    L10n.string("ai.pages.use_current", defaultValue: "현재 페이지"),
                    systemImage: "doc.text"
                )
            }
            .accessibilityIdentifier("ai-page-use-current")

            Button {
                importSidebarSelection()
            } label: {
                Label(
                    L10n.string(
                        "ai.pages.import_sidebar",
                        defaultValue: "사이드바 선택 가져오기"
                    ),
                    systemImage: "sidebar.left"
                )
            }
            .disabled(workspace.selectedPages.isEmpty)
            .accessibilityIdentifier("ai-page-import-sidebar")

            Spacer(minLength: 0)

            Button(L10n.string("action.clear", defaultValue: "지우기")) {
                selection.removeAll()
                rangeError = nil
            }
            .accessibilityIdentifier("ai-page-clear")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
    }

    private var rangeEntry: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(
                L10n.string(
                    "ai.pages.range.label",
                    defaultValue: "페이지 번호 또는 범위"
                )
            )
            .font(.caption.weight(.semibold))

            HStack(spacing: 6) {
                TextField(
                    L10n.string(
                        "ai.pages.range.placeholder",
                        defaultValue: "예: 1-3, 5, 8"
                    ),
                    text: $rangeDraft
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .focused($rangeFieldIsFocused)
                .onSubmit(addEnteredPages)
                .onChange(of: rangeDraft) { _, _ in
                    rangeError = nil
                }
                .accessibilityLabel(
                    L10n.string(
                        "ai.pages.range.label",
                        defaultValue: "페이지 번호 또는 범위"
                    )
                )
                .accessibilityIdentifier("ai-page-range-entry")

                Button(L10n.string("ai.pages.range.add", defaultValue: "추가")) {
                    addEnteredPages()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(rangeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("ai-page-range-add")
            }

            Text(
                rangeError ?? L10n.string(
                    "ai.pages.range.help",
                    defaultValue: "쉼표로 페이지를 나누고 하이픈으로 범위를 입력하세요."
                )
            )
            .font(.caption2)
            .foregroundStyle(rangeError == nil ? theme.secondaryText : theme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pageNumberGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.string("ai.pages.grid.title", defaultValue: "페이지 직접 선택"))
                    .font(.caption.weight(.semibold))
                Spacer()
                if !selectedIndices.isEmpty {
                    Text(AIPageSelectionSpecification.compactDescription(selectedIndices))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 38, maximum: 46), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(0..<workspace.pageCount, id: \.self) { pageIndex in
                        pageToggle(pageIndex)
                    }
                }
                .padding(7)
            }
            .frame(minHeight: 112, maxHeight: 205)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if selectedIndices.isEmpty {
                Label(
                    L10n.string(
                        "ai.pages.empty",
                        defaultValue: "페이지를 한 개 이상 선택해 주세요."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(theme.warning)
            }

            Spacer(minLength: 4)

            Button(L10n.string("action.cancel", defaultValue: "취소"), action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("ai-page-cancel")
            Button(L10n.string("action.apply", defaultValue: "적용"), action: onApply)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
                .accessibilityIdentifier("ai-page-apply")
        }
    }

    private func pageToggle(_ pageIndex: Int) -> some View {
        let isSelected = selection.contains(pageIndex)
        return Button {
            if isSelected {
                selection.remove(pageIndex)
                rangeError = nil
            } else if selectedIndices.count < maximumCount {
                selection.insert(pageIndex)
                rangeError = nil
            } else {
                rangeError = L10n.format("ai.pages.too_many", maximumCount)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Text("\(pageIndex + 1)")
                    .font(.caption.monospacedDigit().weight(isSelected ? .bold : .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .black))
                        .padding(3)
                }
            }
            .frame(height: 30)
            .foregroundStyle(isSelected ? theme.chromeText : theme.primaryText)
            .background(
                isSelected ? theme.accent : theme.panel,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? theme.accent : theme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && selectedIndices.count >= maximumCount)
        .help(
            !isSelected && selectedIndices.count >= maximumCount
                ? L10n.format("ai.pages.too_many", maximumCount)
                : L10n.format("page.number", pageIndex + 1)
        )
        .accessibilityLabel(L10n.format("page.number", pageIndex + 1))
        .accessibilityValue(
            isSelected
                ? L10n.string("selection.selected")
                : L10n.string("selection.not_selected")
        )
        .accessibilityHint(
            !isSelected && selectedIndices.count >= maximumCount
                ? L10n.format("ai.pages.too_many", maximumCount)
                : ""
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("ai-page-toggle-\(pageIndex + 1)")
    }

    private func addEnteredPages() {
        do {
            let parsed = try AIPageSelectionSpecification.parse(
                rangeDraft,
                pageCount: workspace.pageCount
            )
            let combined = selection.union(parsed)
            guard combined.count <= maximumCount else {
                rangeError = L10n.format("ai.pages.too_many", maximumCount)
                return
            }
            selection = combined
            rangeDraft = ""
            rangeError = nil
            rangeFieldIsFocused = true
        } catch let error as AIPageSelectionError {
            rangeError = pageSelectionErrorMessage(error)
        } catch {
            rangeError = L10n.format("ai.pages.invalid_input", workspace.pageCount)
        }
    }

    private func importSidebarSelection() {
        let imported = AIPageSelectionSpecification.sanitized(
            workspace.selectedPages,
            pageCount: workspace.pageCount
        )
        guard imported.count <= maximumCount else {
            rangeError = L10n.format("ai.pages.too_many", maximumCount)
            return
        }
        selection = Set(imported)
        rangeError = nil
    }

    private func normalizeSelection() {
        selection = Set(
            AIPageSelectionSpecification.sanitized(
                selection,
                pageCount: workspace.pageCount
            )
        )
    }

    private func pageSelectionErrorMessage(_ error: AIPageSelectionError) -> String {
        switch error {
        case .tooMany:
            L10n.format("ai.pages.too_many", maximumCount)
        case .empty, .invalidFormat, .outOfBounds:
            L10n.format("ai.pages.invalid_input", workspace.pageCount)
        }
    }
}

private struct AIDraftApplicationRequest: Identifiable {
    let messageID: UUID
    let text: String
    let target: AIDraftApplicationTarget
    var id: UUID { messageID }
}

private struct AIAssistantMessageCard: View {
    let message: AIAssistantMessage
    let theme: VibePDFTheme
    let onOpenLocalCitation: (AILocalContextCitation) -> Void
    let onApplyDraft: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: message.role.systemImage)
                Text(message.role.title)
                Spacer(minLength: 4)
                if let providerName = message.providerName {
                    Text(providerName)
                        .lineLimit(1)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.secondaryText)

            AIAssistantMarkdownText(message.text, theme: theme)
                .textSelection(.enabled)

            if !citedLocalCitations.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        L10n.string(
                            "ai.pdf_sources",
                            defaultValue: "응답에 인용된 PDF 근거"
                        )
                    )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 82), spacing: 5)],
                        alignment: .leading,
                        spacing: 5
                    ) {
                        ForEach(citedLocalCitations) { citation in
                            Button {
                                onOpenLocalCitation(citation)
                            } label: {
                                Label(
                                    "\(citation.citationID) · p.\(citation.pageNumber)",
                                    systemImage: "doc.text"
                                )
                                .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .help("\(citation.documentTitle) · p.\(citation.pageNumber)")
                        }
                    }
                }
            }

            if !safeCitations.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.string("ai.sources", defaultValue: "출처"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                    ForEach(safeCitations) { citation in
                        Link(destination: citation.url) {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.up.right.square")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(citation.title)
                                        .lineLimit(2)
                                    Text(citation.url.host ?? citation.url.absoluteString)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(theme.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            if message.allowsDraftApplication {
                Button(action: onApplyDraft) {
                    Label(
                        L10n.string("ai.draft.apply", defaultValue: "PDF에 초안 적용…"),
                        systemImage: "text.badge.plus"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .help(
                    L10n.string(
                        "ai.draft.apply.help",
                        defaultValue: "확인 후 편집 가능한 텍스트로 추가합니다."
                    )
                )
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? theme.dropHighlight : theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
        .padding(.leading, message.role == .user ? 12 : 0)
        .padding(.trailing, message.role == .assistant ? 12 : 0)
    }

    private var safeCitations: [AISourceCitation] {
        message.citations.filter {
            AIEndpointPolicy.isValidExternalWebURL($0.url)
        }
    }

    private var citedLocalCitations: [AILocalContextCitation] {
        message.localCitations.filter {
            message.text.contains("[\($0.citationID)]")
        }
    }
}

private struct AIAssistantMarkdownText: View {
    private let value: String
    private let theme: VibePDFTheme

    init(_ text: String, theme: VibePDFTheme) {
        value = text
        self.theme = theme
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(
                Array(AIAssistantDisplayFormatter.blocks(from: value).enumerated()),
                id: \.offset
            ) { _, block in
                switch block {
                case let .markdown(source):
                    Text(AIAssistantMarkdownFormatter.attributedString(from: source))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                case let .displayMath(expression):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(expression)
                            .font(.system(size: 16, weight: .medium, design: .serif))
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        theme.dropHighlight.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    }
                    .accessibilityLabel(expression)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AIMCPApprovalSection: View {
    let session: AIMCPApprovalSession
    let decisions: [String: Bool]
    let isResolving: Bool
    let theme: VibePDFTheme
    let setDecision: (AIMCPApprovalRequest, Bool) -> Void
    let submit: () -> Void

    private var allDecided: Bool {
        session.requests.allSatisfy {
            matchingServer(for: $0) != nil
                && decisions[$0.approvalRequestID] != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.string("ai.mcp.approval_title", defaultValue: "MCP 도구 실행 승인"),
                systemImage: "checkmark.shield"
            )
            .font(.headline)

            Text(
                L10n.string(
                    "ai.mcp.approval_message",
                    defaultValue: "서버, 도구 이름, 전달 인자를 확인하세요. 승인한 도구만 실행 요청으로 전송됩니다."
                )
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryText)

            ForEach(session.requests) { request in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(request.serverLabel, systemImage: "server.rack")
                            if let serverURL = serverURL(for: request) {
                                Text(serverURL.absoluteString)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(theme.secondaryText)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(request.name)
                            .font(.caption.monospaced().weight(.semibold))
                    }
                    .font(.caption.weight(.semibold))

                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(request.arguments)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .padding(7)
                    }
                    .frame(maxHeight: 88)
                    .background(theme.canvas.opacity(0.58), in: RoundedRectangle(cornerRadius: 7))

                    if matchingServer(for: request) == nil {
                        Label(
                            L10n.string(
                                "ai.mcp.unknown_server",
                                defaultValue: "설정과 정확히 일치하는 MCP 서버가 없어 승인할 수 없습니다."
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(theme.warning)
                    }

                    HStack(spacing: 7) {
                        decisionButton(
                            title: L10n.string("ai.mcp.reject", defaultValue: "거부"),
                            systemImage: "xmark.circle",
                            value: false,
                            request: request
                        )
                        decisionButton(
                            title: L10n.string("ai.mcp.approve", defaultValue: "승인"),
                            systemImage: "checkmark.circle",
                            value: true,
                            request: request
                        )
                    }
                }
                .padding(9)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(theme.border, lineWidth: 1)
                }
            }

            Button(action: submit) {
                Label(
                    L10n.string("ai.mcp.submit_decisions", defaultValue: "결정 전송"),
                    systemImage: "paperplane"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!allDecided || isResolving)
        }
        .padding(11)
        .background(theme.ribbonSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(theme.ribbon.opacity(0.42), lineWidth: 1)
        }
    }

    private func decisionButton(
        title: String,
        systemImage: String,
        value: Bool,
        request: AIMCPApprovalRequest
    ) -> some View {
        let isSelected = decisions[request.approvalRequestID] == value
        return Button {
            setDecision(request, value)
        } label: {
            Label(title, systemImage: isSelected ? "checkmark.circle.fill" : systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(value ? theme.success : theme.warning)
        .disabled(isResolving || matchingServer(for: request) == nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func serverURL(for request: AIMCPApprovalRequest) -> URL? {
        guard matchingServer(for: request) != nil else { return nil }
        return request.serverURL
    }

    private func matchingServer(for request: AIMCPApprovalRequest) -> AIRemoteMCPServer? {
        let matches = session.configuration.remoteMCPServers.filter {
            $0.label == request.serverLabel
        }
        guard matches.count == 1 else { return nil }
        let match = matches[0]
        guard request.serverURL == match.serverURL else { return nil }
        return match
    }
}

private struct AITransmissionConsentSheet: View {
    let consent: AITransmissionConsent
    let theme: VibePDFTheme
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var acknowledged = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                consentDetails
                    .padding(22)
            }

            Divider()

            consentFooter
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 570)
        .frame(minHeight: 520, idealHeight: 700, maxHeight: 780)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
    }

    private var consentDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.square.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(theme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("ai.consent.title", defaultValue: "외부 AI로 보내기 전 확인"))
                        .font(.title3.weight(.bold))
                    Text(
                        L10n.string(
                            "ai.consent.message",
                            defaultValue: "아래 PDF 내용은 선택한 AI 공급자의 서버로 전송됩니다. HwattakPDF는 API 키를 요청 내용에 포함하지 않습니다."
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                consentRow(
                    L10n.string("ai.provider", defaultValue: "AI 공급자"),
                    "\(consent.configuration.name) · \(consent.configuration.model)"
                )
                consentRow(
                    L10n.string("ai.destination", defaultValue: "전송 대상"),
                    consent.configuration.baseURL.host ?? consent.configuration.baseURL.absoluteString
                )
                consentRow(
                    L10n.string("ai.context_scope", defaultValue: "전송 범위"),
                    consent.scope.title
                )
                if !consent.requestedPageIndices.isEmpty {
                    consentRow(
                        L10n.string(
                            "ai.consent.requested_pages",
                            defaultValue: "요청한 페이지"
                        ),
                        pageListValue(consent.requestedPageIndices)
                    )
                }
                if !consent.context.includedPageIndices.isEmpty {
                    consentRow(
                        L10n.string(
                            "ai.consent.included_pages",
                            defaultValue: "실제 포함 페이지"
                        ),
                        pageListValue(consent.context.includedPageIndices)
                    )
                }
                consentRow(
                    L10n.string("ai.context_size", defaultValue: "전송 분량"),
                    L10n.format(
                        "ai.context_size.value",
                        consent.context.sources.count,
                        consent.contextTransmissionCharacterCount
                    )
                )
                consentRow(
                    L10n.string("ai.consent.history_size", defaultValue: "이전 대화"),
                    L10n.format(
                        "ai.consent.history_size.value",
                        consent.conversation.count,
                        consent.conversationCharacterCount
                    )
                )
                consentRow(
                    L10n.string("ai.consent.instructions_size", defaultValue: "지시·질문"),
                    L10n.format(
                        "ai.consent.instructions_size.value",
                        consent.systemCharacterCount + consent.promptCharacterCount
                    )
                )
                consentRow(
                    L10n.string(
                        "ai.consent.total_size",
                        defaultValue: "사용자 콘텐츠 합계 (정적 JSON/API 래퍼 제외)"
                    ),
                    L10n.format(
                        "ai.consent.total_size.value",
                        consent.totalOutboundCharacterCount,
                        consent.totalOutboundUTF8ByteCount
                    )
                )
            }
            .font(.caption)

            if consent.context.wasTruncated {
                Label(
                    L10n.string(
                        "ai.context.truncated",
                        defaultValue: "성능과 개인정보 보호를 위해 일부 페이지만 대표로 추출했습니다."
                    ),
                    systemImage: "scissors"
                )
                .font(.caption)
                .foregroundStyle(theme.warning)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.string("ai.consent.preview", defaultValue: "전송 내용 미리보기"))
                    .font(.caption.weight(.semibold))
                ScrollView {
                    Text(consent.previewText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 190)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                }
            }

            HStack(spacing: 8) {
                if consent.allowsWebSearch {
                    consentBadge(
                        L10n.string("ai.web_search", defaultValue: "웹 검색 허용"),
                        systemImage: "globe"
                    )
                }
                if consent.allowsMCPTools {
                    consentBadge(
                        L10n.format("ai.mcp.server_count", consent.configuration.remoteMCPServers.count),
                        systemImage: "server.rack"
                    )
                }
                if !consent.allowsWebSearch && !consent.allowsMCPTools {
                    consentBadge(
                        L10n.string("ai.no_external_tools", defaultValue: "추가 외부 도구 없음"),
                        systemImage: "checkmark.shield"
                    )
                }
            }

            if consent.allowsWebSearch {
                Label(
                    L10n.string(
                        "ai.web_search.transmission_warning",
                        defaultValue: "질문과 PDF 문맥을 바탕으로 만든 검색어가 AI 공급자와 검색 서비스에 전달될 수 있습니다. PDF 안의 명령이나 URL은 도구 호출 지시로 신뢰하지 않으며, 검색 결과 사이트에는 PDF 원문을 직접 전송하지 않습니다."
                    ),
                    systemImage: "globe.badge.chevron.backward"
                )
                .font(.caption)
                .foregroundStyle(theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            }

            if consent.allowsMCPTools {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(consent.configuration.remoteMCPServers) { server in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.label)
                                .font(.caption.weight(.semibold))
                            Text(server.serverURL.absoluteString)
                                .font(.caption2.monospaced())
                                .foregroundStyle(theme.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 8))

                Label(
                    L10n.string(
                        "ai.mcp.storage_warning",
                        defaultValue: "MCP 승인 연속 요청을 위해 이 요청은 OpenAI 측에 store=true로 처리되며 계정과 공급자의 보존 정책이 적용됩니다. 승인한 도구의 이름과 인자는 위 제3자 MCP 서버로 전송될 수 있습니다. 일반 질문과 웹 검색 요청은 저장을 요청하지 않습니다."
                    ),
                    systemImage: "externaldrive.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(9)
                .background(theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var consentFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $acknowledged) {
                Text(
                    L10n.string(
                        "ai.consent.acknowledge",
                        defaultValue: "표시된 PDF 내용과 질문을 위 공급자로 전송하는 데 동의합니다."
                    )
                )
                .font(.callout.weight(.semibold))
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button(L10n.string("action.cancel", defaultValue: "취소"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("ai.consent.send", defaultValue: "동의하고 보내기")) {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!acknowledged)
            }
        }
    }

    private func consentRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pageListValue<S: Sequence>(_ pageIndices: S) -> String
    where S.Element == Int {
        let sanitized = AIPageSelectionSpecification.sanitized(
            pageIndices,
            pageCount: consent.context.documentPageCount
        )
        return "\(AIPageSelectionSpecification.compactDescription(sanitized)) · "
            + L10n.format("ai.pages.selection_count", sanitized.count)
    }

    private func consentBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(theme.dropHighlight, in: Capsule())
    }
}
