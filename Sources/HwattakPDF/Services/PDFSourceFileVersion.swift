// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import PDFKit

/// A lightweight identity for the bytes from which a workspace was opened.
///
/// Keeping this snapshot is cheaper than hashing a 50–200 MB PDF whenever it
/// opens. A normal in-place edit changes `contentModificationDate` or size,
/// while an atomic replacement changes the file-system node number. Comparing
/// all of them therefore catches both common kinds of external modification.
///
/// This is conflict detection rather than authentication: a hostile program
/// could deliberately preserve every metadata field. The app's goal here is to
/// prevent accidental data loss when Preview, a cloud client, or another editor
/// saves the same PDF while HwattakPDF still has an older copy in memory.
struct PDFSourceFileVersion: Equatable {
    let canonicalURL: URL
    let fileSize: UInt64
    let contentModificationDate: Date
    let fileSystemNumber: UInt64?
    let fileSystemNodeNumber: UInt64?

    /// Reads metadata while the caller's security-scoped access is alive.
    static func capture(at url: URL) throws -> PDFSourceFileVersion {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let modificationDate = attributes[.modificationDate] as? Date
        else {
            throw CocoaError(.fileReadUnknown)
        }

        return PDFSourceFileVersion(
            canonicalURL: canonicalURL(for: url),
            fileSize: size,
            contentModificationDate: modificationDate,
            fileSystemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileSystemNodeNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    /// Standardizing and resolving symbolic links makes `file.pdf`, `./file.pdf`,
    /// and a symlink to that file participate in the same conflict check.
    ///
    /// Hard links are different paths that resolve to the same physical inode,
    /// so canonical URLs alone are insufficient. When both files exist, compare
    /// their device and inode numbers as well. This prevents "Save Copy" from
    /// selecting a hard link whose direct-write fallback would silently mutate
    /// the original through the shared inode.
    static func refersToSameLocation(_ first: URL, _ second: URL) -> Bool {
        if canonicalURL(for: first) == canonicalURL(for: second) {
            return true
        }
        guard
            let firstIdentity = physicalIdentity(at: first),
            let secondIdentity = physicalIdentity(at: second)
        else {
            // A new Save As destination has no identity yet and is therefore a
            // genuinely different file. Metadata lookup failures fail closed
            // only in overwrite paths, where the caller requires a baseline.
            return false
        }
        return firstIdentity == secondIdentity
    }

    private static func canonicalURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private struct PhysicalIdentity: Equatable {
        let fileSystemNumber: UInt64
        let fileSystemNodeNumber: UInt64
    }

    private static func physicalIdentity(at url: URL) -> PhysicalIdentity? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileSystemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            let fileSystemNodeNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            return nil
        }
        return PhysicalIdentity(
            fileSystemNumber: fileSystemNumber,
            fileSystemNodeNumber: fileSystemNodeNumber
        )
    }
}

/// Captures the exact state of a Save As destination before serialization.
///
/// A save panel's overwrite confirmation is only a point-in-time decision. A
/// different app can create or replace that path while HwattakPDF serializes a
/// large document. Requiring the same `nil`/version state at commit prevents us
/// from silently replacing those newly arrived external bytes.
struct PDFDestinationPrecondition {
    let destination: URL
    private let expectedVersion: PDFSourceFileVersion?

    init(destination: URL) throws {
        self.destination = destination
        expectedVersion = try Self.captureVersionIfPresent(at: destination)
    }

    func validate() throws {
        do {
            guard try Self.captureVersionIfPresent(at: destination) == expectedVersion else {
                throw WorkspaceError.externalModification(destination)
            }
        } catch let workspaceError as WorkspaceError {
            throw workspaceError
        } catch {
            // An unreadable destination is no longer demonstrably the version
            // the user approved. Fail closed and leave its bytes untouched.
            throw WorkspaceError.externalModification(destination)
        }
    }

    private static func captureVersionIfPresent(at url: URL) throws -> PDFSourceFileVersion? {
        do {
            return try PDFSourceFileVersion.capture(at: url)
        } catch {
            if isNoSuchFile(error) {
                return nil
            }
            throw error
        }
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoSuchFile.rawValue {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNoSuchFile(underlying)
        }
        return false
    }
}

/// Coordinates the two file-system transactions that establish or consume a
/// `PDFSourceFileVersion`.
///
/// The comparison is deliberately performed *inside* the coordinated write
/// accessor. Checking first and coordinating later would leave a time-of-check /
/// time-of-use window in which another coordinated editor could replace the PDF.
enum PDFSourceFileAccess {
    struct LoadedDocument {
        let document: PDFDocument
        let version: PDFSourceFileVersion
    }

    struct SavedDocument {
        let url: URL
        let version: PDFSourceFileVersion
    }

    /// Opens the PDF and captures its metadata in one coordinated read.
    static func loadDocument(at url: URL) throws -> LoadedDocument {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<LoadedDocument, Error>?

        coordinator.coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Result {
                // Capture on both sides of PDFKit's lazy document creation. The
                // coordinator protects against cooperating writers; the second
                // capture also detects an uncoordinated replacement during open.
                let before = try PDFSourceFileVersion.capture(at: coordinatedURL)
                guard let document = PDFDocument(url: coordinatedURL) else {
                    throw WorkspaceError.invalidPDF(url)
                }
                let after = try PDFSourceFileVersion.capture(at: coordinatedURL)
                guard before == after else {
                    throw WorkspaceError.cannotOpen(url)
                }
                return LoadedDocument(document: document, version: after)
            }
        }

        if coordinationError != nil {
            // SwiftPM/XCTest hosts are not app bundles and cannot connect to
            // macOS filecoordinationd in some sandboxed CI environments. Keep
            // their production-equivalent metadata checks testable without
            // weakening the packaged app, where a coordination failure remains
            // a hard error.
            if !requiresSystemFileCoordination {
                return try loadDocumentWithoutCoordination(at: url)
            }
            throw WorkspaceError.cannotOpen(url)
        }
        guard let operationResult else {
            throw WorkspaceError.cannotOpen(url)
        }
        return try operationResult.get()
    }

    /// Replaces the original only when its current metadata still matches the
    /// version captured at open/resume/the previous successful save.
    static func overwriteDocument(
        _ document: PDFDocument,
        at url: URL,
        expectedVersion: PDFSourceFileVersion
    ) throws -> SavedDocument {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationResult: Result<SavedDocument, Error>?

        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            operationResult = Result {
                try overwriteWithoutCoordination(
                    document,
                    at: coordinatedURL,
                    reportedURL: url,
                    expectedVersion: expectedVersion
                )
            }
        }

        if coordinationError != nil {
            if !requiresSystemFileCoordination {
                return try overwriteWithoutCoordination(
                    document,
                    at: url,
                    reportedURL: url,
                    expectedVersion: expectedVersion
                )
            }
            throw WorkspaceError.cannotSave(url)
        }
        guard let operationResult else {
            throw WorkspaceError.cannotSave(url)
        }
        return try operationResult.get()
    }

    /// The release bundle requires NSFileCoordinator. Only non-app hosts such
    /// as `swift test` and `swift run` use the metadata-guarded fallback.
    private static var requiresSystemFileCoordination: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private static func loadDocumentWithoutCoordination(at url: URL) throws -> LoadedDocument {
        let before = try PDFSourceFileVersion.capture(at: url)
        guard let document = PDFDocument(url: url) else {
            throw WorkspaceError.invalidPDF(url)
        }
        let after = try PDFSourceFileVersion.capture(at: url)
        guard before == after else {
            throw WorkspaceError.cannotOpen(url)
        }
        return LoadedDocument(document: document, version: after)
    }

    private static func overwriteWithoutCoordination(
        _ document: PDFDocument,
        at destination: URL,
        reportedURL: URL,
        expectedVersion: PDFSourceFileVersion
    ) throws -> SavedDocument {
        func validateCurrentVersion() throws {
            guard
                let currentVersion = try? PDFSourceFileVersion.capture(at: destination),
                currentVersion == expectedVersion
            else {
                // A missing file and an unreadable metadata snapshot are also
                // conflicts. Failing closed is safer than recreating or
                // overwriting a destination whose state is no longer known.
                throw WorkspaceError.externalModification(reportedURL)
            }
        }

        try validateCurrentVersion()
        let resultingURL = try AtomicPDFWriter.write(
            document,
            to: destination,
            validateDestinationBeforeCommit: validateCurrentVersion
        )
        let savedVersion = try PDFSourceFileVersion.capture(at: resultingURL)
        return SavedDocument(url: resultingURL, version: savedVersion)
    }
}
