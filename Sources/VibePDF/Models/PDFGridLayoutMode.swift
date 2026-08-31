// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// 네 페이지를 화면에 배치하는 두 가지 시각적 형태다.
///
/// 이 타입에는 SwiftUI 코드가 없다. 화면 모양을 결정하는 **규칙**을 모델로
/// 분리하면 창 크기와 관계없이 같은 입력이 같은 결과를 내고, AppKit 없이도
/// 단위 테스트할 수 있다. `balanced`는 2×2, `singleRow`는 1×4다.
enum PDFGridLayoutMode: String, CaseIterable, Identifiable {
    case balanced
    case singleRow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: "2×2"
        case .singleRow: "1×4"
        }
    }

    /// 툴바의 4페이지 버튼을 눌렀을 때의 다음 상태를 계산한다.
    /// 이미 4페이지라면 2×2와 1×4를 토글하고, 아니면 2×2부터 시작한다.
    func selectionAfterFourPageButton(currentPageCount: Int) -> PDFGridViewSelection {
        guard currentPageCount == 4 else {
            return PDFGridViewSelection(pageCount: 4, layoutMode: .balanced)
        }

        return PDFGridViewSelection(
            pageCount: 4,
            layoutMode: self == .balanced ? .singleRow : .balanced
        )
    }

    /// 네 페이지 모드에서는 어느 페이지를 요청해도 그 페이지가 속한 묶음의
    /// 첫 인덱스를 반환한다. PDFKit 인덱스가 0부터 시작한다는 점에 유의한다.
    func navigationTarget(for pageIndex: Int, requestedPageCount: Int) -> Int {
        let safePageIndex = max(0, pageIndex)
        guard requestedPageCount == 4 else { return safePageIndex }
        return (safePageIndex / 4) * 4
    }
}

/// 툴바 선택을 한 값으로 전달하기 위한 작고 불변인 상태 묶음이다.
struct PDFGridViewSelection: Equatable {
    let pageCount: Int
    let layoutMode: PDFGridLayoutMode
}

/// 여러 페이지가 동시에 보일 때 어느 페이지를 '현재 페이지'로 삼을지 고른다.
enum PDFGridVisibilityResolver {
    /// 보이는 면적이 가장 큰 페이지를 선택한다. 면적이 거의 같으면 현재
    /// 페이지를 유지하여 스크롤 경계에서 번호가 빠르게 흔들리는 것을 막는다.
    static func mostVisiblePage(
        from visibleAreas: [Int: CGFloat],
        currentPageIndex: Int,
        areaTolerance: CGFloat = 0.5
    ) -> Int? {
        visibleAreas.max { lhs, rhs in
            if abs(lhs.value - rhs.value) <= areaTolerance {
                if lhs.key == currentPageIndex { return false }
                if rhs.key == currentPageIndex { return true }
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key
    }
}

/// 개요 화면의 순수 레이아웃 계산 결과다.
///
/// `PDFGridOverview`는 이 숫자를 그리기만 한다. 계산과 렌더링을 분리하면
/// 작은 창, 2×2/1×4 전환, 70~160% 확대 같은 경계를 빠르게 테스트할 수 있다.
struct PDFGridLayoutMetrics: Equatable {
    /// Must match PDFGridOverview's 10pt outer padding on both sides.
    static let thumbnailHorizontalInset: CGFloat = 20
    /// 10pt vertical padding on both sides + 9pt label spacing + 14pt page label.
    static let thumbnailVerticalOverhead: CGFloat = 43

    let columnCount: Int
    let tileWidth: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let horizontalPadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let viewportHeight: CGFloat
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let enablesHorizontalScrolling: Bool

    func estimatedTileHeight(maximumPageAspect: CGFloat) -> CGFloat {
        max(0, tileWidth - Self.thumbnailHorizontalInset)
            * max(0.1, maximumPageAspect)
            + Self.thumbnailVerticalOverhead
    }

    /// 화면 크기와 사용자 설정을 안전한 범위로 보정한 뒤 타일 크기를 구한다.
    /// 네 페이지 2×2는 너비뿐 아니라 높이에도 맞추며, 다른 모드는 가로로
    /// 넘칠 때 스크롤할 수 있도록 실제 콘텐츠 너비를 그대로 계산한다.
    static func resolve(
        viewportSize: CGSize,
        requestedPageCount: Int,
        layoutMode: PDFGridLayoutMode,
        overviewScale: CGFloat,
        maximumPageAspect: CGFloat
    ) -> PDFGridLayoutMetrics {
        let requested = max(3, min(12, requestedPageCount))
        let isFourPageLayout = requested == 4
        let isBalancedFourPageLayout = isFourPageLayout && layoutMode == .balanced
        let columns = isBalancedFourPageLayout ? 2 : requested
        let rows = isBalancedFourPageLayout ? 2 : 1
        let horizontalSpacing: CGFloat = isFourPageLayout
            ? (isBalancedFourPageLayout ? 18 : 14)
            : (columns >= 8 ? 10 : (columns >= 5 ? 14 : (columns >= 3 ? 18 : 22)))
        let verticalSpacing: CGFloat = isFourPageLayout ? 18 : 26
        let horizontalPadding: CGFloat = isFourPageLayout
            ? 18
            : (columns >= 8 ? 16 : (columns >= 5 ? 20 : 24))
        let topPadding: CGFloat = isFourPageLayout ? 18 : 52
        let bottomPadding: CGFloat = isFourPageLayout ? 18 : 64

        let viewportWidth = max(1, viewportSize.width)
        let viewportHeight = max(1, viewportSize.height)
        let availableWidth = max(
            1,
            viewportWidth
                - horizontalPadding * 2
                - horizontalSpacing * CGFloat(columns - 1)
        )
        let widthFit = availableWidth / CGFloat(columns)

        let safeAspect = maximumPageAspect.isFinite
            ? max(0.1, maximumPageAspect)
            : 1.414
        let baseTileWidth: CGFloat
        if isFourPageLayout {
            let availableHeight = max(
                1,
                viewportHeight
                    - topPadding
                    - bottomPadding
                    - verticalSpacing * CGFloat(rows - 1)
            )
            let heightPerTile = availableHeight / CGFloat(rows)
            let imageWidthForHeight = max(
                1,
                (heightPerTile - thumbnailVerticalOverhead) / safeAspect
            )
            let heightFit = imageWidthForHeight + thumbnailHorizontalInset
            baseTileWidth = min(widthFit, heightFit)
        } else {
            baseTileWidth = widthFit
        }

        let safeScale = overviewScale.isFinite
            ? min(1.6, max(0.7, overviewScale))
            : 1
        let scaledTileWidth = max(1, baseTileWidth * safeScale)
        let tileWidth = (scaledTileWidth * 2).rounded(.down) / 2
        let contentWidth = horizontalPadding * 2
            + tileWidth * CGFloat(columns)
            + horizontalSpacing * CGFloat(columns - 1)
        let estimatedTileHeight = max(0, tileWidth - thumbnailHorizontalInset)
            * safeAspect + thumbnailVerticalOverhead
        let contentHeight = topPadding
            + estimatedTileHeight * CGFloat(rows)
            + verticalSpacing * CGFloat(rows - 1)
            + bottomPadding
        let enablesHorizontalScrolling = safeScale > 1.0001
            && (isFourPageLayout || contentWidth > viewportWidth + 0.5)

        return PDFGridLayoutMetrics(
            columnCount: columns,
            tileWidth: tileWidth,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing,
            horizontalPadding: horizontalPadding,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            viewportHeight: viewportHeight,
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            enablesHorizontalScrolling: enablesHorizontalScrolling
        )
    }
}
