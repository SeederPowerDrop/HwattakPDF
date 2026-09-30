// SPDX-License-Identifier: MPL-2.0

import Foundation
import Vision
import XCTest
@testable import HwattakPDF

final class OCRLanguageTests: XCTestCase {
    func testCatalogNormalizesDeduplicatesAndSortsLocalizedNames() {
        let catalog = OCRRecognitionLanguage.catalog(
            identifiers: ["ko-KR", " EN_us ", "fr-FR", "en-US", "", "zh-hant", "zh-Hans"],
            locale: Locale(identifier: "en-US")
        )

        XCTAssertEqual(catalog.map(\.id), ["zh-Hans", "zh-Hant", "en-US", "fr-FR", "ko-KR"])
        XCTAssertEqual(catalog.first(where: { $0.id == "ko-KR" })?.nativeName, "한국어")
        XCTAssertEqual(catalog.first(where: { $0.id == "en-US" })?.localizedName, "English")
        XCTAssertNotEqual(catalog[0].localizedName, catalog[1].localizedName)
    }

    func testCatalogDistinguishesRegionalVariantsAndVisionVietnameseIdentifier() {
        let catalog = OCRRecognitionLanguage.catalog(
            identifiers: ["pt-BR", "pt-PT", "vi-VT"],
            locale: Locale(identifier: "en-US")
        )

        XCTAssertEqual(Set(catalog.map(\.id)), ["pt-BR", "pt-PT", "vi-VT"])
        XCTAssertNotEqual(catalog[0].localizedName, catalog[1].localizedName)
        let vietnamese = catalog.first(where: { $0.id == "vi-VT" })
        XCTAssertEqual(vietnamese?.localizedName, "Vietnamese")
        XCTAssertEqual(vietnamese?.nativeName, "Tiếng Việt")
    }

    func testSearchFindsLocalNamesNativeNamesAndIdentifiers() throws {
        let catalog = OCRRecognitionLanguage.catalog(
            identifiers: ["fr-FR", "ko-KR"], locale: Locale(identifier: "en-US")
        )
        let french = try XCTUnwrap(catalog.first(where: { $0.id == "fr-FR" }))
        let korean = try XCTUnwrap(catalog.first(where: { $0.id == "ko-KR" }))

        XCTAssertTrue(french.matches(query: " francais "))
        XCTAssertTrue(french.matches(query: "French"))
        XCTAssertTrue(french.matches(query: "FR-fr"))
        XCTAssertTrue(korean.matches(query: "한국어"))
        XCTAssertTrue(korean.matches(query: " "))
        XCTAssertFalse(korean.matches(query: "Japanese"))
    }

    func testSelectionIntersectsSupportPreservingPriorityWithoutFallback() {
        let catalog = OCRRecognitionLanguage.catalog(
            identifiers: ["en-US", "ja-JP", "ko-KR"], locale: Locale(identifier: "en-US")
        )

        XCTAssertEqual(
            OCRRecognitionLanguage.selectedIdentifiers(
                from: ["ja-JP", "zz-XX", "EN_us", "ja-JP", "ko-KR"], available: catalog
            ),
            ["ja-JP", "en-US", "ko-KR"]
        )
        XCTAssertEqual(OCRRecognitionLanguage.selectedIdentifiers(from: [], available: catalog), [])
        XCTAssertEqual(OCRRecognitionLanguage.selectedIdentifiers(from: ["xx"], available: catalog), [])
    }

    func testInitialSelectionKeepsPreferencesOrUsesSupportedSystemLanguage() {
        let catalog = OCRRecognitionLanguage.catalog(
            identifiers: ["en-US", "fr-FR", "ja-JP", "ko-KR"], locale: Locale(identifier: "en-US")
        )

        XCTAssertEqual(
            OCRRecognitionLanguage.initialSelection(
                preferred: ["ko-KR", "unsupported", "en-US"], available: catalog,
                preferredSystemLanguages: ["fr-FR"]
            ), ["ko-KR", "en-US"]
        )
        XCTAssertEqual(
            OCRRecognitionLanguage.initialSelection(
                preferred: ["unsupported"], available: catalog, preferredSystemLanguages: ["fr-CA"]
            ), ["fr-FR"]
        )
        XCTAssertEqual(
            OCRRecognitionLanguage.initialSelection(
                preferred: [], available: catalog, preferredSystemLanguages: ["unsupported"]
            ), ["en-US"]
        )
        XCTAssertEqual(OCRRecognitionLanguage.initialSelection(preferred: ["en-US"], available: []), [])
    }

    func testRuntimeCatalogMatchesVisionForEachQuality() throws {
        for quality in [OCRRecognitionQuality.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = quality == .fast ? .fast : .accurate
            let supported = try request.supportedRecognitionLanguages()
            let catalog = try OCRRecognitionLanguage.supportedLanguages(quality: quality)

            XCTAssertFalse(catalog.isEmpty)
            XCTAssertEqual(Set(catalog.map(\.id)), Set(supported))
            XCTAssertTrue(catalog.allSatisfy { !$0.localizedName.isEmpty && !$0.nativeName.isEmpty })
        }
    }

    func testVisionHonorsLanguagePriorityAndDisablesAutomaticDetection() throws {
        let available = try OCRRecognitionLanguage.supportedLanguages()
        let chosen = Array(available.prefix(2).map(\.id).reversed())
        var configuration = OCRConfiguration()
        configuration.languages = chosen + ["unsupported-language"] + chosen
        configuration.useLanguageCorrection = false

        let request = try VisionOCRService.recognitionRequest(configuration: configuration)

        XCTAssertEqual(request.recognitionLanguages, chosen)
        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertFalse(request.automaticallyDetectsLanguage)
        XCTAssertFalse(request.usesLanguageCorrection)
    }

    func testNoSupportedSelectionFailsInsteadOfSilentlyUsingEnglish() throws {
        for selection in [[], ["unsupported-language"]] {
            var configuration = OCRConfiguration()
            configuration.languages = selection
            XCTAssertThrowsError(try VisionOCRService.recognitionRequest(configuration: configuration))
        }
    }

    func testFastBuilderDefaultsRetainSupportedLanguages() throws {
        var configuration = OCRConfiguration()
        configuration.recognitionQuality = .fast
        let available = try OCRRecognitionLanguage.supportedLanguages(quality: .fast)

        let request = try VisionOCRService.recognitionRequest(configuration: configuration)

        XCTAssertEqual(request.recognitionLevel, .fast)
        XCTAssertEqual(
            request.recognitionLanguages,
            OCRRecognitionLanguage.selectedIdentifiers(from: configuration.languages, available: available)
        )
        XCTAssertFalse(request.recognitionLanguages.isEmpty)
    }
}
