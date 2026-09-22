// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation

struct PluginPackageValidator {
    static let manifestFileName = "manifest.json"
    static let installationRecordFileName = "installation.json"
    static let maximumInstallationRecordBytes = 32 * 1_024
    static let allowedSourceFiles: Set<String> = [
        manifestFileName,
        "README.md",
        "LICENSE",
        "LICENSE.md",
        "icon.png"
    ]

    private let fileManager: FileManager
    private let manifestValidator: PluginManifestValidator

    init(
        fileManager: FileManager = .default,
        hostVersion: String = PluginHost.currentVersion
    ) {
        self.fileManager = fileManager
        manifestValidator = PluginManifestValidator(hostVersion: hostVersion)
    }

    func inspectSourcePackage(at sourceURL: URL) throws -> PluginPackageInspection {
        try inspectPackage(at: sourceURL, isInstalledPackage: false)
    }

    func inspectInstalledPackage(at packageURL: URL) throws -> InstalledPackageInspection {
        let inspection = try inspectPackage(at: packageURL, isInstalledPackage: true)
        let recordURL = packageURL.appendingPathComponent(Self.installationRecordFileName)
        let recordData = try boundedData(
            at: recordURL,
            maximumBytes: Self.maximumInstallationRecordBytes,
            label: Self.installationRecordFileName
        )
        let record: PluginInstallationRecord
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            record = try decoder.decode(PluginInstallationRecord.self, from: recordData)
        } catch {
            throw PluginSystemError.invalidPackage("installation record is invalid")
        }
        guard
            record.schemaVersion == HwattakPluginLimits.installationRecordSchemaVersion,
            record.manifestSHA256 == inspection.manifestDigest,
            packageURL.deletingPathExtension().lastPathComponent == inspection.manifest.identifier
        else {
            throw PluginSystemError.invalidPackage("installed manifest integrity check failed")
        }
        return InstalledPackageInspection(package: inspection, record: record)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func inspectPackage(
        at sourceURL: URL,
        isInstalledPackage: Bool
    ) throws -> PluginPackageInspection {
        guard sourceURL.pathExtension.lowercased() == "hwattakplugin" else {
            throw PluginSystemError.invalidPackage("package name must end in .hwattakplugin")
        }
        let rootValues: URLResourceValues
        do {
            rootValues = try sourceURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        } catch {
            throw PluginSystemError.invalidPackage("package cannot be inspected")
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw PluginSystemError.invalidPackage("package must be a real directory, not a link")
        }

        let maximumFiles = HwattakPluginLimits.maximumPackageFileCount
            + (isInstalledPackage ? 1 : 0)
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationFailed = false
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw PluginSystemError.invalidPackage("package contents cannot be read")
        }
        var entries: [URL] = []
        for case let entry as URL in enumerator {
            entries.append(entry)
            guard entries.count <= maximumFiles else {
                throw PluginSystemError.invalidPackage("package contains too many files")
            }
        }
        guard !enumerationFailed else {
            throw PluginSystemError.invalidPackage("package contents cannot be read")
        }
        guard !entries.isEmpty else {
            throw PluginSystemError.invalidPackage("package contains too many files")
        }
        let allowedFiles = Self.allowedSourceFiles.union(
            isInstalledPackage ? [Self.installationRecordFileName] : []
        )

        var totalBytes = 0
        var payloads: [String: Data] = [:]
        for entry in entries {
            let name = entry.lastPathComponent
            guard
                allowedFiles.contains(name),
                !name.hasPrefix("."),
                name == name.precomposedStringWithCanonicalMapping
            else {
                throw PluginSystemError.invalidPackage("unsupported package entry: \(name)")
            }
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey
                    ]
                )
            } catch {
                throw PluginSystemError.invalidPackage("package entry cannot be inspected: \(name)")
            }
            guard
                values.isRegularFile == true,
                values.isDirectory != true,
                values.isSymbolicLink != true,
                let fileSize = values.fileSize,
                fileSize >= 0
            else {
                throw PluginSystemError.invalidPackage("package entries must be regular files")
            }
            let perFileLimit: Int
            switch name {
            case Self.manifestFileName:
                perFileLimit = HwattakPluginLimits.maximumManifestBytes
            case Self.installationRecordFileName:
                perFileLimit = Self.maximumInstallationRecordBytes
            default:
                perFileLimit = HwattakPluginLimits.maximumAuxiliaryFileBytes
            }
            guard fileSize <= perFileLimit else {
                throw PluginSystemError.invalidPackage("\(name) exceeds its size limit")
            }

            let capturedData: Data?
            if !isInstalledPackage || name == Self.manifestFileName {
                let data = try boundedData(
                    at: entry,
                    maximumBytes: perFileLimit,
                    label: name
                )
                // Reconcile the preflight metadata with the exact bytes used
                // for review and installation. A package being rewritten
                // concurrently must be selected again instead of bypassing the
                // aggregate limit with stale `fileSize` values.
                guard data.count == fileSize else {
                    throw PluginSystemError.invalidPackage(
                        "\(name) changed while it was being read"
                    )
                }
                capturedData = data
            } else {
                capturedData = nil
            }

            // installation.json is small host-owned integrity metadata, not a
            // source-package payload. Keeping its separate 32 KiB ceiling lets
            // a valid source package use the advertised full 2 MiB budget.
            let measuredPackageBytes = name == Self.installationRecordFileName
                ? 0
                : (capturedData?.count ?? fileSize)
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(
                measuredPackageBytes
            )
            guard
                !overflow,
                newTotal <= HwattakPluginLimits.maximumPackageBytes
            else {
                throw PluginSystemError.invalidPackage("package exceeds its total size limit")
            }
            totalBytes = newTotal

            // Installed auxiliary files never affect behavior and need not be
            // retained in memory at launch. Source installation captures every
            // allowed byte so the later commit cannot race a source mutation.
            if let capturedData {
                payloads[name] = capturedData
            }
        }

        guard let manifestData = payloads[Self.manifestFileName] else {
            throw PluginSystemError.invalidPackage("manifest.json is missing")
        }
        if let icon = payloads["icon.png"] {
            let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
            guard icon.starts(with: pngSignature) else {
                throw PluginSystemError.invalidPackage("icon.png is not a PNG file")
            }
        }
        let manifest = try manifestValidator.decodeAndValidate(manifestData)
        return PluginPackageInspection(
            sourceURL: sourceURL,
            manifest: manifest,
            manifestDigest: Self.sha256Hex(manifestData),
            fileCount: entries.count,
            totalBytes: totalBytes,
            filePayloads: payloads
        )
    }

    private func boundedData(
        at url: URL,
        maximumBytes: Int,
        label: String
    ) throws -> Data {
        let data: Data
        do {
            // Read at most one byte beyond the ceiling. `Data(contentsOf:)`
            // would allocate the entire file before we could re-check its
            // length if an untrusted package grew after metadata preflight.
            // A copied bounded snapshot also closes the review/install TOCTOU
            // gap that a memory-mapped value would leave open.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let readLimit = maximumBytes == Int.max ? Int.max : maximumBytes + 1
            data = try handle.read(upToCount: readLimit) ?? Data()
        } catch {
            throw PluginSystemError.invalidPackage("\(label) cannot be read")
        }
        guard data.count <= maximumBytes else {
            throw PluginSystemError.invalidPackage("\(label) changed while it was being read")
        }
        return data
    }
}

struct InstalledPackageInspection {
    let package: PluginPackageInspection
    let record: PluginInstallationRecord
}
