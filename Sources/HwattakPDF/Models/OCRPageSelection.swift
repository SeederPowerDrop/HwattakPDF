// SPDX-License-Identifier: MPL-2.0

import Foundation

enum OCRPageScope: String, CaseIterable, Identifiable {
    case all
    case current
    case custom

    var id: String { rawValue }
}

enum OCRPageSelectionError: LocalizedError, Equatable {
    case emptySelection
    case invalidFormat
    case outOfBounds(pageCount: Int)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            L10n.string("ocr.pages.error.empty")
        case .invalidFormat:
            L10n.string("ocr.pages.error.invalid")
        case let .outOfBounds(pageCount):
            L10n.format("ocr.pages.error.out_of_bounds", pageCount)
        }
    }
}

enum OCRPageSelection {
    // [학습 04] 화면에서 입력한 문자열을 문서 연산에 쓸 값으로 바꾸는 작은 파서(parser)입니다.
    // PDFKit 객체나 화면 없이도 검사할 수 있어 알고리즘(algorithm)과 테스트의 첫 예제로 좋습니다.
    /// Parse one-based page numbers as shown in the PDF viewer. Nil means the
    /// complete document; other results are sorted, unique zero-based indexes.
    static func resolve(
        scope: OCRPageScope,
        input: String,
        currentPageIndex: Int,
        pageCount: Int
    ) throws -> [Int]? {
        // [학습 06] 빈 문서 검사를 switch보다 먼저 합니다. 따라서 .all도 0쪽 문서에서는
        // 성공하지 않습니다. OCRPageSelectionTests는 이런 경계값(boundary value)을 명시적으로 검사합니다.
        guard pageCount > 0 else { throw OCRPageSelectionError.emptySelection }
        switch scope {
        case .all:
            // [학습 04] 여기서 nil은 실패가 아니라 "전체 페이지"를 뜻합니다.
            // 잘못된 입력은 throw로 오류를 던져 표현하므로 두 의미를 구분해야 합니다.
            return nil
        case .current:
            guard currentPageIndex >= 0, currentPageIndex < pageCount else {
                throw OCRPageSelectionError.outOfBounds(pageCount: pageCount)
            }
            return [currentPageIndex]
        case .custom:
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw OCRPageSelectionError.emptySelection }
            let normalized = trimmed
                .replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "—", with: "-")
                .replacingOccurrences(of: "~", with: "-")
                .replacingOccurrences(of: "，", with: ",")
            // [학습 04] 집합(set)인 Set은 "2, 2-3"의 중복을 없앱니다. 마지막의 sorted()는 사용자가
            // 입력한 순서와 무관하게 [1, 2]라는 일정한 결과를 만듭니다.
            var indexes = Set<Int>()
            for component in normalized.split(separator: ",", omittingEmptySubsequences: false) {
                // 빈 조각을 버리지 않아야 "1,,2"와 "2-"를 잘못된 입력으로 잡을 수 있다.
                let endpoints = component.split(separator: "-", omittingEmptySubsequences: false)
                guard endpoints.count == 1 || endpoints.count == 2 else {
                    throw OCRPageSelectionError.invalidFormat
                }
                let numbers = try endpoints.map { endpoint -> Int in
                    let token = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty, token.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                          let number = Int(token) else {
                        throw OCRPageSelectionError.invalidFormat
                    }
                    guard number >= 1, number <= pageCount else {
                        throw OCRPageSelectionError.outOfBounds(pageCount: pageCount)
                    }
                    return number
                }
                let first = numbers[0]
                let last = numbers.last!
                guard first <= last else { throw OCRPageSelectionError.invalidFormat }
                // Validate both bounds before expanding. A huge input cannot
                // overflow or allocate more indexes than the document has.
                // [학습 04] 사용자에게 보이는 1쪽은 배열의 인덱스(index) 0입니다. 번호 체계 변환은
                // 이곳에서 한 번 수행하고, 이후 문서 연산에서는 0부터 시작하는 인덱스를 씁니다.
                for number in first...last { indexes.insert(number - 1) }
            }
            return indexes.sorted()
        }
    }

    /// Turns original zero-based positions into a short, editable one-based list.
    static func compactDescription(_ indexes: [Int]) -> String {
        // [학습 06] Int.max를 제외해 아래의 +1 연산에서 오버플로(overflow)가 발생하지 않도록 합니다.
        // 출력 문자열을 resolve로 다시 읽어 같은 인덱스를 얻는 왕복 검사(round-trip test)로 두 함수의 호환성을 확인합니다.
        let sorted = Array(Set(indexes.filter { $0 >= 0 && $0 < Int.max })).sorted()
        guard var start = sorted.first else { return "" }
        var end = start
        var ranges: [String] = []
        func appendRange() {
            ranges.append(start == end ? "\(start + 1)" : "\(start + 1)-\(end + 1)")
        }
        for index in sorted.dropFirst() {
            // [학습 04] 정렬된 입력에서 연속 구간의 시작과 끝만 기억하며 순회(iteration)합니다.
            // 다음 번호가 연속되지 않으면 이전 구간을 출력하고 새 구간을 시작합니다.
            if index == end + 1 {
                end = index
            } else {
                appendRange()
                start = index
                end = index
            }
        }
        appendRange()
        return ranges.joined(separator: ", ")
    }
}
