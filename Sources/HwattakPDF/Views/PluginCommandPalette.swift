// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct PluginCommandPalette: View {
    @ObservedObject var manager: PluginManager
    @ObservedObject var workspace: PDFWorkspaceState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    private struct Command: Identifiable {
        let plugin: InstalledPlugin
        let action: PluginActionManifest
        var id: String { plugin.id + "/" + action.id }
    }
    private var commands: [Command] {
        manager.enabledPlugins.flatMap { plugin in
            plugin.manifest.actions.map { Command(plugin: plugin, action: $0) }
        }.filter {
            query.isEmpty || "\($0.plugin.manifest.displayName) \($0.action.title) \($0.action.description ?? "")"
                .localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("plugins.palette.title")).font(.title2.bold())
            TextField(L10n.string("plugins.palette.search"), text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit {
                    if let first = commands.first(where: { PluginCommandAvailability.isAvailable($0.action, workspace: workspace) }) {
                        run(first)
                    }
                }
            List(commands) { command in
                Button { run(command) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(BundledPluginPresentation.actionTitle(command.action, in: command.plugin.manifest))
                        Text(BundledPluginPresentation.displayName(for: command.plugin.manifest))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(!PluginCommandAvailability.isAvailable(command.action, workspace: workspace))
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Text(L10n.string("plugins.palette.help")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("action.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 580, height: 470)
        .onAppear { searchFocused = true }
    }

    private func run(_ command: Command) {
        do {
            try PluginActionLauncher.run(manager: manager, plugin: command.plugin, action: command.action, workspace: workspace)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
