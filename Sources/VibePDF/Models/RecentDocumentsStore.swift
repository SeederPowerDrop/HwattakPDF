// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation

struct RecentDocument: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let locationDescription: String
    let lastOpenedAt: Date
}

enum RecentDocumentsError: LocalizedError {
    case invalidFileURL
    case bookmarkCreationFailed(String)
    case bookmarkResolutionFailed(String)
    case documentNotFound
    case fileMissing(String)
    case persistenceCorrupted
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            L10n.string("error.recent_local_only")
        case let .bookmarkCreationFailed(message):
            L10n.format("error.recent_bookmark_save", message)
        case let .bookmarkResolutionFailed(message):
            L10n.format("error.recent_bookmark_restore", message)
        case .documentNotFound:
            L10n.string("error.recent_not_found")
        case let .fileMissing(name):
            L10n.format("error.recent_file_missing", name)
        case .persistenceCorrupted:
            L10n.string("error.recent_corrupted")
        case let .persistenceFailed(message):
            L10n.format("error.recent_persistence", message)
        }
    }
}

/// A resolved security-scoped bookmark whose access remains active for the
/// lifetime of this object. Callers should retain it until they have handed
/// the URL to a workspace, which establishes its own long-lived access scope.
final class RecentDocumentAccess {
    let url: URL
    private let scopedAccess: SecurityScopedAccess

    fileprivate init(url: URL) {
        self.url = url
        scopedAccess = SecurityScopedAccess(url: url)
    }
}

protocol RecentDocumentsPersisting: AnyObject {
    var data: Data? { get set }
}

final class UserDefaultsRecentDocumentsPersistence: RecentDocumentsPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "com.hwattakpdf.recent-documents.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    var data: Data? {
        get { defaults.data(forKey: key) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

protocol RecentDocumentBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
}

struct SecurityScopedRecentDocumentBookmarkCoder: RecentDocumentBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.nameKey, .isRegularFileKey],
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

@MainActor
final class RecentDocumentsStore: ObservableObject {
    @Published private(set) var documents: [RecentDocument] = []
    @Published private(set) var lastError: RecentDocumentsError?

    private struct StoredDocument: Codable {
        let id: UUID
        var bookmark: Data
        var canonicalPath: String
        var displayName: String
        var locationDescription: String
        var lastOpenedAt: Date

        var presentation: RecentDocument {
            RecentDocument(
                id: id,
                displayName: displayName,
                locationDescription: locationDescription,
                lastOpenedAt: lastOpenedAt
            )
        }
    }

    private let persistence: RecentDocumentsPersisting
    private let bookmarkCoder: RecentDocumentBookmarkCoding
    private let maximumCount: Int
    private let now: () -> Date
    private var storedDocuments: [StoredDocument] = []

    convenience init(
        defaults: UserDefaults = .standard,
        key: String = "com.hwattakpdf.recent-documents.v1",
        maximumCount: Int = 7
    ) {
        self.init(
            persistence: UserDefaultsRecentDocumentsPersistence(defaults: defaults, key: key),
            bookmarkCoder: SecurityScopedRecentDocumentBookmarkCoder(),
            maximumCount: maximumCount
        )
    }

    init(
        persistence: RecentDocumentsPersisting,
        bookmarkCoder: RecentDocumentBookmarkCoding,
        maximumCount: Int = 7,
        now: @escaping () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.bookmarkCoder = bookmarkCoder
        self.maximumCount = min(7, max(1, maximumCount))
        self.now = now
        loadPersistedDocuments()
    }

    @discardableResult
    func record(url: URL) throws -> RecentDocument {
        do {
            guard url.isFileURL else { throw RecentDocumentsError.invalidFileURL }
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else {
                throw RecentDocumentsError.fileMissing(url.lastPathComponent)
            }
            let bookmark: Data
            do {
                bookmark = try bookmarkCoder.makeBookmark(for: url)
            } catch {
                throw RecentDocumentsError.bookmarkCreationFailed(error.localizedDescription)
            }

            let canonicalPath = canonicalFileKey(for: url)
            let existing = storedDocuments.first(where: { $0.canonicalPath == canonicalPath })
            let record = StoredDocument(
                id: existing?.id ?? UUID(),
                bookmark: bookmark,
                canonicalPath: canonicalPath,
                displayName: url.lastPathComponent,
                locationDescription: locationDescription(for: url),
                lastOpenedAt: now()
            )
            storedDocuments.removeAll { $0.canonicalPath == canonicalPath }
            storedDocuments.insert(record, at: 0)
            storedDocuments = Array(storedDocuments.prefix(maximumCount))
            try persistAndPublish()
            lastError = nil
            return record.presentation
        } catch let error as RecentDocumentsError {
            lastError = error
            throw error
        } catch {
            let wrapped = RecentDocumentsError.persistenceFailed(error.localizedDescription)
            lastError = wrapped
            throw wrapped
        }
    }

    func remove(id: UUID) {
        guard storedDocuments.contains(where: { $0.id == id }) else { return }
        storedDocuments.removeAll { $0.id == id }
        persistBestEffort()
    }

    func clear() {
        guard !storedDocuments.isEmpty || persistence.data != nil else {
            lastError = nil
            return
        }
        storedDocuments.removeAll()
        persistence.data = nil
        documents = []
        lastError = nil
    }

    func resolve(id: UUID) throws -> RecentDocumentAccess {
        do {
            guard let index = storedDocuments.firstIndex(where: { $0.id == id }) else {
                throw RecentDocumentsError.documentNotFound
            }

            let resolution: (url: URL, isStale: Bool)
            do {
                resolution = try bookmarkCoder.resolveBookmark(storedDocuments[index].bookmark)
            } catch {
                throw RecentDocumentsError.bookmarkResolutionFailed(error.localizedDescription)
            }

            let access = RecentDocumentAccess(url: resolution.url)
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: resolution.url.path,
                    isDirectory: &isDirectory
                ),
                !isDirectory.boolValue
            else {
                throw RecentDocumentsError.fileMissing(storedDocuments[index].displayName)
            }

            if resolution.isStale {
                do {
                    storedDocuments[index].bookmark = try bookmarkCoder.makeBookmark(for: resolution.url)
                    storedDocuments[index].canonicalPath = canonicalFileKey(for: resolution.url)
                    storedDocuments[index].displayName = resolution.url.lastPathComponent
                    storedDocuments[index].locationDescription = locationDescription(for: resolution.url)
                    try persistAndPublish()
                    lastError = nil
                } catch {
                    // The stale bookmark already resolved to a valid, scoped
                    // file. Refreshing persistence is maintenance and must not
                    // prevent this open from succeeding.
                    if let recentError = error as? RecentDocumentsError {
                        lastError = recentError
                    } else {
                        lastError = .bookmarkCreationFailed(error.localizedDescription)
                    }
                }
            } else {
                lastError = nil
            }

            return access
        } catch let error as RecentDocumentsError {
            lastError = error
            throw error
        } catch {
            let wrapped = RecentDocumentsError.persistenceFailed(error.localizedDescription)
            lastError = wrapped
            throw wrapped
        }
    }

    private func loadPersistedDocuments() {
        guard let data = persistence.data else {
            documents = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([StoredDocument].self, from: data)
            var seenPaths: Set<String> = []
            storedDocuments = decoded
                .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
                .filter { seenPaths.insert($0.canonicalPath).inserted }
            storedDocuments = Array(storedDocuments.prefix(maximumCount))
            documents = storedDocuments.map(\.presentation)
        } catch {
            storedDocuments = []
            documents = []
            lastError = .persistenceCorrupted
        }
    }

    private func persistAndPublish() throws {
        do {
            persistence.data = try JSONEncoder().encode(storedDocuments)
            documents = storedDocuments.map(\.presentation)
        } catch {
            throw RecentDocumentsError.persistenceFailed(error.localizedDescription)
        }
    }

    private func persistBestEffort() {
        do {
            if storedDocuments.isEmpty {
                persistence.data = nil
                documents = []
            } else {
                try persistAndPublish()
            }
            lastError = nil
        } catch let error as RecentDocumentsError {
            lastError = error
        } catch {
            lastError = .persistenceFailed(error.localizedDescription)
        }
    }

    private func canonicalFileKey(for url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping
    }

    private func locationDescription(for url: URL) -> String {
        url.deletingLastPathComponent().path
    }
}
