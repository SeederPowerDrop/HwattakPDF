// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import PDFKit

enum PDFPasswordPolicyError: LocalizedError, Equatable {
    case empty
    case invalidLength
    case unsupportedCharacters

    var errorDescription: String? {
        switch self {
        case .empty:
            L10n.string(
                "security.export.password.empty",
                defaultValue: "암호를 입력해 주세요."
            )
        case .invalidLength:
            L10n.string(
                "security.export.password.length",
                defaultValue: "암호는 8–32자로 입력해 주세요."
            )
        case .unsupportedCharacters:
            L10n.string(
                "security.export.password.ascii",
                defaultValue: "PDF 호환성을 위해 영문, 숫자, 일반 기호만 사용할 수 있습니다."
            )
        }
    }
}

/// Core Graphics' standard PDF encryption accepts at most the first 32 ASCII
/// bytes. Rejecting unsupported input before a save prevents a person from
/// believing that a visually longer or non-ASCII password protects the file.
enum PDFPasswordPolicy {
    static let minimumLength = 8
    static let maximumLength = 32

    static func validate(_ password: String) throws {
        guard !password.isEmpty else {
            throw PDFPasswordPolicyError.empty
        }
        guard
            password.utf8.count >= minimumLength,
            password.utf8.count <= maximumLength
        else {
            throw PDFPasswordPolicyError.invalidLength
        }
        guard password.unicodeScalars.allSatisfy({ 0x20...0x7E ~= $0.value }) else {
            throw PDFPasswordPolicyError.unsupportedCharacters
        }
    }
}

struct PDFProtectedExportRequest: Equatable {
    let userPassword: String
    let shareAfterSaving: Bool
}

struct PDFProtectedExportPresentation: Identifiable, Equatable {
    let id = UUID()
    let destinationURL: URL
    let sourceURL: URL?
    let documentIdentity: ObjectIdentifier
    let documentRevision: UUID
}

/// Central security boundary for operations that would change an encrypted
/// document's protection. A user password may grant broad editing permissions,
/// but only an owner unlock authorizes replacing or removing the security
/// dictionary itself.
enum PDFDocumentSecurityPolicy {
    private static func validateUnlocked(_ document: PDFDocument) throws {
        guard !document.isLocked else {
            throw WorkspaceError.operationFailed(
                L10n.string(
                    "security.document_locked",
                    defaultValue: "PDF의 잠금을 먼저 해제해 주세요."
                )
            )
        }
    }

    static func validateCanReencrypt(_ document: PDFDocument) throws {
        try validateUnlocked(document)
        guard !document.isEncrypted || document.permissionsStatus == .owner else {
            throw WorkspaceError.operationFailed(
                L10n.string(
                    "security.owner_required",
                    defaultValue: "암호화 PDF의 보안 설정을 바꾸려면 소유자 암호로 열어야 합니다."
                )
            )
        }
    }

    /// Exporting complete PDF pages both copies protected page content and
    /// assembles that content into a new PDF. A user-password session must
    /// grant both operations; owner authority bypasses the restricted bits.
    static func validateCanExtractPages(_ document: PDFDocument) throws {
        try validateUnlocked(document)
        guard
            !document.isEncrypted
                || document.permissionsStatus == .owner
                || (document.allowsCopying && document.allowsDocumentAssembly)
        else {
            throw WorkspaceError.operationFailed(
                L10n.string(
                    "security.page_extraction_not_allowed",
                    defaultValue: "이 PDF의 현재 권한으로는 페이지를 추출하거나 병합할 수 없습니다."
                )
            )
        }
    }

    /// Raster export extracts the visible page content but does not preserve or
    /// rearrange PDF page objects, so the copying permission is the relevant
    /// restricted-user boundary.
    static func validateCanRasterizePages(_ document: PDFDocument) throws {
        try validateUnlocked(document)
        guard
            !document.isEncrypted
                || document.permissionsStatus == .owner
                || document.allowsCopying
        else {
            throw WorkspaceError.operationFailed(
                L10n.string(
                    "security.content_copying_not_allowed",
                    defaultValue: "이 PDF의 현재 권한으로는 페이지 내용을 이미지로 내보낼 수 없습니다."
                )
            )
        }
    }

    /// Searchable OCR output is an unencrypted, flattened derivative. Keep the
    /// same owner-only rule as OCR snapshot creation so a direct service caller
    /// cannot bypass the workspace's `.ocr` capability gate.
    static func validateCanExportSearchableOCR(_ document: PDFDocument) throws {
        try validateUnlocked(document)
        guard !document.isEncrypted || document.permissionsStatus == .owner else {
            throw WorkspaceError.operationFailed(
                L10n.string(
                    "security.owner_required",
                    defaultValue: "암호화 PDF의 보안 설정을 바꾸려면 소유자 암호로 열어야 합니다."
                )
            )
        }
    }

    static func validateOrdinarySaveAllowed(_ document: PDFDocument) throws {
        guard !document.isEncrypted else {
            throw WorkspaceError.operationFailed(
                L10n.string(
                    "security.save_protected_copy_required",
                    defaultValue: "암호화 PDF는 일반 저장을 사용하지 않습니다. ‘암호로 보호된 PDF 내보내기’를 사용해 주세요."
                )
            )
        }
    }
}

/// Produces a password-protected copy without changing the workspace's source
/// URL, dirty checkpoint, selection, or in-memory document identity.
enum ProtectedPDFExporter {
    private struct EncryptionConfiguration {
        let password: String

        var writeOptions: [PDFDocumentWriteOption: Any] {
            let encryptionLengthKey = PDFDocumentWriteOption(
                rawValue: kCGPDFContextEncryptionKeyLength as String
            )
            return [
                // One password deliberately serves as both the open and owner
                // password. The person who created this copy can therefore
                // later change or remove its protection instead of losing an
                // unrecorded, randomly generated owner credential forever.
                .ownerPasswordOption: password,
                .userPasswordOption: password,
                .accessPermissionsOption: NSNumber(value: Self.allPermissionsRawValue),
                encryptionLengthKey: NSNumber(value: 128)
            ]
        }

        private static let allPermissionsRawValue =
            PDFAccessPermissions.allowsLowQualityPrinting.rawValue
            | PDFAccessPermissions.allowsHighQualityPrinting.rawValue
            | PDFAccessPermissions.allowsDocumentChanges.rawValue
            | PDFAccessPermissions.allowsDocumentAssembly.rawValue
            | PDFAccessPermissions.allowsContentCopying.rawValue
            | PDFAccessPermissions.allowsContentAccessibility.rawValue
            | PDFAccessPermissions.allowsCommenting.rawValue
            | PDFAccessPermissions.allowsFormFieldEntry.rawValue

        func validate(_ candidate: PDFDocument, expectedPageCount: Int) throws {
            guard candidate.isEncrypted, candidate.isLocked else {
                throw WorkspaceError.operationFailed(
                    L10n.string(
                        "security.export.validation_failed",
                        defaultValue: "저장된 PDF의 암호 보호를 확인하지 못했습니다."
                    )
                )
            }
            guard
                candidate.unlock(withPassword: password),
                !candidate.isLocked,
                candidate.permissionsStatus == .owner,
                candidate.pageCount == expectedPageCount,
                candidate.allowsPrinting,
                candidate.allowsCopying,
                candidate.allowsDocumentChanges,
                candidate.allowsDocumentAssembly,
                candidate.allowsCommenting,
                candidate.allowsFormFieldEntry
            else {
                throw WorkspaceError.operationFailed(
                    L10n.string(
                        "security.export.validation_failed",
                        defaultValue: "저장된 PDF의 암호 보호를 확인하지 못했습니다."
                    )
                )
            }
        }
    }

    static func suggestedFileName(for sourceURL: URL?) -> String {
        let base = SelectedPagePDFExporter.documentBaseName(for: sourceURL)
        let suffix = L10n.string(
            "security.export.suggested_suffix",
            defaultValue: "protected"
        )
        return "\(base)-\(suffix).pdf"
    }

    @discardableResult
    static func export(
        document: PDFDocument,
        sourceURL: URL?,
        to destination: URL,
        userPassword: String
    ) throws -> URL {
        try PDFPasswordPolicy.validate(userPassword)
        // Keep this check here even though PDFWorkspaceState performs the same
        // validation. Services, tests, and future integrations can call the
        // exporter directly and must not bypass owner authority.
        try PDFDocumentSecurityPolicy.validateCanReencrypt(document)

        let destinationAccess = SecurityScopedAccess(url: destination)
        if
            let sourceURL,
            PDFSourceFileVersion.refersToSameLocation(sourceURL, destination)
        {
            throw WorkspaceError.operationFailed(
                L10n.string("error.save_copy_same_as_original")
            )
        }

        let configuration = EncryptionConfiguration(
            password: userPassword
        )
        return try withExtendedLifetime(destinationAccess) {
            try AtomicPDFWriter.write(
                document,
                to: destination,
                writeOptions: configuration.writeOptions,
                validateSerializedDocument: configuration.validate,
                validateDestinationBeforeCommit: {
                    if
                        let sourceURL,
                        PDFSourceFileVersion.refersToSameLocation(sourceURL, destination)
                    {
                        throw WorkspaceError.operationFailed(
                            L10n.string("error.save_copy_same_as_original")
                        )
                    }
                },
                allowDirectOverwriteFallback: false
            )
        }
    }
}

/// OCR runs from a URL on a detached worker. For an owner-unlocked encrypted
/// PDF, make a process-local, passwordless snapshot with user-only filesystem
/// permissions so PDFKit can reopen it without retaining the person's secret.
/// The caller removes this random temporary file when OCR finishes or cancels.
enum PDFOCRSnapshotWriter {
    static func write(_ document: PDFDocument, to url: URL) throws {
        let wrote: Bool
        if document.isEncrypted {
            try PDFDocumentSecurityPolicy.validateCanReencrypt(document)
            let encryptionLengthKey = PDFDocumentWriteOption(
                rawValue: kCGPDFContextEncryptionKeyLength as String
            )
            wrote = document.write(
                to: url,
                withOptions: [
                    .ownerPasswordOption: "",
                    .userPasswordOption: "",
                    encryptionLengthKey: NSNumber(value: 128)
                ]
            )
        } else {
            wrote = document.write(to: url)
        }

        guard wrote else {
            throw WorkspaceError.operationFailed(L10n.string("error.ocr_snapshot"))
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
            guard
                let reopened = PDFDocument(url: url),
                !reopened.isLocked,
                reopened.pageCount == document.pageCount
            else {
                throw WorkspaceError.operationFailed(L10n.string("error.ocr_snapshot"))
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
