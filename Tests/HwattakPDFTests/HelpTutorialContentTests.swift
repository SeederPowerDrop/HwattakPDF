// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import XCTest
@testable import HwattakPDF

@MainActor
final class HelpTutorialContentTests: XCTestCase {
    private var previousLanguage: String?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.string(
            forKey: AppPreferences.languageDefaultsKey
        )
        UserDefaults.standard.set(
            AppLanguage.korean.rawValue,
            forKey: AppPreferences.languageDefaultsKey
        )
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(
                previousLanguage,
                forKey: AppPreferences.languageDefaultsKey
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: AppPreferences.languageDefaultsKey
            )
        }
        super.tearDown()
    }

    func testTutorialCoversTheUserFacingAreasWithResolvedText() {
        let topics = HelpTutorialContent.topics

        XCTAssertEqual(
            topics.map(\.id),
            [
                "start", "modes", "tabs", "view", "compare", "edit",
                "signature", "ai", "plugins", "save", "shortcuts", "accessibility"
            ]
        )
        XCTAssertTrue(topics.allSatisfy { !$0.entries.isEmpty })
        XCTAssertTrue(topics.allSatisfy { !$0.title.hasPrefix("help.") })
        XCTAssertTrue(topics.allSatisfy { !$0.summary.hasPrefix("help.") })
        XCTAssertTrue(
            topics.flatMap(\.entries).allSatisfy {
                !$0.title.hasPrefix("help.") && !$0.detail.hasPrefix("help.")
            }
        )
    }

    func testTutorialSearchFindsLocalizedFeatureAndShortcut() {
        XCTAssertEqual(
            HelpTutorialContent.topics(matching: "서명").map(\.id),
            ["modes", "edit", "signature"]
        )
        XCTAssertEqual(
            HelpTutorialContent.topics(matching: "Command + S").map(\.id),
            ["save", "shortcuts"]
        )
        XCTAssertTrue(HelpTutorialContent.topics(matching: "존재하지 않는 기능").isEmpty)
    }

    func testPluginTutorialDocumentsInstallationPermissionsSafetyAndRecovery() throws {
        let plugins = try XCTUnwrap(
            HelpTutorialContent.topics.first { $0.id == "plugins" }
        )
        XCTAssertEqual(
            plugins.entries.map(\.id),
            [
                "plugin_install", "plugin_permissions", "plugin_safety",
                "plugin_performance"
            ]
        )

        let entries = Dictionary(uniqueKeysWithValues: plugins.entries.map { ($0.id, $0) })
        let installation = try XCTUnwrap(entries["plugin_install"])
        let permissions = try XCTUnwrap(entries["plugin_permissions"])
        let safety = try XCTUnwrap(entries["plugin_safety"])
        let performance = try XCTUnwrap(entries["plugin_performance"])

        XCTAssertTrue(installation.detail.contains("플러그인 관리"))
        XCTAssertTrue(installation.detail.contains(".hwattakplugin"))
        XCTAssertTrue(installation.detail.contains("요청 권한"))
        XCTAssertTrue(installation.detail.contains("활성화 스위치"))

        XCTAssertTrue(permissions.detail.contains("문서 정보"))
        XCTAssertTrue(permissions.detail.contains("선택 텍스트"))
        XCTAssertTrue(permissions.detail.contains("클립보드"))
        XCTAssertTrue(permissions.detail.contains("외부 링크"))
        XCTAssertTrue(permissions.detail.contains("현재 페이지 텍스트"))
        XCTAssertTrue(permissions.detail.contains("번역 서비스"))
        XCTAssertTrue(permissions.detail.contains("YouTube"))
        XCTAssertTrue(permissions.detail.contains("내장 웹 패널"))

        XCTAssertTrue(safety.detail.contains("검증된 선언형 템플릿"))
        XCTAssertTrue(safety.detail.contains("임의 코드"))
        XCTAssertTrue(safety.detail.contains("Keychain"))
        XCTAssertTrue(safety.detail.contains("원본 PDF 바이트"))
        XCTAssertTrue(safety.detail.contains("직접 네트워크와 GPU"))
        XCTAssertTrue(safety.detail.contains("v2 웹 패널"))
        XCTAssertTrue(safety.detail.contains("추적 방지기나 방화벽"))

        XCTAssertTrue(performance.detail.contains("32개"))
        XCTAssertTrue(performance.detail.contains("24개"))
        XCTAssertTrue(performance.detail.contains("2MB"))
        XCTAssertTrue(performance.detail.contains("CPU·GPU"))
        XCTAssertTrue(performance.detail.contains("비활성화"))
        XCTAssertTrue(performance.detail.contains("격리된 패키지"))

        XCTAssertEqual(
            HelpTutorialContent.topics(matching: ".hwattakplugin").map(\.id),
            ["plugins"]
        )
        XCTAssertEqual(
            HelpTutorialContent.topics(matching: "외부 링크").map(\.id),
            ["plugins"]
        )
        XCTAssertEqual(
            HelpTutorialContent.topics(matching: "격리된 패키지").map(\.id),
            ["plugins"]
        )
    }

    func testViewTutorialDocumentsDirectJumpAndResizablePagePanel() throws {
        let viewTopic = try XCTUnwrap(
            HelpTutorialContent.topics.first { $0.id == "view" }
        )
        let entries = Dictionary(uniqueKeysWithValues: viewTopic.entries.map { ($0.id, $0) })
        let pageJump = try XCTUnwrap(entries["page_jump"])
        let sidebarResize = try XCTUnwrap(entries["sidebar_resize"])
        let pageLayout = try XCTUnwrap(entries["page_layout"])

        XCTAssertTrue(pageJump.detail.contains("Return"))
        XCTAssertTrue(pageJump.detail.contains("Escape"))
        XCTAssertTrue(sidebarResize.detail.contains("구분선"))
        XCTAssertTrue(sidebarResize.detail.contains("너비"))
        XCTAssertTrue(sidebarResize.detail.contains("높이"))
        XCTAssertTrue(pageLayout.detail.contains("연속 2페이지"))
        XCTAssertTrue(pageLayout.detail.contains("고정 2페이지"))
        XCTAssertTrue(pageLayout.detail.contains("두 페이지 단위"))
        XCTAssertEqual(
            HelpTutorialContent.topics(matching: "페이지 번호").map(\.id),
            ["view"]
        )
        XCTAssertEqual(
            HelpTutorialContent.topics(matching: "구분선").map(\.id),
            ["view", "compare"]
        )
    }

    func testEditTutorialDocumentsDocumentWideUndoAndHistoryLimit() throws {
        let editTopic = try XCTUnwrap(
            HelpTutorialContent.topics.first { $0.id == "edit" }
        )
        let undoRedo = try XCTUnwrap(
            editTopic.entries.first { $0.id == "undo_redo" }
        )

        XCTAssertTrue(undoRedo.detail.contains("⌘Z"))
        XCTAssertTrue(undoRedo.detail.contains("⇧⌘Z"))
        XCTAssertTrue(undoRedo.detail.contains("22"))
        XCTAssertTrue(undoRedo.detail.contains("편집"))
    }

    func testDocumentedShortcutsMatchImplementedCommandChords() throws {
        let shortcutTopic = try XCTUnwrap(
            HelpTutorialContent.topics.first { $0.id == "shortcuts" }
        )
        let chords = Dictionary(
            uniqueKeysWithValues: shortcutTopic.entries.compactMap { entry in
                entry.shortcut.map { (entry.id, $0.components.joined()) }
            }
        )

        XCTAssertEqual(chords["shortcut_new_tab"], "⌘T")
        XCTAssertEqual(chords["shortcut_open"], "⌘O")
        XCTAssertEqual(chords["shortcut_close"], "⌘W")
        XCTAssertEqual(chords["shortcut_save"], "⌘S")
        XCTAssertEqual(chords["shortcut_save_copy"], "⌘⇧S")
        XCTAssertEqual(chords["shortcut_highlight"], "⌘⇧H")
        XCTAssertEqual(chords["shortcut_find"], "⌘F")
        XCTAssertEqual(chords["shortcut_mode_viewer"], "⌃1")
        XCTAssertEqual(chords["shortcut_mode_editing"], "⌃2")
        XCTAssertEqual(chords["shortcut_mode_study"], "⌃3")
        XCTAssertEqual(chords["shortcut_next_tab"], "⌘⇧]")
        XCTAssertEqual(chords["shortcut_previous_tab"], "⌘⇧[")
        XCTAssertEqual(chords["shortcut_settings"], "⌘,")
        XCTAssertEqual(chords["shortcut_undo"], "⌘Z")
        XCTAssertEqual(chords["shortcut_redo"], "⌘⇧Z")
        XCTAssertEqual(chords["shortcut_compare_exit"], "⎋")
        XCTAssertEqual(chords["shortcut_help"], "⌘?")
    }

    func testModeTutorialExplainsTheThreeFocusedContexts() throws {
        let modes = try XCTUnwrap(
            HelpTutorialContent.topics.first { $0.id == "modes" }
        )
        XCTAssertEqual(
            modes.entries.map(\.id),
            [
                "mode_viewer", "mode_editing", "mode_study", "study_palette",
                "study_markup_interop", "runtime_annotation_trust"
            ]
        )
        XCTAssertEqual(
            modes.entries.compactMap { $0.shortcut?.components.joined() },
            ["⌃1", "⌃2", "⌃3"]
        )
        XCTAssertTrue(modes.entries[0].detail.contains("본문 직접 편집"))
        XCTAssertTrue(modes.entries[1].detail.contains("오버레이"))
        XCTAssertTrue(modes.entries[1].detail.contains("원본"))
        XCTAssertTrue(modes.entries[2].detail.contains("계산"))
        XCTAssertTrue(modes.entries[3].detail.contains("미리보기"))
        XCTAssertTrue(modes.entries[3].detail.contains("Sidecar"))
        XCTAssertTrue(modes.entries[3].detail.contains("Command-Z"))
        XCTAssertTrue(modes.entries[4].detail.contains("Stamp"))
        XCTAssertTrue(modes.entries[4].detail.contains("Highlight/Underline"))
        XCTAssertTrue(modes.entries[5].detail.contains("현재 앱 실행"))
        XCTAssertTrue(modes.entries[5].detail.contains("저장 후"))
        XCTAssertTrue(modes.entries[5].detail.contains("휴면"))
        XCTAssertTrue(modes.entries[5].detail.contains("에디팅 모드"))
        XCTAssertTrue(modes.entries[5].detail.contains("공개 마커"))
        XCTAssertTrue(modes.entries[5].detail.contains("삭제 권한"))
        XCTAssertEqual(
            HelpTutorialContent.topics(matching: "Stamp").map(\.id),
            ["modes"]
        )
        XCTAssertEqual(
            HelpTutorialContent.topics(matching: "공개 마커").map(\.id),
            ["modes"]
        )
    }

    func testEveryTutorialSymbolExistsOnTheMinimumSupportedRuntime() {
        let symbols = HelpTutorialContent.topics.flatMap { topic in
            [topic.systemImage] + topic.entries.map(\.systemImage)
        }

        for symbol in Set(symbols) {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "Missing SF Symbol: \(symbol)"
            )
        }
    }

    func testAppRegistersOneTutorialSceneAndTheStandardHelpCommand() throws {
        let appSource = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/HwattakPDF/App/HwattakPDFApp.swift"),
            encoding: .utf8
        )
        let helpSource = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/HwattakPDF/Views/HelpTutorialView.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(
            appSource.components(
                separatedBy: "id: HelpTutorialContent.sceneID"
            ).count - 1,
            1
        )
        XCTAssertTrue(helpSource.contains("CommandGroup(replacing: .help)"))
        XCTAssertTrue(helpSource.contains("keyboardShortcut(\"?\", modifiers: .command)"))
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
