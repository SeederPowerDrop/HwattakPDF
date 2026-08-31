// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation

@MainActor
final class PluginManager: ObservableObject {
    static let shared = PluginManager()
    static let disabledIdentifiersDefaultsKey = "plugins.disabledIdentifiers"
    static let preferencesDefaultsKey = "plugins.preferences.v1"

    @Published private(set) var installedPlugins: [InstalledPlugin] = []
    @Published private(set) var bundledPlugins: [PluginPackageInspection] = []
    @Published private(set) var loadIssues: [PluginLoadIssue] = []
    @Published private(set) var preferencesByIdentifier: [String: PluginPreferences] = [:]

    let pluginsDirectory: URL

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let validator: PluginPackageValidator
    private let now: () -> Date
    private let bundledPluginsDirectory: URL?

    init(
        pluginsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        hostVersion: String = PluginHost.currentVersion,
        bundledPluginsDirectory: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("BundledPlugins", isDirectory: true),
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.now = now
        self.bundledPluginsDirectory = bundledPluginsDirectory
        validator = PluginPackageValidator(
            fileManager: fileManager,
            hostVersion: hostVersion
        )
        if let pluginsDirectory {
            self.pluginsDirectory = pluginsDirectory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.pluginsDirectory = applicationSupport
                .appendingPathComponent("HwattakPDF", isDirectory: true)
                .appendingPathComponent("Plugins", isDirectory: true)
        }
        preferencesByIdentifier = Self.loadPreferences(from: defaults)
        refresh()
    }

    var enabledPlugins: [InstalledPlugin] {
        installedPlugins.filter(\.isEnabled)
    }

    var enabledActionCount: Int {
        enabledPlugins.reduce(0) { $0 + $1.manifest.actions.count }
    }

    var availableBundledPlugins: [PluginPackageInspection] {
        bundledPlugins.filter { bundled in
            !installedPlugins.contains(where: {
                $0.id == bundled.manifest.identifier
                    && $0.manifestDigest == bundled.manifestDigest
            })
        }
    }

    func isInstalled(identifier: String) -> Bool {
        fileManager.fileExists(atPath: packageURL(for: identifier).path)
    }

    func inspectPackage(at url: URL) throws -> PluginPackageInspection {
        let access = SecurityScopedAccess(url: url)
        defer { _ = access }
        let inspection = try validator.inspectSourcePackage(at: url)
        // Reject reserved identities and host-owned web panels before the
        // review sheet can present an untrusted package as installable. The
        // same check remains at install and load boundaries below so callers
        // cannot bypass it by retaining or constructing an inspection.
        try requireTrustedBundledIdentityIfNeeded(inspection)
        return inspection
    }

    func install(
        _ inspection: PluginPackageInspection,
        replacingExisting: Bool
    ) throws {
        try requireTrustedBundledIdentityIfNeeded(inspection)
        try ensurePluginsDirectory()
        let identifier = inspection.manifest.identifier
        let destination = packageURL(for: identifier)
        let alreadyExists = fileManager.fileExists(atPath: destination.path)
        if alreadyExists, !replacingExisting {
            throw PluginSystemError.packageAlreadyInstalled(
                inspection.manifest.displayName
            )
        }
        if !alreadyExists {
            // Invalid packages are quarantined rather than loaded, but they
            // still consume disk and scan budget. Count every visible package
            // entry so a directory full of malformed bundles cannot bypass the
            // process-wide registry ceiling.
            let occupiedSlots = try installedPackageEntryCount()
            if occupiedSlots >= HwattakPluginLimits.maximumInstalledPluginCount {
                throw PluginSystemError.pluginLimitReached(
                    HwattakPluginLimits.maximumInstalledPluginCount
                )
            }
        }

        let temporary = pluginsDirectory.appendingPathComponent(
            ".install-\(UUID().uuidString)",
            isDirectory: true
        )
        let backup = backupURL(for: identifier)
        try? fileManager.removeItem(at: temporary)
        try fileManager.createDirectory(
            at: temporary,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var temporaryExists = true
        defer {
            if temporaryExists {
                try? fileManager.removeItem(at: temporary)
            }
        }

        do {
            for (name, data) in inspection.filePayloads.sorted(by: { $0.key < $1.key }) {
                guard PluginPackageValidator.allowedSourceFiles.contains(name) else {
                    throw PluginSystemError.installationFailed("unexpected staged file")
                }
                let destinationFile = temporary.appendingPathComponent(name)
                try data.write(to: destinationFile, options: [.atomic])
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destinationFile.path
                )
            }

            let record = PluginInstallationRecord(
                schemaVersion: HwattakPluginLimits.installationRecordSchemaVersion,
                manifestSHA256: inspection.manifestDigest,
                installedAt: now()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let recordData = try encoder.encode(record)
            let recordURL = temporary.appendingPathComponent(
                PluginPackageValidator.installationRecordFileName
            )
            try recordData.write(to: recordURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: recordURL.path
            )

            // Validate the exact staged result before it can replace an active
            // version. The directory suffix is part of the installed identity.
            let stagedPackage = pluginsDirectory.appendingPathComponent(
                "\(identifier).hwattakplugin",
                isDirectory: true
            )
            // The validator checks the directory name. Give the staging bytes
            // their final name inside a separate staging parent.
            let stagingParent = pluginsDirectory.appendingPathComponent(
                ".staging-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: stagingParent,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: stagingParent) }
            let namedStagingPackage = stagingParent.appendingPathComponent(
                stagedPackage.lastPathComponent,
                isDirectory: true
            )
            try fileManager.moveItem(at: temporary, to: namedStagingPackage)
            temporaryExists = false
            _ = try validator.inspectInstalledPackage(at: namedStagingPackage)

            if alreadyExists {
                try? fileManager.removeItem(at: backup)
                try fileManager.moveItem(at: destination, to: backup)
                do {
                    try fileManager.moveItem(at: namedStagingPackage, to: destination)
                    try? fileManager.removeItem(at: backup)
                } catch {
                    if !fileManager.fileExists(atPath: destination.path) {
                        try? fileManager.moveItem(at: backup, to: destination)
                    }
                    throw error
                }
            } else {
                try fileManager.moveItem(at: namedStagingPackage, to: destination)
            }
        } catch let error as PluginSystemError {
            throw error
        } catch {
            throw PluginSystemError.installationFailed(error.localizedDescription)
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool, identifier: String) throws {
        guard let index = installedPlugins.firstIndex(where: { $0.id == identifier }) else {
            throw PluginSystemError.pluginNotFound(identifier)
        }
        guard installedPlugins[index].isEnabled != enabled else { return }
        installedPlugins[index].isEnabled = enabled
        persistDisabledIdentifiers()
    }

    func preferences(for identifier: String) -> PluginPreferences {
        preferencesByIdentifier[identifier] ?? .default
    }

    func setPreferences(_ preferences: PluginPreferences, identifier: String) throws {
        guard installedPlugins.contains(where: { $0.id == identifier }) else {
            throw PluginSystemError.pluginNotFound(identifier)
        }
        if preferences == .default {
            preferencesByIdentifier.removeValue(forKey: identifier)
        } else {
            preferencesByIdentifier[identifier] = preferences
        }
        persistPreferences()
    }

    func resetPreferences(identifier: String) throws {
        guard installedPlugins.contains(where: { $0.id == identifier }) else {
            throw PluginSystemError.pluginNotFound(identifier)
        }
        preferencesByIdentifier.removeValue(forKey: identifier)
        persistPreferences()
    }

    func configurationKind(for plugin: InstalledPlugin) -> PluginConfigurationKind {
        guard bundledPlugins.contains(where: {
            $0.manifest.identifier == plugin.id
                && $0.manifestDigest == plugin.manifestDigest
        }) else {
            return .generic
        }
        if plugin.manifest.actions.contains(where: { $0.output == .translatePanel }) {
            return .translation
        }
        if plugin.manifest.actions.contains(where: { $0.output == .youtubePanel }) {
            return .youtube
        }
        if plugin.manifest.actions.contains(where: { $0.output == .browserPanel }) {
            return .browser
        }
        return .generic
    }

    func configurationKind(
        identifier: String,
        manifestDigest: String
    ) -> PluginConfigurationKind {
        guard let plugin = installedPlugins.first(where: {
            $0.id == identifier && $0.manifestDigest == manifestDigest
        }) else {
            return .generic
        }
        return configurationKind(for: plugin)
    }

    func uninstall(identifier: String) throws {
        guard installedPlugins.contains(where: { $0.id == identifier }) else {
            throw PluginSystemError.pluginNotFound(identifier)
        }
        let destination = packageURL(for: identifier)
        do {
            try fileManager.removeItem(at: destination)
        } catch {
            throw PluginSystemError.installationFailed(error.localizedDescription)
        }
        var disabled = disabledIdentifiers
        disabled.remove(identifier)
        defaults.set(Array(disabled).sorted(), forKey: Self.disabledIdentifiersDefaultsKey)
        preferencesByIdentifier.removeValue(forKey: identifier)
        persistPreferences()
        refresh()
    }

    func refresh() {
        do {
            try ensurePluginsDirectory()
            recoverInterruptedUpdatesAndCleanStaging()
            let bundledResult = inspectBundledPlugins()
            let disabled = disabledIdentifiers
            let entries = try fileManager.contentsOfDirectory(
                at: pluginsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            let packages = entries
                .filter { $0.pathExtension.lowercased() == "hwattakplugin" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            var loaded: [InstalledPlugin] = []
            var issues: [PluginLoadIssue] = []
            for package in packages.prefix(HwattakPluginLimits.maximumInstalledPluginCount) {
                do {
                    let inspection = try validator.inspectInstalledPackage(at: package)
                    try requireTrustedBundledIdentityIfNeeded(
                        inspection.package,
                        trustedBundledPlugins: bundledResult.plugins
                    )
                    loaded.append(
                        InstalledPlugin(
                            manifest: inspection.package.manifest,
                            installURL: package,
                            manifestDigest: inspection.package.manifestDigest,
                            installedAt: inspection.record.installedAt,
                            isEnabled: !disabled.contains(
                                inspection.package.manifest.identifier
                            )
                        )
                    )
                } catch {
                    issues.append(
                        PluginLoadIssue(
                            packageName: package.lastPathComponent,
                            message: error.localizedDescription
                        )
                    )
                }
            }
            if packages.count > HwattakPluginLimits.maximumInstalledPluginCount {
                for package in packages.dropFirst(HwattakPluginLimits.maximumInstalledPluginCount) {
                    issues.append(
                        PluginLoadIssue(
                            packageName: package.lastPathComponent,
                            message: PluginSystemError.pluginLimitReached(
                                HwattakPluginLimits.maximumInstalledPluginCount
                            ).localizedDescription
                        )
                    )
                }
            }
            installedPlugins = loaded.sorted {
                $0.manifest.displayName.localizedStandardCompare($1.manifest.displayName)
                    == .orderedAscending
            }
            bundledPlugins = bundledResult.plugins
            issues.append(contentsOf: bundledResult.issues)
            loadIssues = issues
        } catch {
            installedPlugins = []
            bundledPlugins = inspectBundledPlugins().plugins
            loadIssues = [
                PluginLoadIssue(
                    packageName: pluginsDirectory.lastPathComponent,
                    message: error.localizedDescription
                )
            ]
        }
    }

    private func inspectBundledPlugins() -> (
        plugins: [PluginPackageInspection],
        issues: [PluginLoadIssue]
    ) {
        guard let bundledPluginsDirectory,
              let entries = try? fileManager.contentsOfDirectory(
                  at: bundledPluginsDirectory,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return ([], [])
        }

        var plugins: [PluginPackageInspection] = []
        var issues: [PluginLoadIssue] = []
        for package in entries
            .filter({ $0.pathExtension.lowercased() == "hwattakplugin" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        {
            do {
                plugins.append(try validator.inspectSourcePackage(at: package))
            } catch {
                issues.append(
                    PluginLoadIssue(
                        packageName: "BundledPlugins/\(package.lastPathComponent)",
                        message: error.localizedDescription
                    )
                )
            }
        }
        return (
            plugins.sorted {
                $0.manifest.displayName.localizedStandardCompare($1.manifest.displayName)
                    == .orderedAscending
            },
            issues
        )
    }

    /// Web-backed panels and the `dev.hwattakpdf.*` first-party namespace are
    /// host privileges, not a general community extension surface. A matching
    /// package must use the exact manifest bytes shipped in this application.
    /// Ordinary v1 declarative actions under third-party identifiers remain
    /// installable from trusted sources.
    private func requireTrustedBundledIdentityIfNeeded(
        _ inspection: PluginPackageInspection,
        trustedBundledPlugins: [PluginPackageInspection]? = nil
    ) throws {
        let containsPanel = inspection.manifest.actions.contains {
            switch $0.output {
            case .translatePanel, .youtubePanel, .browserPanel:
                true
            case .showText, .copyText, .openURL:
                false
            }
        }
        // `dev.hwattakpdf.*` is the identity namespace used by the three
        // first-party packages. Reserve it independently of output type: an
        // otherwise harmless schema-1 package with the same identifier could
        // replace a first-party install and inherit its localized name/action
        // presentation if only panel outputs were protected.
        let claimsBundledIdentity = inspection.manifest.identifier.hasPrefix(
            "dev.hwattakpdf."
        )
        guard claimsBundledIdentity || containsPanel else { return }

        let trusted = trustedBundledPlugins ?? inspectBundledPlugins().plugins
        guard trusted.contains(where: {
            $0.manifest.identifier == inspection.manifest.identifier
                && $0.manifestDigest == inspection.manifestDigest
        }) else {
            throw PluginSystemError.invalidPackage(
                "reserved HwattakPDF identities and web panel plug-ins must exactly match a HwattakPDF bundled package"
            )
        }
    }

    private var disabledIdentifiers: Set<String> {
        Set(defaults.stringArray(forKey: Self.disabledIdentifiersDefaultsKey) ?? [])
    }

    private func persistDisabledIdentifiers() {
        let disabled = installedPlugins.filter { !$0.isEnabled }.map(\.id).sorted()
        defaults.set(disabled, forKey: Self.disabledIdentifiersDefaultsKey)
    }

    private static func loadPreferences(
        from defaults: UserDefaults
    ) -> [String: PluginPreferences] {
        guard
            let data = defaults.data(forKey: preferencesDefaultsKey),
            data.count <= PluginPreferences.maximumPersistedBytes,
            let decoded = try? JSONDecoder().decode(
                [String: PluginPreferences].self,
                from: data
            )
        else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: decoded
                .sorted(by: { $0.key < $1.key })
                .prefix(HwattakPluginLimits.maximumInstalledPluginCount)
                .map { ($0.key, $0.value) }
        )
    }

    private func persistPreferences() {
        guard !preferencesByIdentifier.isEmpty else {
            defaults.removeObject(forKey: Self.preferencesDefaultsKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(preferencesByIdentifier),
           data.count <= PluginPreferences.maximumPersistedBytes {
            defaults.set(data, forKey: Self.preferencesDefaultsKey)
        }
    }

    private func ensurePluginsDirectory() throws {
        try fileManager.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func packageURL(for identifier: String) -> URL {
        pluginsDirectory.appendingPathComponent(
            "\(identifier).hwattakplugin",
            isDirectory: true
        )
    }

    private func backupURL(for identifier: String) -> URL {
        pluginsDirectory.appendingPathComponent(
            ".\(identifier).backup.hwattakplugin",
            isDirectory: true
        )
    }

    private func installedPackageEntryCount() throws -> Int {
        try fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .lazy
        .filter { $0.pathExtension.lowercased() == "hwattakplugin" }
        .count
    }

    private func recoverInterruptedUpdatesAndCleanStaging() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(".install-") || name.hasPrefix(".staging-") {
                try? fileManager.removeItem(at: entry)
                continue
            }
            let prefix = "."
            let suffix = ".backup.hwattakplugin"
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let start = name.index(after: name.startIndex)
            let end = name.index(name.endIndex, offsetBy: -suffix.count)
            let identifier = String(name[start..<end])
            let destination = packageURL(for: identifier)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: entry)
            } else {
                try? fileManager.moveItem(at: entry, to: destination)
            }
        }
    }
}
