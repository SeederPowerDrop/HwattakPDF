// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Immutable PDF generations plus an atomically replaced small manifest.
/// A failed/interrupted snapshot never replaces the user's original document.
struct PDFRecoveryStore {
    static let enabledKey = "recovery.automatic.enabled"
    static let maximumSnapshotBytes = 256 * 1_024 * 1_024
    let directory: URL

    struct Record: Codable, Identifiable {
        let id: UUID
        let fileName: String
        let displayName: String
        let updatedAt: Date
        let pageCount: Int
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HwattakPDF/Recovery", isDirectory: true)
    }

    func records() -> [Record] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 65_536,
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  url.deletingPathExtension().lastPathComponent == record.id.uuidString,
                  record.fileName == URL(fileURLWithPath: record.fileName).lastPathComponent,
                  record.fileName.hasSuffix(".pdf"),
                  UUID(uuidString: String(record.fileName.dropLast(4))) != nil,
                  record.pageCount > 0,
                  FileManager.default.fileExists(atPath: pdfURL(for: record).path) else { return nil }
            return record
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func pdfURL(for record: Record) -> URL { directory.appendingPathComponent(record.fileName) }

    func makeWorkingCopy(of record: Record) throws -> URL {
        let folder = directory.appendingPathComponent("Working", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent("Recovered.pdf")
        do {
            try FileManager.default.copyItem(at: pdfURL(for: record), to: copy)
            return copy
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func isWorkingCopy(_ url: URL) -> Bool {
        url.lastPathComponent == "Recovered.pdf"
            && UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil
            && url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == directory.appendingPathComponent("Working").standardizedFileURL
    }

    func removeWorkingCopy(at url: URL) {
        guard isWorkingCopy(url) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @MainActor
    func save(document: PDFDocument, id: UUID, displayName: String) throws {
        guard !document.isEncrypted, document.pageCount > 0 else { throw WorkspaceError.noDocument }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let existing = records()
        let previous = existing.first { $0.id == id }
        guard previous != nil || existing.count < 32 else {
            throw WorkspaceError.operationFailed(L10n.string("recovery.limit"))
        }
        let retainedBytes = existing.reduce(Int64(0)) { total, record in
            total + Int64((try? pdfURL(for: record).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let replacedBytes = previous.flatMap { try? pdfURL(for: $0).resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        let fileName = "\(UUID().uuidString).pdf"
        let destination = directory.appendingPathComponent(fileName)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: destination) } }
        try AtomicPDFWriter.write(document, to: destination, validateStagedPDF: { url, _ in
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maximumSnapshotBytes,
                  retainedBytes - Int64(replacedBytes) + Int64(size) <= 1_024 * 1_024 * 1_024 else {
                throw WorkspaceError.operationFailed(L10n.string("recovery.limit"))
            }
        }, allowDirectOverwriteFallback: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let record = Record(id: id, fileName: fileName, displayName: String(displayName.prefix(512)),
            updatedAt: Date(), pageCount: document.pageCount)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
        published = true
        if let previous { try? FileManager.default.removeItem(at: pdfURL(for: previous)) }
    }

    func remove(id: UUID) {
        guard let record = records().first(where: { $0.id == id }) else { return }
        // Remove the manifest first; an interrupted cleanup leaves only an orphan.
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
            try? FileManager.default.removeItem(at: pdfURL(for: record))
        } catch { /* A cleanup error must not compromise the saved original. */ }
    }
}
