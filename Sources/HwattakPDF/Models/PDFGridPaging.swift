// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// 다중 페이지 개요에서 사용자가 선택한 주 스크롤 방향이다.
enum PDFGridPagingDirection: String, CaseIterable, Identifiable {
    case vertical
    case horizontal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vertical: L10n.string("direction.vertical")
        case .horizontal: L10n.string("direction.horizontal")
        }
    }

    var systemImage: String {
        switch self {
        case .vertical: "arrow.up.and.down"
        case .horizontal: "arrow.left.and.right"
        }
    }
}

/// `ScrollViewReader`가 이동할 수 있는 의미 있는 목적지다.
///
/// 3·5·6페이지 보기에서는 개별 페이지가 목적지이고, 엄격한 4페이지 보기에서는
/// 항상 4장 묶음이 목적지다. 이 구분 덕분에 검색 결과는 정확한 현재 페이지를
/// 유지하면서도 화면은 그 페이지가 포함된 묶음을 보여 줄 수 있다.
enum PDFGridOverviewScrollTarget: Hashable {
    case overviewContainer
    case page(Int)
    case pageGroup(Int)

    static func resolve(
        pageIndex: Int,
        requestedPageCount: Int,
        documentPageCount: Int
    ) -> PDFGridOverviewScrollTarget {
        let safePageIndex: Int
        if documentPageCount > 0 {
            safePageIndex = min(max(0, pageIndex), documentPageCount - 1)
        } else {
            safePageIndex = 0
        }

        guard requestedPageCount == PDFGridPageGroup.pageCountPerGroup else {
            return .page(safePageIndex)
        }
        return .pageGroup(
            PDFGridPageGroup(
                containing: safePageIndex,
                documentPageCount: documentPageCount
            ).startIndex
        )
    }

    static func requiresNavigation(
        from oldPageIndex: Int,
        to newPageIndex: Int,
        requestedPageCount: Int,
        documentPageCount: Int
    ) -> Bool {
        resolve(
            pageIndex: oldPageIndex,
            requestedPageCount: requestedPageCount,
            documentPageCount: documentPageCount
        ) != resolve(
            pageIndex: newPageIndex,
            requestedPageCount: requestedPageCount,
            documentPageCount: documentPageCount
        )
    }
}

/// 목적지를 viewport의 어느 위치에 맞출지 결정하는 정책이다.
enum PDFGridOverviewScrollAnchorPolicy: Equatable {
    case center
    case leadingCenter

    static func resolve(
        requestedPageCount: Int,
        enablesHorizontalScrolling: Bool
    ) -> PDFGridOverviewScrollAnchorPolicy {
        if requestedPageCount == PDFGridPageGroup.pageCountPerGroup {
            return .center
        }
        return enablesHorizontalScrolling ? .leadingCenter : .center
    }
}

/// 문서의 연속된 네 페이지를 나타낸다.
/// 마지막 묶음에 페이지가 모자라면 `pageSlots`의 나머지는 `nil`이 된다.
struct PDFGridPageGroup: Equatable {
    static let pageCountPerGroup = 4

    let startIndex: Int
    let documentPageCount: Int

    init(containing pageIndex: Int, documentPageCount: Int) {
        self.init(startIndex: pageIndex, documentPageCount: documentPageCount)
    }

    init(startIndex requestedStartIndex: Int, documentPageCount: Int) {
        let safePageCount = max(0, documentPageCount)
        let lastStart = safePageCount > 0
            ? ((safePageCount - 1) / Self.pageCountPerGroup) * Self.pageCountPerGroup
            : 0
        let requestedGroupStart = max(0, requestedStartIndex) / Self.pageCountPerGroup
            * Self.pageCountPerGroup
        startIndex = min(requestedGroupStart, lastStart)
        self.documentPageCount = safePageCount
    }

    var pageSlots: [Int?] {
        (0..<Self.pageCountPerGroup).map { offset in
            let index = startIndex + offset
            return index < documentPageCount ? index : nil
        }
    }

    var previousStartIndex: Int? {
        startIndex >= Self.pageCountPerGroup
            ? startIndex - Self.pageCountPerGroup
            : nil
    }

    var nextStartIndex: Int? {
        startIndex + Self.pageCountPerGroup < documentPageCount
            ? startIndex + Self.pageCountPerGroup
            : nil
    }

    func targetStartIndex(groupOffset: Int) -> Int? {
        switch groupOffset {
        case ..<0: previousStartIndex
        case 1...: nextStartIndex
        default: startIndex
        }
    }
}

/// 작은 트랙패드 delta를 모아 한 번의 페이지 전환으로 바꾸는 순수 상태 머신이다.
///
/// 손가락이 조금 흔들릴 때마다 페이지가 넘어가지 않도록 임계값과 주축 우세
/// 비율을 적용하고, 한 제스처에서는 오직 한 번만 결과를 낸다.
struct PDFGridPagingAccumulator: Equatable {
    static let defaultThreshold: CGFloat = 48
    static let defaultDominanceRatio: CGFloat = 1.15

    private(set) var accumulatedPrimaryDelta: CGFloat = 0
    private(set) var didTriggerPage = false

    mutating func reset() {
        accumulatedPrimaryDelta = 0
        didTriggerPage = false
    }

    mutating func consume(
        primaryDelta: CGFloat,
        crossAxisDelta: CGFloat,
        threshold: CGFloat = Self.defaultThreshold,
        dominanceRatio: CGFloat = Self.defaultDominanceRatio
    ) -> Int? {
        guard !didTriggerPage else { return nil }
        guard abs(primaryDelta) > 0.01 else { return nil }
        guard abs(primaryDelta) >= abs(crossAxisDelta) * dominanceRatio else { return nil }

        accumulatedPrimaryDelta += primaryDelta
        guard abs(accumulatedPrimaryDelta) >= max(1, threshold) else { return nil }

        didTriggerPage = true
        return accumulatedPrimaryDelta < 0 ? 1 : -1
    }
}

/// Keeps a single page-turn latch alive from the finger phase through any
/// momentum phase. The delayed `finishWaitingForMomentum()` call is what
/// separates two trackpad gestures when AppKit does not emit momentum events.
struct PDFGridPagingGestureSession: Equatable {
    private(set) var accumulator = PDFGridPagingAccumulator()
    private(set) var isTouchActive = false
    private(set) var isAwaitingMomentum = false
    private(set) var isMomentumActive = false

    mutating func beginTouchGesture() {
        guard !isTouchActive else { return }
        accumulator.reset()
        isTouchActive = true
        isAwaitingMomentum = false
        isMomentumActive = false
    }

    mutating func consume(primaryDelta: CGFloat, crossAxisDelta: CGFloat) -> Int? {
        accumulator.consume(
            primaryDelta: primaryDelta,
            crossAxisDelta: crossAxisDelta
        )
    }

    mutating func endTouchGesture() {
        guard isTouchActive else { return }
        isTouchActive = false
        isAwaitingMomentum = true
    }

    mutating func beginMomentum() {
        isTouchActive = false
        isAwaitingMomentum = false
        isMomentumActive = true
    }

    mutating func endMomentum() {
        reset()
    }

    mutating func finishWaitingForMomentum() {
        guard isAwaitingMomentum else { return }
        reset()
    }

    mutating func reset() {
        accumulator.reset()
        isTouchActive = false
        isAwaitingMomentum = false
        isMomentumActive = false
    }
}

/// 한 번의 pinch 제스처 동안 누적된 상대 확대율을 보관한다.
/// 절대 확대율은 뷰가 제스처 시작값에 이 값을 곱해 계산한다.
struct PDFGridMagnificationAccumulator: Equatable {
    private(set) var relativeFactor: CGFloat = 1

    mutating func reset() {
        relativeFactor = 1
    }

    @discardableResult
    mutating func consume(change: CGFloat) -> CGFloat {
        guard change.isFinite else { return relativeFactor }
        relativeFactor = min(2, max(0.5, relativeFactor + change))
        return relativeFactor
    }
}
