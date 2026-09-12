// SPDX-License-Identifier: MPL-2.0

import AppKit
import XCTest
@testable import VibePDF

final class LocalizationAndIconSettingsTests: XCTestCase {
    private static let expectedLanguages = [
        "ko", "en", "fr", "de", "es", "ja", "zh-Hans", "ar", "pt", "vi"
    ]

    private static let requiredSemanticKeys: Set<String> = [
        "settings.title",
        "settings.default_pdf.title",
        "settings.default_pdf.description",
        "settings.default_pdf.current",
        "settings.default_pdf.unknown",
        "settings.default_pdf.active",
        "settings.default_pdf.set",
        "settings.default_pdf.refresh",
        "settings.default_pdf.failed",
        "settings.default_pdf.requires_app",
        "settings.default_pdf.location_hint",
        "settings.default_pdf.manual_title",
        "settings.default_pdf.manual_help",
        "settings.default_pdf.manual_note",
        "settings.default_pdf.revealed",
        "settings.language.title",
        "settings.icon.title",
        "settings.icon.runtime_notice",
        "menu.language",
        "menu.export_selected_pages",
        "menu.export_selected_pages.combined",
        "menu.export_selected_pages.individual",
        "security.open.title",
        "security.open.message",
        "security.open.retry",
        "security.open.privacy",
        "security.open.password",
        "security.export.menu",
        "security.export.title",
        "security.export.detail",
        "security.export.password",
        "security.export.confirm",
        "security.export.requirements",
        "security.export.mismatch",
        "security.export.save",
        "security.export.save_share",
        "security.export.saved",
        "security.export.shared",
        "security.export.password.empty",
        "security.export.password.length",
        "security.export.password.ascii",
        "security.export.validation_failed",
        "security.document_locked",
        "security.export.random_failed",
        "security.export.suggested_suffix",
        "security.owner_required",
        "security.page_extraction_not_allowed",
        "security.content_copying_not_allowed",
        "security.user_session_read_only",
        "about.introduction.1",
        "about.introduction.2",
        "about.introduction.3",
        "about.introduction.4",
        "about.introduction.5",
        "about.support.title",
        "about.support.detail",
        "security.save_protected_copy_required",
        "security.export.document_changed",
        "alert.save_changes.title",
        "action.add",
        "action.apply",
        "action.delete",
        "panel.title.save_selected_pages_combined",
        "panel.title.choose_individual_pages_folder",
        "panel.message.export_individual_pages",
        "status.exported_pages_combined",
        "status.exported_pages_individual",
        "error.invalid_page_selection",
        "error.invalid_png_scale",
        "error.selected_pages_cleanup_failed",
        "error.finish_inline_text_before_export",
        "error.external_file_modified",
        "새 HwattakPDF 창으로 분리",
        "status.opened_pages",
        "page.current_total",
        "comparison.selection_count",
        "comparison.lock_help.lock",
        "workspace.default_name",
        "workspace.menu_title",
        "workspace.menu_item",
        "workspace.current_accessibility",
        "workspace.move_tab",
        "tab.scroll_previous",
        "tab.scroll_next",
        "tab.stack_members",
        "page.sidebar.layout",
        "page.sidebar.layout.single",
        "page.sidebar.layout.facing",
        "page.sidebar.layout.four",
        "page.sidebar.layout_help",
        "page.sidebar.zoom_out",
        "page.sidebar.zoom_in",
        "page.sidebar.thumbnail_size",
        "page.sidebar.resize",
        "page.sidebar.resize_hint",
        "view.two_page.continuous.title",
        "view.two_page.continuous.help",
        "view.two_page.paged.title",
        "view.two_page.paged.help",
        "settings.pdf_input.title",
        "settings.pdf_input.description",
        "settings.pdf_input.zoom_modifier.label",
        "settings.pdf_input.zoom_modifier.option",
        "settings.pdf_input.zoom_modifier.command",
        "settings.pdf_input.zoom_modifier.disabled",
        "settings.pdf_input.horizontal_hint",
        "settings.performance.efficient_rendering",
        "settings.performance.efficient_rendering_detail",
        "settings.plugins.title",
        "settings.plugins.safety_note",
        "settings.plugins.resource_note",
        "plugins.safety.title",
        "plugins.safety.detail",
        "action.clear",
        "plugins.search.empty.detail",
        "plugins.search.empty.title",
        "plugins.search.placeholder",
        "plugins.settings",
        "plugins.settings.actions",
        "plugins.settings.author",
        "plugins.settings.browser_security",
        "plugins.settings.browser_start_page",
        "plugins.settings.browser_start_page_detail",
        "plugins.settings.enabled_detail",
        "plugins.settings.follow_app_language",
        "plugins.settings.identifier",
        "plugins.settings.information",
        "plugins.settings.installed",
        "plugins.settings.no_custom_options",
        "plugins.settings.options",
        "plugins.settings.reset",
        "plugins.settings.search_engine",
        "plugins.settings.search_engine_detail",
        "plugins.settings.translation_language",
        "plugins.settings.translation_language_detail",
        "plugins.settings.translation_provider",
        "plugins.settings.translation_provider_detail",
        "plugins.settings.translation_source",
        "plugins.settings.translation_source_detail",
        "plugins.settings.version",
        "plugins.settings.youtube_security",
        "plugins.settings.youtube_start_page",
        "plugins.settings.youtube_start_page_detail",
        "plugins.permissions.title",
        "plugins.permission.document_metadata",
        "plugins.permission.selected_text",
        "plugins.permission.clipboard",
        "plugins.permission.external_url",
        "plugins.resources.title",
        "plugins.resources.detail",
        "plugins.review.unsigned_notice",
        "plugins.external_url.message",
        "page.jump.label",
        "page.jump.placeholder",
        "page.jump.hint",
        "page.jump.invalid",
        "page.jump.help",
        "share_note.title",
        "share_note.privacy",
        "share_note.selection",
        "share_note.memo",
        "share_note.memo_count",
        "share_note.copy",
        "share_note.share",
        "ai.consent.total_size.value",
        "ai.controls.hide",
        "ai.controls.show",
        "ai.optional_tools",
        "ai.optional_tools.none",
        "ai.related_unavailable.help",
        "ai.pages.summary",
        "ai.pages.select",
        "ai.pages.popover.title",
        "ai.pages.range.label",
        "ai.pages.range.placeholder",
        "ai.pages.range.help",
        "ai.pages.range.add",
        "ai.pages.grid.title",
        "ai.pages.use_current",
        "ai.pages.import_sidebar",
        "ai.pages.selection_count",
        "ai.pages.maximum",
        "ai.pages.empty",
        "ai.pages.invalid_input",
        "ai.pages.too_many",
        "ai.pages.selection_required_help",
        "ai.consent.requested_pages",
        "ai.consent.included_pages",
        "ai.error.selected_pages.empty",
        "ai.error.selected_pages.too_many",
        "ai.error.selected_pages.out_of_bounds",
        "help.item.page_jump.title",
        "help.item.page_jump.detail",
        "help.item.sidebar_resize.title",
        "help.item.sidebar_resize.detail",
        "toolbar.primary.accessibility",
        "toolbar.context.accessibility",
        "toolbar.view_layout",
        "toolbar.mode_tools.show",
        "toolbar.mode_tools.hide",
        "view.focus.enter",
        "view.focus.exit",
        "view.focus.exit_help",
        "view.sidebar.show",
        "view.sidebar.position",
        "toolbar.insert",
        "study.palette.title",
        "study.ai.menu",
        "study.ai.translate",
        "study.ai.explain_terms",
        "study.ai.solve_steps",
        "study.markup.highlight",
        "study.markup.underline",
        "study.markup.color",
        "study.markup.thickness",
        "study.markup.opacity",
        "inline_text.alignment.left",
        "inline_text.alignment.center",
        "inline_text.alignment.right",
        "study.note.handwriting_help",
        "help.item.study_palette.title",
        "help.item.study_palette.detail",
        "help.item.study_markup_interop.title",
        "help.item.study_markup_interop.detail",
        "help.item.runtime_annotation_trust.title",
        "help.item.runtime_annotation_trust.detail",
        "help.item.plugin_permissions.detail",
        "help.item.plugin_safety.detail",
        "help.item.plugin_performance.detail",
        "action.back",
        "action.forward",
        "action.reload",
        "action.stop",
        "plugins.browser.address_placeholder",
        "plugins.browser.privacy",
        "plugins.bundled.title",
        "plugins.bundled.detail",
        "plugins.bundled.review_install",
        "plugins.bundled.translation.name",
        "plugins.bundled.translation.description",
        "plugins.bundled.translation.selection.title",
        "plugins.bundled.translation.selection.description",
        "plugins.bundled.translation.page.title",
        "plugins.bundled.translation.page.description",
        "plugins.bundled.youtube.name",
        "plugins.bundled.youtube.description",
        "plugins.bundled.youtube.open.title",
        "plugins.bundled.youtube.open.description",
        "plugins.bundled.browser.name",
        "plugins.bundled.browser.description",
        "plugins.bundled.browser.open.title",
        "plugins.bundled.browser.open.description",
        "plugins.error.current_page_text_required",
        "plugins.error.translation_mode",
        "plugins.panel.blocked_address",
        "plugins.panel.consent.destination.web",
        "plugins.panel.consent.destination.youtube",
        "plugins.panel.consent.message",
        "plugins.panel.consent.title",
        "plugins.panel.default_browser.continue",
        "plugins.panel.default_browser.title",
        "plugins.panel.dismiss_message",
        "plugins.panel.download_blocked",
        "plugins.panel.external_confirmation",
        "plugins.panel.file_drop_blocked",
        "plugins.panel.file_upload_blocked",
        "plugins.panel.invalid_address",
        "plugins.panel.media_capture_blocked",
        "plugins.panel.navigation_blocked",
        "plugins.panel.open_external",
        "plugins.panel.popup_blocked",
        "plugins.permission.current_page_text",
        "plugins.permission.embedded_browser",
        "plugins.permission.translation_service",
        "plugins.permission.youtube_content",
        "plugins.review.actions_title",
        "plugins.review.action.browser",
        "plugins.review.action.copy_text",
        "plugins.review.action.external_site",
        "plugins.review.action.open_url",
        "plugins.review.action.show_text",
        "plugins.review.action.translate",
        "plugins.review.action.youtube",
        "plugins.translation.character_count",
        "plugins.translation.consent.open_provider",
        "plugins.translation.consent.title",
        "plugins.translation.disclosure.clipboard",
        "plugins.translation.disclosure.google",
        "plugins.translation.empty.detail",
        "plugins.translation.empty.title",
        "plugins.translation.error.clipboard",
        "plugins.translation.error.empty_or_large",
        "plugins.translation.error.google_url",
        "plugins.translation.error.google_url_too_long",
        "plugins.translation.language_picker",
        "plugins.translation.open",
        "plugins.translation.privacy",
        "plugins.translation.provider.google",
        "plugins.translation.service_picker",
        "plugins.translation.source.page",
        "plugins.translation.source.selection",
        "plugins.translation.status.google_sent",
        "plugins.translation.status.prompt_copied",
        "plugins.youtube.privacy",
        "plugins.youtube.search_placeholder"
    ]

    /// A translated table may intentionally keep a small set of language-neutral
    /// tokens. Keep this list key-based instead of value-based: allowing every
    /// occurrence of a value such as "AI" or "PDF" could accidentally hide an
    /// untranslated sentence that merely happens to contain the same token.
    private static let intentionallyLanguageNeutralKeys: Set<String> = [
        "menu.pdf",
        "comparison.layout_label",
        "view.grid.four_overview",
        "ai.title",
        "ai.toolbar",
        "ai.role.assistant",
        "about.github",
        "settings.pdf_input.zoom_modifier.option",
        "settings.pdf_input.zoom_modifier.command",
        "help.key.command",
        "help.key.shift",
        "help.key.option",
        "help.key.control",
        "help.topic.ai.title",
        "search.navigator.compact_position",
        "search.navigator.query",
        "search.navigator.ocr_short_action"
    ]

    func testAllRequestedLanguagesAreAvailable() {
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), Self.expectedLanguages)
        XCTAssertEqual(AppLanguage.arabic.layoutDirection, .rightToLeft)
        XCTAssertTrue(
            AppLanguage.allCases
                .filter { $0 != .arabic }
                .allSatisfy { $0.layoutDirection == .leftToRight }
        )
    }

    func testInfoPlistAdvertisesEveryRequestedLocalization() throws {
        let infoURL = Self.projectRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let info = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(info["CFBundleLocalizations"] as? [String], Self.expectedLanguages)
        XCTAssertEqual(
            info["NSHumanReadableCopyright"] as? String,
            "Copyright © 2026 SeederPowerDrop"
        )
    }

    func testEveryLocalizationHasTheSameKeysAndFormatPlaceholders() throws {
        let localizationDirectory = Self.projectRoot
            .appendingPathComponent("Resources/Localization", isDirectory: true)

        let tables = try Dictionary(uniqueKeysWithValues: Self.expectedLanguages.map { language in
            let url = localizationDirectory
                .appendingPathComponent("\(language).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            return (language, try Self.loadStrings(at: url))
        })

        let korean = try XCTUnwrap(tables["ko"])
        XCTAssertTrue(Self.requiredSemanticKeys.isSubset(of: Set(korean.keys)))

        for language in Self.expectedLanguages {
            let table = try XCTUnwrap(tables[language])
            XCTAssertEqual(
                Set(table.keys),
                Set(korean.keys),
                "\(language) must contain the same localization keys as Korean"
            )

            for key in korean.keys {
                XCTAssertEqual(
                    Self.formatPlaceholders(in: table[key] ?? ""),
                    Self.formatPlaceholders(in: korean[key] ?? ""),
                    "Format placeholders differ for \(language): \(key)"
                )
            }

            XCTAssertNotEqual(
                table["view.two_page.continuous.title"],
                table["view.two_page.paged.title"],
                "\(language) must give the two two-page controls distinct names"
            )
            XCTAssertNotEqual(
                table["view.two_page.continuous.help"],
                table["view.two_page.paged.help"],
                "\(language) must explain the two two-page behaviors separately"
            )

            let interoperabilityDisclosure = try XCTUnwrap(
                table["help.item.study_markup_interop.detail"]
            )
            for technicalTerm in ["Stamp", "Highlight", "Underline"] {
                XCTAssertTrue(
                    interoperabilityDisclosure.contains(technicalTerm),
                    "\(language) must name the \(technicalTerm) interoperability boundary explicitly"
                )
            }

            let runtimeTrustDisclosure = try XCTUnwrap(
                table["help.item.runtime_annotation_trust.detail"]
            )
            XCTAssertGreaterThan(
                runtimeTrustDisclosure.count,
                80,
                "\(language) must explain the runtime annotation trust boundary"
            )
        }
    }

    func testNonEnglishLocalizationsDoNotFallBackToEnglishOrKoreanCopy() throws {
        let localizationDirectory = Self.projectRoot
            .appendingPathComponent("Resources/Localization", isDirectory: true)
        let englishURL = localizationDirectory
            .appendingPathComponent("en.lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        let english = try Self.loadStrings(at: englishURL)

        // Korean is the source language for many of the historical keys, while
        // English is the table that previously leaked into unfinished locales.
        // Check both failure modes across the complete table, not only a hand-picked
        // list of tutorial keys, so future UI copy receives the same protection.
        for language in Self.expectedLanguages where language != "en" && language != "ko" {
            let localizedURL = localizationDirectory
                .appendingPathComponent("\(language).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings")
            let localized = try Self.loadStrings(at: localizedURL)

            for key in english.keys.sorted() {
                let value = try XCTUnwrap(localized[key])

                XCTAssertFalse(
                    Self.containsHangul(value),
                    "\(language) still contains Korean copy for \(key): \(value)"
                )

                if value == english[key] {
                    XCTAssertTrue(
                        Self.intentionallyLanguageNeutralKeys.contains(key),
                        "\(language) still falls back verbatim to English for \(key): \(value)"
                    )
                }
            }
        }
    }

    func testSemanticLocalizationCanSwitchWithoutRelaunching() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppPreferences.languageDefaultsKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.languageDefaultsKey)
            }
        }

        var localizedSettingsTitles = Set<String>()
        for language in AppLanguage.allCases {
            defaults.set(language.rawValue, forKey: AppPreferences.languageDefaultsKey)
            let title = L10n.string("settings.title")
            XCTAssertFalse(title.isEmpty)
            XCTAssertNotEqual(title, "settings.title")
            localizedSettingsTitles.insert(title)
        }
        XCTAssertGreaterThan(localizedSettingsTitles.count, 4)
    }

    func testAllSelectableIconsAreValidSquareImages() throws {
        let resources = Self.projectRoot.appendingPathComponent("Resources", isDirectory: true)

        XCTAssertEqual(AppIconPreference.defaultValue, .foldWorkspace)
        for preference in AppIconPreference.allCases {
            let url = resources
                .appendingPathComponent(preference.resourceName)
                .appendingPathExtension("png")
            let image = try XCTUnwrap(NSImage(contentsOf: url), "Missing icon: \(url.path)")
            XCTAssertEqual(image.size.width, image.size.height)
            XCTAssertGreaterThanOrEqual(image.size.width, 512)
        }
    }

    func testTabBarBrandUsesTheCurrentlySelectedAppIcon() throws {
        let sourceURL = Self.projectRoot
            .appendingPathComponent("Sources/VibePDF/Views/PDFTabBar.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@EnvironmentObject private var iconManager: AppIconManager"))
        XCTAssertTrue(
            source.contains(
                "iconManager.currentImage\n                    ?? NSApplication.shared.applicationIconImage"
            )
        )
        XCTAssertFalse(
            source.contains("Image(systemName: \"doc.text.fill\")"),
            "The top-left brand must not drift back to a synthetic document symbol"
        )
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func loadStrings(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: String], "Invalid strings table: \(url.path)")
    }

    private static func formatPlaceholders(in value: String) -> [String] {
        // All app-localized format strings intentionally use object or decimal
        // substitutions. Restricting the scan avoids treating prose such as
        // “100% CPU” or “100% de CPU” as a printf placeholder.
        let pattern = #"%(?:\d+\$)?[@d]"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression?.matches(in: value, range: range).compactMap { match in
            guard
                let matchRange = Range(match.range, in: value),
                let conversion = value[matchRange].last
            else {
                return nil
            }
            return String(conversion)
        }.sorted() ?? []
    }

    private static func containsHangul(_ value: String) -> Bool {
        // Include modern syllables, canonical/compatibility jamo, and the extended
        // jamo blocks. Checking scalars avoids depending on the host ICU version's
        // interpretation of a regular-expression Unicode script property.
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF,
                 0x3130...0x318F,
                 0xA960...0xA97F,
                 0xAC00...0xD7AF,
                 0xD7B0...0xD7FF:
                return true
            default:
                return false
            }
        }
    }
}
