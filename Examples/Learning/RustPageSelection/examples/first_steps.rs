// SPDX-License-Identifier: MPL-2.0

// 페이지 번호가 문서 안에 있는지 검사합니다.
// 마지막 식에 세미콜론이 없으므로 검사 결과를 돌려줍니다.
fn is_page_available(page: i32, page_count: i32) -> bool {
    page >= 1 && page <= page_count
}

fn main() {
    let page_count = 5;
    let mut current_page = 1;

    println!("문서: {page_count}쪽");
    println!("현재: {current_page}쪽");

    let next_page = current_page + 1;
    if is_page_available(next_page, page_count) {
        current_page = next_page;
        println!("이동: {current_page}쪽");
    }

    let requested_page = 6;
    if is_page_available(requested_page, page_count) {
        println!("열 수 있음: {requested_page}쪽");
    } else {
        println!("거절: {requested_page}쪽은 1~{page_count}쪽 범위를 벗어납니다.");
    }
}
