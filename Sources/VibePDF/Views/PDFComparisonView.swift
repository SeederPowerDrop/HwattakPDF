// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A focused workspace for comparing two to four open PDF tabs.
@MainActor
struct PDFComparisonView: View {
    let documents: [ComparisonDocument]
    @Binding var configuration: PDFComparisonConfiguration
    let onConfigure: () -> Void
    let onExit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @StateObject private var scrollCoordinator = PDFScrollSyncCoordinator()
    @State private var activeDividerIndex: Int?
    @State private var hoveredDividerIndex: Int?
    @State private var dividerInitialFractions: [Double]?
    @State private var draggedDocumentID: UUID?
    @State private var dropTargetDocumentID: UUID?
    @State private var dropPlacement: ComparisonPanelDropPlacement?

    private let dividerHitLength: CGFloat = 12
    private let minimumSideBySidePanelLength: CGFloat = 220
    private let minimumStackedPanelLength: CGFloat = 150

    private var theme: VibePDFTheme {
        VibePDFTheme(colorScheme: colorScheme)
    }

    private var selectedDocuments: [ComparisonDocument] {
        let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        return configuration.selectedDocumentIDs.compactMap { documentsByID[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            comparisonToolbar

            Group {
                if selectedDocuments.count >= PDFComparisonConfiguration.minimumDocumentCount {
                    comparisonPanels
                } else {
                    missingDocuments
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .onChange(of: configuration.syncEnabled, initial: true) { _, enabled in
            scrollCoordinator.enabled = enabled
        }
        .onChange(of: documents.map(\.id), initial: true) { _, availableIDs in
            configuration.normalize(availableDocumentIDs: Set(availableIDs))
        }
        .onChange(of: configuration.selectedDocumentIDs, initial: true) { _, _ in
            configuration.normalizePanelWeights()
            clearTransientDragState()
        }
        .onChange(of: configuration.layout) { _, _ in
            clearTransientDragState()
        }
        .onDisappear(perform: clearTransientDragState)
    }

    private var comparisonToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button(action: onExit) {
                Label("비교 종료", systemImage: "chevron.backward")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(theme.card, in: Capsule())
                    .overlay { Capsule().stroke(theme.border, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            HStack(spacing: 7) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(theme.accent)
                Text("PDF 비교")
                    .font(.system(size: 14, weight: .semibold))
                Text(L10n.format("document.count", selectedDocuments.count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.panel, in: Capsule())
            }

                Spacer(minLength: 6)

            Picker("비교 배치", selection: $configuration.layout) {
                ForEach(PDFComparisonLayout.allCases) { layout in
                    Label(
                        L10n.format("comparison.layout_label", layout.title, layout.splitDescription),
                        systemImage: layout.systemImage
                    )
                        .tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 310)
            .accessibilityLabel("PDF 비교 배치")

            Toggle(isOn: $configuration.syncEnabled) {
                Label("스크롤 동기화", systemImage: "arrow.up.and.down.square")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .fixedSize()
            .help("잠기지 않은 PDF의 트랙패드 스크롤 위치를 함께 맞춥니다.")

                Button(action: onConfigure) {
                Label("문서 선택", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(theme.card, in: Capsule())
                    .overlay { Capsule().stroke(theme.border, lineWidth: 1) }
            }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 54)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private var comparisonPanels: some View {
        GeometryReader { proxy in
            let dividerTotal = dividerHitLength * CGFloat(max(0, selectedDocuments.count - 1))
            let axisLength = configuration.layout == .sideBySide
                ? proxy.size.width
                : proxy.size.height
            let availableLength = max(0, axisLength - dividerTotal)
            let minimumPanelLength = configuration.layout == .sideBySide
                ? minimumSideBySidePanelLength
                : minimumStackedPanelLength
            let panelLengths = configuration.panelLengths(
                for: configuration.layout,
                availableLength: Double(availableLength),
                minimumPanelLength: Double(minimumPanelLength)
            ).map { CGFloat($0) }

            switch configuration.layout {
            case .sideBySide:
                HStack(spacing: 0) {
                    ForEach(Array(selectedDocuments.enumerated()), id: \.element.id) { index, document in
                        comparisonPanel(
                            document,
                            targetExtent: panelLengths[index]
                        )
                        .frame(width: panelLengths[index])
                        .frame(maxHeight: .infinity)

                        if index < selectedDocuments.count - 1 {
                            comparisonDivider(
                                afterPanelAt: index,
                                availableLength: availableLength,
                                minimumPanelLength: minimumPanelLength
                            )
                        }
                    }
                }
            case .stacked:
                VStack(spacing: 0) {
                    ForEach(Array(selectedDocuments.enumerated()), id: \.element.id) { index, document in
                        comparisonPanel(document, targetExtent: 38)
                            .frame(height: panelLengths[index])
                            .frame(maxWidth: .infinity)

                        if index < selectedDocuments.count - 1 {
                            comparisonDivider(
                                afterPanelAt: index,
                                availableLength: availableLength,
                                minimumPanelLength: minimumPanelLength
                            )
                        }
                    }
                }
            }
        }
        .background(theme.border)
        .clipped()
    }

    private func comparisonPanel(
        _ document: ComparisonDocument,
        targetExtent: CGFloat
    ) -> some View {
        PDFComparisonPanel(
            document: document,
            isLocked: configuration.isLocked(document.id),
            syncEnabled: configuration.syncEnabled,
            scrollCoordinator: scrollCoordinator,
            comparisonLayout: configuration.layout,
            targetExtent: targetExtent,
            draggedDocumentID: $draggedDocumentID,
            dropTargetDocumentID: $dropTargetDocumentID,
            dropPlacement: $dropPlacement,
            moveDocument: moveDocument
        ) {
            withAnimation(.easeInOut(duration: 0.16)) {
                configuration.toggleLock(document.id)
            }
        }
    }

    @ViewBuilder
    private func comparisonDivider(
        afterPanelAt index: Int,
        availableLength: CGFloat,
        minimumPanelLength: CGFloat
    ) -> some View {
        let isActive = activeDividerIndex == index
        let isHovered = hoveredDividerIndex == index

        if configuration.layout == .sideBySide {
            dividerBody(isActive: isActive, isHovered: isHovered, vertical: true)
                .frame(width: dividerHitLength)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    dividerDragGesture(
                        afterPanelAt: index,
                        availableLength: availableLength,
                        minimumPanelLength: minimumPanelLength,
                        vertical: true
                    )
                )
                .onHover { updateDividerHover($0, index: index, vertical: true) }
                .accessibilityLabel("\(index + 1)\u{BC88}\u{C9F8} \u{D328}\u{B110} \u{B113}\u{C774} \u{C870}\u{C808}")
        } else {
            dividerBody(isActive: isActive, isHovered: isHovered, vertical: false)
                .frame(height: dividerHitLength)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    dividerDragGesture(
                        afterPanelAt: index,
                        availableLength: availableLength,
                        minimumPanelLength: minimumPanelLength,
                        vertical: false
                    )
                )
                .onHover { updateDividerHover($0, index: index, vertical: false) }
                .accessibilityLabel("\(index + 1)\u{BC88}\u{C9F8} \u{D328}\u{B110} \u{B192}\u{C774} \u{C870}\u{C808}")
        }
    }

    private func dividerBody(isActive: Bool, isHovered: Bool, vertical: Bool) -> some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(isActive || isHovered ? theme.accent : theme.border)
                .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
                .padding(vertical ? .vertical : .horizontal, 7)
        }
        .background((isActive || isHovered ? theme.dropHighlight : theme.border.opacity(0.2)))
    }

    private func dividerDragGesture(
        afterPanelAt index: Int,
        availableLength: CGFloat,
        minimumPanelLength: CGFloat,
        vertical: Bool
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeDividerIndex != index {
                    activeDividerIndex = index
                    dividerInitialFractions = configuration.panelFractions(for: configuration.layout)
                }
                var translation = vertical ? value.translation.width : value.translation.height
                if vertical && layoutDirection == .rightToLeft {
                    translation *= -1
                }
                configuration.resizeDivider(
                    for: configuration.layout,
                    afterPanelAt: index,
                    translation: Double(translation),
                    availableLength: Double(availableLength),
                    minimumPanelLength: Double(minimumPanelLength),
                    initialFractions: dividerInitialFractions
                )
            }
            .onEnded { _ in
                activeDividerIndex = nil
                dividerInitialFractions = nil
            }
    }

    private func updateDividerHover(_ isHovered: Bool, index: Int, vertical: Bool) {
        if isHovered {
            hoveredDividerIndex = index
            (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        } else if hoveredDividerIndex == index {
            hoveredDividerIndex = nil
            NSCursor.arrow.set()
        }
    }

    private func moveDocument(
        _ sourceID: UUID,
        _ targetID: UUID,
        _ placement: ComparisonPanelDropPlacement
    ) {
        guard
            sourceID != targetID,
            configuration.selectedDocumentIDs.contains(sourceID),
            configuration.selectedDocumentIDs.contains(targetID)
        else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            switch placement {
            case .before:
                configuration.moveSelection(sourceID, before: targetID)
            case .after:
                configuration.moveSelection(sourceID, after: targetID)
            }
        }
    }

    private func clearTransientDragState() {
        if hoveredDividerIndex != nil {
            NSCursor.arrow.set()
        }
        activeDividerIndex = nil
        hoveredDividerIndex = nil
        dividerInitialFractions = nil
        draggedDocumentID = nil
        dropTargetDocumentID = nil
        dropPlacement = nil
    }

    private var missingDocuments: some View {
        ContentUnavailableView {
            Label("비교할 PDF가 부족합니다", systemImage: "rectangle.split.2x1")
        } description: {
            Text("열려 있는 PDF 중 2~4개를 다시 선택해 주세요.")
        } actions: {
            HStack {
                Button("문서 선택", action: onConfigure)
                    .buttonStyle(.borderedProminent)
                Button("비교 종료", action: onExit)
            }
        }
    }
}

// `NSItemProvider(object: NSString)` registers the concrete UTF-8 text type.
// AppKit does not consistently match that provider when a drop target asks for
// the broader `public.plain-text` type, so use the concrete identifier here.
let comparisonPanelDragType = UTType.utf8PlainText

private enum ComparisonPanelDropPlacement {
    case before
    case after
}

func comparisonPanelItemProvider(for id: UUID) -> NSItemProvider {
    let payload = PDFComparisonPanelDragPayload.encodedValue(for: id)
    let provider = NSItemProvider(object: payload as NSString)
    provider.suggestedName = payload
    return provider
}

/// Loads the provider-backed source ID before any comparison order mutation.
private func loadComparisonPanelDragSourceID(
    from info: DropInfo,
    completion: @escaping @MainActor (UUID?) -> Void
) -> Bool {
    guard let provider = info.itemProviders(for: [comparisonPanelDragType]).first else {
        return false
    }
    provider.loadObject(ofClass: NSString.self) { object, _ in
        let sourceID = (object as? NSString)
            .map(String.init)
            .flatMap(PDFComparisonPanelDragPayload.decode)
        Task { @MainActor in
            completion(sourceID)
        }
    }
    return true
}

private struct ComparisonPanelDropDelegate: DropDelegate {
    let targetDocumentID: UUID
    let targetExtent: CGFloat
    let layout: PDFComparisonLayout
    let isRightToLeft: Bool
    @Binding var draggedDocumentID: UUID?
    @Binding var dropTargetDocumentID: UUID?
    @Binding var dropPlacement: ComparisonPanelDropPlacement?
    let moveDocument: (UUID, UUID, ComparisonPanelDropPlacement) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard
            let sourceID = draggedDocumentID,
            sourceID != targetDocumentID
        else { return false }
        return info.hasItemsConforming(to: [comparisonPanelDragType])
    }

    func dropEntered(info: DropInfo) {
        updateDropState(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropState(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard dropTargetDocumentID == targetDocumentID else { return }
        dropTargetDocumentID = nil
        dropPlacement = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let placement = resolvedPlacement(info)
        let didScheduleLoad = loadComparisonPanelDragSourceID(from: info) { sourceID in
            guard let sourceID, sourceID != targetDocumentID else { return }
            // `moveDocument` re-checks both IDs against the current binding so
            // a close/reconfigure that races the async load cannot move a
            // stale document.
            moveDocument(sourceID, targetDocumentID, placement)
        }
        guard didScheduleLoad else {
            clearDropState()
            return false
        }
        clearDropState()
        return true
    }

    private func updateDropState(_ info: DropInfo) {
        guard
            let sourceID = draggedDocumentID,
            sourceID != targetDocumentID,
            info.hasItemsConforming(to: [comparisonPanelDragType])
        else {
            if dropTargetDocumentID == targetDocumentID {
                dropTargetDocumentID = nil
                dropPlacement = nil
            }
            return
        }
        dropTargetDocumentID = targetDocumentID
        dropPlacement = resolvedPlacement(info)
    }

    private func resolvedPlacement(_ info: DropInfo) -> ComparisonPanelDropPlacement {
        let extent = max(1, targetExtent)
        switch layout {
        case .sideBySide:
            let isPhysicalTrailingHalf = info.location.x >= extent / 2
            if isRightToLeft {
                return isPhysicalTrailingHalf ? .before : .after
            }
            return isPhysicalTrailingHalf ? .after : .before
        case .stacked:
            return info.location.y >= extent / 2 ? .after : .before
        }
    }

    private func clearDropState() {
        draggedDocumentID = nil
        dropTargetDocumentID = nil
        dropPlacement = nil
    }
}

@MainActor
private struct PDFComparisonPanel: View {
    let document: ComparisonDocument
    let isLocked: Bool
    let syncEnabled: Bool
    @ObservedObject var scrollCoordinator: PDFScrollSyncCoordinator
    let comparisonLayout: PDFComparisonLayout
    let targetExtent: CGFloat
    @Binding var draggedDocumentID: UUID?
    @Binding var dropTargetDocumentID: UUID?
    @Binding var dropPlacement: ComparisonPanelDropPlacement?
    let moveDocument: (UUID, UUID, ComparisonPanelDropPlacement) -> Void
    let toggleLock: () -> Void

    @ObservedObject private var workspace: PDFWorkspaceState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    init(
        document: ComparisonDocument,
        isLocked: Bool,
        syncEnabled: Bool,
        scrollCoordinator: PDFScrollSyncCoordinator,
        comparisonLayout: PDFComparisonLayout,
        targetExtent: CGFloat,
        draggedDocumentID: Binding<UUID?>,
        dropTargetDocumentID: Binding<UUID?>,
        dropPlacement: Binding<ComparisonPanelDropPlacement?>,
        moveDocument: @escaping (UUID, UUID, ComparisonPanelDropPlacement) -> Void,
        toggleLock: @escaping () -> Void
    ) {
        self.document = document
        self.isLocked = isLocked
        self.syncEnabled = syncEnabled
        self.scrollCoordinator = scrollCoordinator
        self.comparisonLayout = comparisonLayout
        self.targetExtent = targetExtent
        _draggedDocumentID = draggedDocumentID
        _dropTargetDocumentID = dropTargetDocumentID
        _dropPlacement = dropPlacement
        self.moveDocument = moveDocument
        self.toggleLock = toggleLock
        _workspace = ObservedObject(wrappedValue: document.workspace)
    }

    private var theme: VibePDFTheme {
        VibePDFTheme(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader

            PDFKitViewer(
                state: workspace,
                scrollSyncCoordinator: scrollCoordinator,
                scrollSyncID: document.id,
                scrollSyncLocked: isLocked,
                viewportContext: .comparison
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.layoutDirection, .leftToRight)
        }
        .background(theme.canvas)
        .overlay {
            Rectangle()
                .stroke(isLocked && syncEnabled ? theme.warning.opacity(0.72) : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .onAppear {
            // A comparison may select an inactive clean tab that the memory
            // manager hibernated. Reload it before PDFKit receives the model;
            // the workspace preserves page/viewport metadata across this hop.
            _ = document.prepareForDisplay()
            // Do not rewrite the source tab's selected tool here. The
            // comparison PDFView derives Select as its local effective tool,
            // while the hidden normal editor keeps the user's Pen/Eraser choice.
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            panelDragHandle

            Text(pageDescription)
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.secondaryText)

            Button(action: toggleLock) {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isLocked ? theme.warning : theme.secondaryText)
                    .frame(width: 27, height: 27)
                    .background(
                        isLocked ? theme.warning.opacity(0.12) : theme.card,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isLocked ? theme.warning.opacity(0.34) : theme.border, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help(lockHelp)
            .accessibilityLabel(
                isLocked
                    ? L10n.format("comparison.unlock_document", document.title)
                    : L10n.format("comparison.lock_document", document.title)
            )
            .accessibilityValue(
                isLocked
                    ? L10n.string("comparison.sync_excluded")
                    : L10n.string("comparison.sync_included")
            )
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(theme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
        .overlay(alignment: dropIndicatorAlignment) {
            if dropTargetDocumentID == document.id, dropPlacement != nil {
                Rectangle()
                    .fill(theme.accent)
                    .frame(
                        width: comparisonLayout == .sideBySide ? 3 : nil,
                        height: comparisonLayout == .stacked ? 3 : nil
                    )
                    .shadow(color: theme.accent.opacity(0.45), radius: 2)
                .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [comparisonPanelDragType],
            delegate: ComparisonPanelDropDelegate(
                targetDocumentID: document.id,
                targetExtent: targetExtent,
                layout: comparisonLayout,
                isRightToLeft: layoutDirection == .rightToLeft,
                draggedDocumentID: $draggedDocumentID,
                dropTargetDocumentID: $dropTargetDocumentID,
                dropPlacement: $dropPlacement,
                moveDocument: moveDocument
            )
        )
    }

    private var panelDragHandle: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.secondaryText)

            Image(systemName: "doc.text.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.accent)

            Text(document.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if workspace.isDirty {
                Circle()
                    .fill(theme.warning)
                    .frame(width: 6, height: 6)
                    .help(L10n.string("document.unsaved_changes"))
                    .accessibilityLabel(L10n.string("document.edited"))
            }

            Spacer(minLength: 2)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .contentShape(Rectangle())
        .onDrag {
            draggedDocumentID = document.id
            return comparisonPanelItemProvider(for: document.id)
        }
        .help("\u{B4DC}\u{B798}\u{ADF8}\u{D558}\u{C5EC} \u{BE44}\u{AD50} \u{D328}\u{B110} \u{C21C}\u{C11C} \u{BCC0}\u{ACBD}")
        .accessibilityHint("\u{B4DC}\u{B798}\u{ADF8}\u{D558}\u{C5EC} \u{B2E4}\u{B978} \u{BE44}\u{AD50} \u{D328}\u{B110} \u{C55E}\u{C774}\u{B098} \u{B4A4}\u{B85C} \u{C774}\u{B3D9}\u{D569}\u{B2C8}\u{B2E4}.")
    }

    private var dropIndicatorAlignment: Alignment {
        guard let dropPlacement else { return .center }
        switch (comparisonLayout, dropPlacement) {
        case (.sideBySide, .before):
            return .leading
        case (.sideBySide, .after):
            return .trailing
        case (.stacked, .before):
            return .top
        case (.stacked, .after):
            return .bottom
        }
    }

    private var pageDescription: String {
        guard workspace.pageCount > 0 else { return L10n.format("page.count", 0) }
        return L10n.format(
            "page.current_total",
            min(workspace.currentPageIndex + 1, workspace.pageCount),
            workspace.pageCount
        )
    }

    private var lockHelp: String {
        if isLocked {
            return L10n.string("comparison.lock_help.unlock")
        }
        if syncEnabled {
            return L10n.string("comparison.lock_help.lock")
        }
        return L10n.string("comparison.lock_help.disabled")
    }
}
