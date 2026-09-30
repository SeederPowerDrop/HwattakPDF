// SPDX-License-Identifier: MPL-2.0
// Swift 첫걸음: 화면 대신 글자로 페이지 이동 결과를 확인합니다.
// 이 파일은 실제 앱이나 PDF 파일을 열거나 변경하지 않습니다.

// 배열(array)은 여러 값을 순서대로 모읍니다. let은 재대입하지 않는 이름입니다.
let pageTitles = ["1페이지", "2페이지", "3페이지", "4페이지", "5페이지"]
let pageCount = pageTitles.count

// 변수(variable)는 달라질 수 있는 값을 저장합니다.
// 인덱스(index)는 0부터 시작하므로, 0은 첫 페이지를 가리킵니다.
var currentPageIndex = 0

// 함수(function)는 이름을 붙인 작업입니다. 입력을 받아 결과를 반환합니다.
func displayPageNumber(for index: Int) -> Int {
    return index + 1
}

// 이 함수는 사람이 읽는 페이지 번호를 입력받습니다.
func moveToPage(_ pageNumber: Int) {
    // if는 조건을 검사합니다. ||는 두 조건 중 하나라도 참이면 참입니다.
    if pageNumber < 1 || pageNumber > pageCount {
        print("이동 거절: \(pageNumber)페이지는 없습니다.")
        // 조기 반환(early return): 이 함수의 나머지 작업을 건너뜁니다.
        return
    }

    // 대입(assignment): 오른쪽의 계산 결과를 왼쪽 변수에 저장합니다.
    currentPageIndex = pageNumber - 1
    print("이동 후: \(pageTitles[currentPageIndex])")
}

print("전체: \(pageCount)페이지")
print("시작: \(displayPageNumber(for: currentPageIndex))페이지")
moveToPage(2)
moveToPage(6)
print("마지막 위치: \(displayPageNumber(for: currentPageIndex))페이지")
