// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VibePDF

/// Documentation and author tooling use the same package/trust validators as the app.
@MainActor
final class PluginAuthoringTests: XCTestCase {
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testCommunityPackagesAndOptionalAuthorPackage() throws {
        let environment = ProcessInfo.processInfo.environment
        let hostVersion = environment["HWATTAK_PLUGIN_HOST_VERSION"] ?? "0.8.0"
        guard PluginSemanticVersion(hostVersion) != nil else {
            XCTFail("Host version must be major.minor.patch without a suffix")
            return
        }
        let suite = "HwattakPDF.PluginAuthoring.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        // No app bundle allowlist: this command verifies community-distributable packages.
        // It neither installs the author's package nor accesses the user's plugin registry.
        let manager = PluginManager(pluginsDirectory: temporary, defaults: defaults,
            hostVersion: hostVersion, bundledPluginsDirectory: nil)
        let packages: [URL]
        if let path = environment["HWATTAK_PLUGIN_VALIDATE_PATH"], !path.isEmpty {
            packages = [URL(fileURLWithPath: path)]
        } else {
            packages = ["OfflineChecklist", "CommunityStarter", "QuickCitation", "MarkdownQuote", "ReferenceSearch"]
                .map { project.appendingPathComponent("Examples/Plugins/\($0).hwattakplugin") }
        }
        for package in packages {
            let inspection = try manager.inspectPackage(at: package)
            print("PLUGIN VALID: \(inspection.manifest.identifier) \(inspection.manifest.version); schema=\(inspection.manifest.schemaVersion); host=\(hostVersion); sha256=\(inspection.manifestDigest)")
        }
        XCTAssertTrue(manager.installedPlugins.isEmpty, "Validation must never install a package")
    }

    func testCompleteManifestExamplesInAuthorDocumentationMatchHostRules() throws {
        let documents = ["PLUGIN-DEVELOPMENT.md", "PLUGIN-DEVELOPMENT.en.md", "PLUGIN-HOST-API.md"]
        let expression = try NSRegularExpression(pattern: "(?s)```json\\s*\\n(.*?)\\n```")
        var count = 0
        for name in documents {
            let text = try String(contentsOf: project.appendingPathComponent("Documentation/\(name)"), encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                let body = try XCTUnwrap(Range(match.range(at: 1), in: text))
                _ = try PluginManifestValidator(hostVersion: "0.8.0")
                    .decodeAndValidate(Data(text[body].utf8))
                count += 1
            }
        }
        XCTAssertGreaterThanOrEqual(count, 3, "Keep at least one complete, validated example per guide")
    }
}
