// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

/// Versioned host API: packages describe intent; PDF objects never leave the host.
struct PluginDocumentCommand: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case highlight, underline, pen, eraser, selection
        case viewerMode, editingMode, studyMode, nextPage, previousPage
    }
    let kind: Kind
    var color: String? = nil
    var width: Double? = nil
    var opacity: Double? = nil

    var needsSelection: Bool { kind == .highlight || kind == .underline }
    var capability: PluginCapability {
        switch kind {
        case .highlight, .underline: .annotationWrite
        case .pen, .eraser, .selection: .toolControl
        default: .workspaceNavigation
        }
    }

    func validate() throws {
        if let color {
            guard color.utf8.count == 7, color.first == "#",
                  color.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw PluginSystemError.invalidManifest("command.color must be #RRGGBB")
            }
        }
        if let width, !width.isFinite || !(0.2...32).contains(width) {
            throw PluginSystemError.invalidManifest("command.width must be 0.2...32")
        }
        if let opacity, !opacity.isFinite || !(0.1...1).contains(opacity) {
            throw PluginSystemError.invalidManifest("command.opacity must be 0.1...1")
        }
        if ![Kind.highlight, .underline, .pen].contains(kind),
           color != nil || width != nil || opacity != nil {
            throw PluginSystemError.invalidManifest("this command does not accept a style")
        }
        if kind == .pen && opacity != nil {
            throw PluginSystemError.invalidManifest("native PDF ink uses opaque color")
        }
    }

    var nsColor: NSColor? {
        guard let color, let value = UInt32(color.dropFirst(), radix: 16) else { return nil }
        return NSColor(deviceRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    @MainActor
    func isAvailable(in workspace: PDFWorkspaceState) -> Bool {
        guard workspace.document != nil else { return false }
        switch kind {
        case .highlight, .underline:
            return workspace.allows(.markup) && workspace.currentSelection != nil
        case .pen: return workspace.allows(.handwriting)
        case .eraser: return workspace.mode.allows(.eraser) && workspace.allows(.markup)
        case .previousPage: return workspace.currentPageIndex > 0
        case .nextPage: return workspace.currentPageIndex + 1 < workspace.pageCount
        default: return true
        }
    }

    @MainActor
    func apply(to workspace: PDFWorkspaceState) throws {
        try validate()
        guard isAvailable(in: workspace) else {
            throw PluginSystemError.actionUnavailable(L10n.string("plugins.command.unavailable"))
        }
        switch kind {
        case .highlight, .underline:
            try workspace.applyPluginMarkup(kind: kind == .highlight ? .highlight : .underline,
                color: nsColor ?? workspace.studyMarkupStyle.color,
                width: width.map { CGFloat($0) }, opacity: opacity.map { CGFloat($0) })
        case .pen:
            if let nsColor { workspace.inkSettings.color = nsColor }
            if let width { workspace.inkSettings.width = CGFloat(width) }
            workspace.activeTool = .pen
            workspace.pageColumns = min(2, workspace.pageColumns)
        case .eraser: workspace.activeTool = .eraser
        case .selection: workspace.activeTool = .select
        case .viewerMode: workspace.setMode(.viewer)
        case .editingMode: workspace.setMode(.editing)
        case .studyMode: workspace.setMode(.study)
        case .nextPage: workspace.setCurrentPage(workspace.currentPageIndex + 1)
        case .previousPage: workspace.setCurrentPage(workspace.currentPageIndex - 1)
        }
    }
}
