// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Finder requests belong to the application lifetime, including the time
/// before a PDF window appears and after its view has disappeared.
@MainActor
final class AppExternalFileOpenCoordinator {
    static let shared = AppExternalFileOpenCoordinator()

    private let coalescingDelay: Duration
    private var presentMainWindow: (() -> Void)?
    private var openFiles: (([URL]) -> Void)?
    private var pendingAccesses: [SecurityScopedAccess] = []
    private var coalescingTask: Task<Void, Never>?
    private var needsWindowPresentation = false

    init(coalescingDelay: Duration = .milliseconds(120)) {
        self.coalescingDelay = coalescingDelay
    }

    func configure(
        workspace: MultiDocumentWorkspaceState,
        presentMainWindow: @escaping () -> Void
    ) {
        configure(presentMainWindow: presentMainWindow) { [weak workspace] urls in
            workspace?.beginOpeningViewableFilesInTabs(urls: urls)
        }
    }

    /// The callbacks keep native window presentation separate from PDF loading
    /// and allow launch ordering to be tested without the user's app/session.
    func configure(
        presentMainWindow: @escaping () -> Void,
        openFiles: @escaping ([URL]) -> Void
    ) {
        self.presentMainWindow = presentMainWindow
        self.openFiles = openFiles
        presentPendingWindowIfPossible()
        schedulePendingOpen()
    }

    func enqueue(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        // Acquire sandbox grants during the native callback and retain them
        // through launch, window presentation, and burst coalescing. The
        // workspace synchronously acquires its own scopes when loading starts.
        pendingAccesses.append(contentsOf: fileURLs.map { SecurityScopedAccess(url: $0) })
        needsWindowPresentation = true
        presentPendingWindowIfPossible()
        schedulePendingOpen()
    }

    func mainWindowDidDisappear() {
        // An external request may have brought the window forward before the
        // coalescing deadline. If it closes in that interval, the eventual
        // drain must show it again before installing the requested document.
        if !pendingAccesses.isEmpty {
            needsWindowPresentation = true
        }
    }

    /// The timer drains one complete burst. Keeping requests here instead of
    /// in a SwiftUI view prevents onDisappear from silently dropping them.
    func flushPendingOpenRequests() {
        guard let openFiles, !pendingAccesses.isEmpty else { return }
        coalescingTask?.cancel()
        coalescingTask = nil
        presentPendingWindowIfPossible()
        let capturedAccesses = pendingAccesses
        pendingAccesses.removeAll()
        var seen: Set<URL> = []
        let urls = capturedAccesses.map(\.url).filter {
            seen.insert($0.standardizedFileURL).inserted
        }
        withExtendedLifetime(capturedAccesses) {
            openFiles(urls)
        }
    }

    private func presentPendingWindowIfPossible() {
        guard needsWindowPresentation, let presentMainWindow else { return }
        // Clear before invoking SwiftUI: presenting a closed window may
        // synchronously run onAppear and configure this coordinator again.
        needsWindowPresentation = false
        presentMainWindow()
    }

    private func schedulePendingOpen() {
        guard openFiles != nil, !pendingAccesses.isEmpty else { return }
        coalescingTask?.cancel()
        let delay = coalescingDelay
        coalescingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushPendingOpenRequests()
        }
    }
}
