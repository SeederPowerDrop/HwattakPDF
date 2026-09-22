// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// A click-open launcher keeps every command inside one persistent surface;
/// reaching a plugin action never requires crossing a hover submenu boundary.
struct PluginToolbarPopover: View {
    @ObservedObject var manager: PluginManager
    @ObservedObject var workspace: PDFWorkspaceState
    let runAction: (PluginActionManifest, InstalledPlugin) -> Void
    let managePlugins: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""

    private var theme: HwattakPDFTheme {
        HwattakPDFTheme(colorScheme: colorScheme)
    }

    private struct PluginSection: Identifiable {
        let plugin: InstalledPlugin
        let actions: [PluginActionManifest]
        var id: String { plugin.id }
    }

    private var sections: [PluginSection] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return manager.enabledPlugins.compactMap { plugin in
            let name = BundledPluginPresentation.displayName(for: plugin.manifest)
            let actions = plugin.manifest.actions.filter { action in
                search.isEmpty || name.localizedStandardContains(search)
                    || BundledPluginPresentation.actionTitle(action, in: plugin.manifest)
                        .localizedStandardContains(search)
                    || (BundledPluginPresentation.actionDescription(action, in: plugin.manifest)?
                        .localizedStandardContains(search) ?? false)
            }
            return actions.isEmpty ? nil : PluginSection(plugin: plugin, actions: actions)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.string("menu.plugins"), systemImage: "puzzlepiece.extension")
                .font(.headline)

            if manager.enabledActionCount > 0 {
                TextField(L10n.string("plugins.palette.search"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("plugin-toolbar-search")
                    .onSubmit(runFirstAvailableAction)
            }

            if sections.isEmpty {
                Text(L10n.string(
                    manager.enabledActionCount == 0
                        ? "plugins.menu.no_actions" : "plugins.search.empty.title"
                ))
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(BundledPluginPresentation.displayName(for: section.plugin.manifest))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.secondaryText)
                                    .padding(.horizontal, 8)
                                ForEach(section.actions) { action in
                                    actionButton(action, plugin: section.plugin)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 3)
                }
                .frame(maxHeight: 340)
            }

            Divider()

            Button(action: managePlugins) {
                Label(L10n.string("plugins.manage"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plugin-toolbar-manage")
        }
        .padding(16)
        .frame(width: 350)
        .foregroundStyle(theme.primaryText)
        .background(theme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-toolbar-popover")
    }

    private func actionButton(
        _ action: PluginActionManifest,
        plugin: InstalledPlugin
    ) -> some View {
        let title = BundledPluginPresentation.actionTitle(action, in: plugin.manifest)
        let detail = BundledPluginPresentation.actionDescription(action, in: plugin.manifest)
        let isAvailable = PluginCommandAvailability.isAvailable(action, workspace: workspace)
        return Button {
            runAction(action, plugin)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: systemImage(for: action.output))
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .opacity(isAvailable ? 1 : 0.48)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help(detail ?? title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("plugin-toolbar-action-\(plugin.id)-\(action.id)")
    }

    private func runFirstAvailableAction() {
        for section in sections {
            if let action = section.actions.first(where: {
                PluginCommandAvailability.isAvailable($0, workspace: workspace)
            }) {
                runAction(action, section.plugin)
                return
            }
        }
    }

    private func systemImage(for output: PluginActionOutput) -> String {
        switch output {
        case .showText: "doc.plaintext"
        case .copyText: "clipboard"
        case .openURL: "arrow.up.right.square"
        case .translatePanel: "character.bubble"
        case .youtubePanel: "play.rectangle"
        case .browserPanel: "globe"
        case .documentCommand: "pencil.and.outline"
        }
    }
}
