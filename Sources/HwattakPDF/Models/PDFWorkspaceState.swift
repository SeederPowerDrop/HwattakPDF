// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import Foundation
import PDFKit

private struct PDFWidgetUndoValue {
    let apply: () -> Void
}

/// Weak object reference used by the runtime annotation provenance registry.
///
/// A bare `ObjectIdentifier` is only an address. If its object dies, an
/// allocator may later reuse that address for an unrelated annotation. Keeping
/// a weak reference beside the key lets every lookup verify `===` and reject
/// both deallocated and address-reused objects.
private final class WeakPDFAnnotationReference {
    weak var annotation: PDFAnnotation?

    init(_ annotation: PDFAnnotation) {
        self.annotation = annotation
    }
}

/// Small dependency seam around Vision OCR.
///
/// Production uses `VisionOCRService`; tests can return a completed checkpoint
/// at an exact instant to exercise cancellation races without making assertions
/// depend on Vision's speed or the host machine's installed language assets.
typealias WorkspaceOCRRecognizer = (
    URL,
    String?,
    OCRConfiguration,
    @escaping (VisionOCRService.Progress) -> Void
) async throws -> OCRCheckpoint

/// Injectable Save Copy writer used to deterministically test the tiny window
/// between a large serialization and its commit-time destination validation.
/// Normal app instances delegate straight to `AtomicPDFWriter`.
typealias WorkspacePDFWriter = (
    PDFDocument,
    URL,
    @escaping () throws -> Void
) throws -> URL

/// A short-lived UI boundary for locked PDFs. The Bool is true after at least
/// one rejected attempt. Production presents an NSSecureTextField; tests inject
/// deterministic answers without ever displaying a modal window.
typealias WorkspacePDFPasswordProvider = @MainActor (URL, Bool) -> String?

/// **PDF 한 탭**의 문서와 편집 상태를 소유하는 중심 모델이다.
///
/// 초보자가 가장 먼저 알아야 할 경계는 다음과 같다.
/// - `PDFWorkspaceState`: PDF 하나의 페이지, 선택, 검색, OCR, undo를 관리한다.
/// - `MultiDocumentWorkspaceState`: 여러 탭·스택·워크스페이스의 순서를 관리한다.
/// - SwiftUI/AppKit view: 이 모델을 관찰하고 사용자 입력을 모델 메서드로 전달한다.
///
/// PDFKit 객체는 thread-safe가 아니므로 이 클래스 전체를 `@MainActor`에 둔다.
/// CPU가 무거운 검색 정규화·OCR·hash는 필요한 값만 snapshot한 뒤 background
/// task로 보내고, 결과를 적용할 때 generation/revision을 다시 확인한다.
@MainActor
final class PDFWorkspaceState: ObservableObject {
    static let undoHistoryLimit = PDFEditHistory.defaultLimit

    /// Lightweight, tab-owned AI conversation state. It survives PDFKit
    /// hibernation and tab switches, while provider requests are cancelled
    /// when the tab is no longer visible.
    let aiAssistantSession: AIAssistantSessionModel

    // @Published는 값이 바뀌면 관찰 중인 SwiftUI view를 다시 계산하게 한다.
    // private(set)은 화면이 속성을 직접 고치지 못하고 모델의 검증된 메서드를
    // 거치게 해 상태 불변식(invariant)을 지킨다.
    @Published private(set) var document: PDFDocument?
    @Published private(set) var documentURL: URL?
    /// Page metadata retained while a clean, inactive PDF document is
    /// hibernated. Keeping this separate from `PDFDocument` lets tab and
    /// session UI remain complete without retaining PDFKit's page/cache graph.
    @Published private(set) var hibernatedPageCount: Int?
    @Published private(set) var revision = UUID()
    @Published private(set) var isDirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var undoActionName: String?
    @Published private(set) var redoActionName: String?
    @Published var selectedPages: Set<Int> = []
    @Published var currentPageIndex = 0
    @Published var pageColumns = 1 {
        didSet {
            // A continuous one-page document and a two-page spread have
            // different document-view geometry. Keep zoom, but do not replay
            // a normalized clip position from one geometry inside the other.
            if oldValue != pageColumns, oldValue <= 2, pageColumns <= 2 {
                pdfViewportState.invalidateScrollPosition()
            }
        }
    }
    /// `pageColumns == 2`일 때 연속 펼침과 한 펼침 고정 보기를 구분한다.
    /// 다른 페이지 수로 잠시 전환해도 마지막 선택을 보존한다.
    @Published var twoPageDisplayMode: PDFTwoPageDisplayMode = .continuous {
        didSet {
            if oldValue != twoPageDisplayMode, pageColumns == 2 {
                pdfViewportState.invalidateScrollPosition()
            }
        }
    }
    @Published var overviewScale: CGFloat = 1.0
    @Published private(set) var pageFitMode: PDFPageFitMode?
    @Published var sidebarVisible = true
    @Published var gridLayoutMode: PDFGridLayoutMode = .balanced
    /// Mode belongs to this tab rather than the application. Two neighboring
    /// PDFs can therefore remain in viewer and study mode independently.
    @Published private(set) var mode: PDFWorkspaceMode = .viewer
    @Published var activeTool: WorkspaceTool = .select {
        didSet {
            // Programmatic callers as well as the toolbar must obey the same
            // policy. For example, a viewer tab cannot accidentally retain a
            // pen tool selected moments earlier in editing mode.
            let normalized = PDFWorkspaceModePolicy.normalizedTool(activeTool, for: mode)
            // Tool buttons live outside PDFView, so their clicks do not reach
            // the canvas overlay's normal pointer-commit hook. Finish a text
            // draft before allowing a pen/eraser/image gesture to mutate the
            // page. Preserve the requested next tool because committing text
            // intentionally returns the editor itself to Select.
            if pendingInlineTextEdit != nil, oldValue == .text, normalized != .text {
                commitPendingInlineTextDraftIfNeeded()
                if activeTool != normalized {
                    activeTool = normalized
                }
                return
            }
            // Assigning a property from its own didSet re-enters the observer.
            // Only perform the corrective write when policy actually changed
            // the value, otherwise every ordinary selection would recurse
            // until the process exhausted its stack.
            if activeTool != normalized {
                activeTool = normalized
            }
        }
    }
    @Published var inkSettings = InkSettings()
    /// 학습 팔레트의 현재 표식 설정이다. 슬라이더 조작 자체는 문서 편집이 아니며,
    /// 사용자가 적용할 때만 PDF annotation과 undo 기록이 만들어진다.
    @Published var studyMarkupStyle = StudyMarkupStyle()
    private var studyMarkupThicknessByKind: [StudyMarkupKind: CGFloat] = [:]
    @Published private(set) var markupSelectionClearRequestID: UUID?
    @Published var signatureSettings = SignatureSettings()
    @Published var pendingTextEdit: PendingTextEdit?
    /// Draft currently owned by the on-page AppKit text editor. It is separate
    /// from `pendingTextEdit`, which intentionally remains the review sheet
    /// used for AI drafts and the legacy comment workflow.
    @Published private(set) var pendingInlineTextEdit: PendingInlineTextEdit?
    private(set) var inlineTextEditRejectionReason: InlineTextEditRejectionReason?
    @Published var currentSelection: PDFSelection?
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            searchQueryDidChange()
        }
    }
    @Published private(set) var searchResults: [PDFSelection] = []
    @Published private(set) var searchNavigatorResults: [PDFSearchResult] = []
    @Published private(set) var searchResultIndex = 0
    @Published var activeSearchSelection: PDFSelection?
    @Published private(set) var isSearching = false
    @Published private(set) var searchProgress = PDFSearchProgress.idle
    @Published private(set) var searchRequiresOCR = false
    @Published private(set) var searchUnsearchablePageCount = 0
    @Published private(set) var searchResultsWereTruncated = false
    @Published private(set) var activeSearchQuery: String?
    @Published private(set) var searchCompletedQuery: String?
    /// A tab-local, host-rendered companion request created by a declarative
    /// plug-in action. It contains bounded immutable text/URLs only and never
    /// participates in PDF revision, undo, saving, or session persistence.
    @Published var pluginPanelRequest: PluginPanelRequest?
    @Published var statusMessage = L10n.string("status.ready")
    @Published var presentedError: String?
    @Published var pendingProtectedExport: PDFProtectedExportPresentation?
    @Published private(set) var ocrState: OCRRunState = .idle
    @Published private(set) var ocrCheckpoint: OCRCheckpoint?

    /// 파일을 연 탭이 살아 있는 동안 샌드박스 URL 권한도 함께 유지한다.
    private var scopedAccess: SecurityScopedAccess?
    @Published private(set) var imageSourceURL: URL?
    private var imageSourceAccess: SecurityScopedAccess?
    private var managedImagePreviewURL: URL?
    @Published private(set) var isRecoveryCopy = false
    @Published private(set) var recoveryWarning: String?
    private var recoveryStore: PDFRecoveryStore?
    private var managedRecoveryWorkingURL: URL?
    private let recoveryID = UUID()
    private var recoveryTask: Task<Void, Never>?

    func configureRecovery(store: PDFRecoveryStore) {
        recoveryStore = store
        // Restored recovery tabs may have been marked dirty before their
        // owning window installs this store. Arm loaded copies at that point.
        if isDirty { scheduleRecoverySnapshot() }
    }

    func markAsRecoveredCopy() {
        isRecoveryCopy = true
        if let documentURL, PDFRecoveryStore().isWorkingCopy(documentURL) {
            managedRecoveryWorkingURL = documentURL
        }
        editHistory.noteUntrackedMutation()
        synchronizeHistoryPresentation()
        scheduleRecoverySnapshot()
    }

    private func scheduleRecoverySnapshot() {
        recoveryTask?.cancel()
        guard let recoveryStore else { return }
        if !isDirty { recoveryStore.remove(id: recoveryID); return }
        guard let document, !document.isEncrypted,
              UserDefaults.standard.object(forKey: PDFRecoveryStore.enabledKey) as? Bool != false else { return }
        // Serialization runs only after an editing pause. Large textbooks use
        // a longer debounce so pointer input and continuous editing stay fast.
        let delay: UInt64 = pageCount > 500 ? 60_000_000_000 : 5_000_000_000
        recoveryTask = Task { @MainActor [weak self, weak document] in
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                guard let self, let document, self.document === document, self.isDirty,
                      !document.isEncrypted, !self.ocrState.isActivelyProcessing,
                      self.officeExportTask == nil,
                      UserDefaults.standard.object(forKey: PDFRecoveryStore.enabledKey) as? Bool != false else { return }
                try recoveryStore.save(document: document, id: self.recoveryID, displayName: self.displayName)
                self.recoveryWarning = nil
            } catch is CancellationError {
            } catch { self?.recoveryWarning = error.localizedDescription }
        }
    }
    @Published private(set) var officeExportProgress: Double?
    @Published var pluginCommandPaletteVisible = false
    private var officeExportTask: Task<Void, Never>?

    func cancelOfficeExport() { officeExportTask?.cancel() }
    func waitForOfficeExport() async { await officeExportTask?.value }

    /// User-owned source identity is independent of disposable rendering storage.
    var sessionDocumentURL: URL? { imageSourceURL ?? documentURL }
    var requiresSaveDestination: Bool {
        isRecoveryCopy || imageSourceURL != nil || documentURL.map {
            ImagePDFConverter.previewDisplayName(for: $0) != nil
        } == true
    }

    func associateImageSource(_ url: URL) {
        imageSourceAccess = SecurityScopedAccess(url: url)
        imageSourceURL = url
        if documentURL != url { managedImagePreviewURL = documentURL }
    }

    private func releaseImagePreview() {
        if let managedRecoveryWorkingURL {
            PDFRecoveryStore().removeWorkingCopy(at: managedRecoveryWorkingURL)
        }
        managedRecoveryWorkingURL = nil
        if let managedImagePreviewURL { ImagePDFConverter.removePreview(at: managedImagePreviewURL) }
        managedImagePreviewURL = nil
        imageSourceURL = nil
        imageSourceAccess = nil
    }
    /// Metadata of the exact on-disk version represented by `document`.
    /// Saving over the original is allowed only while this still matches.
    private var sourceFileVersion: PDFSourceFileVersion?
    private let editHistory = PDFEditHistory(limit: PDFWorkspaceState.undoHistoryLimit)
    private var ocrTask: Task<Void, Never>?
    private var ocrRunID: UUID?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private let searchEngineConfiguration: PDFSearchEngine.Configuration
    private let ocrRecognizer: WorkspaceOCRRecognizer
    private let pdfWriter: WorkspacePDFWriter
    private let passwordProvider: WorkspacePDFPasswordProvider
    private var widgetValueSnapshot: [String: String] = [:]
    private var widgetUndoValueSnapshot: [String: PDFWidgetUndoValue] = [:]
    private var widgetSnapshotPrimedPages: Set<Int> = []
    /// Every live PDF viewport owns an independent synchronous commit hook.
    ///
    /// A workspace can be rendered by both its normal editor and one or more
    /// comparison panels at the same time. Keeping only the most recently
    /// attached hook lets a read-only comparison view accidentally replace the
    /// normal view's pending AcroForm/inline-text commit. Tokens therefore form
    /// a small registry: installing the same token refreshes that one owner,
    /// while installing a different token preserves the other live views.
    private var deactivationCommitHandlers: [UUID: () -> Void] = [:]
    /// A commit callback can synchronously trigger AppKit notifications that
    /// enter another model preparation path. Run the registered view hooks at
    /// most once for that nested transaction so one field edit cannot be
    /// recorded twice or recurse indefinitely.
    private var isRunningDeactivationCommitHandlers = false
    /// Object-identity provenance for annotations created or explicitly
    /// edited during this live document session.
    ///
    /// Annotation dictionaries are public PDF data. A hostile document can
    /// copy `/HwattakPDFKind`, `/Name`, or any other marker that an open-source
    /// app writes, so marker strings are useful for classification but cannot
    /// authorize destructive actions in Viewer or Study mode. Object identity
    /// cannot be supplied by file contents. Editing mode remains the explicit
    /// broad authoring surface; safer modes require this runtime trust as well.
    private var runtimeTrustedAnnotations: [
        ObjectIdentifier: WeakPDFAnnotationReference
    ] = [:]
    private weak var pendingTextAnnotation: PDFAnnotation?
    private weak var pendingInlineTextAnnotation: PDFAnnotation?
    /// Identifies the one visible overlay allowed to push NSTextView values
    /// into the pending draft. SwiftUI can briefly keep an outgoing PDFView
    /// alive after its replacement has appeared; draft UUID alone cannot
    /// distinguish those two views because both display the same transaction.
    private var pendingInlineTextEditorOwnerID: UUID?
    private(set) var pdfViewportState = PDFViewerViewportState()
    private var comparisonPDFViewportState = PDFViewerViewportState()

    /// 휴면 탭에는 PDFDocument가 없어도 탭/페이지 UI가 계속 보이도록 metadata를 쓴다.
    var pageCount: Int { document?.pageCount ?? hibernatedPageCount ?? 0 }

    /// Unlike `document != nil`, this remains true while an inactive tab has
    /// released its PDFKit document to reduce memory pressure.
    var hasOpenDocument: Bool { documentURL != nil }

    /// A review/comment sheet draft is intentionally not a PDF edit until the
    /// person presses Apply. Destructive lifecycle operations use this flag to
    /// refuse closing/reusing the workspace rather than silently applying or
    /// discarding a transactional draft.
    var hasPendingReviewTextDraft: Bool { pendingTextEdit != nil }

    /// Testable policy boundary for OCR checkpoint reuse. An edited document's
    /// source metadata no longer describes its in-memory bytes, so it must never
    /// authorize a reusable source-content hash.
    var reusableOCRSourceVersion: PDFSourceFileVersion? {
        guard !isDirty else { return nil }
        return sourceFileVersion
    }

    var isHibernated: Bool {
        document == nil && documentURL != nil && hibernatedPageCount != nil
    }

    /// Dirty documents and OCR-related state must stay resident because their
    /// in-memory representation cannot be recreated losslessly from the file.
    var canHibernate: Bool {
        document != nil
            && documentURL != nil
            // Passwords are deliberately not retained. A clean encrypted tab
            // may still release its PDFKit graph under the normal memory
            // budget; resuming it asks for the password again instead of
            // keeping every unlocked batch item resident indefinitely.
            && !isDirty
            && pendingTextEdit == nil
            && pendingInlineTextEdit == nil
            && ocrTask == nil
            && officeExportTask == nil
            && !ocrState.isActivelyProcessing
    }

    var displayName: String {
        if let imageSourceURL { return imageSourceURL.lastPathComponent }
        guard let documentURL else { return L10n.string("document.untitled") }
        return ImagePDFConverter.previewDisplayName(for: documentURL)
            ?? documentURL.lastPathComponent
    }

    /// Stable capability boundary used by overlays and future plug-ins.
    /// Feature code should prefer this method to duplicating `mode == ...`
    /// checks, because the central policy may evolve without changing callers.
    func allows(_ capability: PDFWorkspaceCapability) -> Bool {
        mode.allows(capability) && documentAllows(capability)
    }

    /// Encrypted PDFs can grant a user password fewer rights than an owner
    /// password. Mode policy remains the first gate. Because PDFKit cannot
    /// prove that ordinary serialization preserves the source security
    /// dictionary, a user-password session has no durable mutation path and is
    /// therefore read/export-only even when individual PDF permission bits say
    /// that an in-memory change would be allowed.
    private func documentAllows(_ capability: PDFWorkspaceCapability) -> Bool {
        guard let document, document.isEncrypted else { return true }
        guard !document.isLocked else { return false }
        if document.permissionsStatus == .owner { return true }

        switch capability {
        case .reading, .textSelection, .documentSearch:
            return true
        case .copyAndPaste, .translation, .aiAssistance, .noteSharing,
             .calculationHelp, .terminologyHelp:
            return document.allowsCopying
        case .ocr:
            // OCR needs a detached, passwordless temporary snapshot. Only an
            // owner unlock may change the source security dictionary even for
            // that short-lived local file.
            return false
        case .pageEditing:
            return false
        case .inlineTextEditing, .imageInsertion:
            return false
        case .comments, .signature, .signatureImageImport, .handwriting,
             .typedNotes, .markup, .studyTools:
            return false
        }
    }

    func allowsAnnotationEditing(_ kind: EditableAnnotationKind) -> Bool {
        guard PDFWorkspaceModePolicy.allowsAnnotationEditing(kind, in: mode) else {
            return false
        }
        let capability: PDFWorkspaceCapability = switch kind {
        case .image: .imageInsertion
        case .signature: .signature
        case .freeText: .comments
        }
        return documentAllows(capability)
    }

    /// Authoritative overlay policy for a concrete PDF object.
    ///
    /// The kind-only overload remains useful for toolbar policy. Move, resize,
    /// crop and delete UI must call this overload so a forged PDF marker cannot
    /// gain edit authority in Viewer or Study mode.
    func allowsAnnotationEditing(
        _ kind: EditableAnnotationKind,
        annotation: PDFAnnotation
    ) -> Bool {
        guard allowsAnnotationEditing(kind) else { return false }
        if mode == .editing { return true }
        return isRuntimeTrustedAnnotation(annotation)
    }

    func isRuntimeTrustedAnnotation(_ annotation: PDFAnnotation) -> Bool {
        let identifier = ObjectIdentifier(annotation)
        guard let reference = runtimeTrustedAnnotations[identifier] else {
            return false
        }
        guard reference.annotation === annotation else {
            runtimeTrustedAnnotations.removeValue(forKey: identifier)
            return false
        }
        return true
    }

    private func trustRuntimeAnnotation(_ annotation: PDFAnnotation) {
        runtimeTrustedAnnotations[ObjectIdentifier(annotation)] =
            WeakPDFAnnotationReference(annotation)
    }

    /// A conveniently named gate for the direct PDF text overlay. Viewer and
    /// study text tools remain FreeText notes and must not intercept body text.
    var allowsInlineTextEditing: Bool {
        allows(.inlineTextEditing)
    }

    /// PDFKit edits AcroForm widgets natively rather than routing them through
    /// the app's annotation capabilities. Expose an explicit fail-closed gate
    /// for the viewer: an unencrypted document or owner-unlocked encrypted
    /// document can be persisted, while a user-password session cannot.
    var allowsNativeFormEditing: Bool {
        guard let document, !document.isLocked else { return false }
        return !document.isEncrypted || document.permissionsStatus == .owner
    }

    /// Permission-only UI gate. Callers such as menus/sidebar still check that
    /// a non-empty page selection exists; service/model write paths throw and
    /// revalidate independently.
    var canExtractPages: Bool {
        guard let document else { return false }
        return (try? PDFDocumentSecurityPolicy.validateCanExtractPages(document)) != nil
    }

    /// Permission-only UI gate for selected-page PNG rendering. Selection and
    /// destination availability remain separate presentation concerns.
    var canRasterizePages: Bool {
        guard let document else { return false }
        return (try? PDFDocumentSecurityPolicy.validateCanRasterizePages(document)) != nil
    }

    /// Changes only the tab's working context; it never marks PDF bytes dirty.
    func setMode(_ newMode: PDFWorkspaceMode) {
        guard newMode != mode else { return }

        // Settle every view-owned transaction while the outgoing mode still
        // has authority. In particular, a completed image crop is visible but
        // not yet in history until the overlay's deactivation hook finishes it;
        // changing `mode` first would revoke image authority and roll that work
        // back. The same pass commits inline text and native form field editors.
        // It deliberately does *not* apply the separate Viewer/Study review or
        // AI draft sheet, which remains pending until the user presses Apply.
        prepareForDeactivation()

        mode = newMode
        activeTool = PDFWorkspaceModePolicy.normalizedTool(activeTool, for: newMode)
        if !newMode.allows(.aiAssistance) {
            aiAssistantSession.cancelActiveRequest()
        }
        statusMessage = L10n.format("status.mode_changed", newMode.title)
    }

    /// Session restoration happens before the tab is interactive. It applies
    /// the persisted value without announcing a user action or committing an
    /// editor draft that cannot exist in a newly constructed workspace.
    func restoreModeFromSession(_ restoredMode: PDFWorkspaceMode) {
        mode = restoredMode
        activeTool = PDFWorkspaceModePolicy.normalizedTool(activeTool, for: restoredMode)
    }

    var windowTitle: String {
        (isDirty || hasPendingReviewTextDraft)
            ? L10n.format("document.edited_title", displayName)
            : displayName
    }

    init(
        searchEngineConfiguration: PDFSearchEngine.Configuration = .standard,
        /// Tests can inject a session whose context extraction pauses at an
        /// exact point. Production callers omit it and receive the normal
        /// privacy-preserving AI session.
        aiAssistantSession: AIAssistantSessionModel? = nil,
        ocrRecognizer: @escaping WorkspaceOCRRecognizer = { url, fingerprint, configuration, progress in
            try await VisionOCRService.recognize(
                pdfURL: url,
                documentFingerprint: fingerprint,
                configuration: configuration,
                progress: progress
            )
        },
        pdfWriter: @escaping WorkspacePDFWriter = { document, url, validateDestination in
            try AtomicPDFWriter.write(
                document,
                to: url,
                validateDestinationBeforeCommit: validateDestination
            )
        },
        passwordProvider: @escaping WorkspacePDFPasswordProvider = { url, wasRejected in
            PDFPasswordPrompt.requestPassword(for: url, wasRejected: wasRejected)
        }
    ) {
        self.aiAssistantSession = aiAssistantSession ?? AIAssistantSessionModel()
        self.searchEngineConfiguration = searchEngineConfiguration
        self.ocrRecognizer = ocrRecognizer
        self.pdfWriter = pdfWriter
        self.passwordProvider = passwordProvider
    }

    /// Installs one PDFView's synchronous field-editor commit hook.
    ///
    /// The UUID belongs to the coordinator, so dismantling one viewport removes
    /// only that viewport's closure and cannot silence another live viewport.
    func installDeactivationCommitHandler(id: UUID, action: @escaping () -> Void) {
        deactivationCommitHandlers[id] = action
    }

    func removeDeactivationCommitHandler(id: UUID) {
        deactivationCommitHandlers.removeValue(forKey: id)
    }

    private func commitRegisteredViewEditors() {
        guard !isRunningDeactivationCommitHandlers else { return }
        isRunningDeactivationCommitHandlers = true
        defer { isRunningDeactivationCommitHandlers = false }

        // Snapshot first because an action can synchronously trigger AppKit or
        // SwiftUI teardown, which may unregister a coordinator while this loop
        // is running. The copied closures remain valid for this commit pass.
        let commitActions = Array(deactivationCommitHandlers.values)
        commitActions.forEach { $0() }
    }

    /// Commits AppKit's field editor first, then compares PDFKit's resulting
    /// widget values with their baseline. Callers must run this before an
    /// active tab stops being active, so memory pressure cannot hibernate a
    /// clean-looking document while its latest AcroForm value is still held
    /// only by the view hierarchy.
    func prepareForDeactivation() {
        commitRegisteredViewEditors()
        // The visible overlay synchronizes every keystroke, so this also works
        // when a close/save request arrives after AppKit has begun dismantling.
        commitPendingInlineTextDraftIfNeeded()
        // The Viewer/Study review sheet remains transactional: switching tabs
        // preserves its model-synchronized draft but must never imply Apply.
        // Close/open guards separately refuse to destroy a pending draft.
        synchronizeWidgetValues()
        // A hidden tab has no visible search progress surface. Stop its
        // cancellable page scan so it cannot keep consuming CPU after the user
        // moves to another document; already published partial results remain.
        cancelSearch()
    }

    /// Loads and unlocks a PDF before any page, annotation, string, or form
    /// property is read. A cancelled password prompt is a normal nil result,
    /// while file and validation failures remain errors.
    private func loadUnlockedDocument(
        at url: URL
    ) throws -> PDFSourceFileAccess.LoadedDocument? {
        let loaded = try PDFSourceFileAccess.loadDocument(at: url)
        var wasRejected = false
        while loaded.document.isLocked {
            guard let password = passwordProvider(url, wasRejected) else {
                return nil
            }
            let unlocked = loaded.document.unlock(withPassword: password)
            if unlocked, !loaded.document.isLocked {
                break
            }
            wasRejected = true
        }

        // A person can spend an arbitrary amount of time in the password
        // prompt. Recheck the exact source metadata before accepting PDFKit's
        // lazily-backed object so a replacement during that interval cannot be
        // mistaken for the file whose password was entered.
        guard try PDFSourceFileVersion.capture(at: url) == loaded.version else {
            throw WorkspaceError.cannotOpen(url)
        }
        return loaded
    }

    @discardableResult
    func open(url: URL) -> Bool {
        // `open(url:)` is also a public model boundary used by tests and
        // future integrations, not only by today's "empty tab" UI. Materialize
        // an on-page draft before checking dirty state so opening another PDF
        // cannot silently detach the draft from document A and later commit it
        // onto document B.
        prepareForDeactivation()
        if isDirty || hasPendingReviewTextDraft {
            presentedError = L10n.string("error.unsaved_open")
            return false
        }
        let access = SecurityScopedAccess(url: url)
        let loaded: PDFSourceFileAccess.LoadedDocument
        do {
            guard let unlocked = try loadUnlockedDocument(at: url) else {
                // Cancelling a password prompt is not an error and must leave
                // an existing clean document untouched.
                presentedError = nil
                return false
            }
            loaded = unlocked
        } catch {
            presentedError = error.localizedDescription
            return false
        }

        abandonOCR()

        // A pending consent bundle contains extracted text from the previous
        // PDF. Invalidate it synchronously at the successful model replacement
        // boundary, before SwiftUI's later onChange/onDisappear callbacks can
        // run, so it can never be confirmed against the new document.
        aiAssistantSession.documentDidChange()
        pluginPanelRequest = nil
        pendingProtectedExport = nil
        cancelSearchAndInvalidate(clearResults: true)
        runtimeTrustedAnnotations.removeAll(keepingCapacity: false)
        recoveryTask?.cancel()
        recoveryStore?.remove(id: recoveryID)
        isRecoveryCopy = false
        recoveryWarning = nil
        cancelOfficeExport()
        releaseImagePreview()
        scopedAccess = access
        document = loaded.document
        documentURL = url
        sourceFileVersion = loaded.version
        hibernatedPageCount = nil
        presentedError = nil
        editHistory.reset()
        synchronizeHistoryPresentation()
        selectedPages = loaded.document.pageCount > 0 ? [0] : []
        currentPageIndex = 0
        sidebarVisible = true
        gridLayoutMode = .balanced
        pdfViewportState = PDFViewerViewportState()
        comparisonPDFViewportState = PDFViewerViewportState()
        pageFitMode = nil
        currentSelection = nil
        searchText = ""
        resetSearchPresentation()
        ocrCheckpoint = nil
        ocrState = .idle
        // Opening a 50–200 MB PDF must not synchronously hash the entire file
        // or force PDFKit to enumerate every page's annotations. OCR computes
        // its fingerprint in detached work only when requested; widget
        // baselines are primed one viewed page at a time.
        widgetValueSnapshot = [:]
        widgetUndoValueSnapshot = [:]
        widgetSnapshotPrimedPages = []
        if let firstPage = loaded.document.page(at: 0) {
            primeWidgetValues(on: firstPage)
        }
        refresh(L10n.format("status.opened_pages", loaded.document.pageCount))
        return true
    }

    func close() {
        // Direct model callers do not necessarily pass through the window's
        // unsaved-changes coordinator. Inline text is materialized, while a
        // review/AI sheet draft remains unapplied and therefore blocks close.
        // `closeDiscardingChanges()` is the explicit destructive API.
        prepareForDeactivation()
        guard !isDirty, !hasPendingReviewTextDraft else {
            presentedError = L10n.string("error.unsaved_close")
            return
        }
        resetDocumentState()
    }

    /// Called only after the user explicitly chooses “저장 안 함”.
    func closeDiscardingChanges() {
        resetDocumentState()
    }

    private func resetDocumentState() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryStore?.remove(id: recoveryID)
        isRecoveryCopy = false
        recoveryWarning = nil
        cancelOfficeExport()
        releaseImagePreview()
        // Closing/discarding is also a document identity change. Clear pending
        // consent, active network/tool work and conversation context before the
        // PDF object and URL disappear from the workspace.
        aiAssistantSession.documentDidChange()
        pluginPanelRequest = nil
        pendingProtectedExport = nil
        abandonOCR()
        cancelSearchAndInvalidate(clearResults: true)
        document = nil
        documentURL = nil
        sourceFileVersion = nil
        hibernatedPageCount = nil
        scopedAccess = nil
        selectedPages = []
        currentPageIndex = 0
        sidebarVisible = true
        gridLayoutMode = .balanced
        pdfViewportState = PDFViewerViewportState()
        comparisonPDFViewportState = PDFViewerViewportState()
        pageFitMode = nil
        currentSelection = nil
        // `closeDiscardingChanges()` is the explicit destructive path. Clear
        // both the sheet draft and its annotation identity so a later PDF
        // opened in this reusable workspace cannot receive stale text.
        clearPendingTextEdit()
        clearPendingInlineTextEdit()
        runtimeTrustedAnnotations.removeAll(keepingCapacity: false)
        resetSearchPresentation()
        isDirty = false
        ocrCheckpoint = nil
        ocrState = .idle
        widgetValueSnapshot = [:]
        widgetUndoValueSnapshot = [:]
        widgetSnapshotPrimedPages = []
        editHistory.reset()
        synchronizeHistoryPresentation()
        refresh(L10n.string("status.ready"))
    }

    /// Releases the PDFKit document graph for a clean inactive tab. Page and
    /// tab navigation state stays in this model and is applied when resumed.
    /// Form widgets are synchronized first so an unobserved form edit can
    /// never be discarded by hibernation.
    @discardableResult
    func hibernateIfPossible() -> Bool {
        guard canHibernate, let document else { return false }
        prepareForDeactivation()
        guard canHibernate else { return false }

        hibernatedPageCount = document.pageCount
        pluginPanelRequest = nil
        cancelSearchAndInvalidate(clearResults: true)
        invalidateDocumentSelections()
        // Commands contain references to changed annotations/pages. A clean
        // tab may discard its undo history when hibernating so those deltas do
        // not keep PDFKit's document graph resident behind the memory manager.
        editHistory.reset()
        synchronizeHistoryPresentation()
        // Resume reconstructs fresh PDFAnnotation instances. No provenance
        // from the discarded PDFKit graph may survive into those new objects.
        runtimeTrustedAnnotations.removeAll(keepingCapacity: false)
        self.document = nil
        if !isRecoveryCopy, let managedRecoveryWorkingURL {
            PDFRecoveryStore().removeWorkingCopy(at: managedRecoveryWorkingURL)
            self.managedRecoveryWorkingURL = nil
        }
        if imageSourceURL == nil, let managedImagePreviewURL {
            ImagePDFConverter.removePreview(at: managedImagePreviewURL)
            self.managedImagePreviewURL = nil
        }
        revision = UUID()
        return true
    }

    /// Recreates a hibernated PDF document on demand. A failed resume retains
    /// its URL and tab metadata so the user can retry after restoring access.
    @discardableResult
    func resumeIfNeeded() -> Bool {
        guard isHibernated else { return document != nil || !hasOpenDocument }
        if let imageSourceURL,
           documentURL == imageSourceURL || documentURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
            do {
                documentURL = try ImagePDFConverter.makePreviewPDF(from: imageSourceURL)
                managedImagePreviewURL = documentURL
            } catch {
                presentedError = error.localizedDescription
                return false
            }
        }
        guard let documentURL else { return false }
        let loaded: PDFSourceFileAccess.LoadedDocument
        do {
            guard let unlocked = try loadUnlockedDocument(at: documentURL) else {
                presentedError = nil
                return false
            }
            loaded = unlocked
        } catch {
            presentedError = error.localizedDescription
            return false
        }

        // Be defensive even when this method is called by a future path that
        // did not first pass through `hibernateIfPossible()`.
        runtimeTrustedAnnotations.removeAll(keepingCapacity: false)
        document = loaded.document
        sourceFileVersion = loaded.version
        hibernatedPageCount = nil
        currentPageIndex = min(max(0, currentPageIndex), max(0, loaded.document.pageCount - 1))
        selectedPages = Set(selectedPages.filter { $0 >= 0 && $0 < loaded.document.pageCount })
        if selectedPages.isEmpty, loaded.document.pageCount > 0 {
            selectedPages = [currentPageIndex]
        }
        widgetValueSnapshot = [:]
        widgetUndoValueSnapshot = [:]
        widgetSnapshotPrimedPages = []
        if let page = loaded.document.page(at: currentPageIndex) {
            primeWidgetValues(on: page)
        }
        presentedError = nil
        revision = UUID()
        // A recovered copy can be dirty while restored lazily. Once its PDF
        // graph is available it needs the same recovery protection as edits.
        if isDirty { scheduleRecoverySnapshot() }
        return true
    }

    /// Creates a lazy tab during session restoration without parsing or
    /// rendering the PDF. The file is validated when the tab first activates.
    func restoreHibernated(
        url: URL,
        pageCount: Int,
        currentPageIndex requestedPageIndex: Int = 0,
        selectedPages requestedSelection: Set<Int> = []
    ) {
        guard !isDirty, !hasPendingReviewTextDraft else { return }
        resetDocumentState()
        scopedAccess = SecurityScopedAccess(url: url)
        documentURL = url
        // A restored tab has not read the PDF yet. Its baseline is captured by
        // `resumeIfNeeded()` together with the lazy PDFKit document load.
        sourceFileVersion = nil
        hibernatedPageCount = max(0, pageCount)
        let maximumIndex = max(0, pageCount - 1)
        currentPageIndex = min(max(0, requestedPageIndex), maximumIndex)
        selectedPages = Set(requestedSelection.filter { $0 >= 0 && $0 < pageCount })
        if selectedPages.isEmpty, pageCount > 0 {
            selectedPages = [currentPageIndex]
        }
        statusMessage = L10n.format("status.opened_pages", max(0, pageCount))
        revision = UUID()
    }

    func save() {
        _ = saveSynchronously()
    }

    func save(as url: URL) {
        _ = saveSynchronously(as: url)
    }

    /// Ordinary PDFKit serialization is intentionally unavailable for an
    /// encrypted source because it cannot prove that the original protection
    /// survived. Use the verified protected-copy flow instead.
    var canSaveNormally: Bool {
        document?.isEncrypted == false
    }

    var canRequestProtectedPDFExport: Bool {
        guard
            let document,
            pendingProtectedExport == nil,
            pendingTextEdit == nil,
            pendingInlineTextEdit == nil
        else {
            return false
        }
        return (try? PDFDocumentSecurityPolicy.validateCanReencrypt(document)) != nil
    }

    func requestProtectedPDFExport(to destinationURL: URL) {
        // Settle the on-page field editor before capturing the document token.
        // If validation rejects that draft, no password sheet is presented.
        prepareForDeactivation()
        guard let document else {
            presentedError = WorkspaceError.noDocument.localizedDescription
            return
        }
        guard
            pendingProtectedExport == nil,
            pendingInlineTextEdit == nil,
            !hasPendingReviewTextDraft
        else {
            presentedError = L10n.string("error.finish_inline_text_before_export")
            return
        }
        do {
            try PDFDocumentSecurityPolicy.validateCanReencrypt(document)
        } catch {
            presentedError = error.localizedDescription
            pendingProtectedExport = nil
            return
        }
        if
            let documentURL,
            PDFSourceFileVersion.refersToSameLocation(documentURL, destinationURL)
        {
            presentedError = L10n.string("error.save_copy_same_as_original")
            return
        }
        pendingProtectedExport = PDFProtectedExportPresentation(
            destinationURL: destinationURL,
            sourceURL: documentURL,
            documentIdentity: ObjectIdentifier(document),
            documentRevision: revision
        )
        presentedError = nil
    }

    func cancelProtectedPDFExport() {
        pendingProtectedExport = nil
    }

    /// Completes the exact export that was authorized before the password
    /// sheet appeared. A tab/document change cannot redirect a password meant
    /// for PDF A into PDF B.
    @discardableResult
    func exportProtectedCopy(
        presentation: PDFProtectedExportPresentation,
        userPassword: String
    ) -> Bool {
        prepareForDeactivation()
        guard
            let document,
            ObjectIdentifier(document) == presentation.documentIdentity,
            revision == presentation.documentRevision,
            documentURL?.standardizedFileURL
                == presentation.sourceURL?.standardizedFileURL
        else {
            presentedError = L10n.string(
                "security.export.document_changed",
                defaultValue: "문서가 변경되어 내보내기를 중단했습니다. 다시 시도해 주세요."
            )
            return false
        }
        return exportProtectedCopy(
            to: presentation.destinationURL,
            userPassword: userPassword
        )
    }

    /// Writes a non-mutating encrypted copy. Unlike Save As, success does not
    /// change documentURL or mark the current edit history as saved, so a later
    /// ordinary Command-S can never accidentally remove this copy's password.
    @discardableResult
    func exportProtectedCopy(to url: URL, userPassword: String) -> Bool {
        guard let document else {
            presentedError = WorkspaceError.noDocument.localizedDescription
            return false
        }
        do {
            // Model boundary for UI and integrations. ProtectedPDFExporter
            // repeats this check so neither entry point trusts the other.
            try PDFDocumentSecurityPolicy.validateCanReencrypt(document)
        } catch {
            presentedError = error.localizedDescription
            return false
        }
        prepareForDeactivation()
        guard pendingInlineTextEdit == nil, !hasPendingReviewTextDraft else {
            presentedError = L10n.string("error.finish_inline_text_before_export")
            return false
        }
        do {
            let resultingURL = try ProtectedPDFExporter.export(
                document: document,
                sourceURL: documentURL,
                to: url,
                userPassword: userPassword
            )
            statusMessage = L10n.format(
                "security.export.saved",
                resultingURL.lastPathComponent
            )
            presentedError = nil
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    /// Returns a definitive result so a close/quit request can be cancelled
    /// when the write fails or the destination has not been chosen.
    @discardableResult
    func saveSynchronously(as requestedURL: URL? = nil) -> Bool {
        // `WorkspaceSaveCoordinator` already prepares the visible tab, but
        // this model API is also called directly by tests and future
        // integrations. Treat the model itself as the final durability
        // boundary: the on-page inline editor and native PDFKit form field must
        // become PDF objects before serialization starts. The separate
        // Viewer/Study review sheet remains an unapplied model draft until the
        // person presses Apply; Save never turns that draft into PDF content.
        //
        // This is idempotent. The first preparation clears a committed inline
        // draft, and subsequent calls merely observe the synchronized state.
        prepareForDeactivation()
        guard let document else {
            presentedError = WorkspaceError.noDocument.localizedDescription
            return false
        }
        do {
            // PDFKit only creates password protection when explicit write
            // options are supplied. Fail closed instead of letting ordinary
            // Save or Save Copy silently serialize an unlocked document as a
            // plaintext PDF. The protected-export flow performs verified,
            // owner-authorized encryption instead.
            try PDFDocumentSecurityPolicy.validateOrdinarySaveAllowed(document)
        } catch {
            presentedError = error.localizedDescription
            return false
        }
        guard !requiresSaveDestination || requestedURL != nil else {
            presentedError = L10n.string("error.choose_save_location")
            return false
        }
        if let requestedURL, let imageSourceURL,
           PDFSourceFileVersion.refersToSameLocation(requestedURL, imageSourceURL) {
            presentedError = L10n.string("error.save_copy_same_as_original")
            return false
        }
        guard let url = requestedURL ?? documentURL else {
            presentedError = L10n.string("error.choose_save_location")
            return false
        }

        let access = SecurityScopedAccess(url: url)
        if
            requestedURL != nil,
            let currentURL = documentURL,
            PDFSourceFileVersion.refersToSameLocation(currentURL, url)
        {
            // The coordinator normally catches this before calling the model,
            // but the model is also a public internal boundary used by tests,
            // menu actions, and future integrations. Reject explicit Save As
            // to the same inode here so no caller can reach direct-write fallback.
            presentedError = L10n.string("error.save_copy_same_as_original")
            return false
        }
        do {
            let saved: PDFSourceFileAccess.SavedDocument
            if
                requestedURL == nil,
                let currentURL = documentURL,
                PDFSourceFileVersion.refersToSameLocation(currentURL, url)
            {
                // A missing baseline is treated as a conflict. This can happen
                // only when the original disappeared or could not be inspected;
                // guessing here would reintroduce silent overwrite data loss.
                guard let sourceFileVersion else {
                    throw WorkspaceError.externalModification(url)
                }
                saved = try PDFSourceFileAccess.overwriteDocument(
                    document,
                    at: url,
                    expectedVersion: sourceFileVersion
                )
            } else {
                // Save As targets are explicitly selected (and overwrite-
                // confirmed, when needed) by NSSavePanel, so they do not share
                // the original file's baseline.
                let resultingURL = try pdfWriter(document, url) {
                    if let imageSourceURL = self.imageSourceURL,
                       PDFSourceFileVersion.refersToSameLocation(imageSourceURL, url) {
                        throw WorkspaceError.operationFailed(L10n.string("error.save_copy_same_as_original"))
                    }
                    // A destination that was harmless at panel confirmation can
                    // be replaced by a symlink/hard link while a 200 MB PDF is
                    // serializing. Re-check at the writer's final commit point.
                    if
                        let currentURL = self.documentURL,
                        PDFSourceFileVersion.refersToSameLocation(currentURL, url)
                    {
                        throw WorkspaceError.operationFailed(
                            L10n.string("error.save_copy_same_as_original")
                        )
                    }
                }
                saved = PDFSourceFileAccess.SavedDocument(
                    url: resultingURL,
                    version: try PDFSourceFileVersion.capture(at: resultingURL)
                )
            }
            let resultingURL = saved.url
            // Keep the old backing file until PDFKit no longer depends on it.
            // On successful Save As, future hibernation resumes the durable PDF.
            imageSourceURL = nil
            imageSourceAccess = nil
            isRecoveryCopy = false
            recoveryTask?.cancel()
            recoveryStore?.remove(id: recoveryID)
            recoveryWarning = nil
            scopedAccess = resultingURL == url ? access : SecurityScopedAccess(url: resultingURL)
            documentURL = resultingURL
            sourceFileVersion = saved.version
            hibernatedPageCount = nil
            // OCR hashing is deliberately lazy and runs off the main actor.
            editHistory.markSaved()
            synchronizeHistoryPresentation()
            refreshPrimedWidgetValueSnapshot()
            statusMessage = L10n.format("status.saved_file", resultingURL.lastPathComponent)
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    func merge(urls: [URL], insertionIndex: Int? = nil) {
        // Page insertion belongs exclusively to Editing mode. Keep this guard
        // at the model boundary (before even reporting a missing document), so
        // a stale drop callback or future integration cannot mutate—or change
        // presentation state for—a Viewer/Study tab after the UI permission was
        // revoked.
        guard allows(.pageEditing) else { return }
        guard let document else {
            presentedError = WorkspaceError.noDocument.localizedDescription
            return
        }

        do {
            let beforeNavigation = navigationSnapshot
            var pages: [PDFPage] = []
            for url in urls {
                let access = SecurityScopedAccess(url: url)
                let copiedPages: [PDFPage]? = try withExtendedLifetime(access) {
                    guard let loaded = try loadUnlockedDocument(at: url) else {
                        // Cancelling one protected input cancels the entire
                        // merge before the destination has been mutated.
                        return nil
                    }
                    let source = loaded.document
                    try PDFDocumentSecurityPolicy.validateCanExtractPages(source)
                    return try (0..<source.pageCount).map { index in
                        guard
                            let sourcePage = source.page(at: index),
                            let copiedPage = PDFPageOperations.detachedCopy(of: sourcePage)
                        else {
                            throw WorkspaceError.operationFailed(
                                L10n.format(
                                    "error.copy_page_from_file",
                                    url.lastPathComponent,
                                    index + 1
                                )
                            )
                        }
                        return copiedPage
                    }
                }
                guard let copiedPages else { return }
                pages.append(contentsOf: copiedPages)
            }

            guard !pages.isEmpty else { return }
            // Page insertion changes indexes. Commit an editor whose draft is
            // addressed by page index while that index still identifies the
            // page on which the person typed.
            prepareForPageStructureMutation()
            let requestedIndex = insertionIndex ?? document.pageCount
            let start = max(0, min(requestedIndex, document.pageCount))
            for (offset, page) in pages.enumerated() {
                document.insert(page, at: start + offset)
            }
            selectedPages = Set(start..<(start + pages.count))
            currentPageIndex = start
            resetWidgetSnapshotsAfterPageStructureMutation()
            let insertedCount = pages.count
            recordEdit(
                actionName: L10n.format("status.merged_pages", insertedCount),
                beforeNavigation: beforeNavigation,
                invalidatingDocumentSelections: true,
                retainedPageCost: insertedCount,
                undo: {
                    let indexes = pages.map(document.index(for:))
                    guard indexes.allSatisfy({ $0 != NSNotFound }) else {
                        throw WorkspaceError.operationFailed(
                            L10n.string(
                                "error.undo_page_state",
                                defaultValue: "The pages are no longer in the expected state."
                            )
                        )
                    }
                    for index in indexes.sorted().reversed() {
                        document.removePage(at: index)
                    }
                },
                redo: {
                    guard pages.allSatisfy({ document.index(for: $0) == NSNotFound }) else {
                        throw WorkspaceError.operationFailed(
                            L10n.string(
                                "error.undo_page_state",
                                defaultValue: "The pages are no longer in the expected state."
                            )
                        )
                    }
                    for (offset, page) in pages.enumerated() {
                        document.insert(page, at: min(start + offset, document.pageCount))
                    }
                }
            )
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func movePage(from source: Int, before target: Int) {
        // Sidebar/grid drop handlers also validate mode and revision, but this
        // public model operation is the final authority. A delayed drag event
        // must become a complete no-op after leaving Editing mode.
        guard allows(.pageEditing) else { return }
        guard
            let document,
            source >= 0,
            source < document.pageCount,
            target >= 0,
            target <= document.pageCount,
            source != target,
            source + 1 != target,
            let page = document.page(at: source)
        else { return }

        // Moving the page first could make an index-addressed text draft land
        // on a different page. Text therefore becomes an earlier transaction.
        prepareForPageStructureMutation()
        let beforeNavigation = navigationSnapshot
        document.removePage(at: source)
        let insertion = source < target ? target - 1 : target
        let boundedInsertion = max(0, min(insertion, document.pageCount))
        document.insert(page, at: boundedInsertion)
        selectedPages = [boundedInsertion]
        currentPageIndex = boundedInsertion
        resetWidgetSnapshotsAfterPageStructureMutation()
        let movePageObject: (Int) throws -> Void = { destination in
            let current = document.index(for: page)
            guard current != NSNotFound else {
                throw WorkspaceError.operationFailed(
                    L10n.string(
                        "error.undo_page_state",
                        defaultValue: "The pages are no longer in the expected state."
                    )
                )
            }
            document.removePage(at: current)
            document.insert(page, at: min(max(0, destination), document.pageCount))
        }
        recordEdit(
            actionName: L10n.string("status.pages_reordered"),
            beforeNavigation: beforeNavigation,
            invalidatingDocumentSelections: true,
            undo: { try movePageObject(source) },
            redo: { try movePageObject(boundedInsertion) }
        )
    }

    func movePageToEnd(from source: Int) {
        // Keep convenience entry points closed as well as the primitive. This
        // avoids inspecting stale page metadata after a delayed command fires
        // in Viewer or Study mode.
        guard allows(.pageEditing) else { return }
        guard source >= 0, source < pageCount, source != pageCount - 1 else { return }
        movePage(from: source, before: pageCount)
    }

    func moveSelectedPage(by offset: Int) {
        // The delegated move performs the same check, but the wrapper must not
        // read a stale selection before it knows page editing is still allowed.
        guard allows(.pageEditing) else { return }
        guard selectedPages.count == 1, let source = selectedPages.first else { return }
        let destination = source + offset
        guard destination >= 0, destination < pageCount else { return }
        if offset > 0 {
            movePage(from: source, before: destination + 1)
        } else {
            movePage(from: source, before: destination)
        }
    }

    func deleteSelectedPages() {
        // Check capability before validation errors or selection inspection so
        // rejected Viewer/Study commands have no document or UI side effects.
        guard allows(.pageEditing) else { return }
        guard let document, !selectedPages.isEmpty else {
            presentedError = WorkspaceError.noPagesSelected.localizedDescription
            return
        }
        guard selectedPages.count < document.pageCount else {
            presentedError = L10n.string("error.minimum_one_page")
            return
        }

        let oldSelection = selectedPages.sorted()
        let removedPages = oldSelection.compactMap(document.page(at:))
        guard removedPages.count == oldSelection.count else { return }

        // A draft on a deleted page must be materialized before its PDFPage is
        // detached from the document graph.
        prepareForPageStructureMutation()
        let beforeNavigation = navigationSnapshot
        for index in oldSelection.reversed() {
            document.removePage(at: index)
        }
        let next = min(oldSelection.first ?? 0, max(0, document.pageCount - 1))
        selectedPages = [next]
        currentPageIndex = next
        resetWidgetSnapshotsAfterPageStructureMutation()
        recordEdit(
            actionName: L10n.format("status.deleted_pages", oldSelection.count),
            beforeNavigation: beforeNavigation,
            invalidatingDocumentSelections: true,
            retainedPageCost: removedPages.count,
            undo: {
                guard removedPages.allSatisfy({ document.index(for: $0) == NSNotFound }) else {
                    throw WorkspaceError.operationFailed(
                        L10n.string(
                            "error.undo_page_state",
                            defaultValue: "The pages are no longer in the expected state."
                        )
                    )
                }
                for (index, page) in zip(oldSelection, removedPages) {
                    document.insert(page, at: min(index, document.pageCount))
                }
            },
            redo: {
                let indexes = removedPages.map(document.index(for:))
                guard indexes.allSatisfy({ $0 != NSNotFound }) else {
                    throw WorkspaceError.operationFailed(
                        L10n.string(
                            "error.undo_page_state",
                            defaultValue: "The pages are no longer in the expected state."
                        )
                    )
                }
                for index in indexes.sorted().reversed() {
                    document.removePage(at: index)
                }
            }
        )
    }

    func rotateSelectedPages(clockwise: Bool) {
        // Rotation changes page dictionaries in the saved PDF and therefore is
        // editing, even though it can look like a viewing convenience.
        guard allows(.pageEditing) else { return }
        guard let document, !selectedPages.isEmpty else {
            presentedError = WorkspaceError.noPagesSelected.localizedDescription
            return
        }
        let beforeNavigation = navigationSnapshot
        let rotations: [(page: PDFPage, before: Int, after: Int)] = selectedPages.sorted().compactMap {
            guard let page = document.page(at: $0) else { return nil }
            let before = page.rotation
            return (
                page: page,
                before: before,
                after: normalizedRotation(before + (clockwise ? 90 : -90))
            )
        }
        guard !rotations.isEmpty else { return }
        // This also fixes history chronology for type -> toolbar rotate: text
        // is older, rotation is newer, so the first Undo reverses rotation.
        commitPendingInlineTextDraftIfNeeded()
        rotations.forEach { $0.page.rotation = $0.after }
        let applyRotations: (Bool) throws -> Void = { usesFinalValue in
            guard rotations.allSatisfy({ document.index(for: $0.page) != NSNotFound }) else {
                throw WorkspaceError.operationFailed(
                    L10n.string(
                        "error.undo_page_state",
                        defaultValue: "The pages are no longer in the expected state."
                    )
                )
            }
            rotations.forEach { $0.page.rotation = usesFinalValue ? $0.after : $0.before }
        }
        recordEdit(
            actionName: L10n.string("status.rotated_pages"),
            beforeNavigation: beforeNavigation,
            invalidatingDocumentSelections: true,
            undo: { try applyRotations(false) },
            redo: { try applyRotations(true) }
        )
    }

    /// Saves the selected pages, in document order, as one new PDF without
    /// changing the open document.
    func exportSelectedPagesAsCombinedPDF(to url: URL) {
        guard document != nil, !selectedPages.isEmpty else {
            presentedError = WorkspaceError.noPagesSelected.localizedDescription
            return
        }
        // Commit the active AppKit field editor and on-page editing overlays so
        // the export matches what is currently visible.
        prepareForDeactivation()
        guard pendingInlineTextEdit == nil else {
            presentedError = L10n.string(
                "error.finish_inline_text_before_export",
                defaultValue: "내보내기 전에 페이지 위 텍스트 편집을 완료하거나 취소하세요."
            )
            return
        }

        guard let document else {
            presentedError = WorkspaceError.noDocument.localizedDescription
            return
        }
        let requestedIndexes = selectedPages.sorted()
        let sourceURL = documentURL
        do {
            try PDFDocumentSecurityPolicy.validateCanExtractPages(document)
            if
                let sourceURL,
                PDFSourceFileVersion.refersToSameLocation(sourceURL, url)
            {
                throw WorkspaceError.operationFailed(
                    L10n.string("error.save_copy_same_as_original")
                )
            }

            let extracted = try PDFPageOperations.extract(
                from: document,
                indexes: requestedIndexes
            )
            let access = SecurityScopedAccess(url: url)
            _ = try withExtendedLifetime(access) {
                try pdfWriter(extracted, url) {
                    if
                        let sourceURL,
                        PDFSourceFileVersion.refersToSameLocation(sourceURL, url)
                    {
                        throw WorkspaceError.operationFailed(
                            L10n.string("error.save_copy_same_as_original")
                        )
                    }
                }
            }
            statusMessage = L10n.format(
                "status.exported_pages_combined",
                requestedIndexes.count,
                url.lastPathComponent
            )
        } catch {
            presentedError = error.localizedDescription
        }
    }

    /// Compatibility entry point retained for existing commands and tests.
    func extractSelectedPages(to url: URL) {
        exportSelectedPagesAsCombinedPDF(to: url)
    }

    /// Saves each selected page as a separate, validated one-page PDF inside a
    /// newly created output folder. The exporter never overwrites an existing
    /// folder or page file.
    func exportSelectedPagesAsIndividualPDFs(to parentDirectory: URL) {
        guard document != nil, !selectedPages.isEmpty else {
            presentedError = WorkspaceError.noPagesSelected.localizedDescription
            return
        }
        prepareForDeactivation()
        guard pendingInlineTextEdit == nil else {
            presentedError = L10n.string(
                "error.finish_inline_text_before_export",
                defaultValue: "내보내기 전에 페이지 위 텍스트 편집을 완료하거나 취소하세요."
            )
            return
        }

        guard let document else {
            presentedError = WorkspaceError.noDocument.localizedDescription
            return
        }
        let requestedIndexes = selectedPages.sorted()
        do {
            try PDFDocumentSecurityPolicy.validateCanExtractPages(document)
            let result = try SelectedPagePDFExporter.exportIndividually(
                from: document,
                indexes: requestedIndexes,
                to: parentDirectory,
                sourceURL: documentURL
            )
            statusMessage = L10n.format(
                "status.exported_pages_individual",
                result.fileURLs.count,
                result.directoryURL.lastPathComponent
            )
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func exportSelectedPagesAsImages(to directory: URL, scale: CGFloat = 2.0) {
        guard document != nil, !selectedPages.isEmpty else {
            presentedError = WorkspaceError.noPagesSelected.localizedDescription
            return
        }
        prepareForDeactivation()
        guard pendingInlineTextEdit == nil else {
            presentedError = L10n.string(
                "error.finish_inline_text_before_export",
                defaultValue: "내보내기 전에 페이지 위 텍스트 편집을 완료하거나 취소하세요."
            )
            return
        }
        guard let document else {
            presentedError = WorkspaceError.noDocument.localizedDescription
            return
        }

        let requestedIndexes = selectedPages.sorted()
        do {
            try PDFDocumentSecurityPolicy.validateCanRasterizePages(document)
            _ = try SelectedPagePNGExporter.export(
                from: document,
                indexes: requestedIndexes,
                to: directory,
                sourceURL: documentURL,
                scale: scale
            )
            statusMessage = L10n.string("status.exported_png")
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func exportAsOfficeDocument(
        to url: URL,
        format: PDFOfficeExportFormat
    ) {
        prepareForDeactivation()
        guard pendingInlineTextEdit == nil, let document else {
            presentedError = pendingInlineTextEdit == nil
                ? WorkspaceError.noDocument.localizedDescription
                : L10n.string("error.finish_inline_text_before_export")
            return
        }

        guard officeExportTask == nil else { return }
        let expectedRevision = revision
        let source = documentURL
        officeExportProgress = 0
        officeExportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.officeExportTask = nil
                self.officeExportProgress = nil
                if self.isDirty { self.scheduleRecoverySnapshot() }
            }
            do {
                try await PDFOfficeExporter.exportResponsive(document, to: url, format: format, validateDocument: {
                    guard self.document === document, self.revision == expectedRevision else {
                        throw WorkspaceError.operationFailed(L10n.string("security.export.document_changed"))
                    }
                    if let source, PDFSourceFileVersion.refersToSameLocation(source, url) {
                        throw WorkspaceError.operationFailed(L10n.string("error.save_copy_same_as_original"))
                    }
                }, progress: { self.officeExportProgress = $0 })
                self.statusMessage = L10n.format(
                format == .word
                    ? "conversion.word.saved"
                    : "conversion.powerpoint.saved",
                url.lastPathComponent
                )
            } catch is CancellationError {
                guard self.document === document else { return }
                self.statusMessage = L10n.string("builder.status.cancelled")
            } catch {
                guard self.document === document else { return }
                self.presentedError = error.localizedDescription
            }
        }
    }

    func setCurrentPage(_ index: Int) {
        guard index >= 0, index < pageCount else { return }
        currentPageIndex = index
        if selectedPages.isEmpty {
            selectedPages = [index]
        }
    }

    func preparePDFViewportForNavigationMode(_ mode: PDFPageNavigationMode) {
        guard pdfViewportState.navigationMode != mode else { return }
        pdfViewportState.invalidateScrollPosition()
        pdfViewportState.navigationMode = mode
    }

    func selectPageFitMode(_ mode: PDFPageFitMode?) {
        pdfViewportState.invalidateScrollPosition()
        pdfViewportState.autoScales = mode == nil
        if mode == nil { overviewScale = 1 }
        pageFitMode = mode
    }

    func restorePageFitMode(_ mode: PDFPageFitMode?) {
        pageFitMode = mode
    }

    func endPageFitForManualZoom() {
        guard pageFitMode != nil else { return }
        pdfViewportState.autoScales = false
        pageFitMode = nil
    }

    func selectTwoPageDisplayMode(_ mode: PDFTwoPageDisplayMode) {
        // The PDFView may currently be replaced by the 3+ page grid. If the
        // hidden two-page subtype changes there, its retained clip geometry
        // still belongs to the old subtype and must not be restored later.
        if twoPageDisplayMode != mode {
            pdfViewportState.invalidateScrollPosition()
        }
        twoPageDisplayMode = mode
        pageColumns = 2
    }

    func recordPDFViewport(
        autoScales: Bool,
        scaleFactor: CGFloat,
        scrollProgress: PDFScrollProgress?,
        context: PDFViewerViewportContext = .normal
    ) {
        var viewport = pdfViewportState(for: context)
        viewport.autoScales = autoScales
        if scaleFactor.isFinite, scaleFactor > 0 {
            viewport.scaleFactor = scaleFactor
        }
        if let scrollProgress {
            viewport.horizontalScrollProgress = scrollProgress.horizontal
            viewport.verticalScrollProgress = scrollProgress.vertical
            viewport.capturedPageIndex = currentPageIndex
        }
        switch context {
        case .normal:
            pdfViewportState = viewport
        case .comparison:
            comparisonPDFViewportState = viewport
        }
    }

    func pdfViewportState(for context: PDFViewerViewportContext) -> PDFViewerViewportState {
        switch context {
        case .normal: pdfViewportState
        case .comparison: comparisonPDFViewportState
        }
    }

    /// Applies only scalar, normalized session metadata. Invalid floating
    /// point payloads are ignored so a damaged archive cannot poison PDFKit's
    /// scale or clip-view geometry.
    func restorePDFViewport(
        autoScales requestedAutoScales: Bool?,
        scaleFactor requestedScaleFactor: CGFloat?,
        horizontalScrollProgress requestedHorizontal: CGFloat?,
        verticalScrollProgress requestedVertical: CGFloat?,
        capturedPageIndex requestedCapturedPageIndex: Int? = nil,
        navigationMode requestedNavigationMode: PDFPageNavigationMode = .verticalScroll,
        context: PDFViewerViewportContext = .normal
    ) {
        let scaleFactor: CGFloat?
        if
            let requestedScaleFactor,
            requestedScaleFactor.isFinite,
            requestedScaleFactor > 0
        {
            scaleFactor = min(20, max(0.05, requestedScaleFactor))
        } else {
            scaleFactor = nil
        }

        var restored = PDFViewerViewportState()
        restored.navigationMode = context == .normal ? requestedNavigationMode : .verticalScroll
        restored.autoScales = requestedAutoScales != false || scaleFactor == nil
        restored.scaleFactor = scaleFactor
        if
            let requestedHorizontal,
            let requestedVertical,
            requestedHorizontal.isFinite,
            requestedVertical.isFinite
        {
            let progress = PDFScrollProgress(
                horizontal: requestedHorizontal,
                vertical: requestedVertical
            )
            restored.horizontalScrollProgress = progress.horizontal
            restored.verticalScrollProgress = progress.vertical
            if
                let requestedCapturedPageIndex,
                requestedCapturedPageIndex >= 0,
                requestedCapturedPageIndex < pageCount
            {
                restored.capturedPageIndex = requestedCapturedPageIndex
            }
        }
        switch context {
        case .normal:
            pdfViewportState = restored
        case .comparison:
            comparisonPDFViewportState = restored
        }
    }

    func requestTextEdit(pageIndex: Int, point: CGPoint, annotation: PDFAnnotation?) {
        if let annotation {
            let subtype = annotation.type?.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            // The legacy sheet may adopt an unowned FreeText comment, but it
            // must never reinterpret a Widget, Stamp, Link, or other subtype
            // merely because those objects also expose a `contents` property.
            guard subtype == "FreeText" else { return }
        }
        let initialText = annotation?.contents ?? ""
        let limited = InlineTextDraftLimiter.limit(initialText)
        guard !limited.wasTruncated else {
            // Never seed the legacy review sheet with a prefix of an existing
            // annotation. Applying that prefix later would silently destroy
            // the tail of a third-party PDF object. The object is left exactly
            // as opened and the user receives an explicit safety error.
            presentedError = L10n.format(
                "inline_text.existing_length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
            return
        }
        pendingTextAnnotation = annotation
        pendingTextEdit = PendingTextEdit(
            pageIndex: pageIndex,
            point: point,
            isEditingExistingAnnotation: annotation != nil,
            initialText: limited.text
        )
    }

    /// Synchronizes the review sheet's local editor with the document model.
    ///
    /// This does not touch PDFKit or mark the document dirty. It only makes the
    /// bounded draft durable across SwiftUI/tab lifecycle changes. The UUID
    /// prevents a late callback from an outgoing sheet from overwriting a newer
    /// request that happens to use the same workspace.
    func updatePendingTextDraft(id: UUID, text: String) {
        guard var pending = pendingTextEdit, pending.id == id else { return }
        let limited = InlineTextDraftLimiter.limit(text)
        pending.initialText = limited.text
        pendingTextEdit = pending
        if limited.wasTruncated {
            statusMessage = L10n.format(
                "inline_text.length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
        }
    }

    /// Starts the direct-on-page text workflow used only by Editing mode.
    ///
    /// No PDF object is changed here. The editor may be cancelled without an
    /// undo entry and without making the document dirty. Existing objects are
    /// accepted only when HwattakPDF owns/adopted them as FreeText; arbitrary
    /// third-party annotations and AcroForm widgets keep their native behavior.
    @discardableResult
    func requestInlineTextEdit(
        pageIndex: Int,
        point: CGPoint,
        annotation: PDFAnnotation?,
        visualReplacementText: String? = nil,
        visualReplacementBounds: CGRect? = nil
    ) -> Bool {
        inlineTextEditRejectionReason = nil
        guard
            allowsInlineTextEditing,
            pendingTextEdit == nil,
            let page = document?.page(at: pageIndex)
        else { return false }

        // A programmatic request can arrive while a previous view is being
        // replaced. Preserve that draft before starting another transaction.
        commitPendingInlineTextDraftIfNeeded()

        let purpose: InlineTextEditPurpose
        let bounds: CGRect
        let text: String
        let style: InlineTextStyle
        var draftWasTruncated = false

        if let annotation {
            guard
                page.annotations.contains(where: { $0 === annotation }),
                EditableAnnotationIdentity.kind(of: annotation) == .freeText
            else { return false }
            purpose = InlineTextAnnotationIdentity.isVisualReplacement(annotation)
                ? .visualReplacement
                : .freeText
            bounds = InlineTextGeometry.clamped(
                annotation.bounds,
                within: page.bounds(for: .cropBox)
            )
            let limited = InlineTextDraftLimiter.limit(annotation.contents ?? "")
            guard !limited.wasTruncated else {
                pendingInlineTextAnnotation = nil
                inlineTextEditRejectionReason = .existingTextExceedsSafetyLimit
                let lengthNotice = L10n.format(
                    "inline_text.existing_length_limit",
                    InlineTextDraftLimiter.maximumCharacterCount
                )
                statusMessage = purpose == .visualReplacement
                    ? [
                        L10n.string("inline_text.visual_replacement_warning"),
                        lengthNotice,
                    ].joined(separator: " ")
                    : lengthNotice
                return false
            }
            text = limited.text
            style = InlineTextStyle(annotation: annotation, purpose: purpose)
            pendingInlineTextAnnotation = annotation
        } else if
            let visualReplacementText,
            let visualReplacementBounds,
            !visualReplacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            purpose = .visualReplacement
            bounds = InlineTextGeometry.clamped(
                visualReplacementBounds.insetBy(dx: -2, dy: -2),
                within: page.bounds(for: .cropBox)
            )
            let limited = InlineTextDraftLimiter.limit(visualReplacementText)
            text = limited.text
            draftWasTruncated = limited.wasTruncated
            style = .standard(for: purpose)
            pendingInlineTextAnnotation = nil
        } else {
            purpose = .freeText
            bounds = InlineTextGeometry.defaultBounds(
                at: point,
                within: page.bounds(for: .cropBox)
            )
            text = ""
            style = .standard(for: purpose)
            pendingInlineTextAnnotation = nil
        }

        guard !bounds.isEmpty else { return false }
        pendingInlineTextEdit = PendingInlineTextEdit(
            pageIndex: pageIndex,
            bounds: bounds,
            isEditingExistingAnnotation: annotation != nil,
            purpose: purpose,
            text: text,
            style: style
        )
        currentPageIndex = pageIndex
        selectedPages = [pageIndex]
        if draftWasTruncated {
            let lengthNotice = L10n.format(
                "inline_text.length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
            statusMessage = purpose == .visualReplacement
                ? [
                    L10n.string("inline_text.visual_replacement_warning"),
                    lengthNotice,
                ].joined(separator: " ")
                : lengthNotice
        }
        if purpose == .visualReplacement, !draftWasTruncated {
            statusMessage = L10n.string(
                "inline_text.visual_replacement_warning",
                defaultValue: "Visual replacement only: the original PDF text remains searchable and copyable. This is not secure redaction."
            )
        }
        return true
    }

    /// Copies live NSTextView/style-control values into the tab model. This is
    /// intentionally not a document mutation and therefore never creates 100
    /// undo commands while a person types 100 characters.
    func updatePendingInlineTextDraft(
        id: UUID,
        text: String,
        style requestedStyle: InlineTextStyle,
        bounds requestedBounds: CGRect
    ) {
        guard
            var pending = pendingInlineTextEdit,
            pending.id == id,
            let page = document?.page(at: pending.pageIndex)
        else { return }
        var style = requestedStyle
        style.normalize()
        let limited = InlineTextDraftLimiter.limit(text)
        pending.text = limited.text
        pending.style = style
        pending.bounds = InlineTextGeometry.clamped(
            requestedBounds,
            within: page.bounds(for: .cropBox)
        )
        pendingInlineTextEdit = pending
        if limited.wasTruncated {
            let lengthNotice = L10n.format(
                "inline_text.length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
            statusMessage = pending.purpose == .visualReplacement
                ? [
                    L10n.string("inline_text.visual_replacement_warning"),
                    lengthNotice,
                ].joined(separator: " ")
                : lengthNotice
        }
    }

    /// Makes one concrete overlay instance the writer for a pending draft.
    /// A newly created PDFView intentionally replaces the previous owner while
    /// keeping the same draft UUID and transaction.
    @discardableResult
    func claimPendingInlineTextEditor(
        ownerID: UUID,
        draftID: UUID
    ) -> Bool {
        guard pendingInlineTextEdit?.id == draftID else { return false }
        pendingInlineTextEditorOwnerID = ownerID
        return true
    }

    func ownsPendingInlineTextEditor(
        ownerID: UUID,
        draftID: UUID
    ) -> Bool {
        pendingInlineTextEdit?.id == draftID
            && pendingInlineTextEditorOwnerID == ownerID
    }

    func releasePendingInlineTextEditor(
        ownerID: UUID,
        draftID: UUID
    ) {
        guard ownsPendingInlineTextEditor(ownerID: ownerID, draftID: draftID) else { return }
        pendingInlineTextEditorOwnerID = nil
    }

    /// Commits the last synchronized draft. Mode switching, saving, closing,
    /// tab switching, and PDFView dismantling all share this boundary.
    func commitPendingInlineTextDraftIfNeeded() {
        guard let pending = pendingInlineTextEdit else { return }
        commitPendingInlineText(
            id: pending.id,
            text: pending.text,
            style: pending.style,
            bounds: pending.bounds
        )
    }

    func commitPendingInlineText(
        id: UUID,
        text: String,
        style requestedStyle: InlineTextStyle,
        bounds requestedBounds: CGRect
    ) {
        guard
            let pending = pendingInlineTextEdit,
            pending.id == id,
            let page = document?.page(at: pending.pageIndex)
        else { return }

        // The visible NSTextView and update API already preflight this limit,
        // but a public/direct caller can bypass both. Refuse atomically before
        // clearing presentation state: saving a truncated prefix over an
        // existing FreeText object would be irreversible tail loss.
        let limited = InlineTextDraftLimiter.limit(text)
        guard !limited.wasTruncated else {
            statusMessage = L10n.format(
                "inline_text.length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
            return
        }

        // Remove presentation state before registering the semantic mutation.
        // `recordEdit` publishes a revision synchronously; leaving the draft in
        // place until after that publication could briefly recreate the editor.
        let existingAnnotation = pendingInlineTextAnnotation
        clearPendingInlineTextEdit()

        let limitedText = limited.text
        let trimmed = limitedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            activeTool = .select
            return
        }
        var style = requestedStyle
        style.normalize()
        let bounds = InlineTextGeometry.clamped(
            requestedBounds,
            within: page.bounds(for: .cropBox)
        )
        guard !bounds.isEmpty else { return }
        let beforeNavigation = navigationSnapshot

        if pending.isEditingExistingAnnotation {
            guard
                let annotation = existingAnnotation,
                page.annotations.contains(where: { $0 === annotation }),
                EditableAnnotationIdentity.kind(of: annotation) == .freeText
            else { return }
            let original = PDFTextAnnotationSnapshot(annotation: annotation)
            applyInlineText(
                limitedText,
                style: style,
                bounds: bounds,
                purpose: pending.purpose,
                to: annotation
            )
            let edited = PDFTextAnnotationSnapshot(annotation: annotation)
            guard inlineTextSnapshotChanged(from: original, to: edited) else {
                original.apply(to: annotation)
                activeTool = .select
                return
            }
            // An explicit edit adopts this exact in-memory object for the
            // current session. Viewer/Study can now expose its overlay without
            // treating a forgeable marker from the file as provenance.
            trustRuntimeAnnotation(annotation)
            activeTool = .select
            recordEdit(
                actionName: L10n.string(
                    "status.inline_text_updated",
                    defaultValue: "Text and appearance updated."
                ),
                beforeNavigation: beforeNavigation,
                undo: { original.apply(to: annotation) },
                redo: { edited.apply(to: annotation) }
            )
            return
        }

        let annotation = PDFAnnotation(
            bounds: bounds,
            forType: .freeText,
            withProperties: nil
        )
        PDFAnnotationPrivacy.clearImplicitAuthor(on: annotation)
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        applyInlineText(
            limitedText,
            style: style,
            bounds: bounds,
            purpose: pending.purpose,
            to: annotation
        )
        page.addAnnotation(annotation)
        activeTool = .select
        registerAnnotationAdditions(
            [(page: page, annotation: annotation)],
            message: pending.purpose == .visualReplacement
                ? L10n.string(
                    "status.visual_text_replacement_added",
                    defaultValue: "A visual text replacement was added; the original text remains underneath."
                )
                : L10n.string("status.text_added"),
            beforeNavigation: beforeNavigation
        )
    }

    func cancelPendingInlineText() {
        clearPendingInlineTextEdit()
        activeTool = .select
    }

    private func clearPendingInlineTextEdit() {
        pendingInlineTextEdit = nil
        pendingInlineTextAnnotation = nil
        pendingInlineTextEditorOwnerID = nil
        inlineTextEditRejectionReason = nil
    }

    private func applyInlineText(
        _ text: String,
        style: InlineTextStyle,
        bounds: CGRect,
        purpose: InlineTextEditPurpose,
        to annotation: PDFAnnotation
    ) {
        annotation.contents = text
        annotation.bounds = bounds
        annotation.font = style.font
        annotation.fontColor = style.textColor.nsColor
        annotation.color = style.backgroundColor.nsColor
        annotation.alignment = style.alignment
        annotation.modificationDate = Date()
        _ = ensureID(for: annotation)
        EditableAnnotationIdentity.assign(.freeText, to: annotation)
        InlineTextAnnotationIdentity.setVisualReplacement(
            purpose == .visualReplacement,
            on: annotation
        )
    }

    private func inlineTextSnapshotChanged(
        from lhs: PDFTextAnnotationSnapshot,
        to rhs: PDFTextAnnotationSnapshot
    ) -> Bool {
        lhs.contents != rhs.contents
            || lhs.bounds != rhs.bounds
            || lhs.font?.fontName != rhs.font?.fontName
            || lhs.font?.pointSize != rhs.font?.pointSize
            || !PDFTextColor(lhs.fontColor).visuallyEquals(PDFTextColor(rhs.fontColor))
            || !PDFTextColor(lhs.color).visuallyEquals(PDFTextColor(rhs.color))
            || lhs.alignment != rhs.alignment
            || String(describing: lhs.name) != String(describing: rhs.name)
            || lhs.storedKind != rhs.storedKind
            || lhs.isVisualReplacement != rhs.isVisualReplacement
    }

    /// Opens the normal text-review sheet with an AI-produced draft. Nothing
    /// is added to the PDF until the user explicitly presses Apply there.
    @discardableResult
    func prepareAITextDraft(_ text: String) -> Bool {
        prepareAITextDraft(text, pageIndex: currentPageIndex)
    }

    /// Opens an AI draft on the page/document that produced it. Merely moving
    /// to another page is safe; replacing or editing the document makes the
    /// provider response stale and requires a new request.
    @discardableResult
    func prepareAITextDraft(
        _ text: String,
        target: AIDraftApplicationTarget
    ) -> Bool {
        guard
            documentURL == target.documentURL,
            revision == target.documentRevision
        else {
            presentedError = L10n.string(
                "ai.error.document_changed",
                defaultValue: "PDF가 바뀌어 준비 중이던 AI 요청을 취소했습니다. 다시 시도해 주세요."
            )
            return false
        }
        return prepareAITextDraft(text, pageIndex: target.pageIndex)
    }

    private func prepareAITextDraft(_ text: String, pageIndex: Int) -> Bool {
        // AI provider responses are already bounded by the assistant session,
        // but this model boundary also protects future/offline callers.
        let limited = InlineTextDraftLimiter.limit(text)
        let trimmed = limited.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard
            let page = document?.page(at: pageIndex)
        else {
            presentedError = WorkspaceError.noDocument.localizedDescription
            return false
        }
        let pageBounds = page.bounds(for: .cropBox)
        let width = min(260.0, pageBounds.width * 0.55)
        let height = 64.0
        pendingTextAnnotation = nil
        pendingTextEdit = PendingTextEdit(
            pageIndex: pageIndex,
            point: CGPoint(
                x: pageBounds.midX - width / 2,
                y: pageBounds.midY + height / 2
            ),
            isEditingExistingAnnotation: false,
            initialText: limited.text
        )
        if limited.wasTruncated {
            statusMessage = L10n.format(
                "inline_text.length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
        }
        return true
    }

    func commitPendingText(_ text: String) {
        guard
            let pending = pendingTextEdit,
            let page = document?.page(at: pending.pageIndex)
        else {
            clearPendingTextEdit()
            return
        }

        // UI preflight prevents an oversized paste from reaching TextKit, but
        // model APIs must remain safe when called directly by tests, plug-ins,
        // or a future automation. Refuse rather than truncate: silently saving
        // only a prefix would be data loss when editing an existing comment.
        let limited = InlineTextDraftLimiter.limit(text)
        guard !limited.wasTruncated else {
            presentedError = L10n.format(
                "inline_text.length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
            return
        }
        let committedText = limited.text
        defer { clearPendingTextEdit() }
        let trimmed = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let beforeNavigation = navigationSnapshot

        if pending.isEditingExistingAnnotation {
            guard
                let annotation = pendingTextAnnotation,
                annotation.type?.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                ) == "FreeText",
                page.annotations.contains(where: { $0 === annotation })
            else { return }
            let originalText = annotation.contents
            let originalName = annotation.value(forAnnotationKey: .name) as? String
            let originalKind = EditableAnnotationIdentity.storedKind(of: annotation)
            let originalModificationDate = annotation.modificationDate
            guard originalText != committedText else {
                activeTool = .select
                return
            }
            annotation.contents = committedText
            annotation.modificationDate = Date()
            _ = ensureID(for: annotation)
            EditableAnnotationIdentity.assign(.freeText, to: annotation)
            let editedName = annotation.value(forAnnotationKey: .name) as? String
            let editedKind = EditableAnnotationIdentity.storedKind(of: annotation)
            let editedModificationDate = annotation.modificationDate
            trustRuntimeAnnotation(annotation)
            activeTool = .select
            recordEdit(
                actionName: L10n.string("status.text_updated"),
                beforeNavigation: beforeNavigation,
                undo: {
                    annotation.contents = originalText
                    if let originalName {
                        annotation.setValue(originalName, forAnnotationKey: .name)
                    } else {
                        annotation.removeValue(forAnnotationKey: .name)
                    }
                    EditableAnnotationIdentity.restoreStoredKind(originalKind, to: annotation)
                    annotation.modificationDate = originalModificationDate
                },
                redo: {
                    annotation.contents = committedText
                    if let editedName {
                        annotation.setValue(editedName, forAnnotationKey: .name)
                    } else {
                        annotation.removeValue(forAnnotationKey: .name)
                    }
                    EditableAnnotationIdentity.restoreStoredKind(editedKind, to: annotation)
                    annotation.modificationDate = editedModificationDate
                }
            )
            return
        }

        let pageBounds = page.bounds(for: .cropBox)
        let width = min(260.0, pageBounds.width * 0.55)
        let height = 64.0
        let origin = CGPoint(
            x: min(max(pending.point.x, pageBounds.minX), pageBounds.maxX - width),
            y: min(max(pending.point.y - height, pageBounds.minY), pageBounds.maxY - height)
        )
        let annotation = PDFAnnotation(
            bounds: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            forType: .freeText,
            withProperties: nil
        )
        PDFAnnotationPrivacy.clearImplicitAuthor(on: annotation)
        annotation.contents = committedText
        annotation.font = NSFont.systemFont(ofSize: 15)
        annotation.fontColor = NSColor.black
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        _ = ensureID(for: annotation)
        EditableAnnotationIdentity.assign(.freeText, to: annotation)
        page.addAnnotation(annotation)
        activeTool = .select
        registerAnnotationAdditions(
            [(page: page, annotation: annotation)],
            message: L10n.string("status.text_added"),
            beforeNavigation: beforeNavigation
        )
    }

    func cancelPendingText() {
        clearPendingTextEdit()
    }

    private func clearPendingTextEdit() {
        pendingTextEdit = nil
        pendingTextAnnotation = nil
    }

    /// Adds the Viewer/Editing highlight using the color shown in the toolbar.
    ///
    /// `studyMarkupStyle` is tab-owned presentation state, so it is a useful
    /// single source of truth for the highlight color in all three modes. The
    /// other Study-only values (kind, thickness and opacity) are deliberately
    /// ignored here: Viewer and Editing keep an interoperable native PDF
    /// Highlight while still respecting the color the person actually chose.
    func highlightCurrentSelection() {
        let selectedColor = studyMarkupStyle.normalized.color
        addMarkupToCurrentSelection(
            kind: .highlight,
            color: selectedColor,
            thickness: nil,
            opacity: 1
        )
    }

    /// Applies the markup meaning advertised by the current mode.
    ///
    /// The global Shift-Command-H command cannot directly know which toolbar
    /// surface is visible. Viewer/Editing keep the interoperable opaque native
    /// Highlight, while Study must honor the palette's selected color, band
    /// thickness and opacity instead of silently creating a different mark.
    func applyCurrentModeHighlight() {
        if allows(.studyTools) {
            applyStudyMarkup(studyMarkupStyle)
        } else {
            highlightCurrentSelection()
        }
    }

    /// Remember each tool's width without carrying a highlighter band into an underline.
    func selectStudyMarkupKind(_ kind: StudyMarkupKind) {
        guard kind != studyMarkupStyle.kind else { return }
        var style = studyMarkupStyle
        studyMarkupThicknessByKind[style.kind] = style.normalized.thickness
        style.kind = kind
        style.thickness = studyMarkupThicknessByKind[kind] ?? kind.defaultThickness
        studyMarkupStyle = style.normalized
    }

    /// 학습 팔레트에서 고른 표식을 현재 텍스트 선택에 적용한다.
    /// Study 표식의 투명도는 appearance-backed Stamp로 보존하고,
    /// 여러 줄도 하나의 실행 취소 기록으로 묶는다.
    func applyStudyMarkup(_ style: StudyMarkupStyle) {
        // The palette can outlive a mode transition for one SwiftUI update.
        // Keep the model boundary authoritative so a stale button or future
        // integration cannot create Study-only appearances in another mode.
        guard allows(.studyTools) else { return }
        let style = style.normalized
        addMarkupToCurrentSelection(
            kind: style.kind,
            color: style.color,
            thickness: style.thickness,
            opacity: style.opacity
        )
    }

    /// Plug-in edits use exactly the same permission and Undo boundary as UI marks.
    func applyPluginMarkup(kind: StudyMarkupKind, color: NSColor, width: CGFloat?, opacity: CGFloat?) throws {
        guard allows(.markup), let document, let selection = currentSelection,
              !selection.pages.isEmpty,
              selection.pages.allSatisfy({ document.index(for: $0) != NSNotFound }) else {
            throw PluginSystemError.actionUnavailable(L10n.string("plugins.command.unavailable"))
        }
        let previousRevision = revision
        addMarkupToCurrentSelection(kind: kind, color: color,
            thickness: kind == .underline ? (width ?? 1.5) : width,
            opacity: opacity ?? (kind == .highlight && width != nil ? 0.42 : 1))
        guard revision != previousRevision else {
            throw PluginSystemError.actionFailed(presentedError ?? L10n.string("plugins.command.unavailable"))
        }
    }

    private func addMarkupToCurrentSelection(
        kind: StudyMarkupKind,
        color: NSColor,
        thickness: CGFloat?,
        opacity: CGFloat
    ) {
        guard let selection = currentSelection else {
            presentedError = L10n.string("error.select_text_first")
            return
        }

        let beforeNavigation = navigationSnapshot
        var additions: [(page: PDFPage, annotation: PDFAnnotation)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let lineBounds = line.bounds(for: page)
                guard !lineBounds.isEmpty else { continue }

                // A marker's thickness sets the authored appearance band's
                // height. Underline keeps the text bounds so its custom `/AP`
                // can place the requested stroke on the baseline. The border
                // retained below is metadata/test aid, not PDFKit's native
                // Underline renderer (which ignores PDFBorder width).
                let annotationBounds: CGRect
                if kind == .highlight, let thickness {
                    let bandHeight = min(lineBounds.height, max(1, thickness))
                    annotationBounds = CGRect(
                        x: lineBounds.minX,
                        y: lineBounds.midY - bandHeight / 2,
                        width: lineBounds.width,
                        height: bandHeight
                    )
                } else {
                    annotationBounds = lineBounds
                }
                let annotation: PDFAnnotation
                if kind == .highlight, thickness == nil, opacity >= 0.999 {
                    // Keep the long-standing Viewer highlight as a native PDF
                    // Highlight annotation. Study marks with adjustable band
                    // thickness/opacity use a custom saved appearance below.
                    annotation = PDFAnnotation(
                        bounds: annotationBounds,
                        forType: .highlight,
                        withProperties: nil
                    )
                    PDFAnnotationPrivacy.clearImplicitAuthor(on: annotation)
                    annotation.color = color.withAlphaComponent(1)
                } else {
                    annotation = StudyMarkupAnnotation(
                        bounds: annotationBounds,
                        style: StudyMarkupStyle(
                            kind: kind,
                            color: color,
                            thickness: thickness ?? StudyMarkupStyle().thickness,
                            opacity: opacity
                        )
                    )
                }
                annotation.modificationDate = Date()
                _ = ensureID(for: annotation)
                page.addAnnotation(annotation)
                additions.append((page: page, annotation: annotation))
            }
        }

        guard !additions.isEmpty else {
            presentedError = kind == .highlight
                ? L10n.string("error.no_highlight_text")
                : L10n.string(
                    "study.error.no_underline_text",
                    defaultValue: "밑줄을 그을 텍스트를 선택해 주세요."
                )
            return
        }
        currentSelection = nil
        markupSelectionClearRequestID = UUID()
        registerAnnotationAdditions(
            additions,
            message: kind == .highlight
                ? L10n.string("status.highlight_added")
                : L10n.string("study.status.underline_added", defaultValue: "밑줄을 추가했습니다."),
            beforeNavigation: beforeNavigation
        )
    }

    @discardableResult
    func addSignature(_ strokes: [SignatureStroke], canvasSize: CGSize) -> Bool {
        // A signature sheet is presented asynchronously. The user can switch
        // to Study mode through the global mode shortcut while that sheet is
        // still alive, so the final model mutation must re-check capability.
        guard allows(.signature) else { return false }
        guard
            let document,
            !strokes.isEmpty,
            let page = document.page(at: min(currentPageIndex, max(0, document.pageCount - 1)))
        else {
            presentedError = strokes.isEmpty
                ? L10n.string("error.draw_signature_first")
                : WorkspaceError.noDocument.localizedDescription
            return false
        }
        let beforeNavigation = navigationSnapshot

        let allPoints = strokes.flatMap(\.points)
        guard
            let minX = allPoints.map(\.x).min(),
            let maxX = allPoints.map(\.x).max(),
            let minY = allPoints.map(\.y).min(),
            let maxY = allPoints.map(\.y).max(),
            maxX > minX,
            maxY > minY
        else {
            presentedError = L10n.string("error.signature_too_short")
            return false
        }

        _ = canvasSize
        let pageBounds = page.bounds(for: .cropBox)
        let targetWidth = min(pageBounds.width * 0.38, 250)
        let sourceAspect = (maxX - minX) / max(1, maxY - minY)
        let targetHeight = min(targetWidth / max(sourceAspect, 0.5), 110)
        let targetRect = CGRect(
            x: pageBounds.midX - targetWidth / 2,
            y: pageBounds.midY - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )
        let signatureID = "HwattakPDF-Signature-\(UUID().uuidString)"
        let localBounds = CGRect(origin: .zero, size: targetRect.size)
        let renderingScale: CGFloat = 3

        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: max(1, Int(ceil(targetRect.width * renderingScale))),
                pixelsHigh: max(1, Int(ceil(targetRect.height * renderingScale))),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            presentedError = L10n.string("error.signature_image")
            return false
        }

        func map(_ point: SignaturePoint) -> CGPoint {
            CGPoint(
                x: 3 + ((point.x - minX) / (maxX - minX)) * max(1, localBounds.width - 6),
                y: 3 + ((point.y - minY) / (maxY - minY)) * max(1, localBounds.height - 6)
            )
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(
            CGRect(
                x: 0,
                y: 0,
                width: targetRect.width * renderingScale,
                height: targetRect.height * renderingScale
            )
        )
        graphics.cgContext.scaleBy(x: renderingScale, y: renderingScale)
        graphics.shouldAntialias = true
        signatureSettings.color.setStroke()

        var segmentCount = 0
        for stroke in strokes where stroke.points.count > 1 {
            for pairIndex in 1..<stroke.points.count {
                let previous = stroke.points[pairIndex - 1]
                let current = stroke.points[pairIndex]
                let p0 = map(previous)
                let p1 = map(current)
                guard hypot(p1.x - p0.x, p1.y - p0.y) > 0.2 else { continue }

                let pressure = max(0, min(1, (previous.pressure + current.pressure) / 2))
                let response = pow(pressure, signatureSettings.pressureSensitivity)
                let width = signatureSettings.minimumWidth
                    + (signatureSettings.maximumWidth - signatureSettings.minimumWidth) * response
                let path = NSBezierPath()
                path.move(to: p0)
                path.line(to: p1)
                path.lineWidth = width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
                segmentCount += 1
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard segmentCount > 0 else {
            presentedError = L10n.string("error.signature_placement")
            return false
        }

        bitmap.size = targetRect.size
        let signatureImage = NSImage(size: targetRect.size)
        signatureImage.addRepresentation(bitmap)
        let annotation = ImageStampAnnotation(image: signatureImage, bounds: targetRect)
        annotation.setValue(signatureID, forAnnotationKey: .name)
        EditableAnnotationIdentity.assign(.signature, to: annotation)
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        page.addAnnotation(annotation)
        activeTool = .select
        registerAnnotationAdditions(
            [(page: page, annotation: annotation)],
            message: L10n.string("status.signature_added"),
            beforeNavigation: beforeNavigation
        )
        return true
    }

    func insertImage(url: URL) {
        // The open panel/drop target already follows the toolbar policy, but a
        // stale callback or direct model caller must not bypass the mode. This
        // early guard also avoids reading a security-scoped file when the
        // operation is no longer authorized.
        guard allows(.imageInsertion) else { return }
        guard
            let document,
            let page = document.page(at: min(currentPageIndex, max(0, document.pageCount - 1)))
        else {
            presentedError = WorkspaceError.noDocument.localizedDescription
            return
        }
        let beforeNavigation = navigationSnapshot
        let access = SecurityScopedAccess(url: url)
        let image: NSImage
        do {
            image = try BoundedImageLoader().load(at: url)
        } catch {
            _ = access
            presentedError = error.localizedDescription
            return
        }

        let pageBounds = page.bounds(for: .cropBox)
        let maximum = CGSize(width: pageBounds.width * 0.44, height: pageBounds.height * 0.34)
        let scale = min(maximum.width / image.size.width, maximum.height / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let bounds = CGRect(
            x: pageBounds.midX - size.width / 2,
            y: pageBounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let annotation = ImageStampAnnotation(image: image, bounds: bounds)
        _ = ImageAnnotationIdentity.assign(to: annotation)
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        // Image decoding can invoke framework work before returning. Recheck
        // immediately beside the PDF mutation, matching the signature path's
        // final authority boundary.
        guard allows(.imageInsertion) else {
            _ = access
            return
        }
        page.addAnnotation(annotation)
        _ = access
        activeTool = .select
        registerAnnotationAdditions(
            [(page: page, annotation: annotation)],
            message: L10n.string("status.image_added"),
            beforeNavigation: beforeNavigation
        )
    }

    /// Reverses the latest edit belonging to this document. Navigation and
    /// dirty state are restored from the same command, so each tab has an
    /// independent 22-step history and its own saved checkpoint.
    func undo() {
        do {
            guard let command = try editHistory.undo() else { return }
            restoreNavigation(command.beforeNavigation)
            finishHistoryTraversal(command: command, isUndo: true)
        } catch {
            presentedError = error.localizedDescription
            synchronizeHistoryPresentation()
        }
    }

    func redo() {
        do {
            guard let command = try editHistory.redo() else { return }
            restoreNavigation(command.afterNavigation)
            finishHistoryTraversal(command: command, isUndo: false)
        } catch {
            presentedError = error.localizedDescription
            synchronizeHistoryPresentation()
        }
    }

    /// Registers an annotation that has just been added by an AppKit gesture
    /// such as pen drawing. The annotation itself is the delta; no page or PDF
    /// snapshot is retained.
    func registerAddedAnnotation(
        _ annotation: PDFAnnotation,
        on page: PDFPage,
        message: String
    ) {
        let before = navigationSnapshot
        registerAnnotationAdditions(
            [(page: page, annotation: annotation)],
            message: message,
            beforeNavigation: before
        )
    }

    /// Registers an annotation that has just been removed by the eraser or
    /// editing overlay.
    func registerRemovedAnnotation(
        _ annotation: PDFAnnotation,
        from page: PDFPage,
        originalIndex: Int,
        message: String
    ) {
        let finalOrder = page.annotations
        var originalOrder = finalOrder
        originalOrder.insert(
            annotation,
            at: min(max(0, originalIndex), originalOrder.count)
        )
        registerAnnotationOrderChange(
            on: page,
            from: originalOrder,
            to: finalOrder,
            message: message
        )
    }

    /// Captures one completed move/resize/crop gesture. Callers pass the
    /// geometry from mouse-down; final geometry is sampled here at mouse-up.
    func registerAnnotationGeometryChange(
        _ annotation: PDFAnnotation,
        on page: PDFPage,
        from originalBounds: CGRect,
        originalCropRect: CGRect? = nil,
        originalModificationDate: Date?,
        message: String
    ) {
        guard
            let document,
            document.index(for: page) != NSNotFound,
            page.annotations.contains(where: { $0 === annotation })
        else { return }

        // The overlay checks this policy before it starts a gesture, but this
        // model API is also callable by tests, plug-ins, and future UI paths.
        // Recheck the concrete object here so a stale/direct caller cannot move
        // a persisted annotation in Viewer/Study and then turn that forged
        // mutation into runtime trust. Editing deliberately remains the broad
        // adoption surface: its concrete policy accepts a recognized persisted
        // object, and only a real change below grants current-session trust.
        guard
            let kind = EditableAnnotationIdentity.kind(of: annotation),
            allowsAnnotationEditing(kind, annotation: annotation)
        else {
            annotation.bounds = originalBounds
            if let originalCropRect, let image = annotation as? ImageStampAnnotation {
                image.updateCropRect(originalCropRect)
            }
            annotation.modificationDate = originalModificationDate
            return
        }
        let finalBounds = annotation.bounds
        let finalModificationDate = annotation.modificationDate
        let finalCropRect = originalCropRect.flatMap { _ in
            (annotation as? ImageStampAnnotation)?.normalizedCropRect
        }
        guard
            !Self.approximatelyEqual(originalBounds, finalBounds)
                || !Self.approximatelyEqual(originalCropRect, finalCropRect)
        else {
            annotation.bounds = originalBounds
            if let originalCropRect, let image = annotation as? ImageStampAnnotation {
                image.updateCropRect(originalCropRect)
            }
            annotation.modificationDate = originalModificationDate
            return
        }
        // A real, validated geometry change in Editing mode is an explicit
        // adoption action. This lets the same concrete signature/FreeText be
        // adjusted in Viewer after returning there, without ever trusting the
        // marker string that was read from disk. A no-op click returns above
        // and deliberately does not grant provenance.
        trustRuntimeAnnotation(annotation)
        let before = navigationSnapshot
        recordEdit(
            actionName: message,
            beforeNavigation: before,
            undo: {
                guard
                    document.index(for: page) != NSNotFound,
                    page.annotations.contains(where: { $0 === annotation })
                else {
                    throw WorkspaceError.operationFailed(
                        L10n.string(
                            "error.undo_annotation_state",
                            defaultValue: "The annotation is no longer in the expected state."
                        )
                    )
                }
                annotation.bounds = originalBounds
                if let originalCropRect, let image = annotation as? ImageStampAnnotation {
                    image.updateCropRect(originalCropRect)
                }
                annotation.modificationDate = originalModificationDate
            },
            redo: {
                guard
                    document.index(for: page) != NSNotFound,
                    page.annotations.contains(where: { $0 === annotation })
                else {
                    throw WorkspaceError.operationFailed(
                        L10n.string(
                            "error.undo_annotation_state",
                            defaultValue: "The annotation is no longer in the expected state."
                        )
                    )
                }
                annotation.bounds = finalBounds
                if let finalCropRect, let image = annotation as? ImageStampAnnotation {
                    image.updateCropRect(finalCropRect)
                }
                annotation.modificationDate = finalModificationDate
            }
        )
    }

    /// Restores the exact absolute PDF annotation order, including
    /// interleaving between images, signatures, highlights and widgets.
    func registerAnnotationOrderChange(
        on page: PDFPage,
        from originalOrder: [PDFAnnotation],
        to finalOrder: [PDFAnnotation],
        message: String
    ) {
        let owningDocument = document
        if let owningDocument, owningDocument.index(for: page) == NSNotFound {
            return
        }
        guard !zip(originalOrder, finalOrder).allSatisfy({ $0 === $1 })
                || originalOrder.count != finalOrder.count
        else { return }
        let before = navigationSnapshot
        let matches: ([PDFAnnotation], [PDFAnnotation]) -> Bool = { lhs, rhs in
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 === $1 }
        }
        let restore: ([PDFAnnotation], [PDFAnnotation]) throws -> Void = { expected, order in
            guard
                owningDocument.map({ $0.index(for: page) != NSNotFound }) ?? true,
                matches(page.annotations, expected)
            else {
                throw WorkspaceError.operationFailed(
                    L10n.string(
                        "error.undo_annotation_state",
                        defaultValue: "The annotation is no longer in the expected state."
                    )
                )
            }
            page.annotations.forEach(page.removeAnnotation)
            order.forEach(page.addAnnotation)
        }
        recordEdit(
            actionName: message,
            beforeNavigation: before,
            undo: { try restore(finalOrder, originalOrder) },
            redo: { try restore(originalOrder, finalOrder) }
        )
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 0.01
        return abs(lhs.minX - rhs.minX) < tolerance
            && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance
            && abs(lhs.height - rhs.height) < tolerance
    }

    private static func approximatelyEqual(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): approximatelyEqual(lhs, rhs)
        default: false
        }
    }

    func annotationChanged(message: String? = nil) {
        markChanged(message ?? L10n.string("status.annotation_changed"))
    }

    /// PDFKit mutates AcroForm widgets internally, bypassing the app's normal
    /// annotation commands. Compare semantic values after user events so form
    /// edits participate in dirty state and invalidate OCR checkpoints.
    func synchronizeWidgetValues(on page: PDFPage? = nil) {
        guard let document else { return }
        if let page {
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return }
            guard widgetSnapshotPrimedPages.contains(pageIndex) else {
                // Visible pages are primed before PDFKit receives mouse, Tab,
                // or accessibility input. Reaching synchronization first in a
                // user-password session therefore means an untrusted/direct
                // path may already have changed a widget without a baseline.
                // Never adopt that possibly modified value as the original;
                // discard the graph and reopen the exact source instead.
                if
                    document.isEncrypted,
                    !document.isLocked,
                    document.permissionsStatus != .owner
                {
                    recoverReadOnlyDocumentAfterUnprimedWidgetMutation()
                    return
                }
                primeWidgetValues(on: page)
                return
            }
        }
        let beforeNavigation = navigationSnapshot
        let current = currentWidgetValueSnapshot(on: page)
        let currentUndoValues = currentWidgetUndoValueSnapshot(on: page)
        let previous: [String: String]
        let previousUndoValues: [String: PDFWidgetUndoValue]
        if let page {
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return }
            let prefix = "\(pageIndex)|"
            previous = widgetValueSnapshot.filter { $0.key.hasPrefix(prefix) }
            guard current != previous else { return }
            previousUndoValues = widgetUndoValueSnapshot.filter { $0.key.hasPrefix(prefix) }
            widgetValueSnapshot = widgetValueSnapshot.filter { !$0.key.hasPrefix(prefix) }
            widgetValueSnapshot.merge(current) { _, replacement in replacement }
            widgetUndoValueSnapshot = widgetUndoValueSnapshot.filter { !$0.key.hasPrefix(prefix) }
            widgetUndoValueSnapshot.merge(currentUndoValues) { _, replacement in replacement }
        } else {
            previous = widgetValueSnapshot
            guard current != previous else { return }
            previousUndoValues = widgetUndoValueSnapshot
            widgetValueSnapshot = current
            widgetUndoValueSnapshot = currentUndoValues
        }

        // A user-password encrypted session cannot be saved without either
        // stripping or replacing the unknown security dictionary. The viewer
        // blocks native widget input through `allowsNativeFormEditing`; repeat
        // the boundary here so a stale event or future integration cannot leave
        // an unsavable dirty form behind. Restore the exact primed annotation
        // values rather than registering a mutation that can never persist.
        guard allowsNativeFormEditing else {
            previousUndoValues.values.forEach { $0.apply() }
            if let page {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound {
                    let prefix = "\(pageIndex)|"
                    widgetValueSnapshot = widgetValueSnapshot.filter {
                        !$0.key.hasPrefix(prefix)
                    }
                    widgetValueSnapshot.merge(previous) { _, replacement in replacement }
                    widgetUndoValueSnapshot = widgetUndoValueSnapshot.filter {
                        !$0.key.hasPrefix(prefix)
                    }
                    widgetUndoValueSnapshot.merge(previousUndoValues) {
                        _, replacement in replacement
                    }
                }
            } else {
                widgetValueSnapshot = previous
                widgetUndoValueSnapshot = previousUndoValues
            }
            presentedError = L10n.string(
                "security.user_session_read_only",
                defaultValue: "사용자 암호로 연 PDF는 보안을 유지해 저장할 수 없어 읽기 전용으로 열립니다. 편집하려면 소유자 암호로 다시 여세요."
            )
            return
        }

        let changedKeys = Set(previous.keys).union(current.keys).filter {
            previous[$0] != current[$0]
        }.sorted()
        let beforeValues = changedKeys.compactMap { previousUndoValues[$0] }
        let afterValues = changedKeys.compactMap { currentUndoValues[$0] }
        guard
            !changedKeys.isEmpty,
            beforeValues.count == changedKeys.count,
            afterValues.count == changedKeys.count
        else {
            // Widget structure changed outside the app. Preserve correctness
            // by creating an explicit non-reversible barrier.
            markChanged(L10n.string("status.form_changed"))
            return
        }
        recordEdit(
            actionName: L10n.string("status.form_changed"),
            beforeNavigation: beforeNavigation,
            undo: { beforeValues.forEach { $0.apply() } },
            redo: { afterValues.forEach { $0.apply() } }
        )
    }

    /// Captures a single page's initial AcroForm state before interaction.
    /// This avoids an O(all pages + all annotations) scan on open/resume.
    func primeWidgetValues(on page: PDFPage) {
        guard let document else { return }
        let pageIndex = document.index(for: page)
        guard
            pageIndex != NSNotFound,
            !widgetSnapshotPrimedPages.contains(pageIndex)
        else { return }
        widgetValueSnapshot.merge(currentWidgetValueSnapshot(on: page)) {
            _, replacement in replacement
        }
        widgetUndoValueSnapshot.merge(currentWidgetUndoValueSnapshot(on: page)) {
            _, replacement in replacement
        }
        widgetSnapshotPrimedPages.insert(pageIndex)
    }

    /// Form edits are index-keyed, so settle them while the old page graph is
    /// still intact before any insert/delete/move changes those indexes.
    private func prepareForPageStructureMutation() {
        // A toolbar/menu click is not guaranteed to resign PDFKit's shared
        // NSTextView before its model action runs. End every registered native
        // field editor while page indexes still identify the original pages,
        // then compare the committed values exactly once.
        commitRegisteredViewEditors()
        commitPendingInlineTextDraftIfNeeded()
        synchronizeWidgetValues()
    }

    /// A structural page edit invalidates every index-based widget key. Prime
    /// only the newly current page, preserving the lazy O(visible pages) model.
    private func resetWidgetSnapshotsAfterPageStructureMutation() {
        widgetValueSnapshot = [:]
        widgetUndoValueSnapshot = [:]
        widgetSnapshotPrimedPages = []
        if let page = document?.page(at: currentPageIndex) {
            primeWidgetValues(on: page)
        }
    }

    /// No trusted value snapshot exists for an unprimed page. A read-only
    /// encrypted session cannot retain the potentially modified PDF graph, so
    /// reload the same on-disk version (prompting again because passwords are
    /// deliberately not retained). If recovery is cancelled or fails, release
    /// the graph and leave the tab hibernated rather than displaying or
    /// exporting an unverified in-memory mutation.
    private func recoverReadOnlyDocumentAfterUnprimedWidgetMutation() {
        guard let currentDocument = document else { return }
        let retainedPageCount = currentDocument.pageCount
        let expectedVersion = sourceFileVersion
        let message = L10n.string(
            "security.user_session_read_only",
            defaultValue: "사용자 암호로 연 PDF는 보안을 유지해 저장할 수 없어 읽기 전용으로 열립니다. 편집하려면 소유자 암호로 다시 여세요."
        )

        func clearUntrustedGraph() {
            document = nil
            hibernatedPageCount = retainedPageCount
            widgetValueSnapshot = [:]
            widgetUndoValueSnapshot = [:]
            widgetSnapshotPrimedPages = []
            runtimeTrustedAnnotations.removeAll(keepingCapacity: false)
            invalidateDocumentSelections()
            editHistory.reset()
            synchronizeHistoryPresentation()
            revision = UUID()
        }

        guard let documentURL else {
            clearUntrustedGraph()
            presentedError = message
            return
        }

        do {
            guard
                let recovered = try loadUnlockedDocument(at: documentURL),
                recovered.version == expectedVersion
            else {
                clearUntrustedGraph()
                presentedError = message
                return
            }
            document = recovered.document
            sourceFileVersion = recovered.version
            hibernatedPageCount = nil
            widgetValueSnapshot = [:]
            widgetUndoValueSnapshot = [:]
            widgetSnapshotPrimedPages = []
            runtimeTrustedAnnotations.removeAll(keepingCapacity: false)
            invalidateDocumentSelections()
            editHistory.reset()
            synchronizeHistoryPresentation()
            if let page = recovered.document.page(at: currentPageIndex) {
                primeWidgetValues(on: page)
            }
            revision = UUID()
        } catch {
            clearUntrustedGraph()
        }
        presentedError = message
    }

    func performSearch() {
        let engine = PDFSearchEngine(configuration: searchEngineConfiguration)
        let query = engine.prepare(query: searchText)
        cancelSearchAndInvalidate(clearResults: true)

        guard !query.isEmpty else {
            resetSearchPresentation()
            statusMessage = L10n.string("status.search_enter_query")
            return
        }

        guard let document else { return }
        let generation = UUID()
        searchGeneration = generation
        let startingRevision = revision
        activeSearchQuery = query.source
        searchCompletedQuery = nil
        isSearching = true
        searchProgress = PDFSearchProgress(
            phase: .searching,
            completedPages: 0,
            totalPages: document.pageCount,
            resultCount: 0,
            isTruncated: false
        )
        statusMessage = L10n.string(
            "search.navigator.searching",
            defaultValue: "문서 검색 중"
        )

        searchTask = Task { @MainActor [weak self, weak document] in
            guard let self, let document else { return }
            var pendingResults: [PDFSearchResult] = []
            var pendingTextlessPages = 0
            var pagesSincePublication = 0
            var scannedPages = 0
            var truncated = false

            for pageIndex in 0..<document.pageCount {
                guard
                    !Task.isCancelled,
                    self.searchIsCurrent(
                        generation: generation,
                        document: document,
                        startingRevision: startingRevision,
                        query: query.source
                    )
                else { return }

                let remaining = max(
                    0,
                    engine.configuration.maximumResultCount
                        - self.searchNavigatorResults.count
                        - pendingResults.count
                )
                guard remaining > 0 else {
                    truncated = true
                    break
                }

                let outcome: PDFSearchEngine.PageOutcome
                do {
                    outcome = try await engine.searchPage(
                        in: document,
                        pageIndex: pageIndex,
                        query: query,
                        remainingResultCapacity: remaining
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard self.searchIsCurrent(
                        generation: generation,
                        document: document,
                        startingRevision: startingRevision,
                        query: query.source
                    ) else { return }
                    self.cancelSearch()
                    return
                }
                pendingResults.append(contentsOf: outcome.results)
                pendingTextlessPages += outcome.hasExtractableText ? 0 : 1
                truncated = truncated || outcome.reachedPageLimit
                scannedPages = pageIndex + 1
                pagesSincePublication += 1

                let shouldPublish = pagesSincePublication
                        >= engine.configuration.publicationPageBatch
                    || pendingResults.count >= engine.configuration.publicationResultBatch
                    || scannedPages == document.pageCount
                if shouldPublish {
                    self.commitSearchBatch(
                        pendingResults,
                        completedPages: scannedPages,
                        additionalTextlessPages: pendingTextlessPages,
                        isTruncated: truncated,
                        generation: generation,
                        document: document,
                        startingRevision: startingRevision,
                        query: query.source
                    )
                    pendingResults.removeAll(keepingCapacity: true)
                    pendingTextlessPages = 0
                    pagesSincePublication = 0
                }

                if self.searchNavigatorResults.count + pendingResults.count
                    >= engine.configuration.maximumResultCount
                {
                    truncated = truncated
                        || outcome.reachedPageLimit
                        || scannedPages < document.pageCount
                    break
                }

                // Pure normalization/matching already ran off the main actor.
                // This extra yield gives navigation and tab lifecycle work a
                // scheduling point between PDFKit page snapshots.
                await Task.yield()
            }

            guard
                !Task.isCancelled,
                self.searchIsCurrent(
                    generation: generation,
                    document: document,
                    startingRevision: startingRevision,
                    query: query.source
                )
            else { return }

            if !pendingResults.isEmpty || pendingTextlessPages > 0 {
                self.commitSearchBatch(
                    pendingResults,
                    completedPages: scannedPages,
                    additionalTextlessPages: pendingTextlessPages,
                    isTruncated: truncated,
                    generation: generation,
                    document: document,
                    startingRevision: startingRevision,
                    query: query.source
                )
            }
            self.finishSearch(
                generation: generation,
                document: document,
                startingRevision: startingRevision,
                query: query.source,
                completedPages: scannedPages,
                truncated: truncated
            )
        }
    }

    func showNextSearchResult(backwards: Bool = false) {
        guard !searchNavigatorResults.isEmpty else {
            performSearch()
            return
        }
        if backwards {
            searchResultIndex = (
                searchResultIndex - 1 + searchNavigatorResults.count
            ) % searchNavigatorResults.count
        } else {
            searchResultIndex = (searchResultIndex + 1) % searchNavigatorResults.count
        }
        activateSearchResult(at: searchResultIndex)
        statusMessage = L10n.format(
            "status.search_position",
            searchResultIndex + 1,
            searchNavigatorResults.count
        )
    }

    func selectSearchResult(id: PDFSearchResult.ID) {
        guard let index = searchNavigatorResults.firstIndex(where: { $0.id == id }) else {
            return
        }
        selectSearchResult(at: index)
    }

    func selectSearchResult(at index: Int) {
        guard searchNavigatorResults.indices.contains(index) else { return }
        searchResultIndex = index
        activateSearchResult(at: index)
        statusMessage = L10n.format(
            "status.search_position",
            index + 1,
            searchNavigatorResults.count
        )
    }

    /// Stops page scanning without converting a read-only operation into a
    /// document edit. Partial results remain available until the query changes
    /// or the user explicitly clears them.
    func cancelSearch() {
        guard isSearching || searchTask != nil else { return }
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        activeSearchQuery = nil
        searchProgress.phase = .cancelled
        searchProgress.resultCount = searchNavigatorResults.count
        // A cancelled partial scan cannot establish that the whole document
        // lacks a searchable text layer.
        searchRequiresOCR = false
    }

    func clearSearch() {
        cancelSearchAndInvalidate(clearResults: true)
        if !searchText.isEmpty {
            searchText = ""
        }
        resetSearchPresentation()
    }

    private func searchQueryDidChange() {
        cancelSearchAndInvalidate(clearResults: true)
        resetSearchPresentation()
    }

    private func cancelSearchAndInvalidate(clearResults: Bool) {
        searchGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        activeSearchQuery = nil
        if clearResults {
            resetSearchPresentation()
        }
    }

    private func resetSearchPresentation() {
        searchResults = []
        searchNavigatorResults = []
        searchResultIndex = 0
        clearActiveSearchSelection()
        isSearching = false
        searchProgress = .idle
        searchRequiresOCR = false
        searchUnsearchablePageCount = 0
        searchResultsWereTruncated = false
        activeSearchQuery = nil
        searchCompletedQuery = nil
    }

    private func searchIsCurrent(
        generation: UUID,
        document expectedDocument: PDFDocument,
        startingRevision: UUID,
        query: String
    ) -> Bool {
        searchGeneration == generation
            && document === expectedDocument
            && revision == startingRevision
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }

    private func commitSearchBatch(
        _ newResults: [PDFSearchResult],
        completedPages: Int,
        additionalTextlessPages: Int,
        isTruncated: Bool,
        generation: UUID,
        document expectedDocument: PDFDocument,
        startingRevision: UUID,
        query: String
    ) {
        guard searchIsCurrent(
            generation: generation,
            document: expectedDocument,
            startingRevision: startingRevision,
            query: query
        ) else { return }

        let hadNoResults = searchNavigatorResults.isEmpty
        if !newResults.isEmpty {
            searchNavigatorResults.append(contentsOf: newResults)
        }
        searchUnsearchablePageCount += additionalTextlessPages
        searchResultsWereTruncated = searchResultsWereTruncated || isTruncated
        searchProgress.completedPages = completedPages
        searchProgress.resultCount = searchNavigatorResults.count
        searchProgress.isTruncated = searchResultsWereTruncated

        if hadNoResults, !searchNavigatorResults.isEmpty {
            searchResultIndex = 0
            activateSearchResult(at: 0)
        }
    }

    private func finishSearch(
        generation: UUID,
        document expectedDocument: PDFDocument,
        startingRevision: UUID,
        query: String,
        completedPages: Int,
        truncated: Bool
    ) {
        guard searchIsCurrent(
            generation: generation,
            document: expectedDocument,
            startingRevision: startingRevision,
            query: query
        ) else { return }

        searchTask = nil
        isSearching = false
        activeSearchQuery = nil
        searchCompletedQuery = query
        searchResultsWereTruncated = searchResultsWereTruncated || truncated
        searchProgress = PDFSearchProgress(
            phase: .completed,
            completedPages: completedPages,
            totalPages: expectedDocument.pageCount,
            resultCount: searchNavigatorResults.count,
            isTruncated: searchResultsWereTruncated
        )
        searchRequiresOCR = searchNavigatorResults.isEmpty
            && expectedDocument.pageCount > 0
            && completedPages == expectedDocument.pageCount
            && searchUnsearchablePageCount == expectedDocument.pageCount
        statusMessage = searchNavigatorResults.isEmpty
            ? L10n.string("status.search_no_results")
            : L10n.format("status.search_results", searchNavigatorResults.count)
    }

    private func activateSearchResult(at index: Int) {
        guard searchNavigatorResults.indices.contains(index) else { return }
        let result = searchNavigatorResults[index]
        setCurrentPage(result.pageIndex)
        guard
            let page = document?.page(at: result.pageIndex),
            result.sourceRange.location >= 0,
            result.sourceRange.length > 0,
            result.sourceRange.location <= page.numberOfCharacters,
            result.sourceRange.length
                <= page.numberOfCharacters - result.sourceRange.location,
            let selection = page.selection(for: result.sourceRange)
        else {
            clearActiveSearchSelection()
            searchResults = []
            return
        }
        // Keep only the active PDFSelection. The navigator can retain tens of
        // thousands of lightweight ranges/snippets without pinning an equally
        // large PDFKit selection graph in memory.
        activeSearchSelection = selection
        currentSelection = selection
        searchResults = [selection]
    }

    /// Search owns `currentSelection` only while it still points at the exact
    /// PDFKit selection installed for the active result. A later click in the
    /// document produces a different selection object and must survive query
    /// changes, cancellation, or an invalidated result.
    private func clearActiveSearchSelection() {
        let selectionOwnedBySearch = activeSearchSelection
        activeSearchSelection = nil
        if
            let selectionOwnedBySearch,
            currentSelection === selectionOwnedBySearch
        {
            currentSelection = nil
        }
    }

    func clearError() {
        presentedError = nil
    }

    func cancelOCR() {
        guard ocrTask != nil else { return }
        ocrState = .cancelling
        ocrTask?.cancel()
        statusMessage = L10n.string("status.ocr_cancelling")
    }

    func startOCR(configuration: OCRConfiguration) {
        guard let document else {
            presentedError = WorkspaceError.noDocument.localizedDescription
            return
        }
        guard allows(.ocr) else {
            if document.isEncrypted {
                presentedError = L10n.string("security.owner_required")
            }
            return
        }
        guard ocrTask == nil else { return }
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-OCR-\(UUID().uuidString).pdf")
        do {
            try PDFOCRSnapshotWriter.write(document, to: snapshotURL)
        } catch {
            presentedError = error.localizedDescription
            return
        }

        ocrState = .running(completed: 0, total: document.pageCount, page: 1)
        statusMessage = L10n.string("status.ocr_started")
        let runID = UUID()
        // Only a clean document with a known source baseline may reuse a
        // source-content fingerprint. Dirty documents deliberately skip this
        // path so VisionOCRService hashes the exact serialized edit snapshot.
        let expectedSourceVersion = reusableOCRSourceVersion
        let sourceURL = documentURL
        let ocrRecognizer = self.ocrRecognizer
        ocrRunID = runID
        ocrTask = Task { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: snapshotURL)
                // A recovery timer can expire while OCR owns the snapshot.
                // Rearm after every terminal result, but never let an old run
                // clear or schedule work for a replacement document/run.
                if let self, self.ocrRunID == runID {
                    self.ocrRunID = nil
                    self.ocrTask = nil
                    if self.isDirty { self.scheduleRecoverySnapshot() }
                }
            }
            do {
                let stableFingerprint: String?
                if let expectedSourceVersion, let sourceURL {
                    // Hashing 50–200 MB is file I/O and must not block PDFKit's
                    // main actor. The resolver accepts the content hash only if
                    // the source metadata matches this workspace's baseline
                    // both before and after the streaming read. The helper also
                    // forwards cancellation into its detached worker, so a
                    // 200 MB hash does not keep reading after the user cancels.
                    stableFingerprint = try await OCRSourceFingerprintResolver.resolveInBackground(
                        sourceURL: sourceURL,
                        expectedVersion: expectedSourceVersion
                    )
                } else {
                    stableFingerprint = nil
                }

                let checkpoint = try await ocrRecognizer(
                    snapshotURL,
                    stableFingerprint,
                    configuration
                ) { progress in
                    Task { @MainActor [weak self] in
                        guard
                            self?.ocrRunID == runID,
                            self?.ocrState != .cancelling
                        else { return }
                        self?.ocrState = .running(
                            completed: progress.completed,
                            total: progress.total,
                            page: progress.currentPage
                        )
                    }
                }
                // Cancellation can arrive after the recognizer has produced a
                // successful value but before this task commits it. Throwing
                // here routes that narrow race through the cleanup catch below;
                // a plain `return` would leave `.cancelling` and `ocrTask`
                // permanently stuck.
                try Task.checkCancellation()
                guard self?.ocrRunID == runID else { return }
                let recognized = checkpoint.pages.values.filter { !$0.skippedBecauseTextExists }.count
                let skipped = checkpoint.pages.values.filter(\.skippedBecauseTextExists).count
                self?.ocrCheckpoint = checkpoint
                self?.ocrState = .finished(recognizedPages: recognized, skippedPages: skipped)
                self?.statusMessage = L10n.string("status.ocr_finished")
            } catch is CancellationError {
                guard self?.ocrRunID == runID else { return }
                self?.ocrState = .idle
                self?.statusMessage = L10n.string("status.ocr_cancelled")
            } catch {
                guard self?.ocrRunID == runID else { return }
                self?.ocrState = .failed(error.localizedDescription)
                self?.presentedError = error.localizedDescription
            }
        }
    }

    func exportSearchableOCRCopy(to url: URL) {
        guard document != nil, ocrCheckpoint != nil else {
            presentedError = L10n.string("error.ocr_required")
            return
        }
        // The visible PDF may still own a native field editor or an inline text
        // overlay. Materializing either is a document mutation that invalidates
        // the checkpoint, so prepare first and then reacquire both values.
        prepareForDeactivation()
        guard pendingInlineTextEdit == nil else {
            presentedError = L10n.string("error.finish_inline_text_before_export")
            return
        }
        guard let document, let ocrCheckpoint else {
            presentedError = L10n.string("error.ocr_required")
            return
        }
        do {
            let sourceURL = documentURL
            if
                let sourceURL,
                PDFSourceFileVersion.refersToSameLocation(sourceURL, url)
            {
                throw WorkspaceError.operationFailed(
                    L10n.string("error.save_copy_same_as_original")
                )
            }
            try SearchablePDFExporter.export(
                document: document,
                checkpoint: ocrCheckpoint,
                to: url,
                sourceURL: sourceURL
            )
            statusMessage = L10n.format("status.ocr_exported", url.lastPathComponent)
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func refreshLocalization() {
        // Localization refresh rotates `revision`; stop the captured search
        // generation first so it cannot exit as stale while leaving its
        // progress presentation stuck in the running state.
        cancelSearchAndInvalidate(clearResults: true)
        if hasOpenDocument {
            refresh(L10n.format("status.opened_pages", pageCount))
        } else {
            refresh(L10n.string("status.ready"))
        }
    }

    private func normalizedRotation(_ value: Int) -> Int {
        let remainder = value % 360
        return remainder >= 0 ? remainder : remainder + 360
    }

    @discardableResult
    private func ensureID(for annotation: PDFAnnotation) -> String {
        if let existing = id(of: annotation) {
            return existing
        }
        let newID = "HwattakPDF-Annotation-\(UUID().uuidString)"
        annotation.setValue(newID, forAnnotationKey: .name)
        return newID
    }

    private func id(of annotation: PDFAnnotation) -> String? {
        annotation.value(forAnnotationKey: .name) as? String
    }

    private func currentWidgetValueSnapshot(on selectedPage: PDFPage? = nil) -> [String: String] {
        guard let document else { return [:] }
        var snapshot: [String: String] = [:]
        let pageIndexes: [Int]
        if let selectedPage {
            let selectedIndex = document.index(for: selectedPage)
            guard selectedIndex != NSNotFound else { return [:] }
            pageIndexes = [selectedIndex]
        } else {
            // Only pages presented to the user have a baseline and can have
            // received form interaction. Scanning them keeps hibernation and
            // save work proportional to viewed pages, not total page count.
            pageIndexes = widgetSnapshotPrimedPages.sorted()
        }

        for pageIndex in pageIndexes {
            guard let page = document.page(at: pageIndex) else { continue }
            var widgetOrdinal = 0
            for annotation in page.annotations {
                let type = annotation.type?.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
                guard type == "Widget" else { continue }

                let key = widgetSnapshotKey(
                    pageIndex: pageIndex,
                    ordinal: widgetOrdinal,
                    annotation: annotation
                )
                let value = [
                    annotation.widgetStringValue.map { "value:\($0)" } ?? "nil",
                    String(describing: annotation.buttonWidgetState),
                ].joined(separator: "|")
                snapshot[key] = value
                widgetOrdinal += 1
            }
        }
        return snapshot
    }

    private func currentWidgetUndoValueSnapshot(
        on selectedPage: PDFPage? = nil
    ) -> [String: PDFWidgetUndoValue] {
        guard let document else { return [:] }
        let pageIndexes: [Int]
        if let selectedPage {
            let selectedIndex = document.index(for: selectedPage)
            guard selectedIndex != NSNotFound else { return [:] }
            pageIndexes = [selectedIndex]
        } else {
            pageIndexes = widgetSnapshotPrimedPages.sorted()
        }

        var snapshot: [String: PDFWidgetUndoValue] = [:]
        for pageIndex in pageIndexes {
            guard let page = document.page(at: pageIndex) else { continue }
            var widgetOrdinal = 0
            for annotation in page.annotations {
                let type = annotation.type?.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
                guard type == "Widget" else { continue }
                let key = widgetSnapshotKey(
                    pageIndex: pageIndex,
                    ordinal: widgetOrdinal,
                    annotation: annotation
                )
                let stringValue = annotation.widgetStringValue
                let buttonState = annotation.buttonWidgetState
                let modificationDate = annotation.modificationDate
                snapshot[key] = PDFWidgetUndoValue(
                    apply: {
                        annotation.widgetStringValue = stringValue
                        annotation.buttonWidgetState = buttonState
                        annotation.modificationDate = modificationDate
                    }
                )
                widgetOrdinal += 1
            }
        }
        return snapshot
    }

    private func widgetSnapshotKey(
        pageIndex: Int,
        ordinal: Int,
        annotation: PDFAnnotation
    ) -> String {
        let bounds = annotation.bounds
        return [
            String(pageIndex),
            String(ordinal),
            annotation.fieldName ?? "",
            String(
                format: "%.3f,%.3f,%.3f,%.3f",
                bounds.minX,
                bounds.minY,
                bounds.width,
                bounds.height
            ),
        ].joined(separator: "|")
    }

    private func refreshPrimedWidgetValueSnapshot() {
        widgetValueSnapshot = currentWidgetValueSnapshot()
        widgetUndoValueSnapshot = currentWidgetUndoValueSnapshot()
    }

    private var navigationSnapshot: PDFEditNavigationSnapshot {
        PDFEditNavigationSnapshot(
            currentPageIndex: currentPageIndex,
            selectedPages: selectedPages
        )
    }

    private func restoreNavigation(_ snapshot: PDFEditNavigationSnapshot) {
        let maximumIndex = max(0, pageCount - 1)
        currentPageIndex = min(max(0, snapshot.currentPageIndex), maximumIndex)
        selectedPages = Set(snapshot.selectedPages.filter { $0 >= 0 && $0 < pageCount })
        if selectedPages.isEmpty, pageCount > 0 {
            selectedPages = [currentPageIndex]
        }
    }

    private func recordEdit(
        actionName: String,
        beforeNavigation: PDFEditNavigationSnapshot,
        invalidatingDocumentSelections: Bool = false,
        retainedPageCost: Int = 0,
        undo: @escaping () throws -> Void,
        redo: @escaping () throws -> Void
    ) {
        // Toolbar/sidebar actions do not pass through PDFView.mouseDown. If a
        // person types in the floating editor and immediately rotates a page,
        // this common history boundary records the text first and the toolbar
        // action second. Consequently the first Undo reverses the action they
        // performed most recently (the rotation), rather than unexpectedly
        // removing their earlier text.
        //
        // `commitPendingInlineText` clears the pending value before it calls
        // back into `recordEdit`, so this cannot recurse.
        commitPendingInlineTextDraftIfNeeded()
        guard editHistory.register(
            actionName: actionName,
            beforeNavigation: beforeNavigation,
            afterNavigation: navigationSnapshot,
            invalidatesDocumentSelections: invalidatingDocumentSelections,
            retainedPageCost: retainedPageCost,
            undo: undo,
            redo: redo
        ) else { return }
        finishDocumentMutation(
            actionName,
            invalidatingDocumentSelections: invalidatingDocumentSelections
        )
    }

    private func registerAnnotationAdditions(
        _ additions: [(page: PDFPage, annotation: PDFAnnotation)],
        message: String,
        beforeNavigation: PDFEditNavigationSnapshot
    ) {
        guard
            let document,
            !additions.isEmpty,
            additions.allSatisfy({ addition in
                document.index(for: addition.page) != NSNotFound
                    && addition.page.annotations.contains(where: { $0 === addition.annotation })
        })
        else { return }
        // Register provenance beside successful graph validation, before an
        // immediate mode switch can ask an overlay about the new object.
        additions.forEach { trustRuntimeAnnotation($0.annotation) }
        recordEdit(
            actionName: message,
            beforeNavigation: beforeNavigation,
            undo: {
                guard additions.allSatisfy({ addition in
                    document.index(for: addition.page) != NSNotFound
                        && addition.page.annotations.contains(where: { $0 === addition.annotation })
                }) else {
                    throw WorkspaceError.operationFailed(
                        L10n.string(
                            "error.undo_annotation_state",
                            defaultValue: "The annotation is no longer in the expected state."
                        )
                    )
                }
                for addition in additions.reversed() {
                    addition.page.removeAnnotation(addition.annotation)
                }
            },
            redo: {
                guard additions.allSatisfy({ addition in
                    document.index(for: addition.page) != NSNotFound
                        && !addition.page.annotations.contains(where: { $0 === addition.annotation })
                }) else {
                    throw WorkspaceError.operationFailed(
                        L10n.string(
                            "error.undo_annotation_state",
                            defaultValue: "The annotation is no longer in the expected state."
                        )
                    )
                }
                for addition in additions {
                    addition.page.addAnnotation(addition.annotation)
                }
            }
        )
    }

    private func finishHistoryTraversal(command: PDFEditCommand, isUndo: Bool) {
        if command.invalidatesDocumentSelections {
            invalidateDocumentSelections()
            widgetValueSnapshot = [:]
            widgetUndoValueSnapshot = [:]
            widgetSnapshotPrimedPages = []
            if let page = document?.page(at: currentPageIndex) {
                primeWidgetValues(on: page)
            }
        } else {
            refreshPrimedWidgetValueSnapshot()
        }
        finishDocumentMutation(
            L10n.format(
                isUndo ? "status.undo_completed" : "status.redo_completed",
                command.actionName
            ),
            invalidatingDocumentSelections: false
        )
    }

    private func synchronizeHistoryPresentation() {
        canUndo = editHistory.canUndo
        canRedo = editHistory.canRedo
        undoActionName = editHistory.undoActionName
        redoActionName = editHistory.redoActionName
        isDirty = !editHistory.isAtSavedState
    }

    private func finishDocumentMutation(
        _ message: String,
        invalidatingDocumentSelections: Bool = false
    ) {
        if ocrTask != nil {
            cancelOCR()
        }
        if invalidatingDocumentSelections {
            invalidateDocumentSelections()
        } else {
            // Free-text/form/annotation changes can alter PDFKit's extracted
            // text as well. Never let an in-flight generation publish against
            // a new revision or leave a navigator pointing at stale ranges.
            cancelSearchAndInvalidate(clearResults: true)
        }
        ocrCheckpoint = nil
        synchronizeHistoryPresentation()
        refresh(message)
        scheduleRecoverySnapshot()
    }

    private func markChanged(
        _ message: String,
        invalidatingDocumentSelections: Bool = false
    ) {
        editHistory.noteUntrackedMutation()
        finishDocumentMutation(
            message,
            invalidatingDocumentSelections: invalidatingDocumentSelections
        )
    }

    private func invalidateDocumentSelections() {
        currentSelection = nil
        cancelSearchAndInvalidate(clearResults: true)
    }

    private func refresh(_ message: String) {
        revision = UUID()
        statusMessage = message
    }

    private func abandonOCR() {
        ocrRunID = nil
        ocrTask?.cancel()
        ocrTask = nil
        ocrState = .idle
    }
}
