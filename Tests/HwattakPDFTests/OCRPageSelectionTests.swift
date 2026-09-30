// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class OCRPageSelectionTests: XCTestCase {
    func testAllAndCurrentPageScopesUseOriginalIndexes() throws {
        XCTAssertNil(try resolve(.all, "ignored", current: 50, count: 164))
        XCTAssertEqual(try resolve(.current, "ignored", current: 50, count: 164), [50])
        XCTAssertThrowsError(try resolve(.current, "", current: -1, count: 164))
        XCTAssertThrowsError(try resolve(.current, "", current: 164, count: 164))
        XCTAssertThrowsError(try resolve(.all, "", count: 0))
    }

    func testCustomSelectionNormalizesRangesWhitespaceAndDuplicates() throws {
        XCTAssertEqual(try resolve(.custom, " 8, 3-5, 1, 4, 3–4, 8—9, 10 ~ 11，2 "),
                       Array(0...4) + Array(7...10))
        XCTAssertEqual(try resolve(.custom, "2-2, 2"), [1])
    }

    func testEmptyMalformedAndReversedInputsAreRejected() {
        for input in ["", " ", ",", "1,", ",1", "1,,2", "-2", "2-", "1-2-3", "3-1", "one", "1 2", "1.5", "+1"] {
            XCTAssertThrowsError(try resolve(.custom, input), input)
        }
    }

    func testOutOfRangeAndOverflowCannotExpandInvalidRanges() {
        for input in ["0", "13", "1-13", "1-9223372036854775807", "999999999999999999999999999999999999999"] {
            XCTAssertThrowsError(try resolve(.custom, input), input)
        }
        XCTAssertThrowsError(try resolve(.custom, "1", count: -1))
    }

    func testCompactDescriptionIsCanonicalAndRoundTrips() throws {
        let indexes = [10, 2, 3, 4, 0, 7, 8, 8]
        let description = OCRPageSelection.compactDescription(indexes)
        XCTAssertEqual(description, "1, 3-5, 8-9, 11")
        XCTAssertEqual(try resolve(.custom, description), Array(Set(indexes)).sorted())
        XCTAssertEqual(OCRPageSelection.compactDescription([]), "")
    }

    func testConfigurationResolvesAndValidatesExplicitPages() throws {
        var configuration = OCRConfiguration()
        XCTAssertEqual(try configuration.resolvedPageIndexes(pageCount: 4), [0, 1, 2, 3])
        configuration.pageIndexes = [3, 1, 3]
        XCTAssertEqual(try configuration.resolvedPageIndexes(pageCount: 4), [1, 3])
        for indexes in [[], [-1], [4], [Int.max]] {
            configuration.pageIndexes = indexes
            XCTAssertThrowsError(try configuration.resolvedPageIndexes(pageCount: 4))
        }
    }

    func testConfigurationWithoutNewFieldDecodesAsFullDocument() throws {
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [1, 2]
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(configuration)
        ) as? [String: Any])
        oldJSON.removeValue(forKey: "pageIndexes")
        let decoded = try JSONDecoder().decode(
            OCRConfiguration.self,
            from: JSONSerialization.data(withJSONObject: oldJSON)
        )
        XCTAssertNil(decoded.pageIndexes)
        XCTAssertEqual(try decoded.resolvedPageIndexes(pageCount: 3), [0, 1, 2])
    }

    func testConfigurationFingerprintSeparatesScopesAndCanonicalizesOrder() {
        let all = OCRConfiguration()
        var first = all
        first.pageIndexes = [2, 0, 2]
        var equivalent = all
        equivalent.pageIndexes = [0, 2]
        var different = all
        different.pageIndexes = [1, 2]

        XCTAssertEqual(VisionOCRService.configurationFingerprint(for: first),
                       VisionOCRService.configurationFingerprint(for: equivalent))
        XCTAssertNotEqual(VisionOCRService.configurationFingerprint(for: first),
                          VisionOCRService.configurationFingerprint(for: all))
        XCTAssertNotEqual(VisionOCRService.configurationFingerprint(for: first),
                          VisionOCRService.configurationFingerprint(for: different))
    }

    func testConfigurationFingerprintInvalidatesPreviouslyAdoptedLegacyResults() throws {
        let configuration = OCRConfiguration()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        let oldFingerprint = VisionOCRService.fingerprint(
            for: Data("vision-explicit-languages-v1\0".utf8) + data
        )
        XCTAssertNotEqual(VisionOCRService.configurationFingerprint(for: configuration), oldFingerprint)
    }

    func testStrictCheckpointLoadRejectsSchema1WithoutMigratingButCompatibilityLoadRemainsAvailable() throws {
        let store = try makeStore()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let page = OCRPageResult(pageIndex: 1, text: "Unverified old result", observations: [],
                                 completedAt: timestamp, skippedBecauseTextExists: true)
        let legacy = LegacyCheckpointFixture(documentFingerprint: "legacy-document", pageCount: 3,
                                              pages: [1: page], updatedAt: timestamp)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: store.directory.appendingPathComponent("legacy-document.json"))

        XCTAssertNil(store.load(fingerprint: "legacy-document", pageCount: 3,
                                configurationFingerprint: "new-settings", requiresConfigurationMatch: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.checkpointDirectoryURL(
            fingerprint: "legacy-document", pageCount: 3, configurationFingerprint: "new-settings"
        ).path))
        let compatible = try XCTUnwrap(store.load(
            fingerprint: "legacy-document", pageCount: 3, configurationFingerprint: "new-settings"
        ))
        XCTAssertEqual(compatible.pages, [1: page])
    }

    func testStrictCheckpointLoadAcceptsMatchingSchema2AndIncrementalButRejectsDifferentSettings() throws {
        let store = try makeStore()
        var checkpoint = OCRCheckpoint(documentFingerprint: "schema2-document", pageCount: 3,
                                       configurationFingerprint: "matching-settings")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        checkpoint.updatedAt = timestamp
        checkpoint.pages[2] = OCRPageResult(pageIndex: 2, text: "Verified result", observations: [],
                                           completedAt: timestamp, skippedBecauseTextExists: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyURL = store.checkpointURL(fingerprint: checkpoint.documentFingerprint,
                                           configurationFingerprint: checkpoint.configurationFingerprint)
        try encoder.encode(checkpoint).write(to: legacyURL)

        XCTAssertNil(store.load(fingerprint: checkpoint.documentFingerprint, pageCount: 3,
                                configurationFingerprint: "different-settings", requiresConfigurationMatch: true))
        XCTAssertEqual(store.load(fingerprint: checkpoint.documentFingerprint, pageCount: 3,
                                  configurationFingerprint: checkpoint.configurationFingerprint,
                                  requiresConfigurationMatch: true), checkpoint)
        try FileManager.default.removeItem(at: legacyURL)
        XCTAssertEqual(store.load(fingerprint: checkpoint.documentFingerprint, pageCount: 3,
                                  configurationFingerprint: checkpoint.configurationFingerprint,
                                  requiresConfigurationMatch: true), checkpoint)
    }

    func testVisionDoesNotResumeSchema1TextUnderNewExplicitSettings() async throws {
        let store = try makeStore()
        let data = try makeTextPDF(pageCount: 3)
        let fingerprint = VisionOCRService.fingerprint(for: data)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = LegacyCheckpointFixture(documentFingerprint: fingerprint, pageCount: 3, pages: [
            1: OCRPageResult(pageIndex: 1, text: "Wrong old OCR", observations: [],
                             completedAt: timestamp, skippedBecauseTextExists: true)
        ], updatedAt: timestamp)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: store.directory.appendingPathComponent("\(fingerprint).json"))

        let result = try await VisionOCRService.recognize(
            pdfData: data, configuration: skipConfiguration(indexes: [1]), checkpointStore: store,
            progress: { _ in }
        )
        let sourceText = try XCTUnwrap(PDFDocument(data: data)?.page(at: 1)?.string)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(Set(result.pages.keys), [1])
        XCTAssertTrue(sourceText.contains("Selectable"))
        XCTAssertEqual(result.pages[1]?.text, sourceText)
        XCTAssertFalse(result.pages[1]?.text.contains("Wrong old OCR") == true)
    }

    func testVisionProcessesOnlySelectedPagesAndReportsOriginalPageNumbers() async throws {
        let store = try makeStore()
        let data = try makeTextPDF(pageCount: 5)
        var configuration = skipConfiguration(indexes: [3, 1, 3])
        let firstProgress = ProgressRecorder()
        let first = try await VisionOCRService.recognize(
            pdfData: data, configuration: configuration, checkpointStore: store,
            progress: firstProgress.append
        )
        XCTAssertEqual(first.pageCount, 5)
        XCTAssertEqual(Set(first.pages.keys), [1, 3])
        XCTAssertTrue(first.pages.values.allSatisfy(\.skippedBecauseTextExists))
        XCTAssertEqual(firstProgress.values, [
            .init(completed: 1, total: 2, currentPage: 2),
            .init(completed: 2, total: 2, currentPage: 4)
        ])

        let resumedProgress = ProgressRecorder()
        let resumed = try await VisionOCRService.recognize(
            pdfData: data, configuration: configuration, checkpointStore: store,
            progress: resumedProgress.append
        )
        XCTAssertEqual(first.pages.mapValues(\.text), resumed.pages.mapValues(\.text))
        XCTAssertEqual(resumedProgress.values, [
            .init(completed: 2, total: 2, currentPage: 2),
            .init(completed: 2, total: 2, currentPage: 4)
        ])

        configuration.pageIndexes = [0, 4]
        let changed = try await VisionOCRService.recognize(
            pdfData: data, configuration: configuration, checkpointStore: store,
            progress: { _ in }
        )
        XCTAssertEqual(Set(changed.pages.keys), [0, 4])
        XCTAssertNotEqual(changed.configurationFingerprint, first.configurationFingerprint)
    }

    func testResumedCheckpointCannotIncludeUnselectedPagesInResultsOrProgress() async throws {
        let store = try makeStore()
        let data = try makeTextPDF(pageCount: 4)
        let configuration = skipConfiguration(indexes: [2])
        var checkpoint = OCRCheckpoint(
            documentFingerprint: VisionOCRService.fingerprint(for: data), pageCount: 4,
            configurationFingerprint: VisionOCRService.configurationFingerprint(for: configuration)
        )
        for index in [0, 2, 3] {
            checkpoint.pages[index] = OCRPageResult(
                pageIndex: index, text: "Previously recognized page \(index + 1)",
                observations: [], completedAt: Date(), skippedBecauseTextExists: true
            )
        }
        try store.save(checkpoint)
        let progress = ProgressRecorder()
        let result = try await VisionOCRService.recognize(
            pdfData: data, configuration: configuration, checkpointStore: store,
            progress: progress.append
        )
        XCTAssertEqual(Set(result.pages.keys), [2])
        XCTAssertEqual(result.pageCount, 4)
        XCTAssertEqual(progress.values, [.init(completed: 1, total: 1, currentPage: 3)])
    }

    private func resolve(
        _ scope: OCRPageScope, _ input: String, current: Int = 0, count: Int = 12
    ) throws -> [Int]? {
        try OCRPageSelection.resolve(scope: scope, input: input,
                                     currentPageIndex: current, pageCount: count)
    }

    private func skipConfiguration(indexes: [Int]) -> OCRConfiguration {
        var configuration = OCRConfiguration()
        configuration.languages = ["en-US"]
        configuration.skipPagesWithText = true
        configuration.minimumExistingCharacters = 1
        configuration.pageIndexes = indexes
        return configuration
    }

    private func makeStore() throws -> OCRCheckpointStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-OCRPageSelectionTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return OCRCheckpointStore(directory: directory)
    }

    private func makeTextPDF(pageCount: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 20, y: 200)
            let string = NSAttributedString(
                string: "Selectable existing text on original page \(index + 1)",
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

private struct LegacyCheckpointFixture: Encodable {
    let schemaVersion = 1
    let documentFingerprint: String
    let pageCount: Int
    let pages: [Int: OCRPageResult]
    let updatedAt: Date
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [VisionOCRService.Progress] = []

    func append(_ progress: VisionOCRService.Progress) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(progress)
    }

    var values: [VisionOCRService.Progress] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
