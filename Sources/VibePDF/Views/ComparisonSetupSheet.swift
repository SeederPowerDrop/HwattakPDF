// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// 비교 모드에 들어가기 전 문서·순서·분할 방향·동기화 옵션을 고르는 sheet다.
///
/// `draft`는 사용자가 확인하기 전의 임시 복사본이다. 취소하면 binding에 아무것도
/// 쓰지 않고, 시작 버튼을 눌렀을 때만 부모 configuration에 commit한다. 이 패턴은
/// 설정 창에서 '취소'가 정말 무변경이어야 할 때 재사용할 수 있다.
@MainActor
struct ComparisonSetupSheet: View {
    let documents: [ComparisonDocument]
    @Binding private var configuration: PDFComparisonConfiguration
    let onCancel: () -> Void
    let onStart: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// 편집 중인 값과 실제 적용 값을 분리하는 transactional draft.
    @State private var draft: PDFComparisonConfiguration

    init(
        documents: [ComparisonDocument],
        configuration: Binding<PDFComparisonConfiguration>,
        onCancel: @escaping () -> Void,
        onStart: @escaping () -> Void
    ) {
        self.documents = documents
        _configuration = configuration
        self.onCancel = onCancel
        self.onStart = onStart
        _draft = State(initialValue: configuration.wrappedValue)
    }

    private var theme: VibePDFTheme {
        VibePDFTheme(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    documentSelection
                    layoutSelection
                    scrollSelection
                }
                .padding(24)
            }

            footer
        }
        .frame(minWidth: 600, idealWidth: 660, maxWidth: 720, minHeight: 650, idealHeight: 700)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .onAppear(perform: prepareDraft)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.split.2x1.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 44, height: 44)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("PDF 비교 설정")
                    .font(.title3.weight(.semibold))
                Text("함께 볼 문서 2~4개와 배치 방식을 선택하세요.")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(theme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var documentSelection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                "비교할 PDF",
                detail: L10n.format(
                    "comparison.selection_count",
                    draft.selectedDocumentIDs.count,
                    PDFComparisonConfiguration.maximumDocumentCount
                )
            )

            if documents.isEmpty {
                ContentUnavailableView(
                    "비교할 PDF가 없습니다",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("먼저 두 개 이상의 PDF를 탭으로 열어 주세요.")
                )
                .frame(maxWidth: .infinity, minHeight: 170)
                .vibePDFCard(theme, cornerRadius: 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(documents.enumerated()), id: \.element.id) { offset, document in
                        documentRow(document)
                        if offset < documents.count - 1 {
                            Divider().overlay(theme.border)
                        }
                    }
                }
                .vibePDFCard(theme, cornerRadius: 12)
            }

            if !documents.isEmpty && documents.count < PDFComparisonConfiguration.minimumDocumentCount {
                Label("비교하려면 PDF 탭을 하나 더 열어 주세요.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(theme.warning)
            }
        }
    }

    private func documentRow(_ document: ComparisonDocument) -> some View {
        let selectionIndex = draft.selectionIndex(for: document.id)
        let selected = selectionIndex != nil
        let selectionLimitReached = draft.selectedDocumentIDs.count >= PDFComparisonConfiguration.maximumDocumentCount

        return HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    draft.toggleSelection(document.id)
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? theme.accent : theme.panel)
                        if let selectionIndex {
                            Text("\(selectionIndex + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "plus")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .frame(width: 29, height: 29)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selected ? theme.accent : theme.border, lineWidth: 1)
                    }

                    Image(systemName: "doc.richtext.fill")
                        .foregroundStyle(selected ? theme.accent : theme.secondaryText)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(L10n.format("page.count", document.pageCount))
                            if document.isDirty {
                                Text("편집됨")
                                    .foregroundStyle(theme.warning)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selected && selectionLimitReached)
            .accessibilityLabel(
                L10n.format("comparison.document_accessibility", document.title, document.pageCount)
            )
            .accessibilityValue(
                selected
                    ? L10n.format("comparison.order", (selectionIndex ?? 0) + 1)
                    : L10n.string("selection.not_selected")
            )

            if let selectionIndex {
                HStack(spacing: 2) {
                    reorderButton("chevron.up", label: L10n.string("action.move_forward")) {
                        draft.moveSelection(document.id, by: -1)
                    }
                    .disabled(selectionIndex == 0)

                    reorderButton("chevron.down", label: L10n.string("action.move_backward")) {
                        draft.moveSelection(document.id, by: 1)
                    }
                    .disabled(selectionIndex == draft.selectedDocumentIDs.count - 1)
                }
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 58)
        .background(selected ? theme.dropHighlight.opacity(0.62) : Color.clear)
    }

    private var layoutSelection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("배치", detail: "분할선 방향까지 함께 표시합니다.")

            Picker("비교 배치", selection: $draft.layout) {
                ForEach(PDFComparisonLayout.allCases) { layout in
                    Label("\(layout.title) · \(layout.splitDescription)", systemImage: layout.systemImage)
                        .tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("PDF 비교 배치")

            Text(layoutHelp)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var scrollSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("트랙패드 스크롤", detail: nil)

            Toggle(isOn: $draft.syncEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("문서 위치 함께 이동")
                        .font(.system(size: 13, weight: .semibold))
                    Text("한 패널을 스크롤하면 잠기지 않은 PDF들이 같은 비율로 이동합니다.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .toggleStyle(.switch)
            .padding(14)
            .vibePDFCard(theme, cornerRadius: 12)

            Label(
                "비교 화면의 자물쇠를 켠 문서는 다른 문서를 움직이지도, 다른 문서를 따라 움직이지도 않습니다.",
                systemImage: "lock.fill"
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
        }
    }

    private var footer: some View {
        HStack {
            Text(validationMessage)
                .font(.caption)
                .foregroundStyle(draft.canBeginComparison ? theme.secondaryText : theme.warning)

            Spacer()

            Button("취소", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("비교 시작") {
                configuration = draft
                onStart()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canBeginComparison)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(theme.sidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var layoutHelp: String {
        switch draft.layout {
        case .sideBySide:
            L10n.string("comparison.layout.side_by_side_help")
        case .stacked:
            L10n.string("comparison.layout.stacked_help")
        }
    }

    private var validationMessage: String {
        if draft.selectedDocumentIDs.count < PDFComparisonConfiguration.minimumDocumentCount {
            return L10n.format(
                "comparison.minimum_selection",
                PDFComparisonConfiguration.minimumDocumentCount
            )
        }
        return L10n.format("comparison.open_selection", draft.selectedDocumentIDs.count)
    }

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.string(title))
                .font(.headline)
            Spacer()
            if let detail {
                Text(L10n.string(detail))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func reorderButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 25, height: 25)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func prepareDraft() {
        let availableIDs = Set(documents.map(\.id))
        draft.normalize(availableDocumentIDs: availableIDs)

        if draft.selectedDocumentIDs.count < PDFComparisonConfiguration.minimumDocumentCount {
            for id in documents.map(\.id) where !draft.isSelected(id) {
                draft.selectedDocumentIDs.append(id)
                if draft.selectedDocumentIDs.count == PDFComparisonConfiguration.minimumDocumentCount {
                    break
                }
            }
        }
    }
}
