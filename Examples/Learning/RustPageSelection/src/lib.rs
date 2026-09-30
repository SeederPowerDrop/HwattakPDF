// SPDX-License-Identifier: MPL-2.0

//! HwattakPDF의 광학 문자 인식(optical character recognition, OCR) 페이지 선택을 본뜬 독립 학습 예제입니다.
//! 실제 Swift 앱이 이 코드를 호출하거나 PDF를 수정하지는 않습니다.

use std::collections::BTreeSet;
use std::fmt;

/// 열거형(enum)은 코드에서 선택할 수 있는 값을 선언된 선택지로 제한합니다.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PageScope {
    All,
    Current,
    Custom,
}

/// 함께 전달하는 문서 정보를 구조체(struct)에 묶습니다.
/// Swift의 Int처럼 음수 입력도 검증하기 위해 여기서는 isize를 사용합니다.
#[derive(Debug, Clone, Copy)]
pub struct PageContext {
    pub current_page_index: isize,
    pub page_count: isize,
}

/// 오류도 문자열 대신 데이터로 표현하면 테스트에서 정확히 비교할 수 있습니다.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SelectionError {
    EmptySelection,
    InvalidFormat,
    OutOfBounds { page_count: isize },
}

// Display는 println!("{error}")에서 보여 줄 문장을 정하는 표준 트레이트(trait)입니다.
impl fmt::Display for SelectionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptySelection => write!(formatter, "선택할 페이지가 없습니다."),
            Self::InvalidFormat => write!(formatter, "페이지 입력 형식이 올바르지 않습니다."),
            Self::OutOfBounds { page_count } => {
                write!(formatter, "페이지는 1~{page_count} 범위여야 합니다.")
            }
        }
    }
}

impl std::error::Error for SelectionError {}

/// 직접 입력한 페이지 번호는 1부터 시작하므로, 0부터 시작하는 인덱스(index)로 바꿉니다.
/// 성공한 결과가 None이면 전체 문서, Some이면 정렬되고 중복이 없는 페이지 인덱스 목록입니다.
///
/// ```
/// use hwattak_page_selection_lesson::{resolve, PageContext, PageScope};
/// let context = PageContext { current_page_index: 0, page_count: 12 };
/// assert_eq!(resolve(PageScope::Custom, "1, 3-5, 4", context),
///            Ok(Some(vec![0, 2, 3, 4])));
/// ```
pub fn resolve(
    scope: PageScope,
    input: &str,
    context: PageContext,
) -> Result<Option<Vec<usize>>, SelectionError> {
    if context.page_count <= 0 {
        return Err(SelectionError::EmptySelection);
    }

    // match를 이용한 패턴 매칭(pattern matching)에서는 모든 선택지를 처리해야 하므로 누락을 찾기 쉽습니다.
    match scope {
        PageScope::All => Ok(None),
        PageScope::Current => {
            if context.current_page_index < 0 || context.current_page_index >= context.page_count {
                return Err(SelectionError::OutOfBounds {
                    page_count: context.page_count,
                });
            }
            // 음수가 아니라는 검사를 마친 뒤 인덱스에 사용할 부호 없는 정수(unsigned integer) 타입 usize로 변환합니다.
            Ok(Some(vec![context.current_page_index as usize]))
        }
        PageScope::Custom => {
            let trimmed = input.trim();
            if trimmed.is_empty() {
                return Err(SelectionError::EmptySelection);
            }

            // input은 차용(borrowing)하여 읽고, 바꾼 내용은 String 타입의 새 변수 normalized가 소유합니다.
            let normalized = trimmed.replace(['–', '—', '~'], "-").replace('，', ",");
            let mut indexes = BTreeSet::new();

            // split은 끝의 빈 항목도 남기므로 "1,"처럼 끝에 쉼표가 있는 입력을 오류로 처리할 수 있습니다.
            for component in normalized.split(',') {
                let endpoints: Vec<&str> = component.split('-').collect();
                if endpoints.len() != 1 && endpoints.len() != 2 {
                    return Err(SelectionError::InvalidFormat);
                }
                // ?는 Ok의 숫자를 꺼내고, Err라면 현재 함수를 즉시 끝내며 호출한 쪽에 오류를 전달합니다.
                let first = parse_page(endpoints[0], context.page_count)?;
                let last = if endpoints.len() == 2 {
                    parse_page(endpoints[1], context.page_count)?
                } else {
                    first
                };
                if first > last {
                    return Err(SelectionError::InvalidFormat);
                }

                // 범위의 양 끝값이 문서 안에 있는지 먼저 확인한 다음에 범위를 펼칩니다.
                // first >= 1이므로 1을 빼도 음수가 되지 않고, last <= page_count이므로 문서 범위를 벗어나지 않습니다.
                for page in first..=last {
                    indexes.insert((page - 1) as usize);
                }
            }

            // BTreeSet의 소유권(ownership)을 가져와 Vec를 만듭니다. 정렬과 중복 제거는 이미 끝난 상태입니다.
            Ok(Some(indexes.into_iter().collect()))
        }
    }
}

fn parse_page(token: &str, page_count: isize) -> Result<isize, SelectionError> {
    let token = token.trim();
    // ASCII 문자 코드의 숫자 0~9만 허용합니다.
    if token.is_empty() || !token.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(SelectionError::InvalidFormat);
    }
    // 표현 가능한 정수의 최댓값을 넘는 입력도 패닉(panic) 없이 형식 오류로 반환합니다.
    let number = token
        .parse::<isize>()
        .map_err(|_| SelectionError::InvalidFormat)?;
    if number < 1 || number > page_count {
        return Err(SelectionError::OutOfBounds { page_count });
    }
    Ok(number)
}

/// 인덱스 목록을 사용자가 읽고 수정할 수 있는 짧은 페이지 범위 문자열로 바꿉니다.
/// &[usize]는 목록을 읽기 위해 빌리는 슬라이스(slice) 참조(reference)입니다. 원본 Vec는 그대로 남습니다.
pub fn compact_description(indexes: &[usize]) -> String {
    // 1을 더해도 정수 범위를 넘지 않고 Swift Int의 표현 범위에도 맞도록 인덱스의 상한을 제한합니다.
    let sorted: BTreeSet<usize> = indexes
        .iter()
        .copied()
        .filter(|&index| index < isize::MAX as usize)
        .collect();
    let mut iterator = sorted.into_iter();
    let Some(mut start) = iterator.next() else {
        return String::new();
    };
    let mut end = start;
    let mut ranges = Vec::new();

    for index in iterator {
        if index == end + 1 {
            end = index;
        } else {
            ranges.push(format_range(start, end));
            start = index;
            end = index;
        }
    }
    ranges.push(format_range(start, end));
    ranges.join(", ")
}

fn format_range(start: usize, end: usize) -> String {
    if start == end {
        format!("{}", start + 1)
    } else {
        format!("{}-{}", start + 1, end + 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> PageContext {
        PageContext {
            current_page_index: 0,
            page_count: 12,
        }
    }

    #[test]
    fn all_means_the_complete_document() {
        assert_eq!(resolve(PageScope::All, "ignored", context()), Ok(None));
    }

    #[test]
    fn current_keeps_the_original_zero_based_index() {
        let context = PageContext {
            current_page_index: 7,
            page_count: 12,
        };
        assert_eq!(
            resolve(PageScope::Current, "ignored", context),
            Ok(Some(vec![7]))
        );
    }

    #[test]
    fn current_rejects_negative_and_past_the_end() {
        for current_page_index in [-1, 12] {
            let context = PageContext {
                current_page_index,
                page_count: 12,
            };
            assert_eq!(
                resolve(PageScope::Current, "", context),
                Err(SelectionError::OutOfBounds { page_count: 12 })
            );
        }
    }

    #[test]
    fn empty_document_is_rejected_even_for_all() {
        for page_count in [0, -1] {
            let context = PageContext {
                current_page_index: 0,
                page_count,
            };
            assert_eq!(
                resolve(PageScope::All, "", context),
                Err(SelectionError::EmptySelection)
            );
        }
    }

    #[test]
    fn normalizes_whitespace_range_marks_and_duplicates() {
        let actual = resolve(
            PageScope::Custom,
            " 8, 3-5, 1, 4, 3–4, 8—9, 10 ~ 11，2 ",
            context(),
        );
        assert_eq!(actual, Ok(Some(vec![0, 1, 2, 3, 4, 7, 8, 9, 10])));
    }

    #[test]
    fn repeated_single_page_range_is_only_one_page() {
        assert_eq!(
            resolve(PageScope::Custom, "2-2, 2", context()),
            Ok(Some(vec![1]))
        );
    }

    #[test]
    fn empty_custom_input_is_an_error() {
        for input in ["", " \n "] {
            assert_eq!(
                resolve(PageScope::Custom, input, context()),
                Err(SelectionError::EmptySelection)
            );
        }
    }

    #[test]
    fn malformed_and_reversed_input_is_rejected() {
        for input in [
            ",", "1,", ",1", "1,,2", "-2", "2-", "1-2-3", "3-1", "one", "1 2", "1.5", "+1", "１",
        ] {
            assert_eq!(
                resolve(PageScope::Custom, input, context()),
                Err(SelectionError::InvalidFormat),
                "{input}"
            );
        }
    }

    #[test]
    fn bounds_are_checked_before_expanding_ranges() {
        for input in ["0", "13", "1-13"] {
            assert_eq!(
                resolve(PageScope::Custom, input, context()),
                Err(SelectionError::OutOfBounds { page_count: 12 })
            );
        }
        let huge_range = format!("1-{}", isize::MAX);
        assert_eq!(
            resolve(PageScope::Custom, &huge_range, context()),
            Err(SelectionError::OutOfBounds { page_count: 12 })
        );
    }

    #[test]
    fn integer_overflow_becomes_a_format_error() {
        let input = "999999999999999999999999999999999999999";
        assert_eq!(
            resolve(PageScope::Custom, input, context()),
            Err(SelectionError::InvalidFormat)
        );
    }

    #[test]
    fn description_is_canonical_and_round_trips() {
        let indexes = vec![10, 2, 3, 4, 0, 7, 8, 8];
        let description = compact_description(&indexes);
        assert_eq!(description, "1, 3-5, 8-9, 11");
        assert_eq!(
            resolve(PageScope::Custom, &description, context()),
            Ok(Some(vec![0, 2, 3, 4, 7, 8, 10]))
        );
        // 소유권을 넘기지 않고 빌려주기만 했으므로 indexes를 이 시점에도 읽을 수 있습니다.
        assert_eq!(indexes.len(), 8);
    }

    #[test]
    fn description_handles_empty_and_unrepresentable_indexes() {
        assert_eq!(compact_description(&[]), "");
        assert_eq!(compact_description(&[usize::MAX, isize::MAX as usize]), "");
        assert_eq!(compact_description(&[0, usize::MAX]), "1");
    }
}
