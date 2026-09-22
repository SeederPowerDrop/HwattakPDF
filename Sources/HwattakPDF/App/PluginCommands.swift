// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

@MainActor
enum PluginCommandAvailability {
    static func isAvailable(
        _ action: PluginActionManifest,
        workspace: PDFWorkspaceState?
    ) -> Bool {
        guard action.needsOpenDocument else { return true }
        guard let workspace, workspace.document != nil, workspace.pageCount > 0 else { return false }
        if let command = action.command { return command.isAvailable(in: workspace) }
        if action.output == .translatePanel,
           !workspace.allows(.translation) {
            return false
        }
        do {
            try PluginDocumentTextAccess.validate(for: action, workspace: workspace)
        } catch {
            return false
        }
        return true
    }
}

struct PluginCommands: Commands {
    @ObservedObject var manager: PluginManager
    @ObservedObject private var editCommandRouter = AppEditCommandRouter.shared
    @FocusedObject private var focusedWorkspace: MultiDocumentWorkspaceState?
    @FocusedValue(\.comparisonReadOnlyActive) private var comparisonReadOnlyActive
    @Environment(\.openWindow) private var openWindow

    private var documentWorkspace: PDFWorkspaceState? {
        guard comparisonReadOnlyActive != true else { return nil }
        return editCommandRouter.documentWorkspace(
            fallback: focusedWorkspace?.activeWorkspace
        )
    }

    var body: some Commands {
        CommandMenu(L10n.string("menu.plugins", defaultValue: "플러그인")) {
            Button(L10n.string("plugins.palette.title")) {
                documentWorkspace?.pluginCommandPaletteVisible = true
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(documentWorkspace?.document == nil)
            Divider()
            if manager.enabledPlugins.isEmpty {
                Button(
                    L10n.string(
                        "plugins.menu.no_actions",
                        defaultValue: "활성화된 플러그인 없음"
                    )
                ) {}
                .disabled(true)
            } else {
                ForEach(manager.enabledPlugins) { plugin in
                    if plugin.manifest.actions.count == 1,
                       let action = plugin.manifest.actions.first {
                        Button(BundledPluginPresentation.displayName(for: plugin.manifest)) {
                            run(action, from: plugin)
                        }
                        .disabled(!isAvailable(action))
                        .help(
                            BundledPluginPresentation.actionDescription(
                                action,
                                in: plugin.manifest
                            ) ?? BundledPluginPresentation.actionTitle(
                                action,
                                in: plugin.manifest
                            )
                        )
                    } else {
                        // Keep related actions in the same menu surface. A
                        // command no longer depends on crossing the tracking
                        // boundary of a transient, hover-opened submenu.
                        Section {
                            ForEach(plugin.manifest.actions) { action in
                                Button(BundledPluginPresentation.actionTitle(action, in: plugin.manifest)) {
                                    run(action, from: plugin)
                                }
                                .disabled(!isAvailable(action))
                                .help(
                                    BundledPluginPresentation.actionDescription(
                                        action,
                                        in: plugin.manifest
                                    ) ?? ""
                                )
                            }
                        } header: {
                            Text(BundledPluginPresentation.displayName(for: plugin.manifest))
                        }
                    }
                }
            }

            Divider()

            Button(
                L10n.string("plugins.manage", defaultValue: "플러그인 관리…")
            ) {
                openWindow(id: PluginManagerContent.sceneID)
            }
            .keyboardShortcut(",", modifiers: [.command, .shift])
        }
    }

    private func isAvailable(_ action: PluginActionManifest) -> Bool {
        PluginCommandAvailability.isAvailable(
            action,
            workspace: documentWorkspace
        )
    }

    private func run(_ action: PluginActionManifest, from plugin: InstalledPlugin) {
        do {
            try PluginActionLauncher.run(
                manager: manager,
                plugin: plugin,
                action: action,
                workspace: documentWorkspace
            )
        } catch PluginSystemError.externalURLCancelled {
            // Cancellation is an expected consent outcome, not an app error.
        } catch {
            if let workspace = documentWorkspace {
                workspace.presentedError = error.localizedDescription
            } else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.string(
                    "plugins.error.title",
                    defaultValue: "플러그인 오류"
                )
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
