// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

enum PluginManagerContent {
    static let sceneID = "plugin-manager"
    static var windowTitle: String {
        L10n.string("plugins.manager.title", defaultValue: "HwattakPDF 플러그인")
    }
}

@MainActor
struct PluginManagerView: View {
    @ObservedObject var manager: PluginManager

    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingInspection: PluginPackageInspection?
    @State private var settingsPlugin: InstalledPlugin?
    @State private var presentedAlert: PluginManagerAlert?
    @State private var searchQuery = ""

    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    safetyBanner
                    if !manager.availableBundledPlugins.isEmpty {
                        bundledPluginsSection
                    }
                    installedSection
                    if !manager.loadIssues.isEmpty {
                        issuesSection
                    }
                    limitsSection
                }
                .padding(22)
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 600, idealHeight: 700)
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .sheet(item: $pendingInspection) { inspection in
            PluginInstallReviewSheet(
                inspection: inspection,
                isUpdate: manager.isInstalled(identifier: inspection.manifest.identifier),
                onCancel: { pendingInspection = nil },
                onInstall: {
                    install(inspection)
                }
            )
        }
        .sheet(item: $settingsPlugin) { plugin in
            PluginSettingsSheet(
                manager: manager,
                plugin: plugin,
                onDismiss: { settingsPlugin = nil }
            )
        }
        .alert(item: $presentedAlert) { alert in
            switch alert {
            case let .message(title, message):
                Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text(L10n.string("action.close", defaultValue: "닫기")))
                )
            case let .remove(plugin):
                Alert(
                    title: Text(
                        L10n.string(
                            "plugins.remove.title",
                            defaultValue: "플러그인을 제거할까요?"
                        )
                    ),
                    message: Text(
                        L10n.format(
                            "plugins.remove.message",
                            BundledPluginPresentation.displayName(for: plugin.manifest)
                        )
                    ),
                    primaryButton: .destructive(
                        Text(L10n.string("action.delete", defaultValue: "삭제"))
                    ) {
                        uninstall(plugin)
                    },
                    secondaryButton: .cancel(
                        Text(L10n.string("action.cancel", defaultValue: "취소"))
                    )
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 32, height: 32)
                .background(
                    theme.dropHighlight,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(PluginManagerContent.windowTitle)
                    .font(.headline.weight(.semibold))
                Text(
                    L10n.format(
                        "plugins.manager.summary",
                        manager.installedPlugins.count,
                        manager.enabledActionCount
                    )
                )
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Button {
                choosePackage()
            } label: {
                Label(
                    L10n.string("plugins.install", defaultValue: "플러그인 설치…"),
                    systemImage: "plus"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 22)
        .frame(height: 60)
        .background(theme.panel)
    }

    private var safetyBanner: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.success)
                .frame(width: 28, height: 28)
                .background(theme.success.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    L10n.string(
                        "plugins.safety.title",
                        defaultValue: "안전한 선언형 플러그인"
                    )
                )
                .font(.callout.weight(.semibold))

                Text(
                    L10n.string(
                        "plugins.safety.detail",
                        defaultValue: "v1 템플릿 액션은 임의 코드, 셸, Keychain, 원본 PDF 바이트, 직접 네트워크와 GPU에 접근할 수 없습니다. v2 웹 패널은 앱이 검토한 외부 사이트를 임시 세션으로 표시하지만 원격 스크립트·쿠키·추적 기술이 동작할 수 있습니다. 주소창과 상위 페이지 이동 제한은 추적 방지기나 방화벽이 아닙니다."
                    )
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Text(L10n.string("plugins.installed.title", defaultValue: "설치된 플러그인"))
                    .font(.headline)
                Text("\(manager.installedPlugins.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.panel, in: Capsule())
                Spacer()

                Button {
                    manager.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(L10n.string("plugins.refresh", defaultValue: "설치 목록 새로 고침"))
                .accessibilityLabel(L10n.string(
                    "plugins.refresh",
                    defaultValue: "설치 목록 새로 고침"
                ))

                Button {
                    manager.refresh()
                    NSWorkspace.shared.open(manager.pluginsDirectory)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help(L10n.string("plugins.open_folder", defaultValue: "플러그인 폴더 열기"))
                .accessibilityLabel(L10n.string(
                    "plugins.open_folder",
                    defaultValue: "플러그인 폴더 열기"
                ))
            }

            pluginSearchField

            if manager.installedPlugins.isEmpty {
                ContentUnavailableView(
                    L10n.string("plugins.empty.title", defaultValue: "설치된 플러그인이 없습니다"),
                    systemImage: "puzzlepiece.extension",
                    description: Text(
                        L10n.string(
                            "plugins.empty.detail",
                            defaultValue: ".hwattakplugin 폴더 패키지를 선택하면 권한을 검토한 뒤 설치할 수 있습니다."
                        )
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 190)
                .pluginListContainer(theme)
            } else if filteredInstalledPlugins.isEmpty {
                ContentUnavailableView(
                    L10n.string(
                        "plugins.search.empty.title",
                        defaultValue: "검색 결과가 없습니다"
                    ),
                    systemImage: "magnifyingglass",
                    description: Text(
                        L10n.string(
                            "plugins.search.empty.detail",
                            defaultValue: "다른 플러그인 이름이나 제작자를 검색해 보세요."
                        )
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 150)
                .pluginListContainer(theme)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredInstalledPlugins) { plugin in
                        pluginRow(plugin)
                        if plugin.id != filteredInstalledPlugins.last?.id {
                            Divider()
                                .overlay(theme.border)
                                .padding(.leading, 54)
                        }
                    }
                }
                .pluginListContainer(theme)
            }
        }
    }

    private var pluginSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.secondaryText)
            TextField(
                L10n.string(
                    "plugins.search.placeholder",
                    defaultValue: "플러그인 검색…"
                ),
                text: $searchQuery
            )
            .textFieldStyle(.plain)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(L10n.string("action.clear", defaultValue: "지우기"))
                .accessibilityLabel(L10n.string("action.clear", defaultValue: "지우기"))
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
    }

    private var filteredInstalledPlugins: [InstalledPlugin] {
        manager.installedPlugins.filter {
            PluginManagerSearch.matches($0.manifest, query: searchQuery)
        }
    }

    private var bundledPluginsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label(
                    L10n.string("plugins.bundled.title", defaultValue: "HwattakPDF 기본 플러그인"),
                    systemImage: "shippingbox.fill"
                )
                .font(.headline)
                Spacer()
                Text(L10n.string(
                    "plugins.bundled.detail",
                    defaultValue: "앱에 포함됨 · 설치 전 권한 검토"
                ))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            }

            LazyVStack(spacing: 0) {
                ForEach(manager.availableBundledPlugins) { inspection in
                    bundledPluginRow(inspection)
                    if inspection.id != manager.availableBundledPlugins.last?.id {
                        Divider()
                            .overlay(theme.border)
                            .padding(.leading, 54)
                    }
                }
            }
            .pluginListContainer(theme)
        }
    }

    private func bundledPluginRow(_ inspection: PluginPackageInspection) -> some View {
        let installAction = L10n.string(
            "plugins.bundled.review_install",
            defaultValue: "검토 및 설치"
        )
        let installControlLabel = pluginControlLabel(
            action: installAction,
            manifest: inspection.manifest
        )
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: bundledPluginSystemImage(inspection.manifest))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 30, height: 30)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(BundledPluginPresentation.displayName(for: inspection.manifest))
                    .font(.callout.weight(.semibold))
                Text(BundledPluginPresentation.description(for: inspection.manifest))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button(installAction) {
                pendingInspection = inspection
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(installControlLabel)
            .accessibilityLabel(Text(installControlLabel))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pluginRow(_ plugin: InstalledPlugin) -> some View {
        let enableAction = L10n.string("plugins.enabled", defaultValue: "활성화")
        let enableControlLabel = pluginControlLabel(
            action: enableAction,
            manifest: plugin.manifest
        )
        let settingsAction = L10n.string("plugins.settings", defaultValue: "플러그인 설정")
        let settingsControlLabel = pluginControlLabel(
            action: settingsAction,
            manifest: plugin.manifest
        )
        let removeAction = L10n.string("plugins.remove", defaultValue: "플러그인 제거")
        let removeControlLabel = pluginControlLabel(
            action: removeAction,
            manifest: plugin.manifest
        )
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: plugin.isEnabled ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(plugin.isEnabled ? theme.accent : theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(BundledPluginPresentation.displayName(for: plugin.manifest))
                        .font(.callout.weight(.semibold))
                    Text("v\(plugin.manifest.version)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(theme.secondaryText)
                    Text(plugin.manifest.author)
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Text(BundledPluginPresentation.description(for: plugin.manifest))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)

            Button {
                settingsPlugin = plugin
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help(settingsControlLabel)
            .accessibilityLabel(Text(settingsControlLabel))

            Toggle(
                enableAction,
                isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { enabled in
                        do {
                            try manager.setEnabled(enabled, identifier: plugin.id)
                        } catch {
                            present(error)
                        }
                    }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .help(enableControlLabel)
            .accessibilityLabel(Text(enableControlLabel))

            Menu {
                Button(role: .destructive) {
                    presentedAlert = .remove(plugin)
                } label: {
                    Label(removeAction, systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(removeControlLabel)
            .accessibilityLabel(Text(removeControlLabel))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(
                L10n.string("plugins.issues.title", defaultValue: "격리된 패키지"),
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.headline)
            .foregroundStyle(theme.warning)

            ForEach(manager.loadIssues) { issue in
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.packageName)
                        .font(.callout.monospaced().weight(.semibold))
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                L10n.string("plugins.resources.title", defaultValue: "리소스 및 안정성 정책"),
                systemImage: "speedometer"
            )
            .font(.headline)
            Text(
                L10n.format(
                    "plugins.resources.detail",
                    HwattakPluginLimits.maximumInstalledPluginCount,
                    HwattakPluginLimits.maximumActionsPerPlugin,
                    HwattakPluginLimits.maximumPackageBytes / 1_024 / 1_024
                )
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bundledPluginSystemImage(_ manifest: PluginManifest) -> String {
        if manifest.actions.contains(where: { $0.output == .translatePanel }) {
            return "character.bubble"
        }
        if manifest.actions.contains(where: { $0.output == .youtubePanel }) {
            return "play.rectangle"
        }
        return "globe"
    }

    private func pluginControlLabel(
        action: String,
        manifest: PluginManifest
    ) -> String {
        "\(action): \(BundledPluginPresentation.displayName(for: manifest))"
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("plugins.install", defaultValue: "플러그인 설치…")
        panel.message = L10n.string(
            "plugins.install.panel_message",
            defaultValue: ".hwattakplugin 폴더 패키지를 선택하세요."
        )
        panel.prompt = L10n.string("action.review", defaultValue: "검토")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingInspection = try manager.inspectPackage(at: url)
        } catch {
            present(error)
        }
    }

    private func install(_ inspection: PluginPackageInspection) {
        do {
            try manager.install(
                inspection,
                replacingExisting: manager.isInstalled(
                    identifier: inspection.manifest.identifier
                )
            )
            pendingInspection = nil
            presentedAlert = .message(
                title: L10n.string("plugins.install.success_title", defaultValue: "설치 완료"),
                message: L10n.format(
                    "plugins.install.success_message",
                    BundledPluginPresentation.displayName(for: inspection.manifest)
                )
            )
        } catch {
            pendingInspection = nil
            present(error)
        }
    }

    private func uninstall(_ plugin: InstalledPlugin) {
        do {
            try manager.uninstall(identifier: plugin.id)
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        presentedAlert = .message(
            title: L10n.string("plugins.error.title", defaultValue: "플러그인 오류"),
            message: error.localizedDescription
        )
    }
}

private enum PluginManagerAlert: Identifiable {
    case message(title: String, message: String)
    case remove(InstalledPlugin)

    var id: String {
        switch self {
        case let .message(title, message): "message-\(title)-\(message)"
        case let .remove(plugin): "remove-\(plugin.id)"
        }
    }
}

private struct PluginInstallReviewSheet: View {
    let inspection: PluginPackageInspection
    let isUpdate: Bool
    let onCancel: () -> Void
    let onInstall: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(
                    isUpdate
                        ? L10n.string(
                            "plugins.review.update_title",
                            defaultValue: "플러그인 업데이트 검토"
                        )
                        : L10n.string(
                            "plugins.review.install_title",
                            defaultValue: "플러그인 설치 검토"
                        ),
                    systemImage: "checkmark.shield"
                )
                .font(.title2.weight(.bold))

                VStack(alignment: .leading, spacing: 5) {
                    Text(BundledPluginPresentation.displayName(for: inspection.manifest))
                        .font(.headline)
                    Text("v\(inspection.manifest.version) · \(inspection.manifest.author)")
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.secondaryText)
                    Text(BundledPluginPresentation.description(for: inspection.manifest))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("plugins.permissions.title", defaultValue: "허용 권한"))
                        .font(.headline)
                    if inspection.manifest.capabilities.isEmpty {
                        Label(
                            L10n.string("plugins.permissions.none", defaultValue: "문서 권한 없음"),
                            systemImage: "lock.fill"
                        )
                    } else {
                        ForEach(inspection.manifest.capabilities) { capability in
                            Label(capability.title, systemImage: "checkmark.circle")
                        }
                    }
                }
                .font(.callout)

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.string(
                        "plugins.review.actions_title",
                        defaultValue: "작업과 외부 연결"
                    ))
                        .font(.headline)
                    ForEach(inspection.manifest.actions) { action in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: actionIcon(action.output))
                                .frame(width: 18)
                                .foregroundStyle(theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(BundledPluginPresentation.actionTitle(
                                    action,
                                    in: inspection.manifest
                                ))
                                    .font(.callout.weight(.semibold))
                                if let description = BundledPluginPresentation.actionDescription(
                                    action,
                                    in: inspection.manifest
                                ) {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(actionDisclosure(action))
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Label(
                    L10n.string(
                        "plugins.review.unsigned_notice",
                        defaultValue: "게시자 서명은 확인하지 않습니다. v1 패키지는 실행 코드를 담을 수 없고 위의 제한된 호스트 액션만 사용합니다. v2 웹 패널은 앱에 포함된 검토본과 정확히 일치할 때만 설치되지만, 열린 사이트의 원격 스크립트·쿠키·추적 기술은 세션 중 동작할 수 있습니다."
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    L10n.format(
                        "plugins.review.package_info",
                        inspection.fileCount,
                        inspection.totalBytes / 1_024,
                        String(inspection.manifestDigest.prefix(12))
                    )
                )
                .font(.caption2.monospaced())
                .foregroundStyle(theme.secondaryText)

                HStack {
                    Spacer()
                    Button(L10n.string("action.cancel", defaultValue: "취소"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button(
                        installActionTitle,
                        action: onInstall
                    )
                    .keyboardShortcut(.defaultAction)
                    .help(installControlLabel)
                    .accessibilityLabel(Text(installControlLabel))
                }
            }
            .padding(24)
        }
        .frame(
            minWidth: 560,
            idealWidth: 560,
            maxWidth: 560,
            minHeight: 480,
            idealHeight: 620,
            maxHeight: 720
        )
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
    }

    private var installActionTitle: String {
        isUpdate
            ? L10n.string("plugins.update", defaultValue: "업데이트")
            : L10n.string("plugins.install.confirm", defaultValue: "설치")
    }

    private var installControlLabel: String {
        "\(installActionTitle): \(BundledPluginPresentation.displayName(for: inspection.manifest))"
    }

    private func actionIcon(_ output: PluginActionOutput) -> String {
        switch output {
        case .showText: "text.bubble"
        case .copyText: "clipboard"
        case .openURL: "arrow.up.forward.app"
        case .translatePanel: "character.bubble"
        case .youtubePanel: "play.rectangle"
        case .browserPanel: "globe"
        case .documentCommand: "pencil.and.outline"
        }
    }

    private func actionDisclosure(_ action: PluginActionManifest) -> String {
        switch action.output {
        case .documentCommand: return L10n.string("plugins.command.review")
        case .showText:
            return L10n.string(
                "plugins.review.action.show_text",
                defaultValue: "앱 안의 읽기 전용 대화상자에 제한된 텍스트를 표시합니다."
            )
        case .copyText:
            return L10n.string(
                "plugins.review.action.copy_text",
                defaultValue: "제한된 텍스트를 macOS 공용 클립보드에 씁니다."
            )
        case .openURL:
            let host = URL(string: action.template)?.host ?? L10n.string(
                "plugins.review.action.external_site",
                defaultValue: "외부 HTTPS 사이트"
            )
            return L10n.format("plugins.review.action.open_url", host)
        case .translatePanel:
            let source = action.template == "{{selection}}"
                ? L10n.string(
                    "plugins.translation.source.selection",
                    defaultValue: "선택한 문장"
                )
                : L10n.string(
                    "plugins.translation.source.page",
                    defaultValue: "현재 페이지 텍스트"
                )
            return L10n.format("plugins.review.action.translate", source)
        case .youtubePanel:
            return L10n.string(
                "plugins.review.action.youtube",
                defaultValue: "PDF 데이터 전송 없음 → YouTube 검색과 영상 재생. 가능한 영상은 youtube-nocookie.com 플레이어를 사용합니다."
            )
        case .browserPanel:
            return L10n.string(
                "plugins.review.action.browser",
                defaultValue: "PDF 데이터 전송 없음 → 공개 HTTPS 웹사이트. 주소창과 상위 페이지 이동만 제한하며, 원격 JavaScript·쿠키·추적과 하위 네트워크 요청을 막는 추적 방지기나 방화벽은 아닙니다."
            )
        }
    }
}

private extension View {
    func pluginListContainer(_ theme: HwattakPDFTheme) -> some View {
        background(
            theme.panel,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
    }
}
