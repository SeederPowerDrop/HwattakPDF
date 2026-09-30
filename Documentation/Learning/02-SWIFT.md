# 2장 우리 앱을 읽기 위한 Swift 기초

이 장의 목표는 Swift 문법을 전부 외우는 것이 아닙니다. 우리 앱의 짧은 함수 하나를 보고 “무엇을 입력받고, 어떤 상태를 검사하고, 무엇을 돌려주는가”를 설명할 수 있으면 됩니다. Rust를 배우려는 경우에도 먼저 현재 앱에서 사용하는 Swift 문법과 설계를 읽어 두면 두 언어의 차이를 구체적으로 비교할 수 있습니다.

코드를 처음 읽는다면 [0장. 코드를 처음 읽는 사람을 위한 준비](00-FIRST-STEPS.md)을 먼저 읽어 보세요. 아직 `let`, `if`, 함수(function)가 낯설어도 괜찮습니다. 이번에는 아래의 **첫 번째 읽기**만 따라가고, 나머지는 필요한 때 돌아와 읽어도 됩니다.

| 읽는 순서 | 이번에 알아볼 내용 |
|---|---|
| 첫 번째 읽기 | 2절의 `let`·`var`, 3절의 페이지 이동 함수, 6절의 값이 없는 경우를 읽습니다. 아래 입문 예제를 실행한 뒤 연습 1을 풉니다. |
| 두 번째 읽기 | 1절의 빌드, 4절의 값과 참조, 5절의 열거형, 7절의 오류 처리를 읽습니다. |
| 앱 구조가 익숙해진 뒤 | 8절의 클로저·프로토콜·제네릭과 9절의 `@Published`·`@MainActor`를 읽습니다. 처음부터 외울 필요는 없습니다. |

먼저 작은 프로그램을 실행해 보고 싶다면 [Swift 첫걸음 실습](../../Examples/Learning/SwiftFirstSteps/README.md)을 열어 보세요. 5쪽짜리 문서에서 2페이지로 이동하고, 존재하지 않는 6페이지로 이동하려는 요청을 거절하는 예제입니다. 실제 PDF 파일이나 앱 설정을 바꾸지 않으며, 짧은 코드 한 파일만 사용합니다.

## 학습 목표와 원문

이 장을 마치면 빌드 설정을 읽고, 값과 참조를 구분하며, 옵셔널(Optional)과 오류 처리의 목적을 설명할 수 있습니다. `@Published`와 `@MainActor`를 만났을 때도 각각 변경 알림과 실행 격리라는 서로 다른 역할을 알아볼 수 있습니다.

| 먼저 열 파일 | 찾아볼 부분 |
|---|---|
| [Package.swift](../../Package.swift) | 도구 버전, 실행 대상, 테스트 대상 |
| [PDFWorkspaceMode.swift](../../Sources/HwattakPDF/Models/PDFWorkspaceMode.swift) | `enum`, 계산 속성, 함수, `Set` |
| [PDFWorkspaceState.swift](../../Sources/HwattakPDF/Models/PDFWorkspaceState.swift) | `@Published`, `setCurrentPage`, `open(url:)` |
| [HwattakPDFApp.swift](../../Sources/HwattakPDF/App/HwattakPDFApp.swift) | `@main`, `@StateObject`, `some Scene` |
| [PDFKitViewer.swift](../../Sources/HwattakPDF/Views/PDFKitViewer.swift) | 클로저, `weak`, `defer`, `!==` |

소스의 `[학습 02]` 주석을 검색하면 이 장에서 다루는 위치를 찾을 수 있습니다. 아래 발췌는 이 교재 작성 시점의 작업 폴더를 기준으로 합니다. `…` 또는 “축약”이라고 표시한 예는 그대로 붙여 넣어 실행할 수 있는 완전한 프로그램이 아닙니다.

## 1. 코드는 어떻게 앱이 되는가

소스 코드(source code)는 사람이 읽고 작성하는 프로그램입니다. 컴파일러(compiler)는 소스 코드의 문법과 타입(type)을 검사해 실행 가능한 코드로 바꿉니다. 빌드 도구(build tool)는 어떤 파일들을 하나의 프로그램으로 묶을지 결정합니다. 우리 앱은 이 구성을 `Package.swift`에 적어 둡니다.

다음은 실제 설정의 핵심만 남긴 발췌입니다.

```swift
// swift-tools-version: 6.0
// 아래 줄은 Package 선언 안의 각각 다른 위치에서 발췌했다.
platforms: [.macOS(.v14)]
.executable(name: "HwattakPDF", targets: ["HwattakPDF"])
.swiftLanguageMode(.v5)
```

`swift-tools-version: 6.0`은 패키지를 해석하는 도구의 최소 버전과 패키지 명세(manifest)에서 사용할 수 있는 기능의 기준을 정합니다. `swiftLanguageMode(.v5)`는 해당 빌드 대상(target)의 소스를 Swift 5 언어 모드로 검사하라는 설정입니다. 따라서 Swift 6 도구를 사용하면서 앱 소스를 Swift 5 모드로 빌드할 수 있습니다. Swift 6 모드로 바꾸면 특히 동시성(concurrency) 관련 검사가 달라지므로, 단순히 버전 숫자만 바꾸는 작업으로 생각해서는 안 됩니다. [Swift 공식 마이그레이션 안내](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/)에서 두 설정의 관계를 확인할 수 있습니다.

`.macOS(.v14)`는 이 패키지에 선언한 최소 운영체제 버전입니다. `executableTarget`은 실행할 앱의 소스 묶음이고, `testTarget`은 그 앱 코드를 검증하는 별도 소스 묶음입니다. 폴더로 보면 각각 `Sources/HwattakPDF`와 `Tests/HwattakPDFTests`입니다.

프로젝트 폴더에서 아래 명령을 실행하면 각 단계의 차이를 직접 볼 수 있습니다.

```sh
swift --version
swift build
swift test --filter PDFWorkspaceModeTests
```

첫 줄은 설치된 도구의 버전을 확인하고, 둘째는 소스를 컴파일하며, 셋째는 모드 정책 테스트만 실행합니다. 명령이 실패하면 마지막의 “실패했다”는 문장보다 앞서 나온 구체적인 오류를 읽어 보세요. `swift build`가 성공했다는 것은 컴파일이 가능하다는 뜻입니다. 버튼의 동작, 실제 PDF의 저장 결과, macOS 앱 번들(app bundle)의 아이콘과 메뉴까지 모두 검증되었다는 뜻은 아닙니다. 배포용 `.app` 생성 과정은 [빌드 스크립트](../../scripts/build_app.sh)에서 따로 확인해 보세요.

## 2. `let`과 `var`: 무엇이 바뀔 수 있는가

`let`으로 선언한 이름에는 한 번 정한 값을 다시 대입할 수 없습니다. `var`에는 다시 대입할 수 있습니다. 콜론 뒤는 타입이며, 초깃값으로 타입을 알아낼 수 있으면 생략할 수 있습니다. 컴파일러가 타입을 알아내는 기능을 타입 추론(type inference)이라고 합니다.

처음에는 **값을 바꿔야 하는 이름에만 `var`를 쓴다**고 생각하면 됩니다. 예를 들어 이번 실습에서 전체 페이지 수는 바뀌지 않으므로 `let`으로 두고, 현재 페이지 위치는 이동할 때마다 달라지므로 `var`로 둡니다. `=`는 오른쪽 값을 왼쪽 이름에 저장하는 대입(assignment)이고, `==`는 두 값이 같은지 확인하는 비교(comparison)입니다. `currentPageIndex = 1`은 값을 바꾸지만, `currentPageIndex == 1`은 “지금 값이 1인가?”라는 질문의 결과만 만듭니다.

`var`를 써도 아무 종류의 값이나 넣을 수 있는 것은 아닙니다. 처음에 `var currentPageIndex = 0`으로 정수(integer)를 저장했다면, 나중에 문자열(string)인 `"두 번째 페이지"`를 같은 변수에 대입할 수 없습니다. 값은 바뀔 수 있지만, 그 변수가 받아들이는 타입은 정해져 있습니다.

실제 `PDFTabSession`의 속성(property) 두 개를 읽어 보세요.

```swift
let id: UUID
let workspace: PDFWorkspaceState
```

`id`는 탭을 구분하는 식별자(identifier)이고, `workspace`는 그 탭의 문서 모델을 가리킵니다. 여기서 주의할 점이 있습니다. `workspace`가 `let`이어도 참조 대상인 클래스(class) 객체의 변경 가능한 속성은 바뀔 수 있습니다. 금지되는 것은 `workspace`라는 이름에 다른 객체를 다시 대입하는 일입니다. `let`을 썼다고 문서 내용까지 변경할 수 없게 되는 것은 아닙니다.

다음은 문서 모델에 실제로 선언된 속성입니다.

```swift
@Published var currentPageIndex = 0
```

컴파일러는 `0`을 보고 타입을 `Int`로 추론하며, 사용자가 페이지를 옮기면 이 속성의 값이 달라집니다. 여기서의 인덱스(index)는 0부터 시작합니다. 화면에 표시하는 1페이지는 내부 인덱스 0이고, 10페이지는 인덱스 9입니다. 이 구분은 페이지 이동과 배열 접근에서 자주 만납니다.

속성에는 값을 보관하는 저장 속성(stored property)과, 접근할 때 값을 계산해서 돌려주는 계산 속성(computed property)이 있습니다. `PDFWorkspaceMode`의 다음 코드는 계산 속성입니다.

```swift
var id: String { rawValue }
```

`id`를 별도로 저장하지 않고, 접근할 때 현재 모드의 원시값(raw value)인 `rawValue`를 반환합니다. 예를 들어 `.viewer`의 원시값은 `"viewer"`입니다. 화면의 한국어 제목을 식별자로 사용하지 않기 때문에 앱 언어를 바꿔도 같은 모드로 인식할 수 있습니다.

## 3. 함수는 입력, 검사, 결과로 읽는다

`PDFWorkspaceMode`의 실제 함수입니다.

```swift
func allows(_ capability: PDFWorkspaceCapability) -> Bool {
    capabilities.contains(capability)
}
```

`func`는 함수 선언, `allows`는 이름, 괄호 안은 입력, `-> Bool`은 참 또는 거짓을 반환한다는 뜻입니다. `_`는 호출할 때 인자 레이블(argument label)을 쓰지 않는다는 표시입니다. 그래서 `mode.allows(.ocr)`라고 호출합니다. 함수 본문이 단일 표현식(expression)이므로 이 코드에서는 `return`을 생략할 수 있습니다.

반대로 `title(for tool: WorkspaceTool)`에서 `for`는 호출할 때 사용하는 인자 레이블이고, `tool`은 함수 안에서 쓰는 매개변수(parameter) 이름입니다. `mode.title(for: .text)`처럼 읽으면 문장에 가깝습니다. 이름이 같아도 입력 타입이 다른 함수를 여러 개 만들 수 있는데, 이를 오버로딩(overloading)이라고 합니다. 이 파일에는 `allows`가 `capability`를 받는 버전과 `tool`을 받는 버전으로 나뉘어 있습니다.

페이지 이동 함수 전체는 다음처럼 짧습니다.

```swift
func setCurrentPage(_ index: Int) {
    guard index >= 0, index < pageCount else { return }
    currentPageIndex = index
    if selectedPages.isEmpty {
        selectedPages = [index]
    }
}
```

반환 타입(return type)을 따로 쓰지 않았으므로 의미 있는 결과값을 돌려주지 않는 `Void` 함수입니다. `guard`의 조건을 만족하지 않으면 즉시 함수를 빠져나갑니다. 유효한 인덱스일 때만 현재 페이지를 바꾸며, 선택된 페이지가 없으면 현재 페이지를 선택합니다. 이 순서가 중요합니다. 검사를 뒤로 옮기면 유효하지 않은 인덱스가 이미 상태에 반영된 뒤에 검사하게 됩니다.

### 처음 읽을 때는 한 줄씩 따라가세요

| 코드의 한 부분 | 쉬운 말로 읽기 |
|---|---|
| `func setCurrentPage(_ index: Int)` | `setCurrentPage`라는 작업을 정의합니다. 호출한 쪽에서 받은 정수 하나를 이 함수 안에서는 `index`라고 부릅니다. |
| `{`와 `}` | 중괄호(brace) 안에 이 작업의 내용을 묶습니다. 안쪽 `if`도 자신의 중괄호를 가집니다. |
| `guard index >= 0, index < pageCount` | “음수가 아니고, 전체 페이지 수보다 작은가?”를 확인합니다. 쉼표로 나열한 두 조건을 모두 만족해야 다음 줄로 갑니다. |
| `else { return }` | 앞의 조건 중 하나라도 맞지 않으면 여기서 이 함수의 실행을 끝냅니다. 앱 전체를 종료한다는 뜻은 아닙니다. |
| `currentPageIndex = index` | 검사를 통과한 숫자를 현재 페이지 위치로 저장합니다. |
| `if selectedPages.isEmpty` | 현재 선택된 페이지가 하나도 없는 경우에만 안쪽 코드를 실행합니다. |
| `selectedPages = [index]` | 선택 집합에 현재 페이지의 인덱스 하나를 넣습니다. 이미 선택이 있다면 이 줄은 실행하지 않습니다. |

조건이 맞지 않을 때 나머지 작업을 건너뛰는 것을 조기 반환(early return)이라고 합니다. `return`을 만나면 “이 함수에서는 더 할 일이 없다”고 읽어 보세요. 이 예에서 `guard`는 잘못된 숫자를 저장하기 **전에** 막아 줍니다.

전체 페이지 수가 `pageCount == 5`라면 사용할 수 있는 인덱스는 `0, 1, 2, 3, 4`입니다. `setCurrentPage(4)`를 먼저 호출하고 이어서 `setCurrentPage(5)`를 호출하면 다음과 같습니다. 표에서 `[]`는 선택된 페이지가 없다는 뜻이고, `[4]`는 인덱스 4인 페이지 하나가 선택되었다는 뜻입니다.

| 확인 시점 | 전달한 `index` | `currentPageIndex` | `selectedPages` |
|---|---|---|---|
| 시작할 때 | 아직 없음 | `0` | `[]` |
| 첫 호출이 끝난 뒤 | `4` | `4` | `[4]` |
| 두 번째 호출이 끝난 뒤 | `5` | `4` | `[4]` |

첫 호출에서는 `4 < 5`가 참이므로 값이 바뀝니다. 두 번째 호출에서는 `5 < 5`가 거짓이므로 `return`에서 끝나고 값이 그대로 남습니다. 마지막에 사용자에게 보여 줄 번호는 `currentPageIndex + 1`, 즉 **5페이지**입니다. 함수 안에서 쓰는 인덱스와 화면에 보여 주는 페이지 번호를 구분하는 것이 이번 연습의 핵심입니다.

## 4. `struct`와 `class`: 값의 복사와 객체의 공유

구조체(struct)와 열거형(enum)은 값 타입(value type)이며, 클래스는 참조 타입(reference type)입니다. 값 타입은 대입하거나 전달할 때 독립적인 값으로 취급하고, 클래스는 같은 객체를 여러 곳에서 가리킬 수 있습니다. 다만 구조체 안에 클래스 참조가 들어 있으면 그 참조 대상까지 자동으로 깊은 복사(deep copy)가 이루어지는 것은 아닙니다. [Swift 공식 설명](https://docs.swift.org/swift-book/LanguageGuide/ClassesAndStructures.html)

우리 앱에서 이 차이를 가장 잘 보여 주는 두 타입은 다음과 같습니다.

```swift
// 실제 선언에서 본문을 생략한 발췌
struct PDFTabSession: Identifiable { /* … */ }
final class PDFWorkspaceState: ObservableObject { /* … */ }
```

`PDFTabSession`은 탭 ID와 문서 모델 참조를 묶는 작은 값입니다. 이 구조체를 복사해도 안의 `workspace`가 가리키는 문서 모델은 같은 객체입니다. 문서 모델은 툴바, 사이드바, PDF 화면이 함께 사용합니다. 어느 한 곳에서 현재 페이지를 바꾸면 다른 곳에서도 알아야 하므로, 같은 모델을 공유하는 방식이 유용합니다.

`final`은 이 클래스를 상속(inheritance)해 새로운 하위 클래스(subclass)를 만들 수 없다는 뜻입니다. `ObservableObject`는 이 객체가 변경 알림을 제공하는 규약을 따른다는 표시입니다.

객체를 비교하는 기호도 다릅니다.

```swift
let documentChanged = pdfView.document !== state.document
```

이는 `PDFKitViewer`의 실제 코드입니다. `!==`는 서로 다른 객체인지 검사하고, `===`는 같은 객체인지 검사합니다. 두 PDF의 글자가 같은지 비교하는 연산이 아닙니다. 같은 파일을 두 번 읽어 별도 `PDFDocument` 객체를 만들었다면 내용이 같아도 객체의 식별성(identity)은 다릅니다. 반면 `==`는 해당 타입이 정의한 값의 동등성(equality)을 검사합니다.

## 5. `enum`, `switch`, `Set`: 가능한 상태를 제한한다

다음은 모드 선언의 일부입니다.

```swift
enum PDFWorkspaceMode: String, CaseIterable, Codable, Identifiable {
    case viewer
    case editing
    case study
    // 나머지 속성과 함수 생략
}
```

모드를 임의의 문자열로만 저장하면 `"edting"` 같은 오타도 값이 될 수 있습니다. `enum`을 쓰면 코드에서 선택할 수 있는 상태가 이 세 가지로 한정됩니다. `String`은 각 케이스(case)의 원시값 타입입니다. `CaseIterable`, `Codable`, `Identifiable`은 각각 모든 케이스 나열, 인코딩(encoding)·디코딩(decoding), 식별을 위한 규약입니다. 여기서 `Codable`은 PDF 자체를 저장한다는 뜻이 아니라 모드 값을 세션 기록 등에 담을 수 있는 형태로 변환한다는 뜻입니다.

모드별 동작을 나눌 때는 `switch`를 씁니다. 아래는 `availableTools(for:)`의 본문입니다.

```swift
return switch mode {
case .viewer:
    [.select, .text]
case .editing, .study:
    [.select, .text, .pen, .eraser]
}
```

각 분기가 하나의 값을 만들어 전체 `switch`의 결과가 됩니다. `.editing, .study`는 두 모드가 같은 분기를 사용한다는 뜻입니다. 새 케이스를 추가하면 빠진 경우를 컴파일러가 알려 주는 것도 열거형의 장점입니다.

권한 목록은 `Set<PDFWorkspaceCapability>`를 사용합니다. 집합(set)은 중복을 허용하지 않고 요소의 순서를 보장하지 않는 자료구조입니다. 화면 도구 목록처럼 순서가 필요한 곳은 `[WorkspaceTool]`, 즉 배열(array)을 씁니다. `common.union([...])`은 공통 권한과 모드별 권한을 합친 새 집합을 돌려줍니다. 화면에서 권한을 확인할 때 이 규칙을 재사용하므로, 같은 모드의 기능이 화면마다 다르게 활성화되는 일을 줄일 수 있습니다.

## 6. Optional: “없음”을 타입으로 표현한다

가장 익숙한 상황부터 생각해 보세요. 앱을 켰지만 아직 파일을 열지 않았다면 현재 파일의 위치를 무엇으로 기록해야 할까요? 우리 앱은 `documentURL: URL?`이라는 속성으로 파일의 위치를 나타냅니다. `URL`은 여기서 파일 위치를 나타내는 타입이고, 끝의 `?`는 **그 위치 정보가 아직 없을 수도 있다**는 뜻입니다. 새 작업 공간에서 파일을 열기 전에는 값이 `nil`입니다. 파일을 열면 실제 파일 위치를 담을 수 있습니다.

옵셔널(Optional)에서 `nil`은 “값이 없음”입니다. 숫자 0이나 빈 문자열과는 다릅니다.

| 표현 | 의미 |
|---|---|
| `Int?`에 들어 있는 `nil` | 정수 값이 없습니다. |
| `Int?`에 들어 있는 `0` | 정수 값이 있으며, 그 값이 0입니다. 페이지 인덱스라면 첫 페이지를 가리킬 수 있습니다. |
| `String?`에 들어 있는 `nil` | 문자열 값이 없습니다. |
| `String?`에 들어 있는 `""` | 문자열 값은 있지만 글자가 하나도 없습니다. |

위 표는 타입별로 값의 유무를 비교한 예입니다. `URL?`인 `documentURL`에 숫자 `0`이나 문자열 `""`를 대신 넣으라는 뜻은 아닙니다. 타입마다 담을 수 있는 값이 다르며, `nil`은 옵셔널 타입에서 값이 없음을 표현할 때 씁니다.

문서 모델의 `document`는 `PDFDocument?`입니다. 끝의 `?`는 PDF 문서가 있거나 없을 수 있다는 뜻입니다. 이처럼 값의 유무를 표현하는 타입이 옵셔널입니다. 아무 파일도 열지 않았을 때뿐 아니라, 비활성 탭을 휴면 상태로 전환해 문서 객체를 메모리에서 해제했을 때도 값이 없을 수 있습니다. 따라서 `document == nil`만으로 “이 탭에 열었던 파일이 없다”고 단정하면 안 됩니다. 우리 앱에는 URL과 휴면 상태의 페이지 수를 기록하는 별도 상태가 있습니다.

`guard let`은 값이 있는지 검사하고, 있으면 안전하게 사용할 이름을 만듭니다. 이런 과정을 옵셔널 바인딩(optional binding)이라고 합니다. 아래는 실제 `TabbedWorkspaceView.windowTitle`의 첫 줄입니다.

```swift
guard let activeWorkspace = workspace.activeWorkspace else {
    return "HwattakPDF"
}
```

활성 문서 모델이 없으면 기본 창 제목을 반환합니다. 검사를 통과한 뒤에는 `activeWorkspace`가 옵셔널이 아닌 값이므로 속성에 접근할 수 있습니다. `if let`은 값이 있는 경우에만 특정 블록을 실행할 때 쓰고, `guard let`은 이후 작업의 전제조건을 먼저 확인할 때 읽기 편합니다. [Swift Optional 안내](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/thebasics/)

실제 소스에서 `state?.setCurrentPage(index)`를 만나면 “`state`가 있으면 호출하고 없으면 건너뛴다”라고 읽습니다. 이를 옵셔널 체이닝(optional chaining)이라고 합니다. `?? .defaultValue`는 “왼쪽 값이 없으면 기본값을 사용한다”라는 뜻입니다. `!`를 이용하는 강제 언래핑(forced unwrapping)은 값이 없을 때 실행을 중단시킬 수 있습니다. 우리 앱에서 값이 없는 경우를 언제 정상 상황으로 처리하는지 먼저 살펴보세요.

## 7. 실패할 수 있는 함수: `throws`, `try`, `do/catch`

옵셔널은 값의 부재를 표현하고, 오류 처리(error handling)는 실패 이유를 전달합니다. PDF를 열 때는 사용자가 암호 입력을 취소할 수도 있고, 실제로 파일을 읽지 못할 수도 있습니다. 두 상황은 사용자에게 다른 결과로 보여 주어야 합니다.

다음은 `PDFWorkspaceState.open(url:)`의 실제 코드에서 일부 경로를 축약한 것입니다.

```swift
do {
    guard let unlocked = try loadUnlockedDocument(at: url) else {
        presentedError = nil
        return false
    }
    loaded = unlocked
} catch {
    presentedError = error.localizedDescription
    return false
}
```

`throws`가 붙은 함수는 정상 결과를 반환하는 대신 오류를 던질 수 있고, 호출부의 `try`는 그 가능성을 표시합니다. `do` 안에서 오류가 던져지면 `catch`로 이동합니다. 이 예에서는 사용자가 암호 입력을 취소하면 오류 없이 `nil`이 반환되고, 함수는 오류 메시지를 표시하지 않고 종료합니다. 실제 오류가 발생한 경우에는 표시할 메시지를 저장합니다. `try?`로 바꾸면 오류도 `nil`로 처리하므로, 이 예처럼 취소와 실패를 구분해야 하는 곳에서는 동작의 의미가 달라집니다.

함수에 `async`가 함께 있으면 실행을 잠시 중단했다가 이어 갈 수 있는 비동기 함수(asynchronous function)라는 뜻이며, 호출부에서는 `await`를 씁니다. `await` 자체가 “백그라운드 스레드(background thread)에서 실행하라”라는 뜻은 아닙니다. 실행 위치와 공유 상태의 안전성은 액터(actor) 등의 규칙을 따로 살펴야 합니다.

## 8. 클로저, 프로토콜, 제네릭은 낯선 문법을 읽는 열쇠다

클로저(closure)는 전달하거나 저장할 수 있는 실행 코드입니다. `PDFKitViewer`에는 다음 속성이 있습니다.

```swift
private let onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)?
```

오른쪽부터 읽어 보세요. `?`이므로 콜백(callback)이 없을 수 있습니다. 콜백은 특정 시점에 실행하도록 다른 코드에 전달해 둔 함수나 클로저를 뜻합니다. 이 콜백이 있으면 `PDFVerticalScrollMetrics` 하나를 받아 의미 있는 반환값 없이 끝납니다. PDF 화면은 이 함수를 불러 스크롤 정보를 전달하지만, 그 정보를 화면의 어느 위치에 표시할지는 직접 결정하지 않습니다. 사용할 동작을 호출하는 쪽에서 전달하는 방식입니다.

`@escaping`은 전달된 클로저가 그 함수 호출이 끝난 뒤에도 저장되어 사용될 수 있다는 표시입니다. `{ [weak self] in ... }`는 현재 객체를 약한 참조(weak reference)로 캡처(capture)하여, 클로저 때문에 객체의 수명이 계속 유지되지 않도록 하는 방식입니다. `weak` 참조는 객체가 사라지면 `nil`이 되므로 `guard let self else { return }` 같은 확인과 자주 함께 나옵니다.

프로토콜(protocol)은 어떤 기능을 제공해야 하는지 정한 약속입니다. `struct PDFKitViewer: NSViewRepresentable`은 SwiftUI 안에서 AppKit 화면을 만들고 갱신하는 역할을 수행합니다. 실제 메서드(method) 이름인 `makeNSView`, `updateNSView`가 이 약속에 해당합니다. `any PDFLazyDocumentInspecting`은 그 프로토콜을 만족하는 구체적인 구현을 담는다는 뜻이며, 실제 코드에서는 기본 구현과 테스트용 대체 구현을 바꿔 넣을 수 있습니다.

제네릭(generics)은 타입을 매개변수로 받아 코드를 재사용하는 방식입니다. `Set<Int>`는 정수 집합이고 `Set<PDFWorkspaceCapability>`는 권한 집합이지만, 둘 다 같은 `Set` 기능을 사용합니다. `[URL]`은 `Array<URL>`의 짧은 표기입니다. `var body: some View`의 `some View`는 “`View` 규약을 만족하는 구체적인 타입을 구현하는 쪽에서 정하며, 호출자는 세부 타입 이름을 몰라도 된다”라는 뜻의 불투명 반환 타입(opaque return type)입니다. 서로 다른 구체적인 타입을 담을 수 있는 `any View`와는 의미가 다릅니다.

## 9. `@Published`와 `@MainActor`를 혼동하지 않는다

`@Published`는 클래스 속성의 변경을 구독자(subscriber)에게 알리는 프로퍼티 래퍼(property wrapper)입니다. 우리 앱에서는 `ObservableObject` 모델을 관찰하는 SwiftUI 화면이 그 알림을 바탕으로 갱신됩니다. 디스크에 자동 저장하거나 모든 스레드 접근을 안전하게 만드는 기능은 아닙니다. `$activeSearchSelection`처럼 접근하면 이 프로퍼티 래퍼의 퍼블리셔(publisher), 즉 값을 발행하는 객체를 사용합니다. Combine의 구독 콜백은 속성에 새 값이 저장되기 전에 값을 받으므로, 콜백의 인자로 받은 새 값과 객체 속성을 다시 읽은 값을 구분해야 합니다. [Apple의 Published 설명](https://developer.apple.com/documentation/combine/published)

`@MainActor`는 선언에 대한 접근과 실행을 메인 액터(main actor)에 격리(isolation)합니다. 우리 앱에서는 사용자 인터페이스(user interface, UI)와 PDFKit 상태를 하나의 실행 영역에서 관리하는 데 사용합니다. `PDFWorkspaceState`와 `PDFKitViewer.Coordinator`가 대표적입니다. 오래 걸리는 동기 작업(synchronous task)을 이 영역에서 수행하면 화면 반응이 늦어질 수 있습니다. 화면을 안전하게 갱신하는 위치와 오래 걸리는 계산을 수행하는 위치를 나누는 설계는 이후 OCR·비동기 장에서 이어집니다. [Swift 동시성 안내](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)

`private(set)`도 함께 읽어 보세요. `@Published private(set) var isDirty = false`는 바깥에서 읽을 수 있지만 직접 대입할 수는 없다는 뜻입니다. 외부 코드가 임의로 값을 바꾸지 못하게 하고, 이 타입 내부에서 상태 변경을 관리하도록 합니다. 문법이 실제 프로그램의 규칙을 지키는 장치가 되는 예입니다.

## 연습 1. 페이지 인덱스 추적

`pageCount == 5`, `currentPageIndex == 0`, `selectedPages == []`라고 가정해 보세요. 위의 실제 `setCurrentPage`를 기준으로 `setCurrentPage(4)` 다음에 `setCurrentPage(5)`를 호출하면 최종 상태는 무엇인가요? 사용자에게 보여 줄 현재 페이지 번호도 구해 보세요.

**해설:** 첫 호출의 인덱스 4는 유효하므로 현재 인덱스가 4, 선택 집합이 `[4]`가 됩니다. 두 번째 호출은 `index < pageCount`를 통과하지 못해 아무것도 바꾸지 않습니다. 화면에는 5페이지로 표시합니다. 마지막 페이지의 인덱스는 페이지 수보다 1 작습니다.

## 연습 2. 모드 값을 복사하면 무엇이 달라질까

다음은 앱에 정의된 `PDFWorkspaceMode`를 사용하는 짧은 학습 예제입니다. 마지막의 `original`은 무엇인가요? 같은 방식으로 `PDFWorkspaceState` 객체를 두 이름에 대입한 경우와 어떤 차이가 있는지 설명해 보세요.

```swift
let original = PDFWorkspaceMode.viewer
var working = original
working = .study
```

**해설:** `original`은 계속 `.viewer`입니다. 열거형은 값 타입이므로 `working`을 변경해도 `original`은 바뀌지 않습니다. 클래스 객체를 다른 이름에 대입하면 같은 객체를 참조할 수 있으므로, 한 이름으로 객체 내부의 속성을 바꾸면 다른 이름에서도 그 변경을 보게 됩니다. 단, 한 변수에 새 객체를 다시 대입하는 것과 기존 객체 내부를 변경하는 것은 구분해야 합니다.

## 연습 3. 권한과 도구의 차이 찾기

`PDFWorkspaceModePolicy`를 열어 `.editing`에 `.ocr` 권한이 있는지 확인해 보세요. 이어서 `availableTools(for:)`의 반환값에서 `.ocr`가 보이지 않는 이유를 설명해 보세요.

**해설:** 편집 모드의 기능 권한(capability) 집합에는 `.ocr`가 있습니다. 그러나 `WorkspaceTool`은 선택·텍스트·펜·지우개 같은 직접 조작 도구를 표현합니다. OCR은 기능 권한이면서 별도 절차로 실행하므로 같은 목록에 들어갈 필요는 없습니다. 화면에서 기능을 활성화할지 판단하는 데 쓰는 권한과 현재 마우스로 사용할 도구를 별도 타입으로 모델링(modeling)한 것입니다.

다음 [03. 화면과 상태의 흐름](03-UI-STATE.md)에서는 이 문법들이 페이지 이동 한 번을 어떻게 처리하는지 연결해서 읽어 보세요.
