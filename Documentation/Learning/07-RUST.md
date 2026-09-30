<!-- SPDX-License-Identifier: MPL-2.0 -->

# 7장 같은 문제를 Rust로 풀기

현재 HwattakPDF 앱의 구현 언어는 **Swift**입니다. 이 장에서는 앱 안의 작은 규칙을 Rust로 다시 표현하며 두 언어를 비교합니다. 추가한 [Rust 실습 폴더](../../Examples/Learning/RustPageSelection/README.md)는 앱과 분리되어 있습니다. 이 예제를 실행해도 앱이나 PDF 파일이 바뀌지 않습니다.

이번 장에서는 Rust의 소유권(ownership)·차용(borrowing)·오류 반환까지 차근차근 배웁니다. 처음에는 **7.0의 작은 프로그램을 실행하고 한 줄 바꿔 보는 것**만 목표로 잡아도 충분합니다. 변수와 함수라는 말부터 낯설다면 [0장: 코드를 처음 읽는 사람을 위한 준비](00-FIRST-STEPS.md)를 먼저 읽어 보세요.

첫 번째 학습에서는 **7.0 → 7.1 → 7.2 → 7.4 → 7.5** 순서로 읽으세요. 7.4의 구조체부터 어려워지면 일단 다음 학습으로 미뤄도 됩니다. 두 번째 학습에서 7.6 이후를 읽으며 `1, 3-5, 4`가 `[0, 2, 3, 4]`로 바뀌는 과정을 따라갑니다. 7.10의 `Send`·`Sync`와 언어 연결 부분은 심화 내용이므로 건너뛰어도 앞의 예제를 실행하는 데 지장이 없습니다.

## 7.0 작은 프로그램으로 몸풀기

먼저 “5쪽짜리 문서에서 다음 쪽으로 이동하기”만 다뤄 보겠습니다. 입력(input)은 코드에 적힌 페이지 수와 번호이고, 출력(output)은 터미널에 나타나는 문장입니다. 키보드 입력을 기다리거나 실제 PDF를 열지는 않습니다.

터미널(terminal)은 글자로 명령을 입력하고 결과를 확인하는 창입니다. HwattakPDF 프로젝트의 최상위 폴더에서 아래 명령을 실행하세요. Cargo는 Rust 코드를 실행 가능한 프로그램으로 만드는 빌드(build)와 실행을 관리하는 도구입니다. 설치가 안 되어 있다면 7.2의 설치 안내를 먼저 확인하세요.

세 줄을 한꺼번에 복사해 실행하세요. 줄 끝의 `\`는 명령이 다음 줄로 이어진다는 뜻입니다.

```sh
cargo run --offline \
  --manifest-path Examples/Learning/RustPageSelection/Cargo.toml \
  --example first_steps
```

`--manifest-path` 뒤에는 프로젝트 설정 파일을 적습니다. `--example first_steps`는 [examples/first_steps.rs](../../Examples/Learning/RustPageSelection/examples/first_steps.rs)를 실행하라는 뜻입니다. `--offline`은 실행을 준비할 때 네트워크를 사용하지 않게 합니다. Cargo의 빌드 안내 아래에 다음 네 줄이 나오면 성공입니다.

```text
문서: 5쪽
현재: 1쪽
이동: 2쪽
거절: 6쪽은 1~5쪽 범위를 벗어납니다.
```

실행한 파일에서 설명 주석을 제외한 코드는 다음과 같습니다. **실행은 `fn main()`의 안쪽부터 시작**합니다. 위에 적힌 `is_page_available` 함수는 이름을 불렀을 때 실행됩니다.

```rust
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
```

### 실행 순서대로 한 줄씩 읽기

| 코드 | 쉬운 설명 |
| --- | --- |
| `let page_count = 5;` | `page_count`라는 이름에 숫자 5를 연결합니다. `let`만으로 만든 변수(variable)에는 나중에 새 값을 넣을 수 없습니다. |
| `let mut current_page = 1;` | 현재 쪽은 1쪽입니다. `mut`가 있으므로 나중에 이 변수의 값을 바꿀 수 있습니다. |
| `println!("문서: {page_count}쪽");` | 따옴표 안의 글을 한 줄 출력합니다. `{page_count}` 자리에는 실제 값 5가 들어갑니다. |
| `println!("현재: {current_page}쪽");` | 같은 방법으로 현재 값 1을 출력합니다. |
| `let next_page = current_page + 1;` | 1에 1을 더한 결과 2를 `next_page`에 넣습니다. 아직 `current_page`는 1입니다. |
| `if is_page_available(next_page, page_count)` | 검사 함수(function)에 2와 5를 전달합니다. 결과가 참(`true`)이면 뒤의 중괄호 안을 실행합니다. |
| `current_page = next_page;` | 현재 쪽을 2로 바꿉니다. 여기의 `=`는 두 값이 같은지 비교하는 기호가 아니라 새 값을 넣는 대입(assignment) 기호입니다. |
| `println!("이동: {current_page}쪽");` | 바뀐 현재 값 2를 출력합니다. |
| `let requested_page = 6;` | 이번에는 6쪽을 요청한다고 정합니다. |
| `if is_page_available(requested_page, page_count)` | 6과 5를 전달해 검사합니다. 결과는 거짓(`false`)이므로 `else` 뒤의 중괄호 안으로 갑니다. |
| `println!("거절: ...");` | 파일에 적힌 전체 거절 문장을 출력합니다. 현재 쪽은 여전히 2입니다. |

함수의 `page: i32`와 `page_count: i32`는 입력값 두 개가 정수(integer)라는 뜻입니다. `i32`는 음수와 양수를 표현할 수 있는 32비트 정수 타입(type)입니다. `-> bool`은 참 또는 거짓 중 하나인 불리언(boolean) 값을 돌려준다는 뜻입니다. 함수가 돌려주는 값을 반환값(return value)이라고 합니다.

검사식 `page >= 1 && page <= page_count`는 “페이지가 1 이상이고, 전체 페이지 수 이하인가?”라는 질문입니다. `&&`는 양쪽 조건을 모두 만족해야 한다는 뜻입니다. 2와 5를 넣으면 참이고, 6과 5를 넣으면 거짓입니다.

`if ... else`처럼 조건에 따라 실행할 코드를 나누는 문법을 조건문(conditional statement)이라고 합니다. 이 예제에서는 검사 결과에 따라 허용 문장과 거절 문장 중 하나만 출력합니다.

중괄호 `{ ... }`는 함께 실행할 코드의 범위를 묶습니다. 세미콜론 `;`은 보통 문장 끝에 붙이지만, **함수 끝의 값을 돌려주는 식에는 붙이지 않습니다.** 검사식은 값을 만드는 표현식(expression)이며, 함수의 마지막 표현식이므로 그 결과를 돌려줍니다. 대신 `return page >= 1 && page <= page_count;`라고 적어도 여기서는 결과가 같습니다. `return`은 “이 값을 돌려주고 지금 함수를 끝내라”는 명시적인 지시입니다.

### 숫자 하나 바꾸고 예상하기

1. `let requested_page = 6;`에서 6만 5로 바꾼 뒤 같은 명령을 다시 실행해 보세요. 마지막 줄은 어떻게 달라질까요?
2. 그다음 5를 0으로 바꿔 보세요. 0은 전체 페이지 수보다 작은데도 왜 거절될까요?

정답: 첫 번째는 `열 수 있음: 5쪽`입니다. 두 번째는 `거절: 0쪽은 1~5쪽 범위를 벗어납니다.`입니다. 페이지 번호는 1 이상이어야 한다는 조건도 함께 검사하기 때문입니다. 두 경우 모두 앞의 세 줄은 그대로입니다. 실습을 마치면 요청 번호를 원래의 6으로 되돌려 놓으세요.

## 7.1 이미 알고 있는 문제에서 시작하기

광학 문자 인식(optical character recognition, OCR)을 실행할 때 사용자가 3~5쪽만 처리하려고 입력창에 `3-5`를 입력했다고 생각해 봅시다. 컴퓨터가 이 문자열만 보고 처리할 페이지를 알아내는 것은 아닙니다. 프로그램이 입력을 읽고, 잘못된 입력을 거절하고, 각 페이지의 위치를 계산해야 합니다. 이렇게 텍스트를 정해진 규칙에 따라 해석하는 코드를 **파서**(parser)라고 합니다.

원본은 [OCRPageSelection.swift](../../Sources/HwattakPDF/Models/OCRPageSelection.swift)의 `resolve`와 `compactDescription`입니다. 검증 사례는 [OCRPageSelectionTests.swift](../../Tests/HwattakPDFTests/OCRPageSelectionTests.swift)에 있습니다.

| 사용자가 입력하거나 선택한 것 | 내부 표현 | 이유 |
| --- | --- | --- |
| 전체 문서 | Swift `nil`, Rust `None` | 모든 번호를 미리 나열하지 않고 전체라는 뜻을 전달 |
| 현재 화면의 3쪽 | `[2]` | 사람이 보는 번호는 1부터, 내부 위치는 0부터 시작 |
| `1, 3-5, 4` | `[0, 2, 3, 4]` | 범위를 펼치고 겹치는 4쪽은 한 번만 처리 |
| `5-3` | 형식 오류 | 이 앱은 거꾸로 된 범위를 허용하지 않음 |
| 12쪽 문서에서 `13` | 범위 오류 | 실제로 없는 페이지를 요청함 |
| 빈 입력 | 빈 선택 오류 | “아무것도 선택하지 않음”과 “전체 선택”을 구별 |

이 표는 언어를 선택하기 전에 정해야 하는 **입력과 출력의 계약**(contract)입니다. 어떤 입력을 허용하고 어떤 결과를 돌려줄지 정해야 코드를 구현하고 테스트를 작성할 수 있습니다.

## 7.2 먼저 실행해 보기

터미널(terminal)에서 현재 작업 폴더를 HwattakPDF 프로젝트의 최상위 폴더로 이동한 뒤 아래 명령을 실행합니다. Cargo는 Rust 프로젝트의 빌드(build), 실행, 테스트를 관리하는 도구입니다. 빌드는 소스 코드를 실행 가능한 프로그램 등으로 만드는 과정입니다. 명령을 찾을 수 없다는 오류가 나오면 Rust 도구가 설치되어 있고 명령을 실행할 수 있는 경로에 등록되어 있는지 확인하세요. 설치가 필요하면 [공식 Rust 설치 안내](https://www.rust-lang.org/tools/install)를 참고하세요.

```sh
cargo test --offline --manifest-path Examples/Learning/RustPageSelection/Cargo.toml
cargo run --offline --manifest-path Examples/Learning/RustPageSelection/Cargo.toml
```

`--manifest-path`는 어느 프로젝트를 실행할지 지정합니다. `--offline`은 Cargo가 네트워크를 쓰지 않게 합니다. Rust 도구와 표준 라이브러리(standard library)가 설치된 환경이라면 이 예제는 추가 패키지(package) 없이 실행됩니다. 실행 명령과 옵션의 기준은 [Cargo run 공식 문서](https://doc.rust-lang.org/cargo/commands/cargo-run.html)입니다.

```text
입력: 1, 3-5, 4, 8
0부터 시작하는 인덱스: [0, 2, 3, 4, 7]
다시 표시한 페이지: 1, 3-5, 8
```

출력 위의 `Compiling`, `Finished`, `Running`은 Cargo의 안내입니다. 숫자 `4`가 입력에 두 번 포함되어도 결과에는 인덱스(index) `3`이 한 번만 있습니다. 인덱스는 목록에서 각 항목의 위치를 나타내는 번호입니다. 마지막 줄은 사람이 다시 수정하기 편하도록 연속된 페이지를 묶은 결과입니다.

직접 값을 바꾸어 보세요. 문서의 페이지 수는 `main.rs`에서 12쪽으로 정했습니다.

```sh
cargo run --offline --manifest-path Examples/Learning/RustPageSelection/Cargo.toml -- '2, 4–6, 5'
```

예상 인덱스는 `[1, 3, 4, 5]`, 다시 표시한 페이지는 `2, 4-6`입니다. `--` 뒤의 값은 실행할 프로그램에 전달하는 인자(argument)입니다. 따옴표는 공백까지 하나의 입력에 포함시키기 위해 필요합니다.

## 7.3 프로젝트의 파일 살펴보기

| 파일 | 처음 읽을 부분 | 배울 개념 |
| --- | --- | --- |
| [examples/first_steps.rs](../../Examples/Learning/RustPageSelection/examples/first_steps.rs) | `fn main()`, `is_page_available` | 변수, 조건문, 함수의 첫 연습 |
| [Cargo.toml](../../Examples/Learning/RustPageSelection/Cargo.toml) | `[package]`, `[dependencies]` | 프로젝트 설정과 외부 의존성(dependency) |
| [src/main.rs](../../Examples/Learning/RustPageSelection/src/main.rs) | `fn main()` | 프로그램 시작, 입력·출력, 종료 코드(exit code) |
| [src/lib.rs](../../Examples/Learning/RustPageSelection/src/lib.rs) | `resolve`, `parse_page` | 재사용 가능한 규칙 |
| [Cargo.lock](../../Examples/Learning/RustPageSelection/Cargo.lock) | `[[package]]` | 도구가 기록한 패키지 구성 |

`lib.rs`의 코드는 화면이나 터미널을 몰라도 계산할 수 있게 만들었습니다. `main.rs`는 입력을 가져와 계산 결과를 보여 줍니다. 앱에서도 화면과 계산 규칙을 나누면 작은 규칙을 따로 테스트하기 쉬워집니다.

`edition = "2021"`은 이 패키지에 적용할 Rust 언어의 에디션(edition)을 지정합니다. 에디션은 함께 적용할 언어 규칙의 묶음입니다. 이 숫자가 “2021년 버전의 컴파일러(compiler)만 사용한다”는 뜻은 아닙니다. 실습은 설치된 Rust 1.94.0에서 검증했습니다.

## 7.4 Rust 문장의 기본 재료

다음은 실습에서 사용한 문법을 작게 줄인 예입니다.

```rust
let page_count = 12;       // 이름을 붙입니다. 기본적으로 바꿀 수 없습니다.
let mut completed = 0;    // mut가 있으면 이 변수에 새 값을 넣을 수 있습니다.
completed += 1;
let indexes = vec![0, 2]; // 크기가 달라질 수 있는 목록 Vec를 만듭니다.
println!("{completed}/{page_count}: {indexes:?}");
```

`let`은 이름과 값을 연결하는 변수 바인딩(variable binding)을 선언하고, `mut`는 그 변수의 값을 바꿀 수 있음을 표시합니다. 타입(type), 즉 값의 자료형을 명시하지 않아도 컴파일러가 문맥에서 알아내는 것을 타입 추론(type inference)이라고 합니다. `vec!`와 `println!`의 느낌표는 매크로(macro)를 호출한다는 표시입니다. `{:?}`는 개발 중 값을 확인하기 위한 `Debug` 형식으로 출력합니다.

Rust의 함수(function)는 `fn 이름(입력: 타입) -> 결과타입` 형태로 선언합니다. `pub`는 공개 범위를 지정하는 키워드(keyword)입니다. 상위 모듈도 공개되어 있다면 다른 모듈(module)이나 이 라이브러리를 사용하는 코드에서 해당 항목에 접근할 수 있습니다. 이렇게 외부 코드가 사용할 수 있도록 제공하는 기능을 API(application programming interface)라고 합니다. 마지막 표현식(expression)에 세미콜론이 없으면 그 값이 함수나 블록(block)의 결과가 됩니다. 그래서 아래의 `Ok(number)` 뒤에는 세미콜론이 없습니다.

```rust
// 실제 parse_page의 마지막 부분
Ok(number)
```

### struct는 묶음, enum은 선택지

`PageContext`는 “현재 위치”와 “총 페이지 수”를 함께 담는 구조체(struct)입니다. `PageScope`는 전체·현재·직접 입력 중 하나를 나타내는 열거형(enum)입니다.

```rust
pub struct PageContext {
    pub current_page_index: isize,
    pub page_count: isize,
}

pub enum PageScope {
    All,
    Current,
    Custom,
}
```

`PageContext { current_page_index: 0, page_count: 12 }`는 두 필드(field)를 가진 값 하나를 만듭니다. `PageScope::Custom`은 가능한 세 선택지 중 하나입니다. `isize`는 실행 환경의 포인터(pointer) 크기에 맞는 부호 있는 정수(signed integer) 타입이고, `usize`는 같은 크기의 부호 없는 정수(unsigned integer) 타입입니다. 입력은 Swift `Int`처럼 음수도 검사하기 위해 `isize`로 받고, 유효성이 확인된 결과 인덱스는 `usize`로 돌려줍니다. 타입 정의의 기본은 공식 [struct 설명](https://doc.rust-lang.org/book/ch05-01-defining-structs.html)과 [enum 설명](https://doc.rust-lang.org/book/ch06-01-defining-an-enum.html)을 참고하세요.

`#[derive(Debug, Clone, Copy, PartialEq, Eq)]`는 해당 기능의 구현을 컴파일러에 맡기는 문법입니다. 여기서는 개발용 출력, 복제·복사, 두 값이 같은지 비교하는 기능을 자동으로 구현합니다. `PageScope`와 `PageContext`는 단순한 값이라 `Copy`를 붙였습니다. 모든 자료형에 붙일 수 있는 것은 아닙니다. 특히 문자열 데이터를 저장하는 메모리 버퍼(memory buffer)를 소유하는 `String`은 `Copy`를 구현하지 않습니다.

이처럼 타입이 제공할 공통 기능을 정의하는 것을 Rust에서는 **트레이트**(trait)라고 합니다. `impl fmt::Display for SelectionError`는 “이 오류를 사용자에게 보여 줄 문자열로 표현하는 방법을 구현한다”는 뜻입니다. `Debug`가 개발용 출력이라면 `Display`는 이 예제에서 한국어 오류 문장을 제공하는 역할입니다. `impl` 안의 `&self`는 오류 값의 소유권을 가져오지 않고 읽을 수 있도록 빌리는 참조(reference)입니다.

## 7.5 String, &str, 소유권과 차용

Rust 코드를 처음 읽을 때 가장 중요한 질문은 “이 데이터를 누가 소유하며, 누가 잠깐 빌려 쓰는가?”입니다. 소유권은 데이터의 사용과 메모리 해제 책임을 정하는 규칙입니다. `String`은 문자열 버퍼를 소유합니다. 값을 다른 변수로 이동(move)하면 원래 변수로 그 값을 다시 사용할 수 없습니다. 아래 코드는 소유권 오류를 확인하도록 만든 학습 예제이므로 컴파일에 실패합니다.

```rust
let original = String::from("1, 3-5");
let moved = original;
println!("{original}"); // 오류: String의 소유권이 moved로 이동했습니다.
```

여기서 이동은 문자열 내용 전체를 새 메모리에 복사한다는 뜻이 아닙니다. 기존 문자열 데이터를 관리할 책임이 `moved`로 넘어갑니다. 그래서 `original`이라는 이름으로 다시 사용하는 것을 컴파일러가 막습니다.

같은 메모리를 두 번 해제하거나 이미 해제한 메모리를 사용하는 실수를 막기 위한 규칙입니다. 정수처럼 `Copy`인 값은 대입할 때 값이 복사되어 원래 변수도 쓸 수 있습니다. 별도 문자열 복사가 필요할 때는 `clone()`을 명시할 수 있지만, 단지 읽기만 하려는 곳에 매번 복사할 필요는 없습니다. 근거와 더 작은 예제는 [Rust Book 소유권 장](https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html)에 있습니다.

실제 `main.rs`는 `resolve(..., &input, ...)`으로 원본을 **차용**합니다. `input`은 계속 문자열을 소유하고, 함수는 그 안의 텍스트를 잠깐 읽습니다. 함수가 끝난 뒤에도 `println!("입력: {input}")`이 가능한 이유입니다.

| 표현 | 의미 | 이 실습에서의 역할 |
| --- | --- | --- |
| `String` | 문자열 데이터를 소유하는 값 | 명령행(command line)에서 가져온 `input`, 입력 형식을 통일한 `normalized` |
| `&str` | UTF-8 문자열의 일부 또는 전체를 읽는 문자열 슬라이스(string slice) 참조 | `resolve`의 입력, 잘라 낸 숫자 문자열 |
| `&input` | 원본을 읽을 수 있도록 빌림 | `String`에서 `&str`이 필요한 함수로 전달 |
| `&[usize]` | 숫자 목록의 일부 또는 전체를 읽는 슬라이스(slice) 참조 | `compact_description`의 입력 |
| `&mut T` | 값을 바꿀 수 있도록 독점적으로 빌리는 가변 참조(mutable reference) | `Display` 구현에서 출력 형식 지정자(formatter)에 글을 쓸 때 사용 |

같은 데이터를 참조할 때는 여러 공유 참조(shared reference)를 사용하거나 하나의 가변 참조를 사용할 수 있습니다. 가변 참조를 사용하는 동안 같은 데이터에 다른 참조로 접근할 수는 없습니다. 이런 의미에서 가변 참조를 독점 참조(exclusive reference)라고도 합니다. 컴파일러는 참조가 필요한 기간과 참조 대상이 유효한 기간을 검사합니다. 참조가 유효한 범위를 수명(lifetime)이라고 합니다. 자세한 규칙과 예제는 [차용 설명](https://doc.rust-lang.org/book/ch04-02-references-and-borrowing.html)에 있습니다.

입력 형식을 통일하는 과정을 정규화(normalization)라고 합니다. `trim()`과 `split()`은 원본 문자열 안의 구간을 참조할 수 있습니다. 그래서 `Vec<&str>`는 작은 문자열 여러 개를 각각 복사한 목록이 아니라, 원본을 가리키는 참조 목록입니다. `normalized`가 메모리에 존재하는 동안 안쪽 반복문이 그 구간을 사용합니다. 반면 `replace()`는 바뀐 내용을 담는 새로운 `String`을 만듭니다. 이 차이가 이 함수의 소유권 흐름입니다. [문자열 슬라이스 설명](https://doc.rust-lang.org/book/ch04-03-slices.html)

## 7.6 Option과 Result를 안쪽부터 읽기

`resolve`의 반환 타입은 길어 보입니다.

```rust
Result<Option<Vec<usize>>, SelectionError>
```

안쪽부터 읽으면 이해하기 쉽습니다. `usize`는 인덱스 하나를 나타냅니다. `Vec<usize>`는 `usize` 값을 담으며 길이를 바꿀 수 있는 목록인 벡터(vector)입니다. `Option`은 특정 목록이 있는지 없는지를, `Result`는 계산이 성공했는지 실패했는지를 나타냅니다. 꺾쇠괄호 안에 다른 타입을 넣어 사용하는 방식은 제네릭(generics) 문법입니다.

| 반환값 | 이번 프로그램에서의 의미 |
| --- | --- |
| `Ok(Some(vec![0, 2]))` | 성공, 1쪽과 3쪽 선택 |
| `Ok(None)` | 성공, 전체 문서 선택 |
| `Err(SelectionError::EmptySelection)` | 실패, 빈 문서이거나 직접 입력이 비어 있음 |
| `Err(SelectionError::InvalidFormat)` | 실패, 규칙에 맞지 않는 문자나 범위 |
| `Err(SelectionError::OutOfBounds { page_count: 12 })` | 실패, 문서 페이지 범위를 벗어남 |

`None` 자체가 오류라는 뜻은 아닙니다. **이 프로그램이** 전체 문서를 나타내는 값으로 정한 것입니다. 또 `Some(vec![])`는 빈 목록이 들어 있다는 뜻이므로 `None`과 다릅니다. 현재 `resolve`는 유효한 직접 입력에서 빈 목록을 반환하지 않도록 검사합니다.

Swift 원본에서는 `throws -> [Int]?`가 “오류를 던질 수 있고, 성공하면 배열 또는 `nil`을 반환한다”는 뜻입니다. Rust 예제는 성공한 값 또는 오류를 `Result`에 담아 반환합니다. `match`를 이용한 패턴 매칭(pattern matching)으로 값의 형태를 확인하고 `Ok`와 `Err`를 나눠 처리합니다. 관련 규칙은 [Rust Book의 Result 장](https://doc.rust-lang.org/book/ch09-02-recoverable-errors-with-result.html)에서 확인할 수 있습니다.

### ?는 오류를 숨기는 기호가 아닙니다

```rust
let first = parse_page(endpoints[0], context.page_count)?;
```

현재 함수와 호출한 함수가 같은 오류 타입을 사용하므로 다음 뜻입니다.

```rust
let first = match parse_page(endpoints[0], context.page_count) {
    Ok(number) => number,
    Err(error) => return Err(error),
};
```

성공하면 숫자를 꺼내 다음 줄을 실행하고, 실패하면 현재 함수를 끝내고 호출자(caller)에게 오류를 전달합니다. `main.rs`가 최종적으로 `Err(error)`를 받아 사용자에게 오류 메시지를 출력합니다. 일반적으로 `?`는 필요한 오류 타입 변환도 지원하지만 이 예제에서는 같은 `SelectionError`만 다룹니다.

## 7.7 resolve를 핵심 줄 단위로 따라가기

전체 코드는 [lib.rs](../../Examples/Learning/RustPageSelection/src/lib.rs)를 펼쳐 놓고 읽으세요. 아래 표의 코드는 실제 소스에서 발췌했습니다. 코드가 수정되어 줄 번호가 달라져도 함수 이름과 코드 표현을 기준으로 찾으면 됩니다.

| 코드 | 컴퓨터가 하는 일 | 왜 필요한가 |
| --- | --- | --- |
| `if context.page_count <= 0` | 문서가 비어 있는지 먼저 확인 | 전체 선택에도 유효한 문서가 필요 |
| `match scope` | 선택 모드에 따라 경로 분리 | 전체·현재·직접 입력의 의미가 다름 |
| `let trimmed = input.trim();` | 앞뒤 공백을 제외한 부분을 빌림 | 사용자가 공백을 넣어도 처리 |
| `.replace(['–', '—', '~'], "-")` | 다른 범위 기호를 하나로 통일 | 같은 뜻의 입력을 같은 규칙으로 해석 |
| `let mut indexes = BTreeSet::new();` | 정렬되는 중복 없는 집합 준비 | 같은 페이지를 두 번 처리하지 않음 |
| `normalized.split(',')` | 쉼표를 기준으로 항목 구분 | `1`과 `3-5`를 따로 읽음 |
| `component.split('-').collect()` | 각 항목을 하이픈 기준으로 나눠 목록 생성 | 단일 페이지인지 범위인지 확인 |
| `endpoints.len()` | 나눈 부분이 1개도 2개도 아니면 거절 | `1-2-3`처럼 애매한 문법 거절 |
| `parse_page(...)?` | 숫자와 문서 범위를 검사 | 잘못된 값을 반복문 전에 차단 |
| `if first > last` | 역순 범위 거절 | `5-3`의 처리 규칙을 명확히 유지 |
| `for page in first..=last` | 양 끝을 포함한 범위를 반복 | 3-5면 3, 4, 5를 처리 |
| `indexes.insert((page - 1) as usize);` | 번호를 위치로 바꿔 집합에 삽입 | 1쪽은 인덱스 0 |
| `indexes.into_iter().collect()` | 집합을 소비하며 목록으로 변환 | 결과 소유권을 호출자에게 전달 |

`BTreeSet`은 정렬된 순서로 순회할 수 있는 집합(set) 자료구조(data structure)입니다. Swift 원본의 `Set`과 마지막 `.sorted()` 역할을 이 예제에서는 이 자료구조로 표현했습니다. `HashSet`으로 단순히 바꾸면 같은 정렬 순서를 보장하지 않으므로 정렬 단계가 별도로 필요합니다. [BTreeSet 공식 문서](https://doc.rust-lang.org/std/collections/struct.BTreeSet.html)

예를 들어 `3-5,4`에서는 집합에 `2, 3, 4`를 넣고 다시 `3`을 넣습니다. 집합에 이미 `3`이 있으므로 같은 값을 다시 넣어도 원소가 늘어나지 않습니다. 최종 결과는 `[2, 3, 4]`입니다.

### 작은 보조 함수 parse_page

```rust
let number = token
    .parse::<isize>()
    .map_err(|_| SelectionError::InvalidFormat)?;
```

`parse::<isize>()`는 텍스트를 `isize` 타입의 숫자로 변환하는 코드입니다. `::<...>`는 어떤 타입으로 변환할지 명시하는 문법입니다. 너무 큰 정수라면 변환 자체가 실패합니다. `map_err`는 표준 라이브러리가 반환한 변환 오류를 이 예제의 `InvalidFormat` 오류로 바꿉니다. `|_| ...`는 이름 없이 작성하는 함수 형태인 클로저(closure)입니다. 여기서 `_`는 전달된 오류 값을 사용하지 않는다는 뜻입니다.

그 앞의 `token.bytes().all(|byte| byte.is_ascii_digit())`는 모든 바이트(byte)가 ASCII(American Standard Code for Information Interchange) 문자 코드의 숫자 `0`부터 `9`에 해당하는지 확인합니다. `+1`, `1.5`, 전각 숫자 `１`을 허용하지 않습니다. 빈 문자열에는 `all`만으로 충분하지 않아 `is_empty()`도 따로 검사합니다.

이후 `number < 1 || number > page_count`로 문서 범위를 확인합니다. “정수로 읽을 수 있음”과 “이 문서에서 쓸 수 있음”은 별개의 조건입니다. 페이지 수가 12일 때 `13`은 두 번째 조건에서 거절됩니다.

### 왜 범위를 펼치기 전에 검사할까요?

`1-9223372036854775807`을 먼저 목록으로 만들려고 하면 현실적으로 감당할 수 없습니다. 이 코드는 양 끝이 실제 문서 범위에 들어오는지 먼저 검사하므로 12쪽 문서에서 즉시 실패합니다. 다만 호출자가 지나치게 큰 `page_count`를 전달하는 경우까지 이 예제가 메모리 사용량을 제한하지는 않습니다. 실제 앱에 통합하려면 PDF에서 읽은 페이지 수를 사용하고 처리량 제한도 정해야 합니다.

## 7.8 다시 읽기 쉬운 문자열로 돌려놓기

`compact_description(&indexes)`는 `[0, 2, 3, 4, 7]`을 `1, 3-5, 8`로 만듭니다. 입력 목록을 빌리기만 하며 바꾸지 않습니다.

1. 집합으로 중복을 제거하고 정렬합니다.
2. 첫 숫자를 현재 구간의 시작과 끝으로 둡니다.
3. 다음 숫자가 끝보다 정확히 1 크면 같은 구간을 늘립니다.
4. 연속되지 않으면 지금까지의 구간을 문자열로 저장하고 새 구간을 시작합니다.
5. 마지막 구간도 저장한 뒤 쉼표로 연결합니다.

`let Some(mut start) = iterator.next() else { ... };`는 첫 값이 없으면 바로 빈 문자열을 반환하는 문법입니다. 여기서 `iterator`는 값을 하나씩 꺼내 순회하는 반복자(iterator)입니다. `.iter()`는 목록의 요소를 빌려 순회하고, `.copied()`는 여기서 작은 정수 값을 복사합니다. `.into_iter()`는 해당 집합의 소유권을 가져가 소비합니다. 이름이 비슷해도 소유권 측면의 의미는 다릅니다.

인덱스를 화면 번호로 바꾸려면 `+1`을 해야 하므로 표현 가능한 정수 상한도 생각해야 합니다. 예제는 Swift의 `Int` 범위와 맞추기 위해 `isize::MAX` 이상을 설명 문자열에서 제외합니다. 반환 인덱스가 `usize`라 음수 입력은 타입 단계에서 받을 수 없습니다. 이런 차이 때문에 이 코드는 모든 입력에서 원본과 똑같이 동작하는 이식본(port)이 아닙니다. 원본의 규칙을 배우기 위한 예제로 이해하세요.

## 7.9 테스트로 규칙을 고정하기

이 예제는 단위 테스트(unit test) 12개와 문서 테스트(documentation test) 1개를 제공합니다. `#[test]`가 붙은 함수가 테스트이고, `assert_eq!`는 실제 값과 기대 값이 같아야 한다고 선언합니다. `#[cfg(test)]`는 해당 모듈을 테스트 빌드에 포함시키는 조건입니다. 테스트 문법은 [Rust Book 테스트 장](https://doc.rust-lang.org/book/ch11-01-writing-tests.html), 실행 범위는 [Cargo test 문서](https://doc.rust-lang.org/cargo/commands/cargo-test.html)에 설명되어 있습니다.

```rust
#[test]
fn repeated_single_page_range_is_only_one_page() {
    assert_eq!(
        resolve(PageScope::Custom, "2-2, 2", context()),
        Ok(Some(vec![1]))
    );
}
```

이 테스트는 “2쪽을 반복해서 요청해도 2쪽 하나만 선택되어야 한다”는 동작 규칙을 기록합니다. 성능을 개선하기 위해 구현을 바꾸더라도 이 규칙은 유지되어야 합니다.

검사하는 것은 정상 입력뿐만이 아닙니다. 빈 입력, 입력 끝의 쉼표, 역순 범위, 음수 인덱스, 페이지 수가 0인 문서, 정수 변환 실패, 표현 가능한 범위를 벗어난 인덱스도 검사합니다. 또 인덱스를 문자열로 바꾼 뒤 다시 파싱(parsing)했을 때 같은 페이지 집합을 얻는지 확인하는 **왕복 검사**(round-trip test)가 있습니다.

2026-09-30의 작업 환경에서 `cargo 1.94.0`, `rustc 1.94.0`으로 실제 실행한 결과는 다음과 같습니다. 출력 순서와 걸린 시간은 환경에 따라 달라질 수 있습니다.

```text
running 12 tests
test result: ok. 12 passed; 0 failed; ...

Doc-tests hwattak_page_selection_lesson
running 1 test
test result: ok. 1 passed; 0 failed; ...
```

이 통과 결과는 독립 Rust 예제의 규칙을 확인한 것입니다. 원본 앱 전체의 OCR, 저장, 화면 동작을 Rust 테스트가 검증하는 것은 아닙니다.

## 7.10 Swift와 나란히 보기

| 관심사 | 현재 Swift 앱 | 이번 Rust 예제 |
| --- | --- | --- |
| 함수 | `static func resolve(...)` | `pub fn resolve(...)` |
| 바뀌지 않는 바인딩 | `let` | `let` |
| 바꿀 수 있는 바인딩 | `var` | `let mut` |
| 선택지 | `enum OCRPageScope` | `enum PageScope` |
| 선택적인 값 | `[Int]?`, `nil` | `Option<Vec<usize>>`, `None` |
| 실패 | `throws`, `throw`, `try` | `Result`, `Err`, `?` |
| 값에 따른 분기 | `switch` | `match` |
| 중복 제거·정렬 | `Set` 다음 `.sorted()` | `BTreeSet` |
| 주된 문자열 방식 | 값 의미론(value semantics)을 따르는 `String` | 소유하는 `String`, 빌리는 `&str` 구별 |
| 데이터의 메모리 관리 | 클래스 인스턴스(class instance)에 자동 참조 계수(automatic reference counting, ARC) 적용 | 기본 소유권·차용, 필요하면 `Rc`·`Arc` 같은 별도 타입 사용 |
| 테스트 | `XCTest`, `XCTAssertEqual` | `#[test]`, `assert_eq!` |

이 표는 읽기 위한 대응표입니다. 언어 기능이 모두 일대일로 같다는 뜻은 아닙니다. 특히 Swift의 `String` 대입을 Rust의 `String` 이동과 같은 동작으로 생각하면 소유권 오류를 이해하기 어렵습니다.

### Send·Sync와 @MainActor는 역할이 다릅니다

Rust의 `Send`는 값의 소유권을 다른 스레드(thread)로 안전하게 옮길 수 있음을, `Sync`는 공유 참조를 스레드 사이에서 안전하게 사용할 수 있음을 나타내는 트레이트입니다. 대부분의 일반 타입은 구성 요소에 따라 자동으로 이 성질을 갖습니다. 세부 규칙은 [Rust Book Send·Sync 장](https://doc.rust-lang.org/book/ch16-04-extensible-concurrency-sync-and-send.html)에 있습니다.

Swift 앱의 `@MainActor`는 화면 상태에 접근하는 코드 등을 메인 액터(main actor)에 격리(isolation)하여 실행과 접근을 관리하는 기능입니다. Rust에서 `Send`나 `Sync`를 구현해도 사용자 인터페이스(user interface, UI) 작업이 메인 스레드로 자동 전달되지는 않습니다. Swift의 `Sendable`도 함께 비교할 만한 개념이지만 각 언어의 타입·동시성(concurrency) 규칙이 다르므로 서로 같은 키워드로 취급할 수는 없습니다.

이 예제는 스레드를 만들지 않습니다. 우선 순수한 입력·출력 규칙을 이해하고, 이후 앱의 OCR처럼 오래 걸리는 작업을 공부할 때 취소, 진행률, 동시 접근을 별도로 배우면 됩니다.

### Rust가 앱에 들어가려면 무엇이 더 필요할까요?

나중에 공통 계산 기능을 Rust 라이브러리로 분리한다면 Swift에서 호출할 수 있도록 연결해야 합니다. 서로 다른 언어의 함수를 호출하는 데 사용하는 연결 방식을 외부 함수 인터페이스(foreign function interface, FFI)라고 합니다. 함수 호출 규약(calling convention), 문자열 인코딩(encoding), 버퍼의 소유자와 해제 시점, 오류 전달 방식, 빌드·배포 구성을 함께 정해야 합니다. Rust의 `String`이나 `Vec`를 Swift가 곧바로 이해한다고 가정할 수 없습니다.

현재 예제에는 FFI가 없습니다. 언어를 바꾸면 자동으로 앱이 빨라진다고 결론 내릴 수도 없습니다. 먼저 측정할 성능 문제를 정하고, Rust로 옮길 계산 영역을 좁힌 뒤, 언어 사이의 호출·데이터 변환 비용과 유지보수 부담까지 비교해야 합니다.

## 7.11 손으로 풀고 실행하는 연습

답을 보기 전에 결과를 종이에 예상해 보세요. 코드를 바꾸는 연습은 실습 폴더에서만 수행하면 됩니다.

### 연습 1: 번호와 인덱스 구별하기

12쪽 문서에서 `5, 1-3, 2`를 입력하면 어떤 인덱스와 설명 문자열이 나올까요? 명령행에서 실행한 뒤, 왜 `2`가 두 번 처리되지 않는지 한 문장으로 설명해 보세요.

### 연습 2: 실패 이유를 구별하기

`"1,"`, `"0"`, `"999999999999999999999999999999999999999"`의 오류가 각각 무엇일지 예상하세요. `lib.rs`의 테스트 모듈 마지막에 세 입력을 검사하는 테스트를 추가해 보세요. 오류가 하나 발생했다는 사실만이 아니라 오류 종류도 확인해야 합니다.

### 연습 3: 새 구분자 하나 받아들이기

사용자가 `1; 3-4`처럼 세미콜론도 쓸 수 있게 바꿔 보세요. 먼저 새 입력이 `Ok(Some(vec![0, 2, 3]))`이어야 한다는 테스트를 추가해 실패를 확인합니다. 다음으로 정규화 단계에 한 줄만 추가하여 테스트를 통과시키세요. `1;;2`는 여전히 오류여야 합니다.

## 7.12 연습 정답과 해설

### 정답 1

인덱스는 `[0, 1, 2, 4]`, 설명 문자열은 `1-3, 5`입니다. 집합이 동일한 인덱스를 한 번만 보관하고, 정렬된 순서로 내보내기 때문입니다.

```sh
cargo run --offline --manifest-path Examples/Learning/RustPageSelection/Cargo.toml -- '5, 1-3, 2'
```

### 정답 2

입력 끝에 쉼표가 있으면 `InvalidFormat`, 0쪽이면 `OutOfBounds`, 표현 가능한 정수 범위를 넘는 긴 숫자이면 `InvalidFormat`입니다. 긴 숫자는 문서 범위 비교 이전에 숫자 변환 자체가 실패합니다. 아래는 **기존 `mod tests` 블록 안에 추가하는** 코드입니다.

```rust
#[test]
fn exercise_distinguishes_error_categories() {
    for (input, expected) in [
        ("1,", SelectionError::InvalidFormat),
        ("0", SelectionError::OutOfBounds { page_count: 12 }),
        (
            "999999999999999999999999999999999999999",
            SelectionError::InvalidFormat,
        ),
    ] {
        assert_eq!(resolve(PageScope::Custom, input, context()), Err(expected));
    }
}
```

### 정답 3

`normalized`를 만드는 부분을 아래처럼 변경합니다.

```rust
let normalized = trimmed
    .replace(['–', '—', '~'], "-")
    .replace('，', ",")
    .replace(';', ",");
```

테스트 모듈에 추가할 코드는 다음과 같습니다.

```rust
#[test]
fn exercise_accepts_semicolons_but_rejects_empty_items() {
    assert_eq!(
        resolve(PageScope::Custom, "1; 3-4", context()),
        Ok(Some(vec![0, 2, 3]))
    );
    assert_eq!(
        resolve(PageScope::Custom, "1;;2", context()),
        Err(SelectionError::InvalidFormat)
    );
}
```

이 변경은 독립 예제에 새 기능을 더하는 연습입니다. 현재 Swift 앱은 세미콜론 입력을 지원하지 않으므로, 연습 뒤 두 코드가 허용하는 입력이 달라졌다는 점까지 설명할 수 있어야 합니다. 원본 소스에는 이 연습의 변경을 미리 넣지 않았습니다.

## 7.13 다음 학습으로 넘어가기 전 확인

다음 다섯 문장을 자신의 말로 완성할 수 있으면 이 장의 핵심을 이해한 것입니다.

1. `&input`으로 전달하는 이유는 ______이다.
2. `Ok(None)`이 실패가 아닌 이유는 ______이다.
3. 1쪽을 인덱스 0으로 바꾸는 시점은 ______이다.
4. `?`를 만나 오류가 나면 ______로 돌아간다.
5. Rust 예제가 통과해도 실제 앱의 OCR을 검증한 것은 아닌 이유는 ______이다.

예시 답은 순서대로 “원본의 소유권을 유지하면서 읽게 하기 위해서”, “성공적으로 전체 문서를 선택했다는 뜻이므로”, “범위를 검사한 뒤 집합에 넣을 때”, “현재 함수를 호출한 코드”, “독립된 페이지 입력 규칙만 검사했기 때문”입니다. 다음 학습에서는 현재 앱의 Swift 화면·상태 코드로 돌아가, 이 작은 규칙의 결과가 어디에 전달되는지 연결해 보세요.
