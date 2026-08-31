// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
@testable import VibePDF

@MainActor
final class AIAssistantSessionModelTests: XCTestCase {
    func testRequestRequiresConsentBeforeCompletionAndDropsContextAfterCancel() async {
        var completionCallCount = 0
        let model = makeModel { _, configuration in
            completionCallCount += 1
            return AICompletionResponse(text: "unused", provider: configuration.kind)
        }
        model.prompt = "Summarize the evidence"

        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )

        XCTAssertEqual(model.phase, .preparingContext)
        await waitUntil { model.phase == .awaitingConsent }
        XCTAssertNotNil(model.pendingConsent)
        XCTAssertEqual(completionCallCount, 0)

        model.cancelActiveRequest()
        XCTAssertNil(model.pendingConsent)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(completionCallCount, 0)
    }

    func testConfirmedResponseRetainsOnlyLightweightLocalCitationMetadata() async {
        let model = makeModel { _, configuration in
            AICompletionResponse(
                text: "Claim supported by [S1].",
                provider: configuration.kind
            )
        }
        model.prompt = "Analyze"
        model.beginRequest(
            action: .analyze,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )

        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()
        await waitUntil { model.phase == .idle }

        XCTAssertNil(model.pendingConsent)
        XCTAssertEqual(model.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(model.messages.last?.localCitations.first?.citationID, "S1")
        XCTAssertEqual(model.messages.last?.localCitations.first?.pageNumber, 3)
        XCTAssertFalse(model.messages.last?.text.contains("private context body") ?? true)
    }

    func testPendingConsentBlocksASecondRequest() async {
        let model = makeModel { _, configuration in
            AICompletionResponse(text: "unused", provider: configuration.kind)
        }
        model.prompt = "First"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        let firstConsentID = model.pendingConsent?.id

        model.prompt = "Second"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )

        XCTAssertEqual(model.pendingConsent?.id, firstConsentID)
        XCTAssertNotNil(model.errorMessage)
    }

    func testUnknownMCPServerCannotBeApproved() async {
        var configuration = configuration(kind: .openAI)
        configuration.remoteMCPServers = [
            AIRemoteMCPServer(
                label: "known_server",
                serverURL: URL(string: "https://mcp.example.com")!
            )
        ]
        let unknownRequest = AIMCPApprovalRequest(
            approvalRequestID: "approval-1",
            name: "read",
            arguments: "{}",
            serverLabel: "unknown_server"
        )
        let model = makeModel { _, _ in
            AICompletionResponse(
                text: "",
                provider: .openAI,
                responseID: "response-1",
                pendingMCPApprovals: [unknownRequest]
            )
        }
        model.prompt = "Use a tool"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration,
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()
        await waitUntil { model.phase == .awaitingMCPApproval }

        model.setMCPDecision(unknownRequest, true)
        XCTAssertTrue(model.mcpApprovalDecisions.isEmpty)

        model.prompt = "Start another request"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration,
            hasAPIKey: true
        )
        XCTAssertEqual(model.phase, .awaitingMCPApproval)
        XCTAssertEqual(model.mcpApprovalSession?.responseID, "response-1")
        XCTAssertNotNil(model.errorMessage)

        model.cancelActiveRequest()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.mcpApprovalSession)
    }

    func testDuplicateMCPServerLabelCannotBeApproved() async {
        var configuration = configuration(kind: .openAI)
        configuration.remoteMCPServers = [
            AIRemoteMCPServer(
                label: "duplicate",
                serverURL: URL(string: "https://one.example.com")!
            ),
            AIRemoteMCPServer(
                label: "duplicate",
                serverURL: URL(string: "https://two.example.com")!
            )
        ]
        let request = AIMCPApprovalRequest(
            approvalRequestID: "approval-duplicate",
            name: "read",
            arguments: "{}",
            serverLabel: "duplicate",
            serverURL: URL(string: "https://one.example.com")!
        )
        let model = makeModel { _, _ in
            AICompletionResponse(
                text: "",
                provider: .openAI,
                responseID: "response-duplicate",
                pendingMCPApprovals: [request]
            )
        }
        model.prompt = "Use a tool"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration,
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()
        await waitUntil { model.phase == .awaitingMCPApproval }

        model.setMCPDecision(request, true)
        model.submitMCPApprovalDecisions()
        XCTAssertTrue(model.mcpApprovalDecisions.isEmpty)
        XCTAssertEqual(model.phase, .awaitingMCPApproval)
    }

    func testMCPServerURLMustExactlyMatchConfiguration() async {
        var configuration = configuration(kind: .openAI)
        configuration.remoteMCPServers = [
            AIRemoteMCPServer(
                label: "trusted",
                serverURL: URL(string: "https://trusted.example.com")!
            )
        ]
        let request = AIMCPApprovalRequest(
            approvalRequestID: "approval-mismatch",
            name: "read",
            arguments: "{}",
            serverLabel: "trusted",
            serverURL: URL(string: "https://different.example.com")!
        )
        let model = makeModel { _, _ in
            AICompletionResponse(
                text: "",
                provider: .openAI,
                responseID: "response-mismatch",
                pendingMCPApprovals: [request]
            )
        }
        model.prompt = "Use a tool"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration,
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()
        await waitUntil { model.phase == .awaitingMCPApproval }

        model.setMCPDecision(request, true)
        XCTAssertTrue(model.mcpApprovalDecisions.isEmpty)
    }

    func testProviderChangeClearsConversationInsteadOfForwardingIt() async {
        let model = makeModel { _, configuration in
            AICompletionResponse(text: "Provider response", provider: configuration.kind)
        }
        model.prompt = "Question"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()
        await waitUntil { model.phase == .idle }
        XCTAssertFalse(model.messages.isEmpty)

        model.providerDidChange()
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.mcpApprovalSession)
    }

    func testInactiveTabDoesNotForwardConversationAfterProviderConfigurationChanges() async {
        let model = makeModel { _, configuration in
            AICompletionResponse(
                text: "Response from \(configuration.kind.rawValue)",
                provider: configuration.kind
            )
        }
        var firstConfiguration = configuration(kind: .openAI)
        firstConfiguration.id = UUID()
        model.prompt = "First provider question"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: firstConfiguration,
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()
        await waitUntil { model.phase == .idle }
        XCTAssertEqual(model.messages.count, 2)

        var secondConfiguration = configuration(kind: .anthropic)
        secondConfiguration.id = UUID()
        model.prompt = "Second provider question"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: secondConfiguration,
            hasAPIKey: true
        )

        await waitUntil { model.phase == .awaitingConsent }
        XCTAssertEqual(model.phase, .awaitingConsent)
        XCTAssertTrue(model.pendingConsent?.conversation.isEmpty == true)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testCustomEndpointChangeDoesNotForwardPriorEndpointConversation() async {
        let model = makeModel { _, configuration in
            AICompletionResponse(
                text: "Endpoint response",
                provider: configuration.kind
            )
        }
        var configuration = configuration()
        configuration.id = UUID()
        configuration.baseURL = URL(string: "https://first.example/v1")!
        model.prompt = "Question for first endpoint"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration,
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()
        await waitUntil { model.phase == .idle }
        XCTAssertEqual(model.messages.count, 2)

        configuration.baseURL = URL(string: "https://second.example/v1")!
        model.prompt = "Question for second endpoint"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration,
            hasAPIKey: true
        )

        await waitUntil { model.phase == .awaitingConsent }
        XCTAssertEqual(model.phase, .awaitingConsent)
        XCTAssertTrue(model.pendingConsent?.conversation.isEmpty == true)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testConfirmedRequestUsesConsentSnapshotAndBoundedHistory() async {
        var captured: [(AICompletionRequest, AIProviderConfiguration)] = []
        let model = makeModel { request, configuration in
            captured.append((request, configuration))
            return AICompletionResponse(
                text: "Response \(captured.count)",
                provider: configuration.kind
            )
        }
        var selectedConfiguration = configuration()

        model.prompt = "First question"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: selectedConfiguration,
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()
        await waitUntil { captured.count == 1 && model.phase == .idle }

        model.prompt = "Second question"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: selectedConfiguration,
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        XCTAssertEqual(model.pendingConsent?.conversation.count, 2)
        selectedConfiguration.model = "mutated-after-consent"
        model.confirmPendingConsent()
        await waitUntil { captured.count == 2 && model.phase == .idle }

        XCTAssertEqual(captured[1].0.prompt, "Second question")
        XCTAssertEqual(captured[1].0.conversation.count, 2)
        XCTAssertTrue(captured[1].0.context?.contains("private context body") == true)
        XCTAssertEqual(captured[1].1.model, "test-model")
    }

    func testDocumentChangeClearsConsentHistoryAndApprovalState() async {
        let request = AIMCPApprovalRequest(
            approvalRequestID: "approval-clear",
            name: "read",
            arguments: "{}",
            serverLabel: "known_server",
            serverURL: URL(string: "https://mcp.example.com")!
        )
        var configuration = configuration(kind: .openAI)
        configuration.remoteMCPServers = [
            AIRemoteMCPServer(
                label: "known_server",
                serverURL: URL(string: "https://mcp.example.com")!
            )
        ]
        let model = makeModel { _, _ in
            AICompletionResponse(
                text: "",
                provider: .openAI,
                responseID: "response-clear",
                pendingMCPApprovals: [request]
            )
        }
        model.prompt = "Use a tool"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration,
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()
        await waitUntil { model.phase == .awaitingMCPApproval }

        model.documentDidChange()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.pendingConsent)
        XCTAssertNil(model.mcpApprovalSession)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(model.relatedPDFResults.isEmpty)
    }

    func testWorkspaceOpenAndCloseInvalidatePendingConsentSynchronously() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-AI-Document-Boundary-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let firstURL = directory.appendingPathComponent("first.pdf")
        let secondURL = directory.appendingPathComponent("second.pdf")
        for url in [firstURL, secondURL] {
            let document = PDFDocument()
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
            XCTAssertTrue(document.write(to: url))
        }

        var completionCallCount = 0
        let model = makeModel { _, configuration in
            completionCallCount += 1
            return AICompletionResponse(text: "must not send", provider: configuration.kind)
        }
        let workspace = PDFWorkspaceState(aiAssistantSession: model)
        XCTAssertTrue(workspace.open(url: firstURL))

        model.prompt = "Summarize the first private PDF"
        model.beginRequest(
            action: .summarize,
            workspace: workspace,
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        XCTAssertNotNil(model.pendingConsent)

        XCTAssertTrue(workspace.open(url: secondURL))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.pendingConsent)
        model.confirmPendingConsent()
        await Task.yield()
        XCTAssertEqual(completionCallCount, 0)

        model.prompt = "Analyze the second private PDF"
        model.beginRequest(
            action: .analyze,
            workspace: workspace,
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        XCTAssertNotNil(model.pendingConsent)

        workspace.close()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.pendingConsent)
        model.confirmPendingConsent()
        await Task.yield()
        XCTAssertEqual(completionCallCount, 0)
    }

    func testCancelDuringContextPreparationRejectsLateContextResult() async {
        var continuation: CheckedContinuation<PDFAIContextBundle, Never>?
        let model = makeModel(extractContext: { _, scope in
            await withCheckedContinuation { continuation = $0 }
        })
        model.prompt = "Analyze slowly"

        model.beginRequest(
            action: .analyze,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )

        XCTAssertEqual(model.phase, .preparingContext)
        await waitUntil { continuation != nil }
        model.allowsWebSearch = true
        model.allowsMCPTools = true
        model.cancelActiveRequest()
        continuation?.resume(returning: contextBundle(scope: .currentPage))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.pendingConsent)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.allowsWebSearch)
        XCTAssertFalse(model.allowsMCPTools)
    }

    func testContextPreparationUsesRequestTimePrivacySnapshot() async {
        var continuation: CheckedContinuation<PDFAIContextBundle, Never>?
        var requestedScope: PDFAIContextScope?
        let model = makeModel(extractContext: { _, scope in
            requestedScope = scope
            return await withCheckedContinuation { continuation = $0 }
        })
        var selectedConfiguration = configuration(kind: .openAI)
        selectedConfiguration.isWebSearchEnabled = true
        selectedConfiguration.remoteMCPServers = [
            AIRemoteMCPServer(
                label: "trusted",
                serverURL: URL(string: "https://mcp.example.com")!
            )
        ]
        model.scope = .currentPage
        model.allowsWebSearch = true
        model.allowsMCPTools = true
        model.prompt = "Snapshot this request"

        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: selectedConfiguration,
            hasAPIKey: true
        )
        XCTAssertFalse(model.allowsWebSearch)
        XCTAssertFalse(model.allowsMCPTools)
        await waitUntil { continuation != nil }

        model.scope = .wholeDocument
        model.allowsWebSearch = false
        model.allowsMCPTools = false
        model.prompt = "Mutated after request"
        selectedConfiguration.model = "mutated-model"
        continuation?.resume(
            returning: contextBundle(scope: requestedScope ?? .currentPage)
        )
        await waitUntil { model.phase == .awaitingConsent }

        XCTAssertEqual(model.pendingConsent?.scope, .currentPage)
        XCTAssertEqual(model.pendingConsent?.context.scope, .currentPage)
        XCTAssertEqual(model.pendingConsent?.prompt, "Snapshot this request")
        XCTAssertEqual(model.pendingConsent?.configuration.model, "test-model")
        XCTAssertTrue(model.pendingConsent?.allowsWebSearch == true)
        XCTAssertTrue(model.pendingConsent?.allowsMCPTools == true)
    }

    func testSelectedPageContextUsesFrozenAISelectionAndConsentMetadata() async throws {
        let fixture = try makeWorkspace(pageCount: 4)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        var requestedScope: PDFAIContextScope?
        let model = makeModel(extractContext: { [self] _, scope in
            requestedScope = scope
            return contextBundle(scope: scope)
        })
        model.scope = .selectedPages
        model.selectedPageIndices = [3, 0]
        model.prompt = "Use only the approved pages"

        model.beginRequest(
            action: nil,
            workspace: fixture.workspace,
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        // Both selections are mutable presentation state. Neither may change
        // the immutable scope captured synchronously by beginRequest.
        model.selectedPageIndices = [1]
        fixture.workspace.selectedPages = [2]

        await waitUntil { model.phase == .awaitingConsent }

        XCTAssertEqual(requestedScope, .pageIndices([0, 3]))
        XCTAssertEqual(model.pendingConsent?.scope, .selectedPages)
        XCTAssertEqual(model.pendingConsent?.context.scope, .pageIndices([0, 3]))
        XCTAssertEqual(model.pendingConsent?.requestedPageIndices, [0, 3])
    }

    func testSelectedPageScopeRejectsInvalidStateBeforeContextExtraction() async throws {
        let fixture = try makeWorkspace(pageCount: AIPageSelectionSpecification.maximumCount + 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        var extractionCallCount = 0
        var completionCallCount = 0
        let model = AIAssistantSessionModel(
            complete: { _, configuration in
                completionCallCount += 1
                return AICompletionResponse(text: "must not send", provider: configuration.kind)
            },
            resolveApprovals: { _, _, configuration in
                AICompletionResponse(text: "unused", provider: configuration.kind)
            },
            extractContext: { [self] _, scope in
                extractionCallCount += 1
                return contextBundle(scope: scope)
            },
            searchRelatedPDFs: { _, _, _ in [] }
        )
        model.scope = .selectedPages
        model.prompt = "Reject invalid context"

        let invalidSelections: [Set<Int>] = [
            [],
            [fixture.workspace.pageCount],
            Set(0...AIPageSelectionSpecification.maximumCount),
        ]
        for selection in invalidSelections {
            model.selectedPageIndices = selection
            model.beginRequest(
                action: nil,
                workspace: fixture.workspace,
                documentCollection: nil,
                configuration: configuration(),
                hasAPIKey: true
            )

            XCTAssertEqual(model.phase, .idle)
            XCTAssertNil(model.pendingConsent)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(extractionCallCount, 0)
            XCTAssertEqual(completionCallCount, 0)
        }
        await Task.yield()
        XCTAssertEqual(extractionCallCount, 0)
        XCTAssertEqual(completionCallCount, 0)
    }

    func testSelectedPageNormalizationImportsBoundedSidebarSelectionAndClearsOnDocumentChange() throws {
        let fixture = try makeWorkspace(pageCount: AIPageSelectionSpecification.maximumCount + 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let model = makeModel { _, configuration in
            AICompletionResponse(text: "unused", provider: configuration.kind)
        }

        fixture.workspace.selectedPages = [1, 3]
        fixture.workspace.setCurrentPage(3)
        model.normalizeSelectedPageIndices(for: fixture.workspace)
        XCTAssertEqual(model.selectedPageIndices, [1, 3])

        model.documentDidChange()
        XCTAssertTrue(model.selectedPageIndices.isEmpty)

        fixture.workspace.selectedPages = Set(0...AIPageSelectionSpecification.maximumCount)
        fixture.workspace.setCurrentPage(7)
        model.normalizeSelectedPageIndices(for: fixture.workspace)
        XCTAssertEqual(
            model.selectedPageIndices,
            [7],
            "An oversized sidebar selection must default to the current page, not truncate."
        )
    }

    func testPreparingAIDraftDoesNotDirtyOrMutatePDFBeforeUserCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-AIDraft-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = PDFDocument()
        let image = NSImage(size: NSSize(width: 320, height: 420))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        source.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let url = directory.appendingPathComponent("draft.pdf")
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        let originalAnnotationCount = try XCTUnwrap(workspace.document?.page(at: 0))
            .annotations.count

        XCTAssertTrue(workspace.prepareAITextDraft("Review this draft"))

        XCTAssertEqual(workspace.pendingTextEdit?.initialText, "Review this draft")
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(
            workspace.document?.page(at: 0)?.annotations.count,
            originalAnnotationCount
        )
    }

    func testStudyAIActionStillStopsAtConsentBeforeNetworkRequest() async {
        var completionCallCount = 0
        var transmittedSystemPrompt = ""
        let model: AIAssistantSessionModel = makeModel {
            (request: AICompletionRequest, configuration: AIProviderConfiguration) in
            completionCallCount += 1
            transmittedSystemPrompt = request.systemPrompt ?? ""
            return AICompletionResponse(text: "translated", provider: configuration.kind)
        }

        model.scope = .selection
        model.beginRequest(
            action: .translate,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )

        await waitUntil { model.phase == .awaitingConsent }
        XCTAssertEqual(completionCallCount, 0, "Preparing a study action must never auto-send PDF text.")
        XCTAssertEqual(model.pendingConsent?.scope, .selection)
        XCTAssertEqual(model.pendingConsent?.prompt, AIQuickAction.translate.suggestedPrompt)

        model.confirmPendingConsent()
        await waitUntil { model.phase == .idle }
        XCTAssertEqual(completionCallCount, 1)
        XCTAssertTrue(transmittedSystemPrompt.contains("Translate faithfully"))
    }

    func testStudyActionsMapSafelyAndOnlyLearningSpecificActionsStayOutOfGeneralPalette() {
        XCTAssertTrue(AIQuickAction.generalActions.contains(.translate))
        XCTAssertFalse(AIQuickAction.generalActions.contains(.explainTerms))
        XCTAssertFalse(AIQuickAction.generalActions.contains(.studyPoints))
        XCTAssertFalse(AIQuickAction.generalActions.contains(.quiz))
        XCTAssertEqual(StudyAIQuickAction.translate.assistantAction, .translate)
        XCTAssertEqual(StudyAIQuickAction.explainTerms.assistantAction, .explainTerms)
        XCTAssertEqual(StudyAIQuickAction.summarize.assistantAction, .summarize)
        XCTAssertEqual(StudyAIQuickAction.solveWithSteps.assistantAction, .solve)
        XCTAssertEqual(StudyAIQuickAction.studyPoints.assistantAction, .studyPoints)
        XCTAssertEqual(StudyAIQuickAction.quiz.assistantAction, .quiz)
    }

    func testQuickActionExecutionPolicyRejectsKnownDeadEndsBeforeContextExtraction() {
        let baseArguments = (
            phase: AIAssistantPhase.idle,
            hasOpenDocument: true,
            hasDocumentCollection: true,
            providerRequiresAPIKey: true,
            hasAPIKey: true,
            webSearchAvailable: true
        )

        for action in AIQuickAction.generalActions {
            XCTAssertTrue(
                AIQuickActionExecutionPolicy.isAvailable(
                    action,
                    phase: baseArguments.phase,
                    hasOpenDocument: baseArguments.hasOpenDocument,
                    hasDocumentCollection: baseArguments.hasDocumentCollection,
                    providerRequiresAPIKey: baseArguments.providerRequiresAPIKey,
                    hasAPIKey: baseArguments.hasAPIKey,
                    webSearchAvailable: baseArguments.webSearchAvailable
                ),
                "Expected \(action.rawValue) to be available in a fully configured workspace"
            )
        }

        XCTAssertFalse(AIQuickActionExecutionPolicy.isAvailable(
            .webResearch,
            phase: .idle,
            hasOpenDocument: true,
            hasDocumentCollection: true,
            providerRequiresAPIKey: true,
            hasAPIKey: true,
            webSearchAvailable: false
        ))
        XCTAssertFalse(AIQuickActionExecutionPolicy.isAvailable(
            .summarize,
            phase: .idle,
            hasOpenDocument: true,
            hasDocumentCollection: true,
            providerRequiresAPIKey: true,
            hasAPIKey: false,
            webSearchAvailable: true
        ))
        XCTAssertTrue(AIQuickActionExecutionPolicy.isAvailable(
            .relatedPDFs,
            phase: .idle,
            hasOpenDocument: true,
            hasDocumentCollection: true,
            providerRequiresAPIKey: true,
            hasAPIKey: false,
            webSearchAvailable: false
        ))
        XCTAssertFalse(AIQuickActionExecutionPolicy.isAvailable(
            .relatedPDFs,
            phase: .idle,
            hasOpenDocument: true,
            hasDocumentCollection: false,
            providerRequiresAPIKey: false,
            hasAPIKey: false,
            webSearchAvailable: false
        ))
        XCTAssertFalse(AIQuickActionExecutionPolicy.isAvailable(
            .translate,
            phase: .requesting,
            hasOpenDocument: true,
            hasDocumentCollection: true,
            providerRequiresAPIKey: false,
            hasAPIKey: false,
            webSearchAvailable: false
        ))
    }

    func testDirectQuickActionCallsRejectKnownDeadEndsBeforeReadingPDFContext() {
        var contextCallCount = 0
        let model = makeModel(extractContext: { _, scope in
            contextCallCount += 1
            return self.contextBundle(scope: scope)
        })
        let workspace = PDFWorkspaceState()
        var noWebConfiguration = configuration(kind: .openAI)
        noWebConfiguration.isWebSearchEnabled = false

        model.allowsWebSearch = true
        model.allowsMCPTools = true
        model.beginRequest(
            action: .webResearch,
            workspace: workspace,
            documentCollection: nil,
            configuration: noWebConfiguration,
            hasAPIKey: true
        )
        XCTAssertEqual(contextCallCount, 0)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.pendingConsent)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.allowsWebSearch)
        XCTAssertFalse(model.allowsMCPTools)

        var requiredKeyConfiguration = configuration()
        requiredKeyConfiguration.requiresAPIKey = true
        model.allowsWebSearch = true
        model.allowsMCPTools = true
        model.beginRequest(
            action: .summarize,
            workspace: workspace,
            documentCollection: nil,
            configuration: requiredKeyConfiguration,
            hasAPIKey: false
        )
        XCTAssertEqual(contextCallCount, 0)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.pendingConsent)
        XCTAssertFalse(model.allowsWebSearch)
        XCTAssertFalse(model.allowsMCPTools)

        model.allowsWebSearch = true
        model.allowsMCPTools = true
        model.beginRequest(
            action: .relatedPDFs,
            workspace: workspace,
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: false
        )
        XCTAssertEqual(contextCallCount, 0)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.pendingConsent)
        XCTAssertFalse(model.allowsWebSearch)
        XCTAssertFalse(model.allowsMCPTools)
    }

    func testEveryExternalGeneralQuickActionBuildsItsExpectedConsentContract() async {
        let externalActions = AIQuickAction.generalActions.filter {
            !$0.usesLocalRelatedPDFSearch
        }
        XCTAssertEqual(
            externalActions,
            [.summarize, .translate, .analyze, .solve, .fillDraft, .webResearch]
        )

        for action in externalActions {
            let model = makeModel { _, configuration in
                AICompletionResponse(text: "unused", provider: configuration.kind)
            }
            var selectedConfiguration = configuration(kind: .openAI)
            selectedConfiguration.isWebSearchEnabled = true
            model.scope = .currentPage

            model.beginRequest(
                action: action,
                workspace: PDFWorkspaceState(),
                documentCollection: nil,
                configuration: selectedConfiguration,
                hasAPIKey: true
            )
            await waitUntil { model.phase == .awaitingConsent }

            XCTAssertEqual(model.pendingConsent?.action, action)
            XCTAssertEqual(model.pendingConsent?.prompt, action.suggestedPrompt)
            XCTAssertEqual(model.pendingConsent?.scope, .currentPage)
            XCTAssertEqual(
                model.pendingConsent?.allowsWebSearch,
                action == .webResearch,
                "Unexpected web-search contract for \(action.rawValue)"
            )
            XCTAssertFalse(model.pendingConsent?.systemPrompt.isEmpty ?? true)
            model.cancelPendingConsent()
        }
    }

    func testRelatedPDFQuickActionRemainsLocalWithoutAPIKeyOrConsent() async {
        var completionCallCount = 0
        var relatedSearchCallCount = 0
        var capturedQuery = ""
        let workspace = PDFWorkspaceState()
        let collection = MultiDocumentWorkspaceState(initialWorkspace: workspace)
        let model = AIAssistantSessionModel(
            complete: { _, configuration in
                completionCallCount += 1
                return AICompletionResponse(text: "unexpected", provider: configuration.kind)
            },
            resolveApprovals: { _, _, configuration in
                AICompletionResponse(text: "unexpected", provider: configuration.kind)
            },
            extractContext: { _, scope in
                self.contextBundle(scope: scope)
            },
            searchRelatedPDFs: { query, receivedCollection, _ in
                relatedSearchCallCount += 1
                capturedQuery = query
                XCTAssertTrue(receivedCollection === collection)
                return []
            }
        )
        var selectedConfiguration = configuration(kind: .openAI)
        selectedConfiguration.requiresAPIKey = true

        model.beginRequest(
            action: .relatedPDFs,
            workspace: workspace,
            documentCollection: collection,
            configuration: selectedConfiguration,
            hasAPIKey: false
        )
        await waitUntil { model.phase == .idle && relatedSearchCallCount == 1 }

        XCTAssertEqual(completionCallCount, 0)
        XCTAssertEqual(capturedQuery, contextBundle(scope: .currentPage).promptText)
        XCTAssertNil(model.pendingConsent)
        XCTAssertEqual(model.messages.last?.role, .notice)
    }

    func testSolveRequestCarriesMarkdownAndDelimitedLatexFormattingContract() async {
        let model = makeModel { _, configuration in
            AICompletionResponse(text: "unused", provider: configuration.kind)
        }
        model.beginRequest(
            action: .solve,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )

        await waitUntil { model.phase == .awaitingConsent }
        let systemPrompt = model.pendingConsent?.systemPrompt ?? ""
        XCTAssertTrue(systemPrompt.contains("Format the answer as Markdown"))
        XCTAssertTrue(systemPrompt.contains("inline math inside \\( ... \\)"))
        XCTAssertTrue(systemPrompt.contains("display equations inside \\[ ... \\]"))
        XCTAssertTrue(systemPrompt.contains("never wrap equations in code fences"))
    }

    func testQuickActionDoesNotOverwriteAnUnsentCustomQuestion() async {
        let model = makeModel { _, configuration in
            AICompletionResponse(text: "done", provider: configuration.kind)
        }
        model.prompt = "직접 작성 중인 질문"
        model.beginRequest(
            action: .summarize,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )

        await waitUntil { model.phase == .awaitingConsent }
        XCTAssertEqual(model.pendingConsent?.prompt, AIQuickAction.summarize.suggestedPrompt)
        XCTAssertEqual(model.prompt, "직접 작성 중인 질문")

        model.confirmPendingConsent()
        XCTAssertEqual(model.prompt, "직접 작성 중인 질문")
        await waitUntil { model.phase == .idle }
    }

    func testOptionalExternalToolsResetAfterEachConsentDecision() async {
        let model = makeModel { _, configuration in
            AICompletionResponse(text: "done", provider: configuration.kind)
        }
        var selectedConfiguration = configuration(kind: .openAI)
        selectedConfiguration.isWebSearchEnabled = true
        selectedConfiguration.remoteMCPServers = [
            AIRemoteMCPServer(
                label: "trusted",
                serverURL: URL(string: "https://mcp.example.com")!
            )
        ]
        model.allowsWebSearch = true
        model.allowsMCPTools = true
        model.prompt = "First request"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: selectedConfiguration,
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }

        model.cancelPendingConsent()
        XCTAssertFalse(model.allowsWebSearch)
        XCTAssertFalse(model.allowsMCPTools)

        model.allowsWebSearch = true
        model.allowsMCPTools = true
        model.prompt = "Second request"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: selectedConfiguration,
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()

        XCTAssertFalse(model.allowsWebSearch)
        XCTAssertFalse(model.allowsMCPTools)
        await waitUntil { model.phase == .idle }
    }

    func testOptionalExternalToolsResetAfterEveryAsynchronousTerminalPath() async {
        var contextGate: CheckedContinuation<Void, Never>?
        let contextFailureModel = makeModel(extractContext: { _, _ in
            await withCheckedContinuation { contextGate = $0 }
            throw ExpectedFailure.failure
        })
        contextFailureModel.prompt = "Fail context"
        contextFailureModel.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { contextGate != nil }
        contextFailureModel.allowsWebSearch = true
        contextFailureModel.allowsMCPTools = true
        contextGate?.resume()
        await waitUntil { contextFailureModel.phase == .idle }
        XCTAssertFalse(contextFailureModel.allowsWebSearch)
        XCTAssertFalse(contextFailureModel.allowsMCPTools)
        XCTAssertNotNil(contextFailureModel.errorMessage)

        let relatedWorkspace = PDFWorkspaceState()
        let collection = MultiDocumentWorkspaceState(initialWorkspace: relatedWorkspace)
        var relatedGate: CheckedContinuation<[PDFRelatedDocumentResult], Never>?
        let relatedModel = AIAssistantSessionModel(
            complete: { _, configuration in
                AICompletionResponse(text: "unused", provider: configuration.kind)
            },
            resolveApprovals: { _, _, configuration in
                AICompletionResponse(text: "unused", provider: configuration.kind)
            },
            extractContext: { _, scope in
                self.contextBundle(scope: scope)
            },
            searchRelatedPDFs: { _, _, _ in
                await withCheckedContinuation { relatedGate = $0 }
            }
        )
        relatedModel.beginRequest(
            action: .relatedPDFs,
            workspace: relatedWorkspace,
            documentCollection: collection,
            configuration: configuration(),
            hasAPIKey: false
        )
        await waitUntil { relatedGate != nil }
        relatedModel.allowsWebSearch = true
        relatedModel.allowsMCPTools = true
        relatedGate?.resume(returning: [])
        await waitUntil { relatedModel.phase == .idle }
        XCTAssertFalse(relatedModel.allowsWebSearch)
        XCTAssertFalse(relatedModel.allowsMCPTools)

        var providerGate: CheckedContinuation<Void, Never>?
        let providerFailureModel: AIAssistantSessionModel = makeModel(complete: { _, _ in
            await withCheckedContinuation { providerGate = $0 }
            throw ExpectedFailure.failure
        })
        providerFailureModel.prompt = "Fail provider"
        providerFailureModel.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { providerFailureModel.phase == .awaitingConsent }
        providerFailureModel.confirmPendingConsent()
        await waitUntil { providerGate != nil }
        providerFailureModel.allowsWebSearch = true
        providerFailureModel.allowsMCPTools = true
        providerGate?.resume()
        await waitUntil { providerFailureModel.phase == .idle }
        XCTAssertFalse(providerFailureModel.allowsWebSearch)
        XCTAssertFalse(providerFailureModel.allowsMCPTools)
        XCTAssertNotNil(providerFailureModel.errorMessage)
    }

    func testFillDraftTargetsRequestPageAndRefusesStaleDocumentRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-AIDraftTarget-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = NSImage(size: NSSize(width: 320, height: 420))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let source = PDFDocument()
        source.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        source.insert(try XCTUnwrap(PDFPage(image: image)), at: 1)
        let url = directory.appendingPathComponent("source.pdf")
        XCTAssertTrue(source.write(to: url))

        let model = makeModel { _, configuration in
            AICompletionResponse(
                text: "Draft for the original page",
                provider: configuration.kind
            )
        }
        let workspace = PDFWorkspaceState(aiAssistantSession: model)
        XCTAssertTrue(workspace.open(url: url))
        workspace.setCurrentPage(0)
        let requestRevision = workspace.revision

        model.beginRequest(
            action: .fillDraft,
            workspace: workspace,
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        XCTAssertEqual(model.pendingConsent?.draftApplicationTarget?.pageIndex, 0)
        XCTAssertEqual(
            model.pendingConsent?.draftApplicationTarget?.documentRevision,
            requestRevision
        )

        workspace.setCurrentPage(1)
        model.confirmPendingConsent()
        await waitUntil { model.phase == .idle }
        let response = try XCTUnwrap(model.messages.last)
        let target = try XCTUnwrap(response.draftApplicationTarget)
        XCTAssertEqual(target.pageIndex, 0)
        XCTAssertTrue(workspace.prepareAITextDraft(response.text, target: target))
        XCTAssertEqual(workspace.pendingTextEdit?.pageIndex, 0)

        workspace.commitPendingText(response.text)
        XCTAssertNotEqual(workspace.revision, requestRevision)
        XCTAssertFalse(workspace.prepareAITextDraft(response.text, target: target))
        XCTAssertNil(workspace.pendingTextEdit)
        XCTAssertNotNil(workspace.presentedError)
    }

    func testLeavingStudyForEditingCancelsActiveAndPendingAIContext() async {
        var continuation: CheckedContinuation<PDFAIContextBundle, Never>?
        var completionCallCount = 0
        let activeModel = AIAssistantSessionModel(
            complete: { _, configuration in
                completionCallCount += 1
                return AICompletionResponse(text: "unused", provider: configuration.kind)
            },
            resolveApprovals: { _, _, configuration in
                AICompletionResponse(text: "unused", provider: configuration.kind)
            },
            extractContext: { _, scope in
                await withCheckedContinuation { continuation = $0 }
            },
            searchRelatedPDFs: { _, _, _ in [] }
        )
        let activeWorkspace = PDFWorkspaceState(aiAssistantSession: activeModel)
        activeWorkspace.setMode(.study)
        activeModel.prompt = "Explain this page"
        activeModel.beginRequest(
            action: .explainTerms,
            workspace: activeWorkspace,
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { continuation != nil }
        XCTAssertEqual(activeModel.phase, .preparingContext)

        activeWorkspace.setMode(.editing)
        XCTAssertEqual(activeModel.phase, .idle)
        XCTAssertNil(activeModel.pendingConsent)
        continuation?.resume(returning: contextBundle(scope: .currentPage))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(activeModel.phase, .idle)
        XCTAssertNil(activeModel.pendingConsent, "A cancelled late context must never revive consent UI.")
        XCTAssertEqual(completionCallCount, 0)

        let pendingModel = makeModel { _, configuration in
            completionCallCount += 1
            return AICompletionResponse(text: "unused", provider: configuration.kind)
        }
        let pendingWorkspace = PDFWorkspaceState(aiAssistantSession: pendingModel)
        pendingWorkspace.setMode(.study)
        pendingModel.prompt = "Make a quiz"
        pendingModel.beginRequest(
            action: .quiz,
            workspace: pendingWorkspace,
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { pendingModel.phase == .awaitingConsent }
        XCTAssertNotNil(pendingModel.pendingConsent)

        pendingWorkspace.setMode(.editing)
        XCTAssertEqual(pendingModel.phase, .idle)
        XCTAssertNil(pendingModel.pendingConsent)
        XCTAssertEqual(completionCallCount, 0)
    }

    func testEditingModeDirectRequestStopsBeforeContextOrNetworkWork() async {
        var contextCallCount = 0
        var completionCallCount = 0
        let model = AIAssistantSessionModel(
            complete: { _, configuration in
                completionCallCount += 1
                return AICompletionResponse(
                    text: "must not send",
                    provider: configuration.kind
                )
            },
            resolveApprovals: { _, _, configuration in
                AICompletionResponse(text: "unused", provider: configuration.kind)
            },
            extractContext: { [self] _, scope in
                contextCallCount += 1
                return contextBundle(scope: scope)
            },
            searchRelatedPDFs: { _, _, _ in [] }
        )
        let workspace = PDFWorkspaceState(aiAssistantSession: model)
        workspace.setMode(.editing)
        model.prompt = "Stale editing-mode request"

        model.beginRequest(
            action: .summarize,
            workspace: workspace,
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await Task.yield()

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.pendingConsent)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(contextCallCount, 0)
        XCTAssertEqual(completionCallCount, 0)
    }

    func testPathologicalGraphemeIsBoundedAcrossPromptConsentHistoryAndProviderResponse() async {
        let pathological = "a" + String(
            repeating: "\u{0301}",
            count: AIAssistantMessage.textBudget.maximumUTF16CodeUnits + 100
        )
        XCTAssertEqual(pathological.count, 1)
        var capturedRequests: [AICompletionRequest] = []
        let model = makeModel { request, configuration in
            capturedRequests.append(request)
            return AICompletionResponse(
                text: pathological,
                provider: configuration.kind
            )
        }

        model.prompt = pathological
        XCTAssertLessThanOrEqual(
            model.prompt.utf8.count,
            AIAssistantSessionModel.userPromptBudget.maximumUTF8Bytes
        )
        XCTAssertLessThanOrEqual(
            model.prompt.utf16.count,
            AIAssistantSessionModel.userPromptBudget.maximumUTF16CodeUnits
        )
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }

        guard let consent = model.pendingConsent else {
            XCTFail("Expected a bounded consent snapshot")
            return
        }
        let systemBytes: Int = consent.systemPrompt.utf8.count
        let promptBytes: Int = consent.prompt.utf8.count
        let conversationBytes: Int = consent.conversation.reduce(0) {
            partialResult,
            turn in
            partialResult + turn.content.utf8.count
        }
        let contextBytes: Int = consent.context.promptText.utf8.count
        let expectedOutboundBytes: Int = systemBytes
            + promptBytes
            + conversationBytes
            + contextBytes
        XCTAssertEqual(
            consent.totalOutboundUTF8ByteCount,
            expectedOutboundBytes
        )
        XCTAssertTrue(
            consent.previewText.contains(
                L10n.string(
                    "ai.consent.section_truncated",
                    defaultValue: "이 섹션의 미리보기만 줄였습니다."
                )
            )
        )

        model.confirmPendingConsent()
        await waitUntil { model.phase == .idle && capturedRequests.count == 1 }
        let providerMessage = model.messages.last?.text ?? ""
        XCTAssertLessThanOrEqual(
            providerMessage.utf8.count,
            AIAssistantMessage.textBudget.maximumUTF8Bytes
        )
        XCTAssertLessThanOrEqual(
            providerMessage.utf16.count,
            AIAssistantMessage.textBudget.maximumUTF16CodeUnits
        )

        model.prompt = "Follow up"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        let conversation = model.pendingConsent?.conversation ?? []
        XCTAssertLessThanOrEqual(
            conversation.reduce(0) { $0 + $1.content.count },
            AIAssistantSessionModel.transmittedConversationBudget.maximumCharacters
        )
        XCTAssertLessThanOrEqual(
            conversation.reduce(0) { $0 + $1.content.utf8.count },
            AIAssistantSessionModel.transmittedConversationBudget.maximumUTF8Bytes
        )
        XCTAssertLessThanOrEqual(
            conversation.reduce(0) { $0 + $1.content.utf16.count },
            AIAssistantSessionModel.transmittedConversationBudget.maximumUTF16CodeUnits
        )
    }

    func testInjectedCompletionCannotRetainOversizedCitationOrMCPPayloadInUIState() async {
        let oversizedTitle = "a" + String(
            repeating: "\u{0301}",
            count: AIResponseParsingLimits.citationTitleBudget.maximumUTF16CodeUnits + 1
        )
        let oversizedArguments = "a" + String(
            repeating: "\u{0301}",
            count: AIResponseParsingLimits.mcpArgumentsBudget.maximumUTF16CodeUnits + 1
        )
        XCTAssertEqual(oversizedTitle.count, 1)
        XCTAssertEqual(oversizedArguments.count, 1)

        let model = makeModel { _, configuration in
            AICompletionResponse(
                text: "Safe answer",
                citations: [
                    AISourceCitation(
                        title: oversizedTitle,
                        url: URL(string: "https://example.org/source")!
                    )
                ],
                provider: configuration.kind,
                responseID: "response",
                pendingMCPApprovals: [
                    AIMCPApprovalRequest(
                        approvalRequestID: "approval",
                        name: "search",
                        arguments: oversizedArguments,
                        serverLabel: "papers",
                        serverURL: URL(string: "https://papers.example.com/mcp")!
                    )
                ]
            )
        }
        model.prompt = "Search"
        model.beginRequest(
            action: nil,
            workspace: PDFWorkspaceState(),
            documentCollection: nil,
            configuration: configuration(),
            hasAPIKey: true
        )
        await waitUntil { model.phase == .awaitingConsent }
        model.confirmPendingConsent()
        await waitUntil { model.phase == .idle }

        XCTAssertNil(model.mcpApprovalSession)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.messages.last?.text, "Safe answer")
        XCTAssertTrue(model.messages.last?.citations.isEmpty == true)
    }

    private func makeModel(
        complete: @escaping AIAssistantSessionModel.CompleteHandler
    ) -> AIAssistantSessionModel {
        AIAssistantSessionModel(
            complete: complete,
            resolveApprovals: { _, _, configuration in
                AICompletionResponse(text: "continued", provider: configuration.kind)
            },
            extractContext: { _, scope in
                PDFAIContextBundle(
                    scope: scope,
                    documentTitle: "Private.pdf",
                    documentURL: URL(fileURLWithPath: "/private/Private.pdf"),
                    documentPageCount: 10,
                    sources: [
                        PDFAIContextSource(
                            citationID: "S1",
                            documentURL: URL(fileURLWithPath: "/private/Private.pdf"),
                            documentTitle: "Private.pdf",
                            pageIndex: 2,
                            pageNumber: 3,
                            text: "private context body",
                            kind: .pageText,
                            wasTruncated: false
                        )
                    ],
                    omittedPageCount: 0,
                    wasTruncated: false
                )
            },
            searchRelatedPDFs: { _, _, _ in [] }
        )
    }

    private func makeModel(
        extractContext: @escaping AIAssistantSessionModel.ContextHandler
    ) -> AIAssistantSessionModel {
        AIAssistantSessionModel(
            complete: { _, configuration in
                AICompletionResponse(text: "unused", provider: configuration.kind)
            },
            resolveApprovals: { _, _, configuration in
                AICompletionResponse(text: "continued", provider: configuration.kind)
            },
            extractContext: extractContext,
            searchRelatedPDFs: { _, _, _ in [] }
        )
    }

    private func contextBundle(
        scope: PDFAIContextScope
    ) -> PDFAIContextBundle {
        PDFAIContextBundle(
            scope: scope,
            documentTitle: "Private.pdf",
            documentURL: URL(fileURLWithPath: "/private/Private.pdf"),
            documentPageCount: 1,
            sources: [
                PDFAIContextSource(
                    citationID: "S1",
                    documentURL: URL(fileURLWithPath: "/private/Private.pdf"),
                    documentTitle: "Private.pdf",
                    pageIndex: 0,
                    pageNumber: 1,
                    text: "private context body",
                    kind: .pageText,
                    wasTruncated: false
                )
            ],
            omittedPageCount: 0,
            wasTruncated: false
        )
    }

    private func makeWorkspace(
        pageCount: Int
    ) throws -> (workspace: PDFWorkspaceState, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-AI-Selected-Pages-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("selected-pages.pdf")
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 24, height: 32), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        for index in 0..<pageCount {
            let page = try XCTUnwrap(PDFPage(image: image), "Could not create page \(index + 1)")
            document.insert(page, at: index)
        }
        XCTAssertTrue(document.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        return (workspace, directory)
    }

    private func configuration(
        kind: AIProviderKind = .customOpenAICompatible
    ) -> AIProviderConfiguration {
        AIProviderConfiguration(
            name: "Test",
            kind: kind,
            model: "test-model",
            baseURL: URL(string: "https://example.com/v1")!,
            requiresAPIKey: false
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for AI session state")
    }

    private enum ExpectedFailure: Error {
        case failure
    }
}
