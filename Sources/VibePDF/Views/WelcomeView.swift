// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Empty-workspace landing page.
///
/// File access is deliberately delegated through closures: this presentation
/// view never opens a security-scoped URL itself. The parent coordinates the
/// open panel/recent bookmark and installs the resulting tab in the model.
struct WelcomeView: View {
    let openDocument: () -> Void
    let recentDocuments: [RecentDocument]
    let openRecentDocument: (RecentDocument) -> Void
    let removeRecentDocument: (RecentDocument) -> Void
    let clearRecentDocuments: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var iconManager: AppIconManager

    private var theme: VibePDFTheme {
        VibePDFTheme(colorScheme: colorScheme)
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
        ZStack {
            theme.canvas.ignoresSafeArea()

            LinearGradient(
                colors: [
                    theme.paperIvory.opacity(colorScheme == .dark ? 0.04 : 0.92),
                    theme.canvas,
                    theme.steel.opacity(colorScheme == .dark ? 0.10 : 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(theme.ribbon.opacity(colorScheme == .dark ? 0.07 : 0.055))
                .frame(width: 420, height: 420)
                .blur(radius: 2)
                .offset(x: -470, y: 330)

            HStack(spacing: 54) {
                hero
                    .frame(maxWidth: 440, alignment: .leading)

                workspacePreview
                    .frame(width: 440, height: 510)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 42)
            .frame(maxWidth: 1_100)
        }
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 15) {
                Image(nsImage: iconManager.currentImage ?? NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .shadow(color: theme.elevatedShadow, radius: 12, y: 6)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("HwattakPDF")
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(1)

                        Text("v\(VibePDFRelease.badge)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.cream)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.ribbonLabel, in: Capsule())
                    }

                    Text("PRIVATE PDF WORKSPACE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.35)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Text("화딱지나서 만든 앱.")
                .font(.system(size: 42, weight: .bold))
                .tracking(-1.15)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 34)

            Button(action: openDocument) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                    Text("여러 PDF 열기")
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.forward")
                        .font(.caption.weight(.bold))
                        .opacity(0.82)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.cream)
                .padding(.horizontal, 17)
                .frame(minWidth: 224, idealWidth: 250, maxWidth: 320, minHeight: 46)
                .background(theme.brandNavy, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.cream.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: theme.brandNavy.opacity(0.22), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)
            .padding(.top, 35)

            Label("Finder에서 여러 PDF를 놓아도 각각 새 탭으로 열립니다", systemImage: "arrow.down.doc.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 13)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                privacyPill("lock.fill", "온디바이스")
                privacyPill("rectangle.stack.fill", "다중 탭")
                privacyPill("creditcard.fill", "구독 없음")
            }
            .frame(maxWidth: 390, alignment: .leading)
            .padding(.top, 19)
        }
    }

    private var workspacePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(theme.chrome)
                .shadow(color: theme.elevatedShadow, radius: 30, y: 14)

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(theme.cream.opacity(0.13), lineWidth: 1)

            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    recentGlyph

                    VStack(alignment: .leading, spacing: 2) {
                        Text("RECENT PDFS")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.05)
                        Text("최근 PDF")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(theme.chromeText)

                    Spacer()

                    Text("\(recentDocuments.count)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(theme.chromeText)
                        .frame(width: 28, height: 28)
                        .background(theme.chromeRaised, in: Circle())
                        .accessibilityLabel(L10n.format("recent.count", recentDocuments.count))
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)

                panelDivider

                recentDocumentsContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                panelDivider

                recentDocumentsFooter
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
        }
    }

    private var recentGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.paperIvory)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.brandNavy)
            Rectangle()
                .fill(theme.ribbon)
                .frame(height: 5)
                .offset(y: 11)
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(theme.cream.opacity(0.12))
            .frame(height: 1)
    }

    @ViewBuilder
    private var recentDocumentsContent: some View {
        if recentDocuments.isEmpty {
            VStack(spacing: 11) {
                Image(systemName: "clock")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(theme.chromeSecondaryText)

                Text("최근에 연 PDF가 없습니다.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.chromeText)

                Text("PDF를 열면 최대 7개까지 여기에 표시됩니다.")
                    .font(.caption)
                    .foregroundStyle(theme.chromeSecondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            // The store already enforces the seven-item policy, but prefixing
            // here keeps the UI bounded even if a future caller supplies more.
            VStack(spacing: 6) {
                ForEach(Array(recentDocuments.prefix(7))) { document in
                    recentDocumentRow(document)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func recentDocumentRow(_ document: RecentDocument) -> some View {
        // Opening and removing are separate buttons. A single context-sensitive
        // row would be harder to discover with keyboard and VoiceOver.
        HStack(spacing: 7) {
            Button {
                openRecentDocument(document)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.ribbon)
                        .frame(width: 26, height: 26)
                        .background(theme.paperIvory, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.chromeText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 4) {
                            Text(document.locationDescription)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("·")
                            Text(document.lastOpenedAt, style: .relative)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.chromeSecondaryText)
                    }

                    Spacer(minLength: 5)

                    Image(systemName: "chevron.forward")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.chromeSecondaryText)
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.format("recent.open", document.displayName))
            .accessibilityLabel(L10n.format("recent.open", document.displayName))
            .accessibilityValue(document.locationDescription)

            Button {
                removeRecentDocument(document)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.chromeSecondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.format("recent.remove", document.displayName))
            .accessibilityLabel(L10n.format("recent.remove", document.displayName))
        }
        .padding(.trailing, 5)
        .background(theme.chromeRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.cream.opacity(0.08), lineWidth: 1)
        }
    }

    private var recentDocumentsFooter: some View {
        HStack(spacing: 10) {
            Button(action: openDocument) {
                Label("PDF 열기", systemImage: "folder.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.brandNavy)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(theme.paperIvory, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("PDF 열기 (⌘O)")

            Spacer()

            if !recentDocuments.isEmpty {
                Button(action: clearRecentDocuments) {
                    Label("목록 지우기", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.chromeSecondaryText)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .help("최근 PDF 목록 전체 삭제")
                .accessibilityLabel("최근 PDF 목록 지우기")
            }
        }
    }

    private func privacyPill(_ systemImage: String, _ title: String) -> some View {
        Label(L10n.string(title), systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.card.opacity(0.78), in: Capsule())
            .overlay { Capsule().stroke(theme.border, lineWidth: 1) }
    }
}
