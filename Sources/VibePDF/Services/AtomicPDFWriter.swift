// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import PDFKit

/// PDF 저장을 "직렬화 -> 검증 -> 교체" 순서로 수행하는 방어적 writer다.
///
/// 정상 경로에서는 같은 폴더의 임시 PDF를 먼저 다시 열어 페이지 수를 확인하고
/// 원본을 교체한다. App Sandbox가 선택한 **파일 하나**에만 쓰기 권한을 주어 옆에
/// 임시 파일을 만들 수 없을 때만 검증된 메모리 데이터를 원본에 직접 쓴다.
/// 직접 쓰기는 프로세스 중단에 대한 원자성은 낮지만, 쓰기 전에 완전한 PDF인지
/// 확인하고 쓴 뒤에도 다시 열어 조용한 손상을 최대한 탐지한다.
enum AtomicPDFWriter {
    private enum StagingFailure: Error {
        case pdfKitReturnedFalse
    }

    /// 성공하면 실제 destination을 반환하고, 어느 단계든 검증이 실패하면
    /// `WorkspaceError`로 변환해 호출자가 dirty 상태를 유지하도록 한다.
    @discardableResult
    static func write(
        _ document: PDFDocument,
        to destination: URL,
        writeOptions: [PDFDocumentWriteOption: Any]? = nil,
        validateSerializedDocument: ((PDFDocument, Int) throws -> Void)? = nil,
        validateDestinationBeforeCommit: (() throws -> Void)? = nil,
        validateStagedPDF: ((URL, Int) throws -> Void)? = nil,
        allowDirectOverwriteFallback: Bool = true,
        onDirectWriteFallback: (() -> Void)? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        // Capture before any potentially long PDFKit serialization. This state
        // represents exactly what the user approved in the save panel: either
        // a particular existing file version or an absent destination.
        let destinationPrecondition = try PDFDestinationPrecondition(
            destination: destination
        )
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            guard write(document, to: temporary, options: writeOptions) else {
                // PDFKit exposes only Bool here. The catch block performs one
                // zero-byte sibling probe to distinguish sandbox permission
                // denial from ENOSPC/EIO/invalid serialization before deciding
                // whether the less-safe file-scoped fallback is appropriate.
                throw StagingFailure.pdfKitReturnedFalse
            }
            try validatePDF(
                at: temporary,
                expectedPageCount: document.pageCount,
                validateSerializedDocument: validateSerializedDocument
            )
            try validateStagedPDF?(temporary, document.pageCount)
            // Serializing a very large PDF can take seconds. Revalidate only
            // after the complete temporary file is ready so an external save
            // during that interval cannot be silently replaced at commit time.
            try validateDestinationBeforeCommit?()
            try destinationPrecondition.validate()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            return destination
        } catch let atomicError {
            try? fileManager.removeItem(at: temporary)

            // Semantic validation failures (external edit, Save Copy alias,
            // invalid staged PDF) are intentional stops. Falling back after
            // any of them would bypass the very guard that protected the user.
            if let workspaceError = atomicError as? WorkspaceError {
                throw workspaceError
            }

            let mayUseFileScopedFallback: Bool
            if atomicError is StagingFailure {
                mayUseFileScopedFallback = siblingCreationIsPermissionDenied(in: parent)
            } else {
                mayUseFileScopedFallback = isPermissionDeniedForFileScopeFallback(atomicError)
            }
            guard mayUseFileScopedFallback else {
                if atomicError is StagingFailure {
                    throw WorkspaceError.cannotSave(destination)
                }
                // Preserve useful ENOSPC/EIO diagnostics and, most
                // importantly, never touch the destination after such errors.
                throw atomicError
            }

            // A direct fallback truncates an existing inode before the final
            // reopen check can finish. Security-sensitive exports opt out of
            // that trade-off: if the sandbox prevents an atomic sibling-file
            // replacement, preserve the existing destination and report the
            // save failure instead of risking a partial protected copy.
            if
                !allowDirectOverwriteFallback,
                fileManager.fileExists(atPath: destination.path)
            {
                throw WorkspaceError.cannotSave(destination)
            }

            // A sandbox extension granted for a user-selected file permits
            // writing that file, but does not necessarily permit creating a
            // sibling temporary file or renaming over it. That makes the
            // preferred atomic path fail for PDFs opened through NSOpenPanel.
            // Serialize and validate before touching the destination, then
            // fall back to a direct write that only needs access to the file.
            do {
                try writeValidatedDirectly(
                    document,
                    to: destination,
                    writeOptions: writeOptions,
                    validateSerializedDocument: validateSerializedDocument,
                    validateDestinationBeforeCommit: {
                        try validateDestinationBeforeCommit?()
                        try destinationPrecondition.validate()
                    },
                    onDirectWriteCommit: onDirectWriteFallback
                )
                return destination
            } catch {
                if let workspaceError = error as? WorkspaceError {
                    throw workspaceError
                }
                throw WorkspaceError.cannotSave(destination)
            }
        }
    }

    /// Returns true only for errors where a user-granted file scope can help.
    /// Disk-full, I/O, malformed-PDF and unknown failures intentionally return
    /// false: retrying those by truncating the destination risks data loss.
    static func isPermissionDeniedForFileScopeFallback(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileWriteNoPermission.rawValue {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDeniedForFileScopeFallback(underlying)
        }
        return false
    }

    /// PDFKit's Bool-only staging API hides its NSError. Probe a unique sibling
    /// with zero bytes: permission denial confirms the sandbox/file-scope case;
    /// success or any other error means direct overwrite is not justified.
    private static func siblingCreationIsPermissionDenied(in parent: URL) -> Bool {
        let probe = parent.appendingPathComponent(
            ".HwattakPDF-permission-probe-\(UUID().uuidString).tmp"
        )
        do {
            try Data().write(to: probe, options: [])
            try? FileManager.default.removeItem(at: probe)
            return false
        } catch {
            try? FileManager.default.removeItem(at: probe)
            return isPermissionDeniedForFileScopeFallback(error)
        }
    }

    /// sibling 임시 파일 권한이 없는 샌드박스용 최후 수단이다.
    private static func writeValidatedDirectly(
        _ document: PDFDocument,
        to destination: URL,
        writeOptions: [PDFDocumentWriteOption: Any]?,
        validateSerializedDocument: ((PDFDocument, Int) throws -> Void)?,
        validateDestinationBeforeCommit: (() throws -> Void)?,
        onDirectWriteCommit: (() -> Void)?
    ) throws {
        guard
            let data = dataRepresentation(of: document, options: writeOptions),
            let staged = PDFDocument(data: data)
        else {
            throw WorkspaceError.operationFailed(L10n.string("error.validate_saved_pdf"))
        }
        try validate(
            staged,
            expectedPageCount: document.pageCount,
            validateSerializedDocument: validateSerializedDocument
        )

        do {
            // Do not request `.atomic` here: Foundation would create another
            // sibling file, recreating the sandbox failure this is handling.
            try validateDestinationBeforeCommit?()
            try validateIsolatedRegularFileForDirectWrite(at: destination)
            onDirectWriteCommit?()
            try data.write(to: destination, options: [])
            try validatePDF(
                at: destination,
                expectedPageCount: document.pageCount,
                validateSerializedDocument: validateSerializedDocument
            )
        } catch let error as WorkspaceError {
            throw error
        } catch {
            throw WorkspaceError.cannotSave(destination)
        }
    }

    /// Direct writes follow symlinks and mutate every hard link to one inode.
    /// Atomic replacement is safe because it swaps only one directory entry,
    /// but this fallback truncates the existing inode. Immediately before that
    /// point, accept only an absent new path or one regular file with link count
    /// one. Other file types and multiply-linked files remain untouched.
    private static func validateIsolatedRegularFileForDirectWrite(
        at destination: URL
    ) throws {
        var metadata = stat()
        let result = destination.path.withCString { path in
            lstat(path, &metadata)
        }
        if result != 0 {
            let code = errno
            if code == ENOENT {
                return
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }

        let isRegularFile = (metadata.st_mode & S_IFMT) == S_IFREG
        guard isRegularFile, metadata.st_nlink <= 1 else {
            throw WorkspaceError.operationFailed(
                L10n.string("error.save_copy_same_as_original")
            )
        }
    }

    /// 저장 파일을 PDFKit으로 다시 열어 최소 구조와 페이지 수를 확인한다.
    private static func validatePDF(
        at url: URL,
        expectedPageCount: Int,
        validateSerializedDocument: ((PDFDocument, Int) throws -> Void)?
    ) throws {
        guard let staged = PDFDocument(url: url) else {
            throw WorkspaceError.operationFailed(L10n.string("error.validate_saved_pdf"))
        }
        try validate(
            staged,
            expectedPageCount: expectedPageCount,
            validateSerializedDocument: validateSerializedDocument
        )
    }

    private static func validate(
        _ staged: PDFDocument,
        expectedPageCount: Int,
        validateSerializedDocument: ((PDFDocument, Int) throws -> Void)?
    ) throws {
        if let validateSerializedDocument {
            try validateSerializedDocument(staged, expectedPageCount)
        } else if staged.pageCount != expectedPageCount {
            throw WorkspaceError.operationFailed(L10n.string("error.validate_saved_pdf"))
        }
    }

    private static func write(
        _ document: PDFDocument,
        to url: URL,
        options: [PDFDocumentWriteOption: Any]?
    ) -> Bool {
        if let options {
            return document.write(to: url, withOptions: options)
        }
        return document.write(to: url)
    }

    private static func dataRepresentation(
        of document: PDFDocument,
        options: [PDFDocumentWriteOption: Any]?
    ) -> Data? {
        if let options {
            return document.dataRepresentation(options: options)
        }
        return document.dataRepresentation()
    }
}
