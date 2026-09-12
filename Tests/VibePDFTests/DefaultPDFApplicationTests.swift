// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import VibePDF

@MainActor
final class DefaultPDFApplicationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DefaultPDFApplication-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testRefreshingReadsCurrentAssociationWithoutCreatingFilesOrOpeningFinder() {
        let app = root.appendingPathComponent("HwattakPDF.app")
        var current: URL?
        let model = DefaultPDFApplicationModel(
            applicationURL: app,
            lookupApplication: { current },
            applicationName: { $0.deletingPathExtension().lastPathComponent },
            prepareSetupPDF: { XCTFail("Reading status must not prepare a file"); return self.root },
            revealFile: { _ in XCTFail("Reading status must not open Finder") }
        )
        model.refresh()
        XCTAssertNil(model.currentApplicationName)
        XCTAssertFalse(model.isDefault)

        current = root.appendingPathComponent("Preview.app")
        model.refresh()
        XCTAssertEqual(model.currentApplicationName, "Preview")
        XCTAssertFalse(model.isDefault)

        current = app
        model.refresh()
        XCTAssertTrue(model.isDefault)

        current = nil
        model.refresh()
        XCTAssertNil(model.currentApplicationURL)
        XCTAssertNil(model.currentApplicationName)
        XCTAssertFalse(model.isDefault, "Do not cache a local success flag")
    }

    func testSameBundleIdentifierAtAnotherLocationDoesNotMeanThisCopyIsDefault() throws {
        let running = try makeApp(in: "new")
        let old = try makeApp(in: "old")
        XCTAssertEqual(running.bundleIdentifier, old.bundleIdentifier)
        var current = old.bundleURL
        let model = DefaultPDFApplicationModel(applicationURL: running.bundleURL, lookupApplication: { current })
        model.refresh()
        XCTAssertEqual(model.currentApplicationName, "HwattakPDF")
        XCTAssertFalse(model.isDefault)
        current = running.bundleURL
        model.refresh()
        XCTAssertTrue(model.isDefault)
    }

    func testSymlinkToTheRunningApplicationIsRecognized() throws {
        let app = try makeApp(in: "installed")
        let alias = root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app.bundleURL)
        let model = DefaultPDFApplicationModel(applicationURL: app.bundleURL, lookupApplication: { alias })
        model.refresh()
        XCTAssertTrue(model.isDefault)
    }

    func testOpeningFinderNeverReportsSuccessUntilSystemAssociationChanges() {
        let app = root.appendingPathComponent("HwattakPDF.app")
        let sample = root.appendingPathComponent("setup.pdf")
        var current = root.appendingPathComponent("Preview.app")
        var revealed: [URL] = []
        let model = DefaultPDFApplicationModel(
            applicationURL: app,
            lookupApplication: { current },
            prepareSetupPDF: { sample },
            revealFile: { revealed.append($0) }
        )
        model.refresh()
        model.showSetupInFinder()
        XCTAssertEqual(revealed, [sample])
        XCTAssertEqual(model.feedback, .finderInstructions)
        XCTAssertFalse(model.isDefault)
        XCTAssertFalse(model.isPreparing)
        model.refresh() // The user may return without changing anything.
        XCTAssertFalse(model.isDefault)

        current = app
        model.refresh()
        XCTAssertTrue(model.isDefault)
        XCTAssertNil(model.feedback)

        current = root.appendingPathComponent("AnotherReader.app")
        model.refresh()
        XCTAssertFalse(model.isDefault)
    }

    func testFailedPreparationDoesNotOpenFinderAndAllowsRetry() {
        var attempts = 0
        var revealed = 0
        let failure = NSError(domain: "SetupTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot write"])
        let model = DefaultPDFApplicationModel(
            applicationURL: root.appendingPathComponent("HwattakPDF.app"),
            lookupApplication: { nil },
            prepareSetupPDF: {
                attempts += 1
                if attempts == 1 { throw failure }
                return self.root.appendingPathComponent("setup.pdf")
            },
            revealFile: { _ in revealed += 1 }
        )
        model.showSetupInFinder()
        XCTAssertEqual(model.feedback, .failure("Cannot write"))
        XCTAssertEqual(revealed, 0)
        XCTAssertFalse(model.isPreparing)
        XCTAssertFalse(model.isDefault)
        model.showSetupInFinder()
        XCTAssertEqual(revealed, 1)
        XCTAssertEqual(model.feedback, .finderInstructions)
    }

    func testDevelopmentExecutableCannotStartSetup() {
        let model = DefaultPDFApplicationModel(
            applicationURL: nil,
            lookupApplication: { nil },
            prepareSetupPDF: { XCTFail("A bare executable cannot be selected as an app"); return self.root },
            revealFile: { _ in XCTFail("Do not open Finder from an unsupported host") }
        )
        model.showSetupInFinder()
        XCTAssertNil(model.feedback)
        XCTAssertFalse(model.isPreparing)
        XCTAssertFalse(model.isDefault)
        XCTAssertNil(DefaultPDFApplicationModel.bundledApplicationURL())
    }

    func testReentrantSetupDoesNotCreateDuplicateFilesOrFinderRequests() {
        var model: DefaultPDFApplicationModel!
        var prepares = 0
        var reveals = 0
        model = DefaultPDFApplicationModel(
            applicationURL: root.appendingPathComponent("HwattakPDF.app"),
            lookupApplication: { nil },
            prepareSetupPDF: {
                prepares += 1
                XCTAssertTrue(model.isPreparing)
                model.showSetupInFinder()
                return self.root.appendingPathComponent("setup.pdf")
            },
            revealFile: { _ in reveals += 1 }
        )
        model.showSetupInFinder()
        XCTAssertEqual(prepares, 1)
        XCTAssertEqual(reveals, 1)
        XCTAssertFalse(model.isPreparing)
        model = nil
    }

    func testSetupFileIsSmallValidPDFAndCanBeRecreatedWithoutTouchingOtherFiles() throws {
        let untouched = root.appendingPathComponent("user-document.pdf")
        let original = Data("User-owned bytes".utf8)
        try original.write(to: untouched)
        let sample = try DefaultPDFSetupFile.prepare(cacheDirectory: root)
        XCTAssertEqual(sample.pathExtension, "pdf")
        let document = try XCTUnwrap(PDFDocument(url: sample))
        XCTAssertEqual(document.pageCount, 1)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(page.string?.contains("HwattakPDF") == true)
        XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 595, height: 842))
        XCTAssertGreaterThan(page.thumbnail(of: CGSize(width: 100, height: 140), for: .mediaBox).size.width, 0)
        XCTAssertLessThan(try Data(contentsOf: sample).count, 65_536)

        try Data("damaged setup file".utf8).write(to: sample)
        XCTAssertEqual(try DefaultPDFSetupFile.prepare(cacheDirectory: root), sample)
        XCTAssertEqual(PDFDocument(url: sample)?.pageCount, 1)
        try FileManager.default.removeItem(at: sample)
        XCTAssertEqual(try DefaultPDFSetupFile.prepare(cacheDirectory: root), sample)
        XCTAssertEqual(PDFDocument(url: sample)?.pageCount, 1)
        XCTAssertEqual(try Data(contentsOf: untouched), original)
    }

    func testSetupFileWriteFailurePreservesExistingFile() throws {
        let blocked = root.appendingPathComponent("HwattakPDF")
        let original = Data("not a directory".utf8)
        try original.write(to: blocked)
        XCTAssertThrowsError(try DefaultPDFSetupFile.prepare(cacheDirectory: root))
        XCTAssertEqual(try Data(contentsOf: blocked), original)
    }

    func testOnlyRunnableApplicationBundlesAreEligible() throws {
        let valid = try makeApp(in: "valid")
        XCTAssertEqual(DefaultPDFApplicationModel.bundledApplicationURL(in: valid), valid.bundleURL)
        let missingExecutable = try makeApp(in: "missing-executable", executable: false)
        XCTAssertNil(DefaultPDFApplicationModel.bundledApplicationURL(in: missingExecutable))
        let wrongPackage = try makeApp(in: "not-an-application", packageType: "BNDL")
        XCTAssertNil(DefaultPDFApplicationModel.bundledApplicationURL(in: wrongPackage))
    }

    func testLiveStatusLookupUsesTheSystemPDFTypeWithoutChangingIt() {
        let expected = NSWorkspace.shared.urlForApplication(toOpen: .pdf)
        let model = DefaultPDFApplicationModel(applicationURL: nil)
        model.refresh()
        XCTAssertEqual(model.currentApplicationURL, expected)
        XCTAssertEqual(NSWorkspace.shared.urlForApplication(toOpen: .pdf), expected)
    }

    private func makeApp(in directory: String, executable: Bool = true, packageType: String = "APPL") throws -> Bundle {
        let url = root.appendingPathComponent(directory).appendingPathComponent("HwattakPDF.app")
        let contents = url.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.vibepdf.test.default-app",
            "CFBundleName": "HwattakPDF",
            "CFBundleDisplayName": "HwattakPDF",
            "CFBundlePackageType": packageType,
            "CFBundleExecutable": "HwattakPDF"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if executable {
            let binary = macOS.appendingPathComponent("HwattakPDF")
            try Data("fixture only".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return try XCTUnwrap(Bundle(url: url))
    }
}
