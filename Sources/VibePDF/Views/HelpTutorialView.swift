// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Stable integration points for the app scene and Help menu.
///
/// `VibePDFApp` owns scene registration, so this file deliberately exposes a
/// scene identifier and a self-contained view instead of registering a second
/// app or settings scene.
enum HelpTutorialContent {
    static let sceneID = "help-tutorial"

    static var windowTitle: String {
        L10n.string("help.title", defaultValue: "HwattakPDF 사용법")
    }

    static var topics: [HelpTutorialTopic] {
        [
            topic(
                "start",
                icon: "sparkles.rectangle.stack",
                entries: [
                    entry("open", icon: "folder.fill", shortcut: .command("O")),
                    entry("layout", icon: "rectangle.3.group"),
                    entry("resume", icon: "clock.arrow.circlepath")
                ]
            ),
            topic(
                "modes",
                icon: "rectangle.3.group",
                entries: [
                    entry("mode_viewer", icon: "eye", shortcut: .control("1")),
                    entry("mode_editing", icon: "pencil.and.outline", shortcut: .control("2")),
                    entry("mode_study", icon: "graduationcap", shortcut: .control("3")),
                    entry("study_palette", icon: "paintpalette"),
                    entry("study_markup_interop", icon: "paintpalette"),
                    entry("runtime_annotation_trust", icon: "lock.shield")
                ]
            ),
            topic(
                "tabs",
                icon: "square.stack.3d.up.fill",
                entries: [
                    entry("tab_stack", icon: "square.stack.3d.up.fill"),
                    entry("unstack", icon: "arrow.up.forward.square"),
                    entry("workspace", icon: "rectangle.3.group"),
                    entry("resources", icon: "gauge.with.dots.needle.67percent")
                ]
            ),
            topic(
                "view",
                icon: "rectangle.split.2x1",
                entries: [
                    entry("page_panel", icon: "rectangle.leadinghalf.inset.filled"),
                    entry("page_jump", icon: "number.square"),
                    entry("search_navigator", icon: "text.magnifyingglass", shortcut: .command("F")),
                    entry("sidebar_resize", icon: "rectangle.split.2x1"),
                    entry("page_layout", icon: "rectangle.split.2x1"),
                    entry("zoom_pan", icon: "plus.magnifyingglass"),
                    entry("thumbnails", icon: "rectangle.grid.2x2")
                ]
            ),
            topic(
                "compare",
                icon: "rectangle.on.rectangle.angled",
                entries: [
                    entry("compare_start", icon: "rectangle.on.rectangle.angled"),
                    entry("compare_layout", icon: "rectangle.split.2x1"),
                    entry("compare_sync", icon: "link")
                ]
            ),
            topic(
                "edit",
                icon: "pencil.and.outline",
                entries: [
                    entry("tools", icon: "cursorarrow"),
                    entry("inline_text", icon: "character.cursor.ibeam"),
                    entry("visual_text_replacement", icon: "exclamationmark.shield"),
                    entry("undo_redo", icon: "arrow.uturn.backward.circle"),
                    entry("markup", icon: "highlighter"),
                    entry("pages", icon: "rectangle.stack.badge.plus"),
                    entry("ocr", icon: "text.viewfinder"),
                    entry("move_delete", icon: "move.3d")
                ]
            ),
            topic(
                "signature",
                icon: "signature",
                entries: [
                    entry("signature_capture", icon: "hand.draw"),
                    entry("signature_secure", icon: "key.fill"),
                    entry("signature_place", icon: "cursorarrow.motionlines")
                ]
            ),
            topic(
                "ai",
                icon: "sparkles",
                entries: [
                    entry("ai_setup", icon: "key.horizontal.fill"),
                    entry("ai_actions", icon: "text.magnifyingglass"),
                    entry("ai_privacy", icon: "hand.raised.fill")
                ]
            ),
            topic(
                "plugins",
                titleDefault: "플러그인",
                summaryDefault: "필요한 기능을 안전하게 추가하고 권한과 리소스 사용을 관리합니다.",
                icon: "puzzlepiece.extension",
                entries: [
                    entry(
                        "plugin_install",
                        titleDefault: "설치와 관리",
                        detailDefault: "메뉴 막대의 플러그인 > 플러그인 관리…를 여세요. 앱에 포함된 번역·웹 브라우저는 ‘HwattakPDF 기본 플러그인’에서 검토 및 설치할 수 있고, v1 .hwattakplugin 폴더도 직접 선택할 수 있습니다. 설치 전 이름, 제작자, 버전, 작업별 외부 연결과 요청 권한을 확인하세요.",
                        icon: "square.and.arrow.down"
                    ),
                    entry(
                        "plugin_permissions",
                        titleDefault: "최소 권한 검토",
                        detailDefault: "v1 권한과 별도로 v2는 현재 페이지 텍스트, 번역 서비스, YouTube, 임베디드 공개 HTTPS 브라우저 권한을 구분합니다. 설치 검토 화면에서 각 작업의 데이터 출처와 목적지를 확인하고 목적에 필요하지 않은 권한을 요청하면 설치하지 마세요.",
                        icon: "hand.raised.fill"
                    ),
                    entry(
                        "plugin_safety",
                        titleDefault: "안전성과 신뢰 경계",
                        detailDefault: "패키지는 검증된 선언만 담고 임의 코드, 셸, Keychain, 원본 PDF 바이트나 GPU에 접근할 수 없습니다. v1은 직접 네트워크를 쓰지 않지만, 앱 검토본과 해시가 일치해야 설치되는 v2 패널은 외부 사이트를 앱 안에서 엽니다. 임시 세션이어도 원격 JavaScript·쿠키·추적과 하위 리소스 요청은 가능하므로 전송 확인을 읽고 민감한 작업은 기본 브라우저를 사용하세요.",
                        icon: "checkmark.shield"
                    ),
                    entry(
                        "plugin_performance",
                        titleDefault: "성능과 문제 해결",
                        detailDefault: "플러그인은 최대 32개, 플러그인당 액션 24개, 패키지당 2MB로 제한되며 필요할 때만 실행되어 평소 CPU·GPU 작업을 만들지 않습니다. 앱이 느려지거나 오류가 반복되면 해당 플러그인을 비활성화하고 목록을 새로 고친 뒤 격리된 패키지 메시지를 확인하거나 제거하세요.",
                        icon: "gauge.with.dots.needle.67percent"
                    )
                ]
            ),
            topic(
                "save",
                icon: "square.and.arrow.down",
                entries: [
                    entry("save_choices", icon: "square.and.arrow.down", shortcut: .command("S")),
                    entry("save_copy", icon: "doc.on.doc", shortcut: .commandShift("S")),
                    entry("save_close", icon: "exclamationmark.circle"),
                    entry("session_vs_pdf", icon: "externaldrive.badge.checkmark")
                ]
            ),
            HelpTutorialTopic(
                id: "shortcuts",
                title: text("help.topic.shortcuts.title"),
                summary: text("help.topic.shortcuts.summary"),
                systemImage: "command",
                entries: [
                    shortcutEntry("new_tab", shortcut: .command("T")),
                    shortcutEntry("open", shortcut: .command("O")),
                    shortcutEntry("close", shortcut: .command("W")),
                    shortcutEntry("save", shortcut: .command("S")),
                    shortcutEntry("save_copy", shortcut: .commandShift("S")),
                    shortcutEntry("highlight", shortcut: .commandShift("H")),
                    shortcutEntry("find", shortcut: .command("F")),
                    shortcutEntry("mode_viewer", shortcut: .control("1")),
                    shortcutEntry("mode_editing", shortcut: .control("2")),
                    shortcutEntry("mode_study", shortcut: .control("3")),
                    shortcutEntry("next_tab", shortcut: .commandShift("]")),
                    shortcutEntry("previous_tab", shortcut: .commandShift("[")),
                    shortcutEntry("settings", shortcut: .command(",")),
                    shortcutEntry("undo", shortcut: .command("Z")),
                    shortcutEntry("redo", shortcut: .commandShift("Z")),
                    shortcutEntry("compare_exit", shortcut: .plain("⎋")),
                    shortcutEntry("help", shortcut: .command("?"))
                ]
            ),
            topic(
                "accessibility",
                icon: "accessibility",
                entries: [
                    entry("accessibility_labels", icon: "voiceover"),
                    entry("accessibility_keyboard", icon: "keyboard"),
                    entry("accessibility_display", icon: "circle.lefthalf.filled")
                ]
            )
        ]
    }

    static func topics(matching query: String) -> [HelpTutorialTopic] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return topics }
        return topics.compactMap { topic in
            if topic.matches(normalized) {
                return topic.filtered(matching: normalized)
            }
            return nil
        }
    }

    private static func topic(
        _ id: String,
        titleDefault: String? = nil,
        summaryDefault: String? = nil,
        icon: String,
        entries: [HelpTutorialEntry]
    ) -> HelpTutorialTopic {
        HelpTutorialTopic(
            id: id,
            title: text("help.topic.\(id).title", defaultValue: titleDefault),
            summary: text("help.topic.\(id).summary", defaultValue: summaryDefault),
            systemImage: icon,
            entries: entries
        )
    }

    private static func entry(
        _ id: String,
        titleDefault: String? = nil,
        detailDefault: String? = nil,
        icon: String,
        shortcut: HelpTutorialShortcut? = nil
    ) -> HelpTutorialEntry {
        HelpTutorialEntry(
            id: id,
            title: text("help.item.\(id).title", defaultValue: titleDefault),
            detail: text("help.item.\(id).detail", defaultValue: detailDefault),
            systemImage: icon,
            shortcut: shortcut
        )
    }

    private static func shortcutEntry(
        _ id: String,
        shortcut: HelpTutorialShortcut
    ) -> HelpTutorialEntry {
        HelpTutorialEntry(
            id: "shortcut_\(id)",
            title: text("help.shortcut.\(id)"),
            detail: "",
            systemImage: "keyboard",
            shortcut: shortcut
        )
    }

    private static func text(_ key: String, defaultValue: String? = nil) -> String {
        L10n.string(key, defaultValue: defaultValue)
    }
}

struct HelpTutorialTopic: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let systemImage: String
    let entries: [HelpTutorialEntry]

    fileprivate func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
            || summary.localizedCaseInsensitiveContains(query)
            || entries.contains { $0.matches(query) }
    }

    fileprivate func filtered(matching query: String) -> HelpTutorialTopic {
        guard
            !title.localizedCaseInsensitiveContains(query),
            !summary.localizedCaseInsensitiveContains(query)
        else { return self }

        return HelpTutorialTopic(
            id: id,
            title: title,
            summary: summary,
            systemImage: systemImage,
            entries: entries.filter { $0.matches(query) }
        )
    }
}

struct HelpTutorialEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let shortcut: HelpTutorialShortcut?

    fileprivate func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query)
            || detail.localizedCaseInsensitiveContains(query)
            || shortcut?.spokenLabel.localizedCaseInsensitiveContains(query) == true
    }
}

struct HelpTutorialShortcut: Equatable {
    enum Modifier: String, Equatable {
        case command = "⌘"
        case shift = "⇧"
        case option = "⌥"
        case control = "⌃"
    }

    let modifiers: [Modifier]
    let key: String

    static func command(_ key: String) -> HelpTutorialShortcut {
        HelpTutorialShortcut(modifiers: [.command], key: key)
    }

    static func commandShift(_ key: String) -> HelpTutorialShortcut {
        HelpTutorialShortcut(modifiers: [.command, .shift], key: key)
    }

    static func control(_ key: String) -> HelpTutorialShortcut {
        HelpTutorialShortcut(modifiers: [.control], key: key)
    }

    static func plain(_ key: String) -> HelpTutorialShortcut {
        HelpTutorialShortcut(modifiers: [], key: key)
    }

    var components: [String] {
        modifiers.map(\.rawValue) + [key]
    }

    var spokenLabel: String {
        let modifierNames = modifiers.map { modifier in
            switch modifier {
            case .command: L10n.string("help.key.command", defaultValue: "Command")
            case .shift: L10n.string("help.key.shift", defaultValue: "Shift")
            case .option: L10n.string("help.key.option", defaultValue: "Option")
            case .control: L10n.string("help.key.control", defaultValue: "Control")
            }
        }
        return (modifierNames + [key]).joined(separator: " + ")
    }
}

/// A reusable command set for `VibePDFApp.commands`.
struct HelpTutorialCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(HelpTutorialContent.windowTitle) {
                openWindow(id: HelpTutorialContent.sceneID)
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

struct HelpTutorialView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTopicID = "start"
    @State private var query = ""

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }
    private var visibleTopics: [HelpTutorialTopic] {
        HelpTutorialContent.topics(matching: query)
    }
    private var selectedTopic: HelpTutorialTopic? {
        visibleTopics.first { $0.id == selectedTopicID } ?? visibleTopics.first
    }

    var body: some View {
        NavigationSplitView {
            tutorialSidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 330)
        } detail: {
            tutorialDetail
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 610, idealHeight: 720)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .onChange(of: query) { _, _ in
            if !visibleTopics.contains(where: { $0.id == selectedTopicID }) {
                selectedTopicID = visibleTopics.first?.id ?? "start"
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HelpTutorialContent.windowTitle)
    }

    private var tutorialSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text(HelpTutorialContent.windowTitle)
                        .font(.title3.weight(.bold))
                } icon: {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(theme.ribbon)
                }
                Text(L10n.string("help.subtitle"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 13)

            Divider()

            if visibleTopics.isEmpty {
                noResults
            } else {
                List(visibleTopics, selection: $selectedTopicID) { topic in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(topic.title)
                                .font(.callout.weight(.semibold))
                            Text(topic.summary)
                                .font(.caption2)
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: topic.systemImage)
                            .foregroundStyle(theme.accent)
                            .frame(width: 22)
                    }
                    .padding(.vertical, 5)
                    .tag(topic.id)
                    .accessibilityLabel("\(topic.title). \(topic.summary)")
                }
                .listStyle(.sidebar)
            }
        }
        .background(theme.sidebar)
        .searchable(
            text: $query,
            placement: .sidebar,
            prompt: Text(L10n.string("help.search", defaultValue: "기능이나 단축키 검색"))
        )
    }

    @ViewBuilder
    private var tutorialDetail: some View {
        if let selectedTopic {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    topicHeader(selectedTopic)

                    LazyVStack(spacing: 11) {
                        ForEach(selectedTopic.entries) { entry in
                            tutorialEntry(entry)
                        }
                    }

                    hoverTip
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(theme.canvas)
            .navigationTitle(selectedTopic.title)
        } else {
            noResults
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.canvas)
        }
    }

    private func topicHeader(_ topic: HelpTutorialTopic) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: topic.systemImage)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(theme.ribbon)
                .frame(width: 52, height: 52)
                .background(theme.ribbonSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(topic.title)
                    .font(.largeTitle.weight(.bold))
                Text(topic.summary)
                    .font(.body)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tutorialEntry(_ entry: HelpTutorialEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: entry.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 36, height: 36)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: entry.detail.isEmpty ? 0 : 5) {
                Text(entry.title)
                    .font(.headline)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.callout)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            if let shortcut = entry.shortcut {
                shortcutBadge(shortcut)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vibePDFCard(theme, cornerRadius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entryAccessibilityLabel(entry))
    }

    private func shortcutBadge(_ shortcut: HelpTutorialShortcut) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(shortcut.components.enumerated()), id: \.offset) { _, component in
                Text(component)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, component.count > 1 ? 3 : 0)
                    .background(theme.panel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    }
            }
        }
        // Key chords retain their familiar physical order in an Arabic UI.
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    private var hoverTip: some View {
        Label(
            L10n.string("help.hover_tip"),
            systemImage: "cursorarrow.rays"
        )
        .font(.caption)
        .foregroundStyle(theme.secondaryText)
        .padding(.top, 5)
        .accessibilityLabel(L10n.string("help.hover_tip"))
    }

    private var noResults: some View {
        ContentUnavailableView(
            L10n.string("help.no_results.title", defaultValue: "검색 결과 없음"),
            systemImage: "magnifyingglass",
            description: Text(
                L10n.string("help.no_results.detail", defaultValue: "다른 기능 이름이나 단축키로 검색해 보세요.")
            )
        )
        .accessibilityElement(children: .combine)
    }

    private func entryAccessibilityLabel(_ entry: HelpTutorialEntry) -> String {
        [entry.title, entry.detail, entry.shortcut?.spokenLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}
