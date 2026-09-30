// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Empty-workspace landing page. The parent owns file access and tab creation.
struct WelcomeView: View {
    let openDocument: () -> Void
    let recentDocuments: [RecentDocument]
    let openRecentDocument: (RecentDocument) -> Void
    let removeRecentDocument: (RecentDocument) -> Void
    let clearRecentDocuments: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var iconManager: AppIconManager
    @State private var hoveredRecentDocumentID: UUID?

    private var theme: HwattakPDFTheme {
        HwattakPDFTheme(colorScheme: colorScheme)
    }

    init(
        openDocument: @escaping () -> Void,
        recentDocuments: [RecentDocument] = [],
        openRecentDocument: @escaping (RecentDocument) -> Void = { _ in },
        removeRecentDocument: @escaping (RecentDocument) -> Void = { _ in },
        clearRecentDocuments: @escaping () -> Void = {}
    ) {
        self.openDocument = openDocument
        self.recentDocuments = recentDocuments
        self.openRecentDocument = openRecentDocument
        self.removeRecentDocument = removeRecentDocument
        self.clearRecentDocuments = clearRecentDocuments
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 40) {
                    openDocumentSection
                    recentDocumentsSection
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background(theme.canvas.ignoresSafeArea())
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
    }

    private var openDocumentSection: some View {
        VStack(spacing: 20) {
            HStack(spacing: 10) {
                Image(nsImage: iconManager.currentImage ?? NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)

                Text("HwattakPDF")
                    .font(.system(size: 24, weight: .medium))
            }

            VStack(spacing: 10) {
                Button(action: openDocument) {
                    Label(L10n.string("menu.open_document"), systemImage: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(
                            Color(red: 0.20, green: 0.39, blue: 0.62),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut("o", modifiers: .command)
                .help(L10n.string("menu.open_document") + " (⌘O)")

                Text(L10n.string("Finder에서 여러 PDF를 놓아도 각각 새 탭으로 열립니다"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var recentDocumentsSection: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L10n.string("최근 PDF"))
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityValue(L10n.format("recent.count", recentDocuments.count))

                Spacer(minLength: 8)

                if !recentDocuments.isEmpty {
                    Button(action: clearRecentDocuments) {
                        Text(L10n.string("목록 지우기"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("최근 PDF 목록 전체 삭제"))
                    .accessibilityLabel(L10n.string("최근 PDF 목록 지우기"))
                }
            }
            .padding(.horizontal, 10)

            Rectangle()
                .fill(theme.border.opacity(0.65))
                .frame(height: 1)

            if recentDocuments.isEmpty {
                emptyRecentDocuments
            } else {
                // The store already enforces the seven-item policy. Keep the
                // presentation bounded if another caller supplies more items.
                VStack(spacing: 2) {
                    ForEach(Array(recentDocuments.prefix(7))) { document in
                        recentDocumentRow(document)
                    }
                }
            }
        }
    }

    private var emptyRecentDocuments: some View {
        VStack(spacing: 8) {
            Text(L10n.string("최근에 연 PDF가 없습니다."))
                .font(.system(size: 13))
            Text(L10n.string("PDF를 열면 최대 7개까지 여기에 표시됩니다."))
                .font(.system(size: 12))
        }
        .foregroundStyle(theme.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func recentDocumentRow(_ document: RecentDocument) -> some View {
        HStack(spacing: 8) {
            Button {
                openRecentDocument(document)
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "doc")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 30)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(document.locationDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    Text(document.lastOpenedAt, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.format("recent.open", document.displayName))
            .accessibilityLabel(L10n.format("recent.open", document.displayName))
            .accessibilityValue(document.locationDescription)

            // Keep the secondary action available to keyboard and VoiceOver
            // users even while its row is not hovered.
            Button {
                removeRecentDocument(document)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                    .opacity(hoveredRecentDocumentID == document.id ? 1 : 0.55)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.format("recent.remove", document.displayName))
            .accessibilityLabel(L10n.format("recent.remove", document.displayName))
        }
        .padding(.trailing, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hoveredRecentDocumentID == document.id ? theme.panel : Color.clear)
        }
        .onHover { isHovered in
            if isHovered {
                hoveredRecentDocumentID = document.id
            } else if hoveredRecentDocumentID == document.id {
                hoveredRecentDocumentID = nil
            }
        }
        .contextMenu {
            Button(L10n.format("recent.remove", document.displayName)) {
                removeRecentDocument(document)
            }
        }
    }
}
