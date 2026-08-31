// SPDX-License-Identifier: MPL-2.0

import Foundation

/// 페이지 표시 UI에 보여 줄 1-based 페이지 범위를 계산한다.
///
/// 앱 내부의 `currentPageIndex`는 배열과 PDFKit 관례에 따라 0부터 시작하지만,
/// 사람에게 보여 주는 페이지 번호는 1부터 시작한다. 이 타입이 두 체계 사이의
/// 변환을 한곳에서 담당해 화면마다 `+ 1` 계산이 흩어지는 것을 막는다.
struct PDFPageDisplayRange: Equatable {
    let firstPageNumber: Int
    let lastPageNumber: Int
    let totalPageCount: Int

    /// 잘못된 인덱스와 페이지 수를 먼저 clamp하므로 복원 중인 문서나 페이지
    /// 삭제 직후의 일시적인 값이 들어와도 유효한 표시 문자열을 만든다.
    static func resolve(
        pageIndex: Int,
        pageCount: Int,
        groupSize: Int
    ) -> PDFPageDisplayRange {
        let safePageCount = max(0, pageCount)
        guard safePageCount > 0 else {
            return PDFPageDisplayRange(
                firstPageNumber: 0,
                lastPageNumber: 0,
                totalPageCount: 0
            )
        }

        let safePageIndex = min(max(0, pageIndex), safePageCount - 1)
        let safeGroupSize = max(1, groupSize)
        let groupStartIndex = (safePageIndex / safeGroupSize) * safeGroupSize

        return PDFPageDisplayRange(
            firstPageNumber: groupStartIndex + 1,
            lastPageNumber: min(safePageCount, groupStartIndex + safeGroupSize),
            totalPageCount: safePageCount
        )
    }

    var pageNumberDescription: String {
        if firstPageNumber == lastPageNumber {
            return "\(firstPageNumber)"
        }
        return "\(firstPageNumber)–\(lastPageNumber)"
    }

    var compactDescription: String {
        "\(pageNumberDescription) / \(totalPageCount)"
    }

    /// VoiceOver에서는 축약 기호 대신 완전한 번역 문장으로 읽는다.
    var accessibilityDescription: String {
        if firstPageNumber == lastPageNumber {
            return L10n.format("page.current_total", firstPageNumber, totalPageCount)
        }
        return L10n.format(
            "page.range_total",
            firstPageNumber,
            lastPageNumber,
            totalPageCount
        )
    }
}
