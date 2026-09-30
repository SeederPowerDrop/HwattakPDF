// SPDX-License-Identifier: MPL-2.0

use hwattak_page_selection_lesson::{compact_description, resolve, PageContext, PageScope};
use std::process::ExitCode;

fn main() -> ExitCode {
    // 명령행(command line) 입력이 없으면 교재의 예제를 사용합니다. input이 문자열의 소유권(ownership)을 가집니다.
    let input = std::env::args()
        .nth(1)
        .unwrap_or_else(|| String::from("1, 3-5, 4, 8"));
    let context = PageContext {
        current_page_index: 0,
        page_count: 12,
    };

    // &input으로 원본을 차용(borrowing)합니다. 소유권을 유지하면서 함수가 문자열을 읽게 합니다.
    match resolve(PageScope::Custom, &input, context) {
        Ok(Some(indexes)) => {
            println!("입력: {input}");
            println!("0부터 시작하는 인덱스: {indexes:?}");
            println!("다시 표시한 페이지: {}", compact_description(&indexes));
            ExitCode::SUCCESS
        }
        Ok(None) => {
            println!("전체 문서가 선택되었습니다.");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("입력 오류: {error}");
            ExitCode::FAILURE
        }
    }
}
