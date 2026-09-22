// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Revalidates a menu or toolbar snapshot against the live registry immediately
/// before execution. Both entry points therefore share the same disable/update/
/// uninstall and manifest-digest boundary.
@MainActor
enum PluginActionLauncher {
    @discardableResult
    static func run(
        manager: PluginManager,
        plugin: InstalledPlugin,
        action: PluginActionManifest,
        workspace: PDFWorkspaceState?
    ) throws -> PluginActionEffect {
        try run(
            manager: manager,
            plugin: plugin,
            action: action,
            workspace: workspace,
            runner: PluginActionRunner()
        )
    }

    @discardableResult
    static func run(
        manager: PluginManager,
        plugin: InstalledPlugin,
        action: PluginActionManifest,
        workspace: PDFWorkspaceState?,
        runner: PluginActionRunner
    ) throws -> PluginActionEffect {
        guard
            let livePlugin = manager.enabledPlugins.first(where: {
                $0.id == plugin.id && $0.manifestDigest == plugin.manifestDigest
            }),
            let liveAction = livePlugin.manifest.actions.first(where: {
                $0.id == action.id && $0 == action
            })
        else {
            throw PluginSystemError.actionUnavailable(
                L10n.string(
                    "plugins.error.changed",
                    defaultValue: "플러그인이 비활성화·업데이트·제거되어 작업을 실행하지 않았습니다. 메뉴를 다시 여세요."
                )
            )
        }

        return try runner.run(
            plugin: livePlugin,
            action: liveAction,
            workspace: liveAction.needsOpenDocument ? workspace : nil
        )
    }
}
