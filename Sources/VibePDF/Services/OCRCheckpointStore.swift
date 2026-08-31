// SPDX-License-Identifier: MPL-2.0

import Foundation

struct OCRCheckpointStore {
    let directory: URL
    private let legacyDirectory: URL?

    private static let storageSchemaVersion = 1

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
            self.legacyDirectory = nil
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.directory = applicationSupport
                .appendingPathComponent("HwattakPDF", isDirectory: true)
                .appendingPathComponent("OCR Checkpoints", isDirectory: true)
            self.legacyDirectory = applicationSupport
                .appendingPathComponent("VibePDF", isDirectory: true)
                .appendingPathComponent("OCR Checkpoints", isDirectory: true)
        }
    }

    func load(
        fingerprint: String,
        pageCount: Int,
        configurationFingerprint: String = "default"
    ) -> OCRCheckpoint? {
        if let checkpoint = loadIncremental(
            fingerprint: fingerprint,
            pageCount: pageCount,
            configurationFingerprint: configurationFingerprint
        ) {
            return checkpoint
        }

        if let legacy = loadLegacyCheckpoint(
            fingerprint: fingerprint,
            pageCount: pageCount,
            configurationFingerprint: configurationFingerprint
        ) {
            // Migration is best effort. A read-only or full disk must not make an
            // otherwise valid legacy checkpoint unusable for the current run.
            try? save(legacy)
            return legacy
        }

        // The product rename moved new checkpoints to Application Support/HwattakPDF.
        // Read the former location once and copy any valid checkpoint forward.
        guard
            let legacyDirectory,
            let legacy = OCRCheckpointStore(directory: legacyDirectory).load(
                fingerprint: fingerprint,
                pageCount: pageCount,
                configurationFingerprint: configurationFingerprint
            )
        else {
            return nil
        }
        try? save(legacy)
        return legacy
    }

    /// Writes a complete checkpoint snapshot.
    ///
    /// This remains available for migrations and small callers. OCR itself uses
    /// `savePage(_:for:)`, which writes only the newly completed page.
    func save(_ checkpoint: OCRCheckpoint) throws {
        try validate(checkpoint)

        let fileManager = FileManager.default
        let checkpointDirectory = checkpointDirectoryURL(
            fingerprint: checkpoint.documentFingerprint,
            pageCount: checkpoint.pageCount,
            configurationFingerprint: checkpoint.configurationFingerprint
        )
        let generationsDirectory = checkpointDirectory
            .appendingPathComponent("generations", isDirectory: true)
        let generation = UUID().uuidString
        let pagesDirectory = generationsDirectory
            .appendingPathComponent(generation, isDirectory: true)
            .appendingPathComponent("pages", isDirectory: true)
        let manifest = StorageManifest(checkpoint: checkpoint, generation: generation)

        try fileManager.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
        do {
            for (index, result) in checkpoint.pages.sorted(by: { $0.key < $1.key }) {
                try write(
                    result,
                    to: pagesDirectory.appendingPathComponent(pageFileName(index))
                )
            }

            // The manifest is the commit point. Until this atomic write succeeds,
            // readers continue using the previous generation in full.
            try write(
                manifest,
                to: checkpointDirectory.appendingPathComponent("manifest.json")
            )
        } catch {
            try? fileManager.removeItem(
                at: generationsDirectory.appendingPathComponent(generation, isDirectory: true)
            )
            throw error
        }

        removeInactiveGenerations(
            in: generationsDirectory,
            keeping: generation
        )
    }

    /// Atomically persists one completed page without re-encoding prior pages.
    /// This makes checkpoint write volume linear in the number of OCR pages.
    func savePage(_ result: OCRPageResult, for checkpoint: OCRCheckpoint) throws {
        try validateIdentity(checkpoint)
        guard
            result.pageIndex >= 0,
            result.pageIndex < checkpoint.pageCount
        else {
            throw CheckpointStorageError.invalidPageIndex(result.pageIndex)
        }

        let manifest = try activeManifest(for: checkpoint)
        let pagesDirectory = pagesDirectoryURL(for: checkpoint, manifest: manifest)
        try FileManager.default.createDirectory(
            at: pagesDirectory,
            withIntermediateDirectories: true
        )
        try write(
            result,
            to: pagesDirectory.appendingPathComponent(pageFileName(result.pageIndex))
        )
    }

    /// Location used by schema-2 versions that stored the whole checkpoint in
    /// one JSON file. Kept so existing installs can migrate on first load.
    func checkpointURL(
        fingerprint: String,
        configurationFingerprint: String = "default"
    ) -> URL {
        directory.appendingPathComponent("\(fingerprint)-\(configurationFingerprint).json")
    }

    func checkpointDirectoryURL(
        fingerprint: String,
        pageCount: Int,
        configurationFingerprint: String = "default"
    ) -> URL {
        directory.appendingPathComponent(
            "\(fingerprint)-\(configurationFingerprint)-\(pageCount).checkpoint",
            isDirectory: true
        )
    }

    private func loadIncremental(
        fingerprint: String,
        pageCount: Int,
        configurationFingerprint: String
    ) -> OCRCheckpoint? {
        let checkpointDirectory = checkpointDirectoryURL(
            fingerprint: fingerprint,
            pageCount: pageCount,
            configurationFingerprint: configurationFingerprint
        )
        let manifestURL = checkpointDirectory.appendingPathComponent("manifest.json")
        guard
            let manifest: StorageManifest = decode(from: manifestURL),
            manifest.isValid(
                fingerprint: fingerprint,
                pageCount: pageCount,
                configurationFingerprint: configurationFingerprint
            )
        else {
            return nil
        }

        let pagesDirectory = checkpointDirectory
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(manifest.generation, isDirectory: true)
            .appendingPathComponent("pages", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: pagesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var checkpoint = OCRCheckpoint(
            documentFingerprint: fingerprint,
            pageCount: pageCount,
            configurationFingerprint: configurationFingerprint
        )
        checkpoint.updatedAt = manifest.baselineUpdatedAt

        for file in files where file.pathExtension == "json" {
            guard
                let fileIndex = Int(file.deletingPathExtension().lastPathComponent),
                fileIndex >= 0,
                fileIndex < pageCount,
                let result: OCRPageResult = decode(from: file),
                result.pageIndex == fileIndex
            else {
                // A damaged page checkpoint is treated as incomplete. The next
                // OCR run safely recomputes only that page.
                continue
            }
            checkpoint.pages[fileIndex] = result
            if result.completedAt > checkpoint.updatedAt {
                checkpoint.updatedAt = result.completedAt
            }
        }
        return checkpoint
    }

    private func loadLegacyCheckpoint(
        fingerprint: String,
        pageCount: Int,
        configurationFingerprint: String
    ) -> OCRCheckpoint? {
        let schema2URL = checkpointURL(
            fingerprint: fingerprint,
            configurationFingerprint: configurationFingerprint
        )
        if
            let checkpoint: OCRCheckpoint = decode(from: schema2URL),
            checkpoint.schemaVersion == 2,
            checkpoint.documentFingerprint == fingerprint,
            checkpoint.configurationFingerprint == configurationFingerprint,
            checkpoint.pageCount == pageCount,
            isValidPages(checkpoint.pages, pageCount: pageCount)
        {
            return checkpoint
        }

        // Schema 1 predated configuration fingerprints and used
        // `<document fingerprint>.json`. Preserve its former resume behavior by
        // adopting it into the currently requested configuration on migration.
        let schema1URL = directory.appendingPathComponent("\(fingerprint).json")
        guard
            let legacy: LegacyCheckpointV1 = decode(from: schema1URL),
            legacy.schemaVersion == 1,
            legacy.documentFingerprint == fingerprint,
            legacy.pageCount == pageCount,
            isValidPages(legacy.pages, pageCount: pageCount)
        else {
            return nil
        }

        var checkpoint = OCRCheckpoint(
            documentFingerprint: fingerprint,
            pageCount: pageCount,
            configurationFingerprint: configurationFingerprint
        )
        checkpoint.pages = legacy.pages
        checkpoint.updatedAt = legacy.updatedAt
        return checkpoint
    }

    private func activeManifest(for checkpoint: OCRCheckpoint) throws -> StorageManifest {
        let checkpointDirectory = checkpointDirectoryURL(
            fingerprint: checkpoint.documentFingerprint,
            pageCount: checkpoint.pageCount,
            configurationFingerprint: checkpoint.configurationFingerprint
        )
        let manifestURL = checkpointDirectory.appendingPathComponent("manifest.json")
        if
            let manifest: StorageManifest = decode(from: manifestURL),
            manifest.isValid(
                fingerprint: checkpoint.documentFingerprint,
                pageCount: checkpoint.pageCount,
                configurationFingerprint: checkpoint.configurationFingerprint
            )
        {
            return manifest
        }

        let fileManager = FileManager.default
        let generation = UUID().uuidString
        let manifest = StorageManifest(checkpoint: checkpoint, generation: generation)
        let generationsDirectory = checkpointDirectory
            .appendingPathComponent("generations", isDirectory: true)
        let pagesDirectory = generationsDirectory
            .appendingPathComponent(generation, isDirectory: true)
            .appendingPathComponent("pages", isDirectory: true)
        try fileManager.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
        do {
            try write(manifest, to: manifestURL)
        } catch {
            try? fileManager.removeItem(
                at: generationsDirectory.appendingPathComponent(generation, isDirectory: true)
            )
            throw error
        }
        removeInactiveGenerations(in: generationsDirectory, keeping: generation)
        return manifest
    }

    private func pagesDirectoryURL(
        for checkpoint: OCRCheckpoint,
        manifest: StorageManifest
    ) -> URL {
        checkpointDirectoryURL(
            fingerprint: checkpoint.documentFingerprint,
            pageCount: checkpoint.pageCount,
            configurationFingerprint: checkpoint.configurationFingerprint
        )
        .appendingPathComponent("generations", isDirectory: true)
        .appendingPathComponent(manifest.generation, isDirectory: true)
        .appendingPathComponent("pages", isDirectory: true)
    }

    private func removeInactiveGenerations(in directory: URL, keeping active: String) {
        guard let generations = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for generation in generations where generation.lastPathComponent != active {
            try? FileManager.default.removeItem(at: generation)
        }
    }

    private func validate(_ checkpoint: OCRCheckpoint) throws {
        try validateIdentity(checkpoint)
        guard
            isValidPages(checkpoint.pages, pageCount: checkpoint.pageCount)
        else {
            throw CheckpointStorageError.invalidCheckpoint
        }
    }

    private func validateIdentity(_ checkpoint: OCRCheckpoint) throws {
        guard checkpoint.schemaVersion == 2, checkpoint.pageCount >= 0 else {
            throw CheckpointStorageError.invalidCheckpoint
        }
    }

    private func isValidPages(
        _ pages: [Int: OCRPageResult],
        pageCount: Int
    ) -> Bool {
        pages.allSatisfy { index, result in
            index >= 0 && index < pageCount && result.pageIndex == index
        }
    }

    private func pageFileName(_ index: Int) -> String {
        String(format: "%08d.json", index)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func decode<Value: Decodable>(from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Value.self, from: data)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension OCRCheckpointStore {
    struct StorageManifest: Codable {
        let storageSchemaVersion: Int
        let checkpointSchemaVersion: Int
        let documentFingerprint: String
        let configurationFingerprint: String
        let pageCount: Int
        let generation: String
        let baselineUpdatedAt: Date

        init(checkpoint: OCRCheckpoint, generation: String) {
            storageSchemaVersion = OCRCheckpointStore.storageSchemaVersion
            checkpointSchemaVersion = checkpoint.schemaVersion
            documentFingerprint = checkpoint.documentFingerprint
            configurationFingerprint = checkpoint.configurationFingerprint
            pageCount = checkpoint.pageCount
            self.generation = generation
            baselineUpdatedAt = checkpoint.updatedAt
        }

        func isValid(
            fingerprint: String,
            pageCount: Int,
            configurationFingerprint: String
        ) -> Bool {
            storageSchemaVersion == OCRCheckpointStore.storageSchemaVersion
                && checkpointSchemaVersion == 2
                && documentFingerprint == fingerprint
                && self.configurationFingerprint == configurationFingerprint
                && self.pageCount == pageCount
                && !generation.isEmpty
        }
    }

    struct LegacyCheckpointV1: Codable {
        let schemaVersion: Int
        let documentFingerprint: String
        let pageCount: Int
        let pages: [Int: OCRPageResult]
        let updatedAt: Date
    }

    enum CheckpointStorageError: LocalizedError {
        case invalidCheckpoint
        case invalidPageIndex(Int)

        var errorDescription: String? {
            switch self {
            case .invalidCheckpoint:
                L10n.string("error.ocr_checkpoint")
            case let .invalidPageIndex(index):
                L10n.format("error.ocr_checkpoint_page", index + 1)
            }
        }
    }
}
