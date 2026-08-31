// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
@testable import VibePDF

@MainActor
final class PluginSystemTests: XCTestCase {
    private var testRoot: URL!
    private var pluginsDirectory: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let nonce = UUID().uuidString
        testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-PluginSystemTests-\(nonce)",
            isDirectory: true
        )
        pluginsDirectory = testRoot.appendingPathComponent("Installed", isDirectory: true)
        defaultsSuiteName = "HwattakPDF.PluginSystemTests.\(nonce)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.createDirectory(
            at: testRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDown() {
        if let defaultsSuiteName {
            defaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        defaults = nil
        defaultsSuiteName = nil
        pluginsDirectory = nil
        testRoot = nil
        super.tearDown()
    }

    func testSemanticVersionsAndMinimumHostCompatibilityAreStrict() throws {
        let valid = [
            "0.0.0",
            "1.2.3",
            "999999.999999.999999"
        ]
        for value in valid {
            XCTAssertNotNil(PluginSemanticVersion(value), "Expected valid semver: \(value)")
        }

        let invalid = [
            "1",
            "1.2",
            "1.2.3.4",
            "01.2.3",
            "1.02.3",
            "1.2.03",
            "1.2.-3",
            "1.2.3-beta",
            "1000000.0.0"
        ]
        for value in invalid {
            XCTAssertNil(PluginSemanticVersion(value), "Expected invalid semver: \(value)")
        }

        XCTAssertLessThan(
            try XCTUnwrap(PluginSemanticVersion("1.9.9")),
            try XCTUnwrap(PluginSemanticVersion("2.0.0"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(PluginSemanticVersion("2.1.9")),
            try XCTUnwrap(PluginSemanticVersion("2.2.0"))
        )

        let validator = PluginManifestValidator(hostVersion: "2.4.0")
        XCTAssertNoThrow(
            try validator.validate(makeManifest(minimumHostVersion: "2.4.0"))
        )
        do {
            try validator.validate(makeManifest(minimumHostVersion: "2.4.1"))
            XCTFail("A newer minimum host version must be rejected")
        } catch PluginSystemError.incompatibleHost(let required, let current) {
            XCTAssertEqual(required, "2.4.1")
            XCTAssertEqual(current, "2.4.0")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        assertInvalidManifest(
            try encodedManifest(makeManifest(version: "1.0")),
            validator: validator,
            contains: "version must use major.minor.patch"
        )
        assertInvalidManifest(
            try encodedManifest(makeManifest(minimumHostVersion: "2.4")),
            validator: validator,
            contains: "minimumHostVersion must use major.minor.patch"
        )
    }

    func testPluginPreferencesDecodeDefensivelyAndSearchAcrossUsefulMetadata() throws {
        let encoded = Data(#"""
        {
            "translationProvider": "unknown-provider",
            "translationTargetLanguageCode": "not-a-language",
            "translationShowsSource": false,
            "youtubeLoadsStartPage": false,
            "browserSearchEngine": "unknown-engine",
            "browserLoadsStartPage": false
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(PluginPreferences.self, from: encoded)

        XCTAssertEqual(decoded.translationProvider, .google)
        XCTAssertEqual(
            decoded.translationTargetLanguageCode,
            PluginPreferences.followAppLanguageCode
        )
        XCTAssertFalse(decoded.translationShowsSource)
        XCTAssertFalse(decoded.youtubeLoadsStartPage)
        XCTAssertEqual(decoded.browserSearchEngine, .google)
        XCTAssertFalse(decoded.browserLoadsStartPage)

        let manifest = PluginManifest(
            schemaVersion: HwattakPluginLimits.legacyManifestSchemaVersion,
            identifier: "org.example.study-helper",
            displayName: "Study Helper",
            version: "1.0.0",
            author: "PDF Learners",
            description: "Creates concise citations for research papers",
            minimumHostVersion: nil,
            capabilities: [],
            actions: [makeAction()]
        )
        XCTAssertTrue(PluginManagerSearch.matches(manifest, query: "study"))
        XCTAssertTrue(PluginManagerSearch.matches(manifest, query: "learners"))
        XCTAssertTrue(PluginManagerSearch.matches(manifest, query: "citations"))
        XCTAssertTrue(PluginManagerSearch.matches(manifest, query: "org.example"))
        XCTAssertTrue(PluginManagerSearch.matches(manifest, query: "   "))
        XCTAssertFalse(PluginManagerSearch.matches(manifest, query: "youtube"))
    }

    func testManifestDecoderRejectsUnknownRootAndActionFields() throws {
        let validator = PluginManifestValidator(hostVersion: "1.0.0")
        let unknownRoot = try mutatedManifestData { root in
            root["networkAccess"] = true
        }
        assertInvalidManifest(
            unknownRoot,
            validator: validator,
            contains: "unknown manifest field: networkAccess"
        )

        let unknownAction = try mutatedManifestData { root in
            var actions = root["actions"] as! [[String: Any]]
            actions[0]["script"] = "run-me"
            root["actions"] = actions
        }
        assertInvalidManifest(
            unknownAction,
            validator: validator,
            contains: "unknown action 1 field: script"
        )

        let duplicateActions = makeManifest(actions: [
            makeAction(id: "same"),
            makeAction(id: "same", title: "Duplicate")
        ])
        assertInvalidManifest(
            try encodedManifest(duplicateActions),
            validator: validator,
            contains: "duplicate action id"
        )

        let unknownCapability = try mutatedManifestData { root in
            root["capabilities"] = ["executeCode"]
        }
        assertInvalidManifest(
            unknownCapability,
            validator: validator,
            contains: "required fields or field types are invalid"
        )

        assertInvalidManifest(
            try encodedManifest(makeManifest(identifier: "com.hwattakpdf.lookalike")),
            validator: validator,
            contains: "namespaces are reserved"
        )

        let disguisedName = try mutatedManifestData { root in
            root["displayName"] = "Trusted\u{202E}nigulp"
        }
        assertInvalidManifest(
            disguisedName,
            validator: validator,
            contains: "contains control characters"
        )

        let controlledTemplate = try mutatedManifestData { root in
            var actions = root["actions"] as! [[String: Any]]
            actions[0]["template"] = "Visible\u{2066}hidden"
            root["actions"] = actions
        }
        assertInvalidManifest(
            controlledTemplate,
            validator: validator,
            contains: "action.template is empty or too large"
        )
    }

    func testManifestRawJSONRejectsDuplicateAndEscapedEquivalentKeys() {
        let validator = PluginManifestValidator(hostVersion: "1.0.0")
        let cases: [(label: String, data: Data, duplicatedKey: String)] = [
            (
                "literal root key",
                rawManifestData(rootPrefix: #""schemaVersion": 999,"#),
                "schemaVersion"
            ),
            (
                "literal action key",
                rawManifestData(actionPrefix: #""id": "other","#),
                "id"
            ),
            (
                "escaped-equivalent root key",
                rawManifestData(rootPrefix: #""schema\u0056ersion": 999,"#),
                "schemaVersion"
            ),
            (
                "escaped-equivalent action key",
                rawManifestData(actionPrefix: #""i\u0064": "other","#),
                "id"
            )
        ]

        for testCase in cases {
            assertInvalidManifest(
                testCase.data,
                validator: validator,
                contains: "duplicate object key: \(testCase.duplicatedKey)"
            )
        }
    }

    func testManifestRawJSONRejectsBOMAndExcessiveNesting() throws {
        let validator = PluginManifestValidator(hostVersion: "1.0.0")
        var byteOrderMarked = Data([0xEF, 0xBB, 0xBF])
        byteOrderMarked.append(try encodedManifest(makeManifest()))
        assertInvalidManifest(
            byteOrderMarked,
            validator: validator,
            contains: "UTF-8 without a byte-order mark"
        )

        let nestingCount = 66
        let deeplyNested = Data(
            (
                String(repeating: "[", count: nestingCount)
                    + "0"
                    + String(repeating: "]", count: nestingCount)
            ).utf8
        )
        assertInvalidManifest(
            deeplyNested,
            validator: validator,
            contains: "nesting is too deep"
        )
    }

    func testManifestRequiresExactPermissionsAndKnownSafeTokens() throws {
        let validator = PluginManifestValidator(hostVersion: "1.0.0")
        let action = makeAction(
            output: .copyText,
            template: "Selected: {{selection}}"
        )
        let valid = makeManifest(
            capabilities: [.selectedText, .clipboardWrite],
            actions: [action]
        )
        XCTAssertNoThrow(try validator.decodeAndValidate(encodedManifest(valid)))

        let missingPermission = makeManifest(
            capabilities: [.selectedText],
            actions: [action]
        )
        assertInvalidManifest(
            try encodedManifest(missingPermission),
            validator: validator,
            contains: "missing: clipboardWrite"
        )

        let unusedPermission = makeManifest(
            capabilities: [.selectedText, .clipboardWrite, .externalURL],
            actions: [action]
        )
        assertInvalidManifest(
            try encodedManifest(unusedPermission),
            validator: validator,
            contains: "unused: externalURL"
        )

        let duplicatePermission = makeManifest(
            capabilities: [.selectedText, .clipboardWrite, .selectedText],
            actions: [action]
        )
        assertInvalidManifest(
            try encodedManifest(duplicatePermission),
            validator: validator,
            contains: "capabilities contains duplicates"
        )

        let unknownToken = makeManifest(actions: [
            makeAction(template: "{{environment.secret}}")
        ])
        assertInvalidManifest(
            try encodedManifest(unknownToken),
            validator: validator,
            contains: "unknown token"
        )

        let rawURLToken = makeManifest(
            capabilities: [.selectedText, .externalURL],
            actions: [makeAction(
                output: .openURL,
                template: "https://search.example.com/?q={{selection}}"
            )]
        )
        assertInvalidManifest(
            try encodedManifest(rawURLToken),
            validator: validator,
            contains: "must use a .urlEncoded token"
        )

        let encodedURLToken = makeManifest(
            capabilities: [.selectedText, .externalURL],
            actions: [makeAction(
                output: .openURL,
                template: "https://search.example.com/?q={{selection.urlEncoded}}"
            )]
        )
        XCTAssertNoThrow(
            try validator.decodeAndValidate(encodedManifest(encodedURLToken))
        )
    }

    func testSchemaOneRejectsEveryVersionTwoSurfaceWhileSchemaTwoUsesTypedTranslationSources() throws {
        let validator = PluginManifestValidator(hostVersion: "0.8.0")

        let legacyPanel = makeManifest(
            schemaVersion: 1,
            capabilities: [],
            actions: [makeAction(output: .browserPanel, template: "https://www.google.com/")]
        )
        assertInvalidManifest(
            try encodedManifest(legacyPanel),
            validator: validator,
            contains: "schemaVersion 1 does not support browserPanel"
        )

        let legacyCapability = makeManifest(
            schemaVersion: 1,
            capabilities: [.embeddedWebBrowser]
        )
        assertInvalidManifest(
            try encodedManifest(legacyCapability),
            validator: validator,
            contains: "schemaVersion 1 does not support capability"
        )

        let legacyPageToken = makeManifest(
            schemaVersion: 1,
            capabilities: [],
            actions: [makeAction(template: "{{page.text}}")]
        )
        assertInvalidManifest(
            try encodedManifest(legacyPageToken),
            validator: validator,
            contains: "schemaVersion 1 does not support current-page text tokens"
        )

        for token in ["{{selection}}", "{{page.text}}"] {
            let capabilities: [PluginCapability] = token == "{{selection}}"
                ? [.selectedText, .clipboardWrite, .translationService]
                : [.currentPageText, .clipboardWrite, .translationService]
            let manifest = makeManifest(
                schemaVersion: 2,
                capabilities: capabilities,
                actions: [makeAction(output: .translatePanel, template: token)]
            )
            XCTAssertNoThrow(try validator.decodeAndValidate(encodedManifest(manifest)))
        }

        let disguisedTranslationTemplates = [
            "Translate this: {{selection}}",
            "{{selection}}{{selection}}",
            "{{selection}}\n{{page.text}}",
            "{{selection.urlEncoded}}"
        ]
        for template in disguisedTranslationTemplates {
            let capabilities = Array(makeAction(
                output: .translatePanel,
                template: template
            ).requiredCapabilities)
            assertInvalidManifest(
                try encodedManifest(makeManifest(
                    schemaVersion: 2,
                    capabilities: capabilities,
                    actions: [makeAction(output: .translatePanel, template: template)]
                )),
                validator: validator,
                contains: "translatePanel template must be exactly"
            )
        }

        let encodedPageURL = makeManifest(
            schemaVersion: 2,
            capabilities: [.currentPageText, .externalURL],
            actions: [makeAction(
                output: .openURL,
                template: "https://example.com/?q={{page.text.urlEncoded}}"
            )]
        )
        assertInvalidManifest(
            try encodedManifest(encodedPageURL),
            validator: validator,
            contains: "current-page text is panel-only"
        )
    }

    func testManifestComplexityAndEncodedSizeLimitsFailClosed() throws {
        let validator = PluginManifestValidator(hostVersion: "1.0.0")
        assertInvalidManifest(
            try encodedManifest(makeManifest(actions: [])),
            validator: validator,
            contains: "actions must contain"
        )

        let tooManyActions = (0...HwattakPluginLimits.maximumActionsPerPlugin).map { index in
            makeAction(id: "action-\(index)")
        }
        assertInvalidManifest(
            try encodedManifest(makeManifest(actions: tooManyActions)),
            validator: validator,
            contains: "actions must contain"
        )

        let oversizedTemplate = makeManifest(actions: [
            makeAction(
                template: String(
                    repeating: "x",
                    count: HwattakPluginLimits.maximumTemplateUTF8Bytes + 1
                )
            )
        ])
        assertInvalidManifest(
            try encodedManifest(oversizedTemplate),
            validator: validator,
            contains: "action.template is empty or too large"
        )

        let oversizedManifestData = Data(
            repeating: 0x20,
            count: HwattakPluginLimits.maximumManifestBytes + 1
        )
        assertInvalidManifest(
            oversizedManifestData,
            validator: validator,
            contains: "size is outside the allowed range"
        )
    }

    func testSourcePackageRejectsRootAndEntrySymlinks() throws {
        let validator = PluginPackageValidator(hostVersion: "1.0.0")
        let realPackage = try writeSourcePackage(manifest: makeManifest())
        let linkedPackage = testRoot.appendingPathComponent(
            "linked.hwattakplugin",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedPackage,
            withDestinationURL: realPackage
        )
        assertInvalidPackage(
            try validator.inspectSourcePackage(at: linkedPackage),
            contains: "real directory, not a link"
        )

        let packageWithLinkedEntry = try writeSourcePackage(manifest: makeManifest())
        let externalReadme = testRoot.appendingPathComponent("outside-readme.md")
        try Data("outside".utf8).write(to: externalReadme)
        try FileManager.default.createSymbolicLink(
            at: packageWithLinkedEntry.appendingPathComponent("README.md"),
            withDestinationURL: externalReadme
        )
        assertInvalidPackage(
            try validator.inspectSourcePackage(at: packageWithLinkedEntry),
            contains: "package entries must be regular files"
        )
    }

    func testSourcePackageRejectsExtraFilesInvalidIconsAndSizeLimitBreaches() throws {
        let validator = PluginPackageValidator(hostVersion: "1.0.0")

        let packageWithExtraFile = try writeSourcePackage(
            manifest: makeManifest(),
            auxiliaryFiles: ["payload.js": Data("alert(1)".utf8)]
        )
        assertInvalidPackage(
            try validator.inspectSourcePackage(at: packageWithExtraFile),
            contains: "unsupported package entry: payload.js"
        )

        let packageWithInvalidIcon = try writeSourcePackage(
            manifest: makeManifest(),
            auxiliaryFiles: ["icon.png": Data("not-a-png".utf8)]
        )
        assertInvalidPackage(
            try validator.inspectSourcePackage(at: packageWithInvalidIcon),
            contains: "icon.png is not a PNG file"
        )

        let oversizedAuxiliary = try writeSourcePackage(
            manifest: makeManifest(),
            auxiliaryFiles: [
                "README.md": Data(
                    repeating: 0x41,
                    count: HwattakPluginLimits.maximumAuxiliaryFileBytes + 1
                )
            ]
        )
        assertInvalidPackage(
            try validator.inspectSourcePackage(at: oversizedAuxiliary),
            contains: "README.md exceeds its size limit"
        )

        let boundedChunk = Data(repeating: 0x42, count: 700 * 1_024)
        let oversizedTotal = try writeSourcePackage(
            manifest: makeManifest(),
            auxiliaryFiles: [
                "README.md": boundedChunk,
                "LICENSE": boundedChunk,
                "LICENSE.md": boundedChunk
            ]
        )
        assertInvalidPackage(
            try validator.inspectSourcePackage(at: oversizedTotal),
            contains: "package exceeds its total size limit"
        )
    }

    func testExactTwoMiBSourceInstallsWithHostRecordOutsidePayloadBudget() throws {
        let manifest = makeManifest(identifier: "org.example.exact-budget")
        let manifestData = try encodedManifest(manifest)
        let firstAuxiliary = Data(
            repeating: 0x41,
            count: HwattakPluginLimits.maximumAuxiliaryFileBytes
        )
        let remainingBytes = HwattakPluginLimits.maximumPackageBytes
            - manifestData.count
            - firstAuxiliary.count
        XCTAssertGreaterThan(remainingBytes, 0)
        XCTAssertLessThanOrEqual(
            remainingBytes,
            HwattakPluginLimits.maximumAuxiliaryFileBytes
        )
        let source = try writeSourcePackage(
            manifestData: manifestData,
            auxiliaryFiles: [
                "README.md": firstAuxiliary,
                "LICENSE": Data(repeating: 0x42, count: remainingBytes)
            ]
        )
        let validator = PluginPackageValidator(hostVersion: "1.0.0")
        let inspection = try validator.inspectSourcePackage(at: source)
        XCTAssertEqual(
            inspection.totalBytes,
            HwattakPluginLimits.maximumPackageBytes
        )
        XCTAssertEqual(
            inspection.filePayloads.values.reduce(0) { $0 + $1.count },
            HwattakPluginLimits.maximumPackageBytes
        )

        let manager = PluginManager(
            pluginsDirectory: pluginsDirectory,
            defaults: defaults,
            hostVersion: "1.0.0"
        )
        try manager.install(inspection, replacingExisting: false)

        let installed = try XCTUnwrap(manager.installedPlugins.first)
        let installedInspection = try validator.inspectInstalledPackage(at: installed.installURL)
        XCTAssertEqual(
            installedInspection.package.totalBytes,
            HwattakPluginLimits.maximumPackageBytes,
            "Host-owned installation.json must not consume the source payload budget"
        )
        let recordData = try Data(
            contentsOf: installed.installURL.appendingPathComponent("installation.json")
        )
        XCTAssertFalse(recordData.isEmpty)
        XCTAssertLessThanOrEqual(
            recordData.count,
            PluginPackageValidator.maximumInstallationRecordBytes
        )
    }

    func testDocumentedQuickCitationExampleIsAValidSourcePackage() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let package = projectRoot.appendingPathComponent(
            "Examples/Plugins/QuickCitation.hwattakplugin",
            isDirectory: true
        )

        let inspection = try PluginPackageValidator(hostVersion: "0.7.0")
            .inspectSourcePackage(at: package)

        XCTAssertEqual(
            inspection.manifest.identifier,
            "dev.example.hwattakpdf.quick-citation"
        )
        XCTAssertEqual(inspection.manifest.version, "1.0.0")
        XCTAssertEqual(inspection.manifest.minimumHostVersion, "0.7.0")
        XCTAssertEqual(
            Set(inspection.manifest.capabilities),
            Set([
                .documentMetadata,
                .selectedText,
                .clipboardWrite,
                .externalURL
            ])
        )
        XCTAssertEqual(
            inspection.manifest.actions.map(\.output.rawValue),
            ["showText", "copyText", "openURL"]
        )
        XCTAssertEqual(inspection.fileCount, 1)
        XCTAssertEqual(Set(inspection.filePayloads.keys), ["manifest.json"])
        XCTAssertEqual(
            inspection.manifestDigest,
            PluginPackageValidator.sha256Hex(
                try Data(contentsOf: package.appendingPathComponent("manifest.json"))
            )
        )
    }

    func testAdditionalDocumentedExamplesAreValidAndMinimallyPermissioned() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let examples: [(
            directory: String,
            identifier: String,
            capabilities: Set<PluginCapability>,
            outputs: [PluginActionOutput]
        )] = [
            (
                "MarkdownQuote.hwattakplugin",
                "dev.example.hwattakpdf.markdown-quote",
                [.documentMetadata, .selectedText, .clipboardWrite],
                [.showText, .copyText]
            ),
            (
                "ReferenceSearch.hwattakplugin",
                "dev.example.hwattakpdf.reference-search",
                [.selectedText, .externalURL],
                [.openURL, .openURL]
            )
        ]
        let validator = PluginPackageValidator(hostVersion: "0.7.0")
        let renderer = PluginActionRenderer()
        let context = PluginActionContext(
            documentName: "Research Notes.pdf",
            pageNumber: 7,
            pageCount: 42,
            selectedText: "bounded search phrase"
        )

        for example in examples {
            let package = projectRoot.appendingPathComponent(
                "Examples/Plugins/\(example.directory)",
                isDirectory: true
            )
            let inspection = try validator.inspectSourcePackage(at: package)

            XCTAssertEqual(inspection.manifest.identifier, example.identifier)
            XCTAssertEqual(inspection.manifest.version, "1.0.0")
            XCTAssertEqual(inspection.manifest.minimumHostVersion, "0.7.0")
            XCTAssertEqual(Set(inspection.manifest.capabilities), example.capabilities)
            XCTAssertEqual(inspection.manifest.actions.map(\.output), example.outputs)
            XCTAssertEqual(inspection.fileCount, 2)
            XCTAssertEqual(
                Set(inspection.filePayloads.keys),
                ["manifest.json", "README.md"]
            )
            for action in inspection.manifest.actions {
                let rendered = try renderer.render(action: action, context: context)
                XCTAssertTrue(rendered.contains("bounded"))
                if action.output == .openURL {
                    let url = try renderer.validatedExternalURL(from: rendered)
                    XCTAssertEqual(url.scheme, "https")
                    XCTAssertNotNil(url.host)
                }
            }
        }
    }

    func testBundledPanelPluginsAreValidMinimalAndTrustedByExactDigest() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let examplesDirectory = projectRoot.appendingPathComponent(
            "Examples/Plugins",
            isDirectory: true
        )
        let trustedBundledDirectory = testRoot.appendingPathComponent(
            "BundledPlugins",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: trustedBundledDirectory,
            withIntermediateDirectories: false
        )
        let examples: [(
            directory: String,
            identifier: String,
            capabilities: Set<PluginCapability>,
            outputs: [PluginActionOutput]
        )] = [
            (
                "TranslationCompanion.hwattakplugin",
                "dev.hwattakpdf.plugins.translation-companion",
                [.selectedText, .currentPageText, .clipboardWrite, .translationService],
                [.translatePanel, .translatePanel]
            ),
            (
                "YouTubeStudy.hwattakplugin",
                "dev.hwattakpdf.plugins.youtube-study",
                [.youtubeContent],
                [.youtubePanel]
            ),
            (
                "WebBrowser.hwattakplugin",
                "dev.hwattakpdf.plugins.web-browser",
                [.embeddedWebBrowser],
                [.browserPanel]
            )
        ]
        let packageValidator = PluginPackageValidator(hostVersion: "0.8.0")
        for example in examples {
            try FileManager.default.copyItem(
                at: examplesDirectory.appendingPathComponent(
                    example.directory,
                    isDirectory: true
                ),
                to: trustedBundledDirectory.appendingPathComponent(
                    example.directory,
                    isDirectory: true
                )
            )
        }
        let manager = PluginManager(
            pluginsDirectory: pluginsDirectory,
            defaults: defaults,
            hostVersion: "0.8.0",
            bundledPluginsDirectory: trustedBundledDirectory
        )

        XCTAssertEqual(manager.bundledPlugins.count, 3)
        for example in examples {
            let package = examplesDirectory.appendingPathComponent(
                example.directory,
                isDirectory: true
            )
            let inspection = try packageValidator.inspectSourcePackage(at: package)
            XCTAssertEqual(inspection.manifest.schemaVersion, 2)
            XCTAssertEqual(inspection.manifest.minimumHostVersion, "0.8.0")
            XCTAssertEqual(inspection.manifest.identifier, example.identifier)
            XCTAssertEqual(Set(inspection.manifest.capabilities), example.capabilities)
            XCTAssertEqual(inspection.manifest.actions.map(\.output), example.outputs)
            try manager.install(inspection, replacingExisting: false)
        }
        XCTAssertEqual(manager.installedPlugins.count, 3)
        XCTAssertTrue(manager.availableBundledPlugins.isEmpty)
        let configurationKinds = Dictionary(
            uniqueKeysWithValues: manager.installedPlugins.map {
                ($0.id, manager.configurationKind(for: $0))
            }
        )
        XCTAssertEqual(
            configurationKinds["dev.hwattakpdf.plugins.translation-companion"],
            .translation
        )
        XCTAssertEqual(
            configurationKinds["dev.hwattakpdf.plugins.youtube-study"],
            .youtube
        )
        XCTAssertEqual(
            configurationKinds["dev.hwattakpdf.plugins.web-browser"],
            .browser
        )
        let trustedBrowser = try XCTUnwrap(manager.installedPlugins.first(where: {
            $0.id == "dev.hwattakpdf.plugins.web-browser"
        }))
        let digestMismatch = InstalledPlugin(
            manifest: trustedBrowser.manifest,
            installURL: trustedBrowser.installURL,
            manifestDigest: String(repeating: "0", count: 64),
            installedAt: trustedBrowser.installedAt,
            isEnabled: true
        )
        XCTAssertEqual(manager.configurationKind(for: digestMismatch), .generic)
        XCTAssertEqual(
            manager.configurationKind(
                identifier: trustedBrowser.id,
                manifestDigest: digestMismatch.manifestDigest
            ),
            .generic
        )

        let stalePlugin = try XCTUnwrap(manager.installedPlugins.first)
        let staleManifestURL = stalePlugin.installURL.appendingPathComponent("manifest.json")
        var staleBytes = try Data(contentsOf: staleManifestURL)
        staleBytes.append(0x0A)
        try staleBytes.write(to: staleManifestURL, options: [.atomic])
        manager.refresh()
        XCTAssertFalse(manager.installedPlugins.contains(where: { $0.id == stalePlugin.id }))
        let recovery = try XCTUnwrap(
            manager.availableBundledPlugins.first(where: {
                $0.manifest.identifier == stalePlugin.id
            })
        )
        try manager.install(recovery, replacingExisting: true)
        XCTAssertTrue(manager.installedPlugins.contains(where: {
            $0.id == stalePlugin.id && $0.manifestDigest == recovery.manifestDigest
        }))
        XCTAssertFalse(manager.availableBundledPlugins.contains(where: {
            $0.manifest.identifier == stalePlugin.id
        }))

        let forgedAction = makeAction(
            output: .browserPanel,
            template: "https://www.google.com/"
        )
        let forged = makeManifest(
            identifier: "org.example.forged-browser",
            minimumHostVersion: "0.8.0",
            capabilities: [.embeddedWebBrowser],
            actions: [forgedAction]
        )
        let forgedPackage = try writeSourcePackage(manifest: forged)
        assertInvalidPackage(
            try manager.inspectPackage(at: forgedPackage),
            contains: "exactly match"
        )

        // The installer keeps the same defense even if another caller obtains
        // a syntactically valid inspection without using PluginManager's
        // pre-review entry point.
        let forgedInspection = try packageValidator.inspectSourcePackage(
            at: forgedPackage
        )
        do {
            try manager.install(forgedInspection, replacingExisting: false)
            XCTFail("An unbundled manifest must not gain the host WebKit privilege")
        } catch PluginSystemError.invalidPackage(let detail) {
            XCTAssertTrue(detail.contains("exactly match"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReservedBundledIdentifierRejectsSchemaOneSpoofAtEveryBoundary() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let officialPackage = projectRoot.appendingPathComponent(
            "Examples/Plugins/TranslationCompanion.hwattakplugin",
            isDirectory: true
        )
        let trustedBundledDirectory = testRoot.appendingPathComponent(
            "BundledPlugins",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: trustedBundledDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.copyItem(
            at: officialPackage,
            to: trustedBundledDirectory.appendingPathComponent(
                officialPackage.lastPathComponent,
                isDirectory: true
            )
        )

        let spoofAction = makeAction(
            id: "translate-selection",
            title: "Counterfeit action",
            output: .showText,
            template: "This is not the bundled translation action"
        )
        let spoofManifest = makeManifest(
            schemaVersion: 1,
            identifier: "dev.hwattakpdf.plugins.translation-companion",
            actions: [spoofAction]
        )
        let spoofPackage = try writeSourcePackage(manifest: spoofManifest)
        let manager = PluginManager(
            pluginsDirectory: pluginsDirectory,
            defaults: defaults,
            hostVersion: "0.8.0",
            bundledPluginsDirectory: trustedBundledDirectory
        )

        // A reserved first-party identity must be rejected before an install
        // review can lend it legitimacy.
        assertInvalidPackage(
            try manager.inspectPackage(at: spoofPackage),
            contains: "reserved HwattakPDF identities"
        )

        // Keep the install boundary independently defensive against a caller
        // that bypasses manager.inspectPackage(at:).
        let rawInspection = try PluginPackageValidator(
            hostVersion: "0.8.0"
        ).inspectSourcePackage(at: spoofPackage)
        do {
            try manager.install(rawInspection, replacingExisting: false)
            XCTFail("A schema-1 package must not claim a bundled identifier")
        } catch PluginSystemError.invalidPackage(let detail) {
            XCTAssertTrue(detail.contains("reserved HwattakPDF identities"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Simulate a same-user filesystem modification that places a valid
        // schema-1 package and matching host record directly in the install
        // directory. Refresh/load must still quarantine it.
        let installedSpoof = pluginsDirectory.appendingPathComponent(
            "\(spoofManifest.identifier).hwattakplugin",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: spoofPackage, to: installedSpoof)
        let record = PluginInstallationRecord(
            schemaVersion: HwattakPluginLimits.installationRecordSchemaVersion,
            manifestSHA256: rawInspection.manifestDigest,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(
            to: installedSpoof.appendingPathComponent("installation.json"),
            options: [.atomic]
        )
        manager.refresh()
        XCTAssertFalse(manager.installedPlugins.contains(where: {
            $0.id == spoofManifest.identifier
        }))
        XCTAssertTrue(manager.loadIssues.contains(where: {
            $0.packageName == installedSpoof.lastPathComponent
                && $0.message.contains("reserved HwattakPDF identities")
        }))

        // Presentation also fails closed: a known identifier with the wrong
        // schema/action/capability shape keeps its own untrusted wording.
        XCTAssertEqual(
            BundledPluginPresentation.displayName(for: spoofManifest),
            spoofManifest.displayName
        )
        XCTAssertEqual(
            BundledPluginPresentation.description(for: spoofManifest),
            spoofManifest.description
        )
        XCTAssertEqual(
            BundledPluginPresentation.actionTitle(
                spoofAction,
                in: spoofManifest
            ),
            spoofAction.title
        )
        XCTAssertEqual(
            BundledPluginPresentation.actionDescription(
                spoofAction,
                in: spoofManifest
            ),
            spoofAction.description
        )

        // Even a schema-2 lookalike with all official action IDs/templates must
        // not inherit first-party copy when its capability array is invalid.
        let officialManifest = try PluginPackageValidator(
            hostVersion: "0.8.0"
        ).inspectSourcePackage(at: officialPackage).manifest
        let lookalikeAction = PluginActionManifest(
            id: officialManifest.actions[0].id,
            title: "Counterfeit official-shaped action",
            description: "Counterfeit official-shaped description",
            output: officialManifest.actions[0].output,
            template: officialManifest.actions[0].template
        )
        let duplicateCapabilityLookalike = PluginManifest(
            schemaVersion: officialManifest.schemaVersion,
            identifier: officialManifest.identifier,
            displayName: "Counterfeit official-shaped plug-in",
            version: officialManifest.version,
            author: officialManifest.author,
            description: "Counterfeit official-shaped plug-in description",
            minimumHostVersion: officialManifest.minimumHostVersion,
            capabilities: officialManifest.capabilities + [.selectedText],
            actions: [lookalikeAction, officialManifest.actions[1]]
        )
        XCTAssertEqual(
            BundledPluginPresentation.displayName(
                for: duplicateCapabilityLookalike
            ),
            duplicateCapabilityLookalike.displayName
        )
        XCTAssertEqual(
            BundledPluginPresentation.actionTitle(
                lookalikeAction,
                in: duplicateCapabilityLookalike
            ),
            lookalikeAction.title
        )
    }

    func testInstallUsesCapturedBytesAndDisableSurvivesRefreshBeforeUninstall() throws {
        let installedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let manager = PluginManager(
            pluginsDirectory: pluginsDirectory,
            defaults: defaults,
            hostVersion: "1.0.0",
            now: { installedAt }
        )
        let versionOne = makeManifest(version: "1.0.0")
        let originalReadme = Data("reviewed bytes".utf8)
        let source = try writeSourcePackage(
            manifest: versionOne,
            auxiliaryFiles: ["README.md": originalReadme]
        )
        let originalManifestData = try Data(
            contentsOf: source.appendingPathComponent("manifest.json")
        )
        let inspection = try manager.inspectPackage(at: source)

        // Mutating the source after inspection must not change the committed
        // bytes. Installation is based only on the bounded review snapshot.
        try encodedManifest(makeManifest(version: "9.9.9")).write(
            to: source.appendingPathComponent("manifest.json"),
            options: [.atomic]
        )
        try Data("unreviewed bytes".utf8).write(
            to: source.appendingPathComponent("README.md"),
            options: [.atomic]
        )
        try manager.install(inspection, replacingExisting: false)

        let installed = try XCTUnwrap(manager.installedPlugins.first)
        XCTAssertEqual(installed.manifest.version, "1.0.0")
        XCTAssertEqual(installed.installedAt, installedAt)
        XCTAssertTrue(installed.isEnabled)
        XCTAssertEqual(manager.enabledActionCount, 1)
        XCTAssertEqual(
            try Data(contentsOf: installed.installURL.appendingPathComponent("manifest.json")),
            originalManifestData
        )
        XCTAssertEqual(
            try Data(contentsOf: installed.installURL.appendingPathComponent("README.md")),
            originalReadme
        )
        XCTAssertEqual(
            try posixPermissions(at: installed.installURL),
            0o700
        )
        XCTAssertEqual(
            try posixPermissions(
                at: installed.installURL.appendingPathComponent("manifest.json")
            ),
            0o600
        )

        let preferences = PluginPreferences(
            translationProvider: .claude,
            translationTargetLanguageCode: "en",
            translationShowsSource: false,
            youtubeLoadsStartPage: false,
            browserSearchEngine: .duckDuckGo,
            browserLoadsStartPage: false
        )
        try manager.setPreferences(preferences, identifier: versionOne.identifier)
        XCTAssertEqual(manager.preferences(for: versionOne.identifier), preferences)
        XCTAssertNotNil(defaults.data(forKey: PluginManager.preferencesDefaultsKey))

        do {
            try manager.install(inspection, replacingExisting: false)
            XCTFail("Duplicate installation must require an explicit replace")
        } catch PluginSystemError.packageAlreadyInstalled {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try manager.setEnabled(false, identifier: versionOne.identifier)
        XCTAssertFalse(try XCTUnwrap(manager.installedPlugins.first).isEnabled)
        XCTAssertEqual(
            defaults.stringArray(forKey: PluginManager.disabledIdentifiersDefaultsKey),
            [versionOne.identifier]
        )

        let reloaded = PluginManager(
            pluginsDirectory: pluginsDirectory,
            defaults: defaults,
            hostVersion: "1.0.0"
        )
        XCTAssertFalse(try XCTUnwrap(reloaded.installedPlugins.first).isEnabled)
        XCTAssertEqual(reloaded.preferences(for: versionOne.identifier), preferences)

        try reloaded.setEnabled(true, identifier: versionOne.identifier)
        XCTAssertTrue(try XCTUnwrap(reloaded.installedPlugins.first).isEnabled)
        XCTAssertEqual(
            defaults.stringArray(forKey: PluginManager.disabledIdentifiersDefaultsKey),
            []
        )
        try reloaded.setEnabled(false, identifier: versionOne.identifier)

        let updateSource = try writeSourcePackage(manifest: makeManifest(version: "2.0.0"))
        let updateInspection = try reloaded.inspectPackage(at: updateSource)
        try reloaded.install(updateInspection, replacingExisting: true)
        XCTAssertEqual(
            try XCTUnwrap(reloaded.installedPlugins.first).manifest.version,
            "2.0.0"
        )
        XCTAssertFalse(try XCTUnwrap(reloaded.installedPlugins.first).isEnabled)
        XCTAssertEqual(reloaded.preferences(for: versionOne.identifier), preferences)

        try reloaded.uninstall(identifier: versionOne.identifier)
        XCTAssertTrue(reloaded.installedPlugins.isEmpty)
        XCTAssertEqual(
            defaults.stringArray(forKey: PluginManager.disabledIdentifiersDefaultsKey),
            []
        )
        XCTAssertEqual(reloaded.preferences(for: versionOne.identifier), .default)
        XCTAssertNil(defaults.data(forKey: PluginManager.preferencesDefaultsKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.installURL.path))
    }

    func testManagerEnforcesTheInstalledPluginRegistryLimit() throws {
        let manager = PluginManager(
            pluginsDirectory: pluginsDirectory,
            defaults: defaults,
            hostVersion: "1.0.0"
        )
        for index in 0..<HwattakPluginLimits.maximumInstalledPluginCount {
            let manifest = makeManifest(identifier: "org.example.fixture-\(index)")
            let source = try writeSourcePackage(manifest: manifest)
            try manager.install(
                manager.inspectPackage(at: source),
                replacingExisting: false
            )
        }
        XCTAssertEqual(
            manager.installedPlugins.count,
            HwattakPluginLimits.maximumInstalledPluginCount
        )

        let overflowManifest = makeManifest(identifier: "org.example.fixture-overflow")
        let overflowSource = try writeSourcePackage(manifest: overflowManifest)
        let overflowInspection = try manager.inspectPackage(at: overflowSource)
        do {
            try manager.install(overflowInspection, replacingExisting: false)
            XCTFail("The bounded registry must reject a thirty-third plug-in")
        } catch PluginSystemError.pluginLimitReached(let limit) {
            XCTAssertEqual(limit, HwattakPluginLimits.maximumInstalledPluginCount)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(
            manager.installedPlugins.count,
            HwattakPluginLimits.maximumInstalledPluginCount
        )
    }

    func testQuarantinedBundlesConsumeSlotsAndCannotBypassRegistryLimit() throws {
        try FileManager.default.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var quarantinedPackages: [URL] = []
        for index in 0..<HwattakPluginLimits.maximumInstalledPluginCount {
            let package = pluginsDirectory.appendingPathComponent(
                "invalid-\(index).hwattakplugin",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: package,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            quarantinedPackages.append(package)
        }
        let manager = PluginManager(
            pluginsDirectory: pluginsDirectory,
            defaults: defaults,
            hostVersion: "1.0.0"
        )
        XCTAssertTrue(manager.installedPlugins.isEmpty)
        XCTAssertEqual(
            manager.loadIssues.count,
            HwattakPluginLimits.maximumInstalledPluginCount
        )

        let manifest = makeManifest(identifier: "org.example.after-quarantine")
        let source = try writeSourcePackage(manifest: manifest)
        let inspection = try manager.inspectPackage(at: source)
        do {
            try manager.install(inspection, replacingExisting: false)
            XCTFail("Malformed bundles must still occupy the bounded scan registry")
        } catch PluginSystemError.pluginLimitReached(let limit) {
            XCTAssertEqual(limit, HwattakPluginLimits.maximumInstalledPluginCount)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Removing one quarantined entry frees exactly one slot; a valid
        // package can then install normally without touching the others.
        try FileManager.default.removeItem(at: quarantinedPackages[0])
        try manager.install(inspection, replacingExisting: false)
        XCTAssertEqual(manager.installedPlugins.map(\.id), [manifest.identifier])
        XCTAssertEqual(
            manager.loadIssues.count,
            HwattakPluginLimits.maximumInstalledPluginCount - 1
        )
    }

    func testTamperedInstalledManifestIsQuarantinedUntilAValidatedUpdateReplacesIt() throws {
        let manager = PluginManager(
            pluginsDirectory: pluginsDirectory,
            defaults: defaults,
            hostVersion: "1.0.0"
        )
        let versionOne = makeManifest(version: "1.0.0")
        let sourceOne = try writeSourcePackage(manifest: versionOne)
        try manager.install(
            manager.inspectPackage(at: sourceOne),
            replacingExisting: false
        )
        try manager.setEnabled(false, identifier: versionOne.identifier)
        let destination = try XCTUnwrap(manager.installedPlugins.first).installURL
        var tamperedData = try Data(
            contentsOf: destination.appendingPathComponent("manifest.json")
        )
        tamperedData.append(0x0A)
        try tamperedData.write(
            to: destination.appendingPathComponent("manifest.json"),
            options: [.atomic]
        )

        manager.refresh()

        XCTAssertTrue(manager.installedPlugins.isEmpty)
        XCTAssertEqual(manager.loadIssues.count, 1)
        XCTAssertEqual(manager.loadIssues.first?.packageName, destination.lastPathComponent)

        let versionTwo = makeManifest(version: "2.0.0")
        let sourceTwo = try writeSourcePackage(manifest: versionTwo)
        try manager.install(
            manager.inspectPackage(at: sourceTwo),
            replacingExisting: true
        )

        XCTAssertEqual(manager.installedPlugins.map(\.manifest.version), ["2.0.0"])
        XCTAssertFalse(try XCTUnwrap(manager.installedPlugins.first).isEnabled)
        XCTAssertTrue(manager.loadIssues.isEmpty)
    }

    func testFailedUpdateRestoresPriorVersionAndLeavesNoStagingArtifacts() throws {
        let fileManager = ActivationFailingFileManager(activationRoot: pluginsDirectory)
        let manager = PluginManager(
            pluginsDirectory: pluginsDirectory,
            fileManager: fileManager,
            defaults: defaults,
            hostVersion: "1.0.0"
        )
        let identifier = "com.example.fixture"
        let sourceOne = try writeSourcePackage(
            manifest: makeManifest(identifier: identifier, version: "1.0.0")
        )
        try manager.install(
            manager.inspectPackage(at: sourceOne),
            replacingExisting: false
        )

        let sourceTwo = try writeSourcePackage(
            manifest: makeManifest(identifier: identifier, version: "2.0.0")
        )
        let update = try manager.inspectPackage(at: sourceTwo)
        fileManager.failNextActivationMove = true

        do {
            try manager.install(update, replacingExisting: true)
            XCTFail("Injected activation failure should abort the update")
        } catch PluginSystemError.installationFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        manager.refresh()
        XCTAssertEqual(manager.installedPlugins.map(\.manifest.version), ["1.0.0"])
        let entriesAfterFailure = try FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        XCTAssertFalse(entriesAfterFailure.contains { url in
            let name = url.lastPathComponent
            return name.hasPrefix(".install-")
                || name.hasPrefix(".staging-")
                || name.hasSuffix(".backup.hwattakplugin")
        })

        try manager.install(update, replacingExisting: true)
        XCTAssertEqual(manager.installedPlugins.map(\.manifest.version), ["2.0.0"])
    }

    func testRefreshRecoversInterruptedBackupAndRemovesAbandonedStaging() throws {
        let manager = PluginManager(
            pluginsDirectory: pluginsDirectory,
            defaults: defaults,
            hostVersion: "1.0.0"
        )
        let manifest = makeManifest()
        let source = try writeSourcePackage(manifest: manifest)
        try manager.install(manager.inspectPackage(at: source), replacingExisting: false)

        let destination = try XCTUnwrap(manager.installedPlugins.first).installURL
        let backup = pluginsDirectory.appendingPathComponent(
            ".\(manifest.identifier).backup.hwattakplugin",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: destination, to: backup)
        let abandonedInstall = pluginsDirectory.appendingPathComponent(
            ".install-abandoned",
            isDirectory: true
        )
        let abandonedStaging = pluginsDirectory.appendingPathComponent(
            ".staging-abandoned",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: abandonedInstall, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: abandonedStaging, withIntermediateDirectories: false)

        manager.refresh()

        XCTAssertEqual(manager.installedPlugins.map(\.id), [manifest.identifier])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedInstall.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedStaging.path))
    }

    func testRendererPercentEncodesUntrustedURLValuesAndResolvesMetadata() throws {
        let action = makeAction(
            output: .openURL,
            template: "https://search.example.com/find?q={{selection.urlEncoded}}&doc={{document.name.urlEncoded}}&page={{page.number}}&count={{document.pageCount}}"
        )
        let context = PluginActionContext(
            documentName: "Report #1 & notes.pdf",
            pageNumber: 2,
            pageCount: 12,
            selectedText: "A&B / 한글?%"
        )

        let rendered = try PluginActionRenderer().render(action: action, context: context)

        XCTAssertFalse(rendered.contains("A&B /"))
        XCTAssertTrue(rendered.contains("%26"))
        XCTAssertTrue(rendered.contains("%2F"))
        XCTAssertTrue(rendered.contains("%23"))
        let components = try XCTUnwrap(URLComponents(string: rendered))
        let queryItems = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(queryItems["q"], "A&B / 한글?%")
        XCTAssertEqual(queryItems["doc"], "Report #1 & notes.pdf")
        XCTAssertEqual(queryItems["page"], "2")
        XCTAssertEqual(queryItems["count"], "12")
    }

    func testRendererRequiresCompleteContextAndRejectsOversizedOutput() throws {
        let action = makeAction(
            output: .showText,
            template: "{{document.name}}: {{selection}}"
        )
        do {
            _ = try PluginActionRenderer().render(
                action: action,
                context: PluginActionContext(
                    documentName: "Fixture.pdf",
                    pageNumber: 1,
                    pageCount: 1,
                    selectedText: "   \n"
                )
            )
            XCTFail("Whitespace-only selection must be unavailable")
        } catch PluginSystemError.actionUnavailable {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let repeatedToken = makeAction(
            template: String(repeating: "{{selection}}", count: 1_000)
        )
        do {
            _ = try PluginActionRenderer().render(
                action: repeatedToken,
                context: PluginActionContext(
                    documentName: nil,
                    pageNumber: nil,
                    pageCount: nil,
                    selectedText: String(repeating: "가", count: 4_000)
                )
            )
            XCTFail("Projected output must fail before repeated-token allocation")
        } catch PluginSystemError.actionFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let oversizedAction = makeAction(template: "{{selection}}")
        do {
            _ = try PluginActionRenderer().render(
                action: oversizedAction,
                context: PluginActionContext(
                    documentName: nil,
                    pageNumber: nil,
                    pageCount: nil,
                    selectedText: String(
                        repeating: "x",
                        count: HwattakPluginLimits.maximumRenderedCharacters + 1
                    )
                )
            )
            XCTFail("Oversized rendered output must fail instead of being truncated")
        } catch PluginSystemError.actionFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRendererPreservesTemplateSyntaxInsideReplacementValues() throws {
        let renderer = PluginActionRenderer()
        let literalTokens = "literal {{selection}} and {{page.text}}"

        let selectedText = try renderer.render(
            action: makeAction(template: "Selected: {{selection}}"),
            context: PluginActionContext(
                documentName: nil,
                pageNumber: nil,
                pageCount: nil,
                selectedText: literalTokens,
                currentPageText: "must not replace the inserted page token"
            )
        )
        XCTAssertEqual(selectedText, "Selected: \(literalTokens)")

        let pageText = try renderer.render(
            action: makeAction(template: "{{page.text}}"),
            context: PluginActionContext(
                documentName: nil,
                pageNumber: nil,
                pageCount: nil,
                selectedText: "must not replace the inserted selection token",
                currentPageText: literalTokens
            )
        )
        XCTAssertEqual(pageText, literalTokens)
    }

    func testRendererPreflightsRepeatedCrossTokenValuesWithoutRecursiveExpansion() throws {
        let renderer = PluginActionRenderer()
        let crossTokenDocumentName = String(
            repeating: "{{selection}}",
            count: 1_000
        )
        let context = PluginActionContext(
            documentName: crossTokenDocumentName,
            pageNumber: 1,
            pageCount: 1,
            selectedText: String(repeating: "x", count: 4_000)
        )

        let preserved = try renderer.render(
            action: makeAction(template: "{{document.name}}"),
            context: context
        )
        XCTAssertEqual(
            preserved,
            crossTokenDocumentName,
            "Tokens supplied by a replacement must remain opaque output"
        )

        do {
            _ = try renderer.render(
                action: makeAction(
                    template: "{{document.name}}{{document.name}}"
                ),
                context: context
            )
            XCTFail("Projected cross-token output must fail before assembly")
        } catch PluginSystemError.actionFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRendererAcceptsOnlyBoundedPublicHTTPSURLs() throws {
        let renderer = PluginActionRenderer()
        let valid = try renderer.validatedExternalURL(
            from: "https://public.example.com/path?q=pdf#result"
        )
        XCTAssertEqual(valid.host, "public.example.com")

        let rejected = [
            "http://public.example.com/path",
            "https://localhost/path",
            "https://127.0.0.1/path",
            "https://2130706433/path",
            "https://[::1]/path",
            "https://printer.local/path",
            "https://printer/path",
            "https://user:secret@public.example.com/path"
        ]
        for value in rejected {
            assertExternalURLRejected(
                try renderer.validatedExternalURL(from: value),
                value: value
            )
        }

        let oversized = "https://public.example.com/" + String(
            repeating: "a",
            count: HwattakPluginLimits.maximumExternalURLUTF8Bytes
        )
        assertExternalURLRejected(
            try renderer.validatedExternalURL(from: oversized),
            value: "oversized URL"
        )
    }

    func testRuntimeRequiresConsentForEveryExternalURLInvocation() throws {
        let action = makeAction(
            output: .openURL,
            template: "https://public.example.com/help"
        )
        let manifest = makeManifest(
            capabilities: [.externalURL],
            actions: [action]
        )
        let plugin = installedPlugin(manifest: manifest, isEnabled: true)
        var approvalCalls: [(String, URL, PluginExternalURLDisclosure)] = []
        var openedURLs: [URL] = []
        let environment = PluginRuntimeEnvironment(
            showText: { _, _ in XCTFail("Unexpected text effect") },
            writeClipboard: { _ in
                XCTFail("Unexpected clipboard effect")
                return false
            },
            approveExternalURL: { pluginName, url, disclosure in
                approvalCalls.append((pluginName, url, disclosure))
                return approvalCalls.count == 2
            },
            openExternalURL: { url in
                openedURLs.append(url)
                return true
            }
        )
        let runner = PluginActionRunner(environment: environment)

        do {
            try runner.run(plugin: plugin, action: action, workspace: nil)
            XCTFail("The first invocation should be cancelled by the consent host")
        } catch PluginSystemError.externalURLCancelled {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(approvalCalls.count, 1)
        XCTAssertTrue(openedURLs.isEmpty)

        let effect = try runner.run(plugin: plugin, action: action, workspace: nil)
        XCTAssertEqual(
            effect,
            .openedURL(URL(string: "https://public.example.com/help")!)
        )
        XCTAssertEqual(approvalCalls.count, 2, "Consent must be requested per invocation")
        XCTAssertEqual(openedURLs.count, 1)
        XCTAssertEqual(approvalCalls.last?.0, manifest.displayName)
        XCTAssertEqual(
            approvalCalls.last?.2,
            PluginExternalURLDisclosure(
                includesDocumentMetadata: false,
                includesSelectedText: false
            )
        )

        let disabled = installedPlugin(manifest: manifest, isEnabled: false)
        do {
            try runner.run(plugin: disabled, action: action, workspace: nil)
            XCTFail("A disabled plug-in must not reach the consent host")
        } catch PluginSystemError.actionUnavailable {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(approvalCalls.count, 2)
        XCTAssertEqual(openedURLs.count, 1)
    }

    func testRuntimeRechecksActionOwnershipAndDeclaredPermissionCoverage() throws {
        let owned = makeAction(output: .copyText, template: "copy me")
        let unowned = makeAction(id: "other", output: .copyText, template: "other")
        var clipboardWrites = 0
        let environment = PluginRuntimeEnvironment(
            showText: { _, _ in },
            writeClipboard: { _ in
                clipboardWrites += 1
                return true
            },
            approveExternalURL: { _, _, _ in false },
            openExternalURL: { _ in false }
        )
        let runner = PluginActionRunner(environment: environment)
        let validManifest = makeManifest(
            capabilities: [.clipboardWrite],
            actions: [owned]
        )

        do {
            try runner.run(
                plugin: installedPlugin(manifest: validManifest),
                action: unowned,
                workspace: nil
            )
            XCTFail("An action not present in the installed manifest must be rejected")
        } catch PluginSystemError.actionFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let underdeclaredManifest = makeManifest(capabilities: [], actions: [owned])
        do {
            try runner.run(
                plugin: installedPlugin(manifest: underdeclaredManifest),
                action: owned,
                workspace: nil
            )
            XCTFail("Runtime must not trust an underdeclared in-memory manifest")
        } catch PluginSystemError.actionFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(clipboardWrites, 0)
    }

    func testPanelRunnerCapturesImmutableRevisionBoundTextWithoutSendingIt() throws {
        let sourceText = "번역 전까지 외부로 보내지 않는 현재 페이지 문장입니다."
        let pdfURL = try writeTextPDF(sourceText)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: pdfURL))
        let capturedRevision = workspace.revision

        let translateAction = makeAction(
            id: "translate-page",
            output: .translatePanel,
            template: "{{page.text}}"
        )
        let translateManifest = makeManifest(
            identifier: "org.example.translation",
            minimumHostVersion: "0.8.0",
            capabilities: [.currentPageText, .clipboardWrite, .translationService],
            actions: [translateAction]
        )
        let translatePlugin = installedPlugin(manifest: translateManifest)
        var clipboardWrites = 0
        var approvals = 0
        var externalOpens = 0
        let environment = PluginRuntimeEnvironment(
            showText: { _, _ in XCTFail("Unexpected text dialog") },
            writeClipboard: { _ in
                clipboardWrites += 1
                return true
            },
            approveExternalURL: { _, _, _ in
                approvals += 1
                return true
            },
            openExternalURL: { _ in
                externalOpens += 1
                return true
            }
        )
        let runner = PluginActionRunner(environment: environment)

        let effect = try runner.run(
            plugin: translatePlugin,
            action: translateAction,
            workspace: workspace
        )
        guard case .openedPanel(let request) = effect else {
            return XCTFail("Expected a translation panel request")
        }
        XCTAssertEqual(request.pluginIdentifier, translateManifest.identifier)
        XCTAssertEqual(request.manifestDigest, translatePlugin.manifestDigest)
        XCTAssertEqual(request.documentRevision, capturedRevision)
        XCTAssertEqual(request.actionID, translateAction.id)
        XCTAssertEqual(request.kind, .translation)
        XCTAssertEqual(request.sourceText, sourceText)
        XCTAssertFalse(request.includesSelectedText)
        XCTAssertTrue(request.includesCurrentPageText)
        XCTAssertEqual(workspace.pluginPanelRequest, request)
        XCTAssertEqual(clipboardWrites, 0, "Opening the review UI must not copy or send text")
        XCTAssertEqual(approvals, 0, "Translation provider consent happens inside the review UI")
        XCTAssertEqual(externalOpens, 0)

        workspace.close()
        XCTAssertNil(workspace.pluginPanelRequest)
        XCTAssertEqual(request.sourceText, sourceText, "The captured value is immutable")
        XCTAssertEqual(request.documentRevision, capturedRevision)
    }

    func testTranslationCommandAvailabilityMatchesWorkspaceModePolicy() throws {
        let pdfURL = try writeTextPDF("번역 메뉴 모드 정책")
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: pdfURL))
        let translation = makeAction(
            id: "translate-current-page",
            output: .translatePanel,
            template: "{{page.text}}"
        )
        let browser = makeAction(
            id: "open-browser",
            output: .browserPanel,
            template: "https://www.google.com/"
        )

        workspace.setMode(.viewer)
        XCTAssertTrue(PluginCommandAvailability.isAvailable(
            translation,
            workspace: workspace
        ))

        workspace.setMode(.editing)
        XCTAssertFalse(PluginCommandAvailability.isAvailable(
            translation,
            workspace: workspace
        ))
        XCTAssertTrue(
            PluginCommandAvailability.isAvailable(browser, workspace: workspace),
            "Only translation is restricted to viewing and study modes"
        )

        workspace.setMode(.study)
        XCTAssertTrue(PluginCommandAvailability.isAvailable(
            translation,
            workspace: workspace
        ))
    }

    func testSharedLauncherOpensTrustedBrowserPanelForTheCurrentWorkspace() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePackage = projectRoot.appendingPathComponent(
            "Examples/Plugins/WebBrowser.hwattakplugin",
            isDirectory: true
        )
        let bundledDirectory = testRoot.appendingPathComponent(
            "BundledPlugins",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundledDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.copyItem(
            at: sourcePackage,
            to: bundledDirectory.appendingPathComponent(
                "WebBrowser.hwattakplugin",
                isDirectory: true
            )
        )
        let manager = PluginManager(
            pluginsDirectory: pluginsDirectory,
            defaults: defaults,
            hostVersion: "0.8.0",
            bundledPluginsDirectory: bundledDirectory
        )
        let inspection = try XCTUnwrap(manager.availableBundledPlugins.first)
        try manager.install(inspection, replacingExisting: false)
        let plugin = try XCTUnwrap(manager.installedPlugins.first)
        let action = try XCTUnwrap(plugin.manifest.actions.first)
        let pdfURL = try writeTextPDF("툴바에서 웹 브라우저 패널 열기")
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: pdfURL))

        var approvalCount = 0
        let runner = PluginActionRunner(environment: PluginRuntimeEnvironment(
            showText: { _, _ in XCTFail("Unexpected text dialog") },
            writeClipboard: { _ in
                XCTFail("Unexpected clipboard write")
                return false
            },
            approveExternalURL: { _, _, _ in
                XCTFail("Unexpected default-browser approval")
                return false
            },
            openExternalURL: { _ in
                XCTFail("Unexpected default-browser open")
                return false
            },
            approvePanelURL: { _, _, kind in
                approvalCount += 1
                return kind == .browser
            }
        ))

        let effect = try PluginActionLauncher.run(
            manager: manager,
            plugin: plugin,
            action: action,
            workspace: workspace,
            runner: runner
        )
        guard case .openedPanel(let request) = effect else {
            return XCTFail("Expected the toolbar launcher to open a panel")
        }
        XCTAssertEqual(approvalCount, 1)
        XCTAssertEqual(request.kind, .browser)
        XCTAssertEqual(request.pluginIdentifier, plugin.id)
        XCTAssertEqual(request.manifestDigest, plugin.manifestDigest)
        XCTAssertEqual(workspace.pluginPanelRequest, request)

        try manager.setEnabled(false, identifier: plugin.id)
        XCTAssertThrowsError(try PluginActionLauncher.run(
            manager: manager,
            plugin: plugin,
            action: action,
            workspace: workspace,
            runner: runner
        ))
    }

    func testBrowserPanelRequiresDedicatedConsentWithoutOpeningTheDefaultBrowser() throws {
        let pdfURL = try writeTextPDF("브라우저 패널 동의 테스트")
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: pdfURL))
        let action = makeAction(
            id: "open-browser",
            output: .browserPanel,
            template: "https://www.google.com/"
        )
        let manifest = makeManifest(
            identifier: "org.example.browser",
            minimumHostVersion: "0.8.0",
            capabilities: [.embeddedWebBrowser],
            actions: [action]
        )
        let plugin = installedPlugin(manifest: manifest)
        var panelApprovals: [(String, URL, PluginPanelKind)] = []
        var defaultBrowserOpens = 0
        let environment = PluginRuntimeEnvironment(
            showText: { _, _ in XCTFail("Unexpected text dialog") },
            writeClipboard: { _ in
                XCTFail("Unexpected clipboard write")
                return false
            },
            approveExternalURL: { _, _, _ in
                XCTFail("A WebKit panel must use its dedicated disclosure")
                return false
            },
            openExternalURL: { _ in
                defaultBrowserOpens += 1
                return true
            },
            approvePanelURL: { pluginName, url, kind in
                panelApprovals.append((pluginName, url, kind))
                return panelApprovals.count == 2
            }
        )
        let runner = PluginActionRunner(environment: environment)

        do {
            try runner.run(plugin: plugin, action: action, workspace: workspace)
            XCTFail("The first in-app web consent should be cancelled")
        } catch PluginSystemError.externalURLCancelled {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(workspace.pluginPanelRequest)
        XCTAssertEqual(panelApprovals.count, 1)

        let effect = try runner.run(plugin: plugin, action: action, workspace: workspace)
        guard case .openedPanel(let request) = effect else {
            return XCTFail("Expected a browser panel request")
        }
        XCTAssertEqual(request.kind, .browser)
        XCTAssertEqual(request.initialURL, URL(string: "https://www.google.com/"))
        XCTAssertEqual(request.documentRevision, workspace.revision)
        XCTAssertEqual(panelApprovals.count, 2, "Consent is required on every open")
        XCTAssertEqual(panelApprovals.last?.2, .browser)
        XCTAssertEqual(defaultBrowserOpens, 0)
    }

    func testBrowserPanelRejectsNonstandardHTTPSPortBeforeConsent() throws {
        let action = makeAction(
            id: "open-browser",
            output: .browserPanel,
            template: "https://example.com:444/"
        )
        let manifest = makeManifest(
            identifier: "org.example.browser",
            minimumHostVersion: "0.8.0",
            capabilities: [.embeddedWebBrowser],
            actions: [action]
        )
        assertInvalidManifest(
            try encodedManifest(manifest),
            validator: PluginManifestValidator(hostVersion: "0.8.0"),
            contains: "browserPanel must use an allowed public HTTPS destination"
        )

        let pdfURL = try writeTextPDF("비표준 포트 차단 테스트")
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: pdfURL))
        var panelApprovals = 0
        let environment = PluginRuntimeEnvironment(
            showText: { _, _ in XCTFail("Unexpected text dialog") },
            writeClipboard: { _ in
                XCTFail("Unexpected clipboard write")
                return false
            },
            approveExternalURL: { _, _, _ in
                XCTFail("Unexpected external URL approval")
                return false
            },
            openExternalURL: { _ in
                XCTFail("Unexpected default-browser open")
                return false
            },
            approvePanelURL: { _, _, _ in
                panelApprovals += 1
                return true
            }
        )
        let runner = PluginActionRunner(environment: environment)

        do {
            _ = try runner.run(
                plugin: installedPlugin(manifest: manifest),
                action: action,
                workspace: workspace
            )
            XCTFail("A browser panel using a nonstandard HTTPS port must be rejected")
        } catch PluginSystemError.externalURLRejected {
            // Expected before any consent UI is invoked.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(panelApprovals, 0)
        XCTAssertNil(workspace.pluginPanelRequest)
    }

    func testDocumentReplacementCloseAndHibernationRevokePanelRequests() throws {
        let firstURL = try writeTextPDF("첫 번째 문서")
        let secondURL = testRoot.appendingPathComponent("plugin-panel-second.pdf")
        try Data(contentsOf: firstURL).write(to: secondURL, options: [.atomic])
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: firstURL))

        workspace.pluginPanelRequest = panelRequest(for: workspace)
        XCTAssertTrue(workspace.hibernateIfPossible())
        XCTAssertNil(workspace.pluginPanelRequest)
        XCTAssertTrue(workspace.resumeIfNeeded())

        workspace.pluginPanelRequest = panelRequest(for: workspace)
        XCTAssertTrue(workspace.open(url: secondURL))
        XCTAssertNil(workspace.pluginPanelRequest)

        workspace.pluginPanelRequest = panelRequest(for: workspace)
        workspace.close()
        XCTAssertNil(workspace.pluginPanelRequest)
    }

    private func makeManifest(
        schemaVersion: Int = HwattakPluginLimits.manifestSchemaVersion,
        identifier: String = "com.example.fixture",
        version: String = "1.0.0",
        minimumHostVersion: String? = nil,
        capabilities: [PluginCapability] = [],
        actions: [PluginActionManifest]? = nil
    ) -> PluginManifest {
        PluginManifest(
            schemaVersion: schemaVersion,
            identifier: identifier,
            displayName: "Fixture Plug-in",
            version: version,
            author: "HwattakPDF Tests",
            description: "A deterministic declarative plug-in fixture.",
            minimumHostVersion: minimumHostVersion,
            capabilities: capabilities,
            actions: actions ?? [makeAction()]
        )
    }

    private func makeAction(
        id: String = "show",
        title: String = "Show fixture",
        output: PluginActionOutput = .showText,
        template: String = "Fixture"
    ) -> PluginActionManifest {
        PluginActionManifest(
            id: id,
            title: title,
            description: "Fixture action",
            output: output,
            template: template
        )
    }

    private func encodedManifest(_ manifest: PluginManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private func mutatedManifestData(
        _ mutation: (inout [String: Any]) -> Void
    ) throws -> Data {
        let data = try encodedManifest(makeManifest())
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        mutation(&root)
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func rawManifestData(
        rootPrefix: String = "",
        actionPrefix: String = ""
    ) -> Data {
        Data(
            """
            {
              \(rootPrefix)
              "schemaVersion": 1,
              "identifier": "org.example.raw-json",
              "displayName": "Raw JSON Fixture",
              "version": "1.0.0",
              "author": "HwattakPDF Tests",
              "description": "Raw scanner fixture",
              "capabilities": [],
              "actions": [{
                \(actionPrefix)
                "id": "show",
                "title": "Show",
                "description": "Fixture action",
                "output": "showText",
                "template": "Fixture"
              }]
            }
            """.utf8
        )
    }

    private func writeSourcePackage(
        manifest: PluginManifest,
        auxiliaryFiles: [String: Data] = [:]
    ) throws -> URL {
        try writeSourcePackage(
            manifestData: encodedManifest(manifest),
            auxiliaryFiles: auxiliaryFiles
        )
    }

    private func writeSourcePackage(
        manifestData: Data,
        auxiliaryFiles: [String: Data] = [:]
    ) throws -> URL {
        let sourceDirectory = testRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let package = sourceDirectory.appendingPathComponent(
            "\(UUID().uuidString).hwattakplugin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try manifestData.write(
            to: package.appendingPathComponent("manifest.json"),
            options: [.atomic]
        )
        for (name, data) in auxiliaryFiles {
            try data.write(to: package.appendingPathComponent(name), options: [.atomic])
        }
        return package
    }

    private func writeTextPDF(_ text: String) throws -> URL {
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 720, height: 900))
        textView.backgroundColor = .white
        textView.textColor = .black
        textView.font = .systemFont(ofSize: 17)
        textView.string = text
        let pageData = textView.dataWithPDF(inside: textView.bounds)
        let pageDocument = try XCTUnwrap(PDFDocument(data: pageData))
        let document = PDFDocument()
        document.insert(try XCTUnwrap(pageDocument.page(at: 0)), at: 0)
        let url = testRoot.appendingPathComponent("plugin-panel-text.pdf")
        XCTAssertTrue(document.write(to: url))
        return url
    }

    private func panelRequest(for workspace: PDFWorkspaceState) -> PluginPanelRequest {
        PluginPanelRequest(
            pluginIdentifier: "org.example.panel",
            manifestDigest: "fixture-digest",
            documentRevision: workspace.revision,
            pluginName: "Panel Fixture",
            actionID: "open",
            title: "Open",
            kind: .browser,
            initialURL: URL(string: "https://example.com/")
        )
    }

    private func installedPlugin(
        manifest: PluginManifest,
        isEnabled: Bool = true
    ) -> InstalledPlugin {
        InstalledPlugin(
            manifest: manifest,
            installURL: pluginsDirectory.appendingPathComponent(
                "\(manifest.identifier).hwattakplugin",
                isDirectory: true
            ),
            manifestDigest: "fixture-digest",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isEnabled: isEnabled
        )
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func assertInvalidManifest(
        _ expression: @autoclosure () throws -> PluginManifest,
        contains expectedDetail: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("Expected invalid manifest", file: file, line: line)
        } catch PluginSystemError.invalidManifest(let detail) {
            XCTAssertTrue(
                detail.contains(expectedDetail),
                "Expected '\(expectedDetail)' in '\(detail)'",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertInvalidManifest(
        _ data: Data,
        validator: PluginManifestValidator,
        contains expectedDetail: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertInvalidManifest(
            try validator.decodeAndValidate(data),
            contains: expectedDetail,
            file: file,
            line: line
        )
    }

    private func assertInvalidPackage(
        _ expression: @autoclosure () throws -> PluginPackageInspection,
        contains expectedDetail: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("Expected invalid package", file: file, line: line)
        } catch PluginSystemError.invalidPackage(let detail) {
            XCTAssertTrue(
                detail.contains(expectedDetail),
                "Expected '\(expectedDetail)' in '\(detail)'",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertExternalURLRejected(
        _ expression: @autoclosure () throws -> URL,
        value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("Expected URL rejection: \(value)", file: file, line: line)
        } catch PluginSystemError.externalURLRejected {
            // Expected.
        } catch {
            XCTFail("Unexpected error for \(value): \(error)", file: file, line: line)
        }
    }
}

private final class ActivationFailingFileManager: FileManager {
    let activationRoot: URL
    var failNextActivationMove = false

    init(activationRoot: URL) {
        self.activationRoot = activationRoot.standardizedFileURL
        super.init()
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        let sourceParentIsStaging = sourceURL
            .deletingLastPathComponent()
            .lastPathComponent
            .hasPrefix(".staging-")
        let destinationIsActivePackage = destinationURL
            .deletingLastPathComponent()
            .standardizedFileURL == activationRoot
            && destinationURL.pathExtension.lowercased() == "hwattakplugin"
        if failNextActivationMove, sourceParentIsStaging, destinationIsActivePackage {
            failNextActivationMove = false
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "Injected activation failure"]
            )
        }
        try super.moveItem(at: sourceURL, to: destinationURL)
    }
}
