<!-- SPDX-License-Identifier: MPL-2.0 -->

# Rust로 배우는 OCR 페이지 선택

이 폴더는 광학 문자 인식(optical character recognition, OCR)에 사용할 페이지를 선택하는 HwattakPDF의 [Swift 페이지 선택 코드](../../../Sources/HwattakPDF/Models/OCRPageSelection.swift)를 본뜬 **독립 학습 예제**입니다. 현재 macOS 앱은 Swift로 작성되어 있으며, 앱이 이 Rust 코드를 호출하지 않습니다. PDF를 열거나 수정하지도 않습니다. 문자열을 검사하고 페이지 번호 목록으로 바꾸는 규칙에 집중합니다.

전체 설명은 [교재 7장: 같은 문제를 Rust로 풀기](../../../Documentation/Learning/07-RUST.md)에 있습니다. 원래 앱의 [테스트](../../../Tests/HwattakPDFTests/OCRPageSelectionTests.swift)와 비교하면 언어가 달라도 지켜야 할 규칙을 확인할 수 있습니다.

## 처음이라면 작은 예제부터 실행하기

프로젝트 최상위 폴더에서 다음 명령을 실행합니다. Rust와 Cargo가 이미 설치되어 있어야 합니다. Cargo는 Rust 프로젝트의 빌드(build), 실행, 테스트를 관리하는 도구입니다. 이 예제는 추가로 설치해야 하는 외부 라이브러리(library)에 의존하지 않습니다.

세 줄을 한꺼번에 복사해 실행하세요. 줄 끝의 `\`는 명령이 다음 줄로 이어진다는 뜻입니다.

```sh
cargo run --offline \
  --manifest-path Examples/Learning/RustPageSelection/Cargo.toml \
  --example first_steps
```

이 명령은 [examples/first_steps.rs](examples/first_steps.rs)를 실행합니다. 5쪽짜리 문서에서 현재 쪽을 1에서 2로 바꾸고, 존재하지 않는 6쪽 요청을 거절하는 작은 예제입니다. 입력은 코드에 정해 두었으며, 키보드 입력을 기다리지 않습니다. 빌드 안내 아래에 다음 네 줄이 나타납니다.

```text
문서: 5쪽
현재: 1쪽
이동: 2쪽
거절: 6쪽은 1~5쪽 범위를 벗어납니다.
```

`let`은 값에 이름을 붙이고, `mut`는 그 값을 바꿀 수 있게 합니다. `println!`은 결과를 출력하고, `if`는 조건에 따라 실행할 코드를 고릅니다. 먼저 이 네 가지와 `fn`으로 만드는 함수(function)에 익숙해지세요. 코드를 한 줄씩 읽는 설명과 숫자를 바꾸는 연습은 [교재 7.0](../../../Documentation/Learning/07-RUST.md)에 있습니다. 변수(variable)부터 낯설다면 [0장](../../../Documentation/Learning/00-FIRST-STEPS.md)부터 시작해도 좋습니다.

## 페이지 선택 예제 실행하기

작은 예제를 이해했다면 문자열로 입력한 페이지 범위를 해석해 봅니다. 다음 명령에서 `--example first_steps`를 빼면 원래의 페이지 선택 프로그램이 실행됩니다.

```sh
cargo test --offline --manifest-path Examples/Learning/RustPageSelection/Cargo.toml
cargo run --offline --manifest-path Examples/Learning/RustPageSelection/Cargo.toml
```

소스 코드를 실행 가능한 프로그램으로 만드는 빌드 과정의 안내를 제외하면 다음 세 줄이 나옵니다. 여기서 인덱스(index)는 각 페이지의 위치를 나타내며 0부터 시작합니다.

```text
입력: 1, 3-5, 4, 8
0부터 시작하는 인덱스: [0, 2, 3, 4, 7]
다시 표시한 페이지: 1, 3-5, 8
```

직접 입력할 때는 공백과 쉼표가 하나의 입력으로 전달되도록 따옴표로 감쌉니다. `--` 뒤의 첫 번째 인자(argument)만 읽으며, 문서의 페이지 수는 학습을 위해 12쪽으로 고정했습니다.

```sh
cargo run --offline --manifest-path Examples/Learning/RustPageSelection/Cargo.toml -- '2, 4–6, 5'
```

```text
입력: 2, 4–6, 5
0부터 시작하는 인덱스: [1, 3, 4, 5]
다시 표시한 페이지: 2, 4-6
```

실패하는 입력도 확인해 보세요.

```sh
cargo run --offline --manifest-path Examples/Learning/RustPageSelection/Cargo.toml -- '1-13'
```

```text
입력 오류: 페이지는 1~12 범위여야 합니다.
```

이 경우 종료 코드(exit code)는 `1`입니다. 정상 입력의 종료 코드는 `0`입니다. 프로그램을 호출한 쪽에서도 이 값으로 실패 여부를 구별할 수 있습니다.

## 읽는 순서

| 파일 | 역할 |
| --- | --- |
| [examples/first_steps.rs](examples/first_steps.rs) | 처음 배우는 변수·조건문·함수 연습 |
| [Cargo.toml](Cargo.toml) | 패키지(package) 이름, Rust 에디션(edition), 라이선스(license), 의존성(dependency) |
| [src/main.rs](src/main.rs) | 입력을 받아 함수를 호출하고 결과를 출력하는 시작점 |
| [src/lib.rs](src/lib.rs) | 페이지 선택 규칙과 단위 테스트(unit test) |
| [Cargo.lock](Cargo.lock) | Cargo가 기록한 정확한 패키지 구성 |

처음에는 `first_steps.rs`와 교재 7.0만 읽어도 충분합니다. 이어서 교재 7.1·7.2·7.4·7.5를 읽은 뒤 `main.rs`로 넘어가세요. `main.rs`에서는 값의 형태에 따라 처리를 나누는 패턴 매칭(pattern matching) 구문인 `match`를 읽고, `lib.rs`의 `resolve` → `parse_page` → `compact_description` 순으로 따라갑니다. `#[cfg(test)]` 아래에는 입력과 기대 결과를 비교하는 12개 테스트가 있습니다. 함수 설명 안의 예제 코드도 문서 테스트(documentation test) 1개로 실행됩니다. 교재의 스레드(thread)나 언어 연결 설명은 이 단계에서는 건너뛰어도 됩니다.

## Swift 원본과 학습 예제의 경계

전체 선택은 `Ok(None)`, 현재·직접 입력 선택은 `Ok(Some(...))`로 표현합니다. 공백, 쉼표, `-`·`–`·`—`·`~`, 전각 쉼표 `，`, 중복 제거, 정렬, 역순·범위 초과·정수 변환 실패 처리를 연습할 수 있습니다.

입력 문서 정보는 음수를 검사할 수 있는 `isize`, 결과 인덱스는 음수가 없는 `usize`를 사용합니다. 문자열 양 끝의 공백 처리는 Rust 표준 라이브러리(standard library)의 `trim`에 맡깁니다. 모든 유니코드(Unicode) 입력에서 Foundation과 완전히 같은 동작을 보장하는 정식 이식본(port)은 아닙니다. Swift의 OCR 설정, 작업 진행 상태를 저장하는 체크포인트(checkpoint), PDFKit, Vision, 화면 코드는 포함하지 않습니다.

문서 범위 검사는 실제 페이지 수를 넘는 범위를 계산하기 전에 거절하는 장치입니다. 호출하는 코드가 지나치게 큰 `page_count`를 전달하는 경우까지 메모리 사용량을 제한하지는 않습니다. 실제 앱에 통합하려면 PDF에서 읽은 페이지 수를 사용하고 처리량 제한도 정해야 합니다.

## 확인한 환경

2026-09-30 작업 환경의 `cargo 1.94.0`, `rustc 1.94.0`에서 오프라인 단위 테스트 12개와 문서 테스트 1개가 통과했습니다. 기본 입력과 범위 초과 입력도 실제 실행했습니다. 도구 설치는 수행하지 않았습니다.

초보자용 `first_steps`도 실제 실행해 위의 네 줄이 출력되는지 확인했습니다. 요청 번호를 5와 0으로 바꾼 연습도 별도 사본으로 실행하여 각각 허용과 거절 결과를 확인했습니다.

라이선스는 저장소와 같은 MPL-2.0이며 [LICENSE](../../../LICENSE)를 따릅니다.
