// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import XCTest
@testable import HwattakPDF

final class AboutContentTests: XCTestCase {
    func testAuthorIntroductionPreservesProvidedWordingAndParagraphOrder() {
        XCTAssertEqual(
            AboutContent.introductionParagraphs,
            [
                "모 PDF 프로그램을 유로로 구입해서 사용하고 있는데 이제는 기본적인 기능 조차 구독으로 바뀌어서 화딱지나서 바이브 코딩으로 만들었습니다.",
                "그 회사도 먹고 살기위해서 어쩔 수 없는 것을 알지만 기존에 유로 구입자에게 너무한 조치라서 만들었습니다.",
                "많은 사람들이 편리하게 사용했으면 합니다.",
                "그리고 평생 무료로 최대한 지원해드리며 소정의 tip만 받도록 하겠습니다.",
                "그리고 ERW FWS WRG"
            ]
        )
        XCTAssertEqual(
            AboutContent.introductionLocalizationKeys,
            (1...5).map { "about.introduction.\($0)" }
        )
    }

    func testIntroductionAndSupportCopyAreLocalizedInEveryAppLanguage() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppPreferences.languageDefaultsKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.languageDefaultsKey)
            }
        }

        var localizedIntroductions = Set<[String]>()
        var localizedSupportTitles = Set<String>()
        for language in AppLanguage.allCases {
            defaults.set(language.rawValue, forKey: AppPreferences.languageDefaultsKey)
            let paragraphs = AboutContent.localizedIntroductionParagraphs

            XCTAssertEqual(paragraphs.count, 5)
            XCTAssertTrue(
                paragraphs.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            )
            XCTAssertFalse(AboutContent.supportTitle.isEmpty)
            XCTAssertFalse(AboutContent.supportDetail.isEmpty)

            if language != .korean {
                XCTAssertNotEqual(paragraphs, AboutContent.introductionParagraphs)
                XCTAssertFalse(
                    AboutContent.supportDetail.contains("유일한 지원 수단"),
                    "\(language.rawValue) must not show the Korean support appeal"
                )
            }

            localizedIntroductions.insert(paragraphs)
            localizedSupportTitles.insert(AboutContent.supportTitle)
        }

        XCTAssertEqual(localizedIntroductions.count, AppLanguage.allCases.count)
        XCTAssertEqual(localizedSupportTitles.count, AppLanguage.allCases.count)
    }

    @MainActor
    func testAboutViewRendersAtReleaseWindowSizeInEveryAppLanguageAndAppearance() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppPreferences.languageDefaultsKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.languageDefaultsKey)
            }
        }

        let previewDirectory = ProcessInfo.processInfo.environment["HWATTAK_ABOUT_PREVIEWS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let previewDirectory {
            try FileManager.default.createDirectory(
                at: previewDirectory,
                withIntermediateDirectories: true
            )
        }

        for language in AppLanguage.allCases {
            defaults.set(language.rawValue, forKey: AppPreferences.languageDefaultsKey)
            for colorScheme in [ColorScheme.light, .dark] {
                let variant = "\(language.rawValue)-\(colorScheme == .dark ? "dark" : "light")"
                let rootView = AboutView(authorImage: AboutContent.authorImage())
                    .environment(\.locale, language.locale)
                    .environment(\.layoutDirection, language.layoutDirection)
                    .environment(\.colorScheme, colorScheme)
                let hostingView = NSHostingView(rootView: rootView)
                hostingView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
                hostingView.frame = NSRect(x: 0, y: 0, width: 840, height: 690)
                hostingView.layoutSubtreeIfNeeded()

                let representation = try XCTUnwrap(
                    hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
                )
                hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
                let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
                let backingBounds = hostingView.convertToBacking(hostingView.bounds)

                XCTAssertGreaterThan(png.count, 10_000, variant)
                XCTAssertEqual(
                    representation.pixelsWide,
                    Int(backingBounds.width.rounded()),
                    variant
                )
                XCTAssertEqual(
                    representation.pixelsHigh,
                    Int(backingBounds.height.rounded()),
                    variant
                )
                XCTAssertEqual(hostingView.bounds.width, 840, accuracy: 0.01, variant)
                XCTAssertEqual(hostingView.bounds.height, 690, accuracy: 0.01, variant)

                // Sample the empty dialog margin, clear of content in both
                // layout directions, to catch a window stuck in one appearance.
                let canvasColor = try XCTUnwrap(
                    representation.colorAt(
                        x: representation.pixelsWide * 10 / 840,
                        y: representation.pixelsHigh * 200 / 690
                    )?.usingColorSpace(.sRGB)
                )
                let brightness = (canvasColor.redComponent + canvasColor.greenComponent + canvasColor.blueComponent) / 3
                if colorScheme == .dark {
                    XCTAssertLessThan(brightness, 0.25, variant)
                } else {
                    XCTAssertGreaterThan(brightness, 0.80, variant)
                }

                if let previewDirectory {
                    let suffix = colorScheme == .dark ? "-dark" : ""
                    try png.write(
                        to: previewDirectory.appendingPathComponent("about-\(language.rawValue)\(suffix).png")
                    )
                }
            }
        }
    }

    func testPublishedLinksUseExactExpectedWebDestinations() throws {
        let githubURL = try XCTUnwrap(AboutContent.githubURL)
        let supportURL = try XCTUnwrap(AboutContent.supportURL)

        XCTAssertEqual(
            githubURL.absoluteString,
            "https://github.com/SeederPowerDrop/HwattakPDF"
        )
        XCTAssertEqual(supportURL.absoluteString, "https://buymeacoffee.com/master_chief")
    }

    func testExternalLinkValidationAllowsOnlyHTTPWebOriginsWithoutUserInfo() {
        XCTAssertNotNil(AboutContent.validatedExternalURL("https://example.com/path?q=1"))
        XCTAssertNotNil(AboutContent.validatedExternalURL("http://example.com"))

        XCTAssertNil(AboutContent.validatedExternalURL("file:///tmp/private.pdf"))
        XCTAssertNil(AboutContent.validatedExternalURL("javascript:alert(1)"))
        XCTAssertNil(AboutContent.validatedExternalURL("mailto:owner@example.com"))
        XCTAssertNil(AboutContent.validatedExternalURL("https://user@example.com/path"))
        XCTAssertNil(AboutContent.validatedExternalURL("https:///missing-host"))
    }

    func testUserProvidedArtworkIsReadableAndSquare() throws {
        let artworkURL = Self.projectRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(AboutContent.imageResourceName)
            .appendingPathExtension(AboutContent.imageResourceExtension)
        let image = try XCTUnwrap(NSImage(contentsOf: artworkURL))

        XCTAssertEqual(image.size.width, image.size.height)
        XCTAssertEqual(image.size.width, 640)
        XCTAssertGreaterThan(try Data(contentsOf: artworkURL).count, 10_000)
        XCTAssertNotNil(AboutContent.authorImage())
    }

    func testReleasePackagingScriptCopiesAndVerifiesArtworkAndLegalNotices() throws {
        let scriptURL = Self.projectRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("build_app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("ABOUT_IMAGE=\"AboutAuthor-SeederPowerDrop-UserProvided.jpg\""))
        XCTAssertTrue(script.contains("VERIFIED_APP}/Contents/Resources/${ABOUT_IMAGE}"))
        XCTAssertTrue(script.contains("LEGAL_DOCUMENTS=("))
        XCTAssertTrue(script.contains("\"TranslationCompanion.hwattakplugin\""))
        XCTAssertTrue(script.contains("\"WebBrowser.hwattakplugin\""))
        XCTAssertTrue(script.contains("SOURCE_ONLY_PLUGIN_NAMES=("))
        XCTAssertTrue(script.contains("\"YouTubeStudy.hwattakplugin\""))
        XCTAssertTrue(script.contains("Source-only plugin must not be packaged"))
        XCTAssertTrue(script.contains("Archived app contains source-only plugin"))
        XCTAssertTrue(script.contains("Contents/Resources/Legal/${legal_document}"))
        XCTAssertTrue(script.contains("AboutAuthor-UserProvided-NOTICE.txt"))
        XCTAssertTrue(script.contains("ARCHIVE_CHECKSUM_PATH=\"${ARCHIVE_PATH}.sha256\""))
        XCTAssertTrue(script.contains("rm -f \"${ARCHIVE_PATH}\" \"${ARCHIVE_CHECKSUM_PATH}\" \"${ARCHIVE_TEMPORARY}\""))
        XCTAssertTrue(script.contains("shasum -a 256"))
        XCTAssertTrue(script.contains("-file-prefix-map"))
        XCTAssertTrue(script.contains("strip -S -x"))
        XCTAssertTrue(script.contains("Release executable contains a local build path"))
        XCTAssertTrue(script.contains("grep -E '/Users/|/private/var/folders/|/var/folders/' >/dev/null"))
        XCTAssertFalse(script.contains("grep -Eq '/Users/|/private/var/folders/|/var/folders/'"))
        XCTAssertTrue(script.contains("--norsrc"))
        XCTAssertTrue(script.contains("--noextattr"))
        XCTAssertTrue(script.contains("Archive contains AppleDouble metadata"))
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
