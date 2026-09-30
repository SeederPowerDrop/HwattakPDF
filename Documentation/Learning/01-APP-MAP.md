# 1장 우리가 만든 앱의 전체 지도

## 처음 읽는 순서

이 장은 앱을 이루는 부분을 알아보는 지도입니다. 먼저 아래의 네 문장과 1절의 기술 역할 표만 읽으세요. 개발 기록과 기능 목록은 나중에 필요한 코드를 찾을 때 돌아와도 됩니다. 변수와 함수가 아직 낯설면 [0장](00-FIRST-STEPS.md)을 먼저 읽으세요.

1. **화면**은 사용자가 문서를 보거나 버튼을 누르는 곳입니다.
2. **상태**(state)는 지금 몇 쪽을 보고 있는지처럼 앱이 기억하는 값입니다.
3. **처리 코드**는 입력을 검사하고 페이지를 옮기거나 주석을 추가합니다.
4. **저장 코드**는 편집 결과를 파일에 기록합니다.

예를 들어 3쪽으로 이동할 때는 화면에서 번호를 입력하고, 처리 코드가 그 페이지가 있는지 확인한 뒤, 현재 페이지 상태를 바꿉니다. 화면은 바뀐 상태를 보여 줍니다. 이 동작만으로 PDF 파일의 내용까지 바뀌는 것은 아닙니다. 먼저 이 한 동작을 따라간 뒤, 저장과 OCR처럼 단계가 더 많은 기능으로 넓혀 가세요.

## 이 장에서 배울 것

- HwattakPDF가 해결하는 문제와 현재 기능의 범위를 설명합니다.
- 화면, 상태, 문서 처리, 파일 저장이 각각 맡은 역할을 구분합니다.
- 큰 파일 전체를 외우지 않고 기능 하나가 호출되는 경로를 따라갑니다.
- 현재 앱의 구현 언어와 앞으로 공부할 Rust의 관계를 정확히 이해합니다.

이 교재는 **2026-09-30에 읽은 현재 작업 폴더의 소스 코드**(source code)를 기준으로 합니다. 아직 Git에 반영하지 않은 최근 글자 인식·선택 기능도 포함합니다. [Info.plist](../../Resources/Info.plist)에 기록된 버전은 0.9.0이고, 빌드 번호(build number)는 20입니다. 소스 코드의 버전, 현재 실행 중인 설치본의 버전, 공개 다운로드 버전은 서로 다를 수 있습니다. 이 장은 설치본을 새로 실행해 검증한 보고서는 아닙니다.

## 1. 어떤 프로그램을 만들었나

HwattakPDF는 여러 PDF를 탭으로 열어 읽고 비교하며, 메모를 남기고 페이지를 편집하는 Mac 앱입니다. 스캔 문서에 검색용 글자를 넣는 광학 문자 인식(optical character recognition, OCR) 기능도 제공합니다. 핵심 읽기·주석·페이지 작업·OCR은 사용자 컴퓨터에서 처리합니다. 외부 AI 기능은 사용자가 설정한 서비스 제공자와 API 키(API key)를 사용하며, 내용을 보내기 전에 전송 대상을 확인하는 과정이 있습니다. API(Application Programming Interface)는 프로그램끼리 기능이나 데이터를 주고받을 때 사용하는 인터페이스이며, API 키는 외부 서비스에 접근할 때 사용하는 인증 정보입니다.

**현재 앱은 Swift로 만들었습니다.** [Package.swift](../../Package.swift)는 Swift 패키지 관리자(SwiftPM, Swift Package Manager)가 사용할 빌드 대상(target)을 선언합니다. 실행 대상을 `HwattakPDF`, 테스트 대상을 `HwattakPDFTests`로 정의합니다. 도구 버전 선언은 Swift 6.0이고 두 대상의 언어 모드는 Swift 5입니다. 지원 운영체제는 macOS 14 이상으로 선언되어 있습니다. 앱 소스에는 Rust 프로젝트 설정 파일인 `Cargo.toml`이나 Rust 구현 파일인 `.rs` 파일이 없습니다. 교재의 Rust 실습은 현재 앱의 작은 알고리즘을 다른 언어로 다시 구현해 보는 학습입니다. 이미 Rust가 앱 안에서 작동한다는 뜻은 아닙니다.

| 기술 | 앱에서 맡은 일 | 처음 배울 핵심 질문 |
| --- | --- | --- |
| Swift | 데이터와 기능의 실행 규칙 | 값은 어디에 저장되고 언제 바뀌는가? |
| SwiftUI | 창, 툴바, 설정, 상태에 반응하는 화면 | 상태가 바뀌면 어떤 화면을 다시 구성하는가? |
| AppKit | Mac 메뉴·입력·파일 선택 창 등 | 운영체제 이벤트(event)를 앱 동작에 어떻게 연결하는가? |
| PDFKit | PDF 문서·페이지·선택·주석·표시 | PDF의 페이지와 주석은 어떤 객체(object)인가? |
| Vision | 이미지 속 글자 인식 | 오래 걸리는 작업의 진행률·취소·재개를 어떻게 다루는가? |
| Foundation·Core Graphics·WebKit | 파일·데이터·렌더링(rendering)·HTML 변환 등 | 각 도구의 역할과 한계를 어떻게 나누는가? |
| XCTest | 기대한 대로 동작하는지 자동으로 확인 | 바꾼 코드가 이전 기능을 깨뜨렸는가? |

Swift 문법을 모두 공부한 다음에 앱 코드를 읽을 필요는 없습니다. `OCRPageSelection`처럼 입력과 출력이 단순한 부분부터 읽고, 필요한 문법을 그때 연결해 보세요.

## 2. 개발 여정: 화면에서 데이터 보존까지

[개발 기록](../DEVELOPMENT-LOG.md)은 기능을 추가한 이유와 당시 한계를 남긴 문서입니다. 과거에 “아직 없음”이라고 쓴 기능이 나중에 구현되기도 했으므로 현재 기능표와 함께 읽어 보세요.

| 단계 | 만들어 온 것 | 그 과정에서 배울 지식 |
| --- | --- | --- |
| 읽는 화면 | 1·2페이지 보기, 다중 페이지 개요, 확대·이동, 썸네일(thumbnail) | 좌표, 이벤트, 화면 배치, 지연 렌더링(lazy rendering) |
| 여러 문서 | 독립 탭, 탭 스택, 작업 공간, 2~4개 비교 | 식별자(identifier), 상태를 관리하는 주체, 배열(array), 참조(reference) 공유 |
| 편집 기능 | 주석, 텍스트·이미지 추가, 서명, 페이지 조립 | 객체 모델(object model), 좌표 변환, 사용자 동작을 하나의 편집으로 묶는 기준 |
| 작업 보존 | 문서별 실행 취소, 저장 실패 처리, 외부 변경 충돌 검사 | 스택(stack), 명령 패턴(command pattern), 저장 지점, 실패해도 유지해야 하는 불변 조건(invariant) |
| 다시 열기·큰 파일 | 세션(session) 복원, 복구 사본, 비활성 문서 휴면 | 직렬화(serialization), 객체 수명(lifetime), 캐시(cache), 메모리 사용량 제한 |
| 공부 기능 | 유니코드(Unicode) 검색, 로컬 OCR, 선택적 외부 AI·플러그인(plugin) | 문자열, 비동기 작업(asynchronous task), 취소, 권한 확인 |
| 최근 사용성 수정 | 비정상 글꼴 선택 보정, OCR 오류 재인식, OCR 페이지 범위 | 오류를 재현하는 최소 사례(minimal reproduction), 외부 라이브러리(library)의 한계, 회귀 테스트(regression test) |

최근 사례는 특히 좋은 학습 자료입니다. 선택 영역이 큰 파란 띠가 되는 문제는 [선택 보완 기록](../REGION-SELECTION-2026-09-23.md)에, 보이는 ‘췌장’을 검색하지 못하는 문제는 [OCR 오류 수정 기록](../OCR-TEXT-REPAIR-2026-09-25.md)에 원인과 검사 범위가 정리되어 있습니다. 전자는 선택 좌표가 잘못된 문제였고, 후자는 PDF 속 기존 검색 텍스트가 잘못된 문제였습니다. 겉으로는 똑같이 “글자가 이상하다”는 증상으로 보여도 원인이 발생한 부분은 다를 수 있습니다.

## 3. 현재 구현과 한계

다음 표의 **구현**은 해당 사용자 동작을 처리하는 코드가 있다는 뜻입니다. 모든 문서·기기·외부 앱에서 완전히 검증됐다는 뜻은 아닙니다.

| 상태 | 기능 | 정확한 범위 |
| --- | --- | --- |
| 구현 | PDF 읽기와 작업 공간 | 탭·스택·주제별 작업 공간, 비교, 다양한 페이지 보기, 검색, 최근 문서와 세션 복원 |
| 구현 | 페이지 편집과 주석 | 재정렬·회전·삭제·추출·병합, 자유 텍스트·이미지·잉크·학습 표식·그래픽 서명 |
| 구현 | 되돌리기·저장 보호 | 기본 22개 편집 이력, 저장 지점 추적, 외부 변경 시 덮어쓰기 차단, 별도 저장과 로컬 복구 사본 |
| 구현 | 로컬 OCR | 지원 언어 조회, 전체·현재·직접 지정 페이지, 진행·취소·재개, 현재 문서에 적용 또는 새 PDF 저장 |
| 구현 | 이미지·HTML 기반 PDF 조립 | 입력 순서 관리, 빈 페이지·선택한 PDF 페이지 조립, 처리 방식 선택, 선택적 OCR |
| 구현 | 외부 AI·선언형 플러그인(declarative plugin) | 전송 내용 확인, 탭별 대화·문맥, 앱이 권한을 확인하고 직접 실행하는 명령·패널 |
| 부분 구현 | PDF 본문·이미지 편집 | 새 주석과 이미지 스탬프를 추가·수정합니다. 원래 콘텐츠 스트림(content stream)의 글자·이미지 객체를 직접 편집하는 엔진은 없습니다. |
| 부분 구현 | Word·PowerPoint 변환 | PDF 페이지 이미지를 문서에 배치합니다. 편집 가능한 문단·표·도형 구조를 복원하지는 않습니다. |
| 부분 구현 | 서명과 클라우드 | 눈에 보이는 그래픽 서명과 시스템 파일 선택 창의 클라우드 위치를 지원합니다. 인증서 기반 디지털 서명(digital signature)이나 자체 OAuth 인증을 사용하는 파일 탐색기는 없습니다. |
| 부분 구현 | 큰 파일과 복구 | 메모리 사용량 제한·휴면·복구 기능은 있지만, 모든 크기의 PDF를 장시간 안정적으로 처리하거나 아직 확정하지 않은 입력을 완전히 복구한다고 보장하지는 않습니다. |
| 미구현·향후 | 고급 편집 | 안전한 영구 삭제, 원래 본문 재배치, 인증서 검증, 변경된 문서의 자동 비교·병합 |
| 미구현·향후 | 다른 플랫폼·엔진 | iPad 앱, 대체 로컬 OCR 엔진 다운로드·선택, Rust를 앱과 연결해 실행하는 기능 |

OCR에서는 특히 세 가지 과정을 구분해야 합니다. **인식**은 글자를 알아내는 과정, **적용**은 열린 문서를 바꾸는 과정, **저장**은 파일에 쓰는 과정입니다. OCR을 끝냈다고 원본 파일이 즉시 바뀌는 것은 아닙니다.

최신 [페이지 선택 구현](../OCR-PAGE-SCOPE-2026-09-25.md)은 선택하지 않은 페이지와 새 인식 결과가 없는 페이지를 보존합니다. 새 OCR 결과로 교체하는 페이지에서는 화면에 보이는 주석 모양을 페이지 내용에 합칩니다. 이 과정을 평면화(flattening)라고 합니다. 교체한 페이지의 링크·입력 양식·댓글은 사용자가 클릭하거나 수정할 수 있는 기능으로 유지되지 않습니다. 따라서 “OCR이 기존 문서의 모든 기능을 그대로 보존한다”는 설명은 부정확합니다.

또한 스캔 이미지에 보이는 글자와 PDF에 숨겨진 검색 텍스트는 다를 수 있습니다. 기존 글자를 건너뛰는 OCR 설정을 사용하면 잘못된 이전 인식 결과도 남을 수 있습니다. 기본 재인식과 결과 교체가 추가된 이유입니다. OCR 진행 기록은 사용자 컴퓨터에 저장되며, 현재 [설정 화면](../../Sources/HwattakPDF/Views/SettingsView.swift)에는 기록 삭제 기능이 있습니다. 과거 초기 사용 안내(온보딩, onboarding) 문서의 “삭제 UI 없음”은 현재 소스와 다릅니다. 여기서 사용자 인터페이스(user interface, UI)는 사용자가 앱을 조작하는 화면과 메뉴 등을 뜻합니다.

## 4. 폴더를 책임으로 읽기

```text
Package.swift                 무엇을 빌드하는지 선언
Sources/HwattakPDF/App/       앱 시작, 창, 메뉴, 종료 보호
Sources/HwattakPDF/Views/     화면과 사용자 입력
Sources/HwattakPDF/Models/    상태, 값, 정책, 작은 알고리즘
Sources/HwattakPDF/Services/  OCR, 저장, 변환, 파일·외부 서비스 처리
Sources/HwattakPDF/Plugins/   플러그인 형식, 권한, 실행 정책
Resources/                   번역, 이미지, Info.plist, 앱 권한
Tests/HwattakPDFTests/        동작별 자동 검사
scripts/                     빌드·배포·검사 작업
Documentation/               제품 범위, 설계, 개발·검증 기록
```

폴더 이름만으로 역할이 완벽하게 나뉘는 것은 아닙니다. 예를 들어 `PDFWorkspaceState`에는 상태뿐 아니라 편집·저장·OCR 작업을 조정하는 메서드(method)도 있습니다. 처음부터 그 파일을 끝까지 읽기보다, 아래 표에 있는 심벌(symbol)을 검색해 보세요. 심벌은 함수·타입·속성 등 코드에서 이름으로 식별하는 요소입니다.

| 읽을 코드 | 먼저 찾을 심벌 | 확인할 질문 |
| --- | --- | --- |
| [HwattakPDFApp.swift](../../Sources/HwattakPDF/App/HwattakPDFApp.swift) | `HwattakPDFApp` | 어떤 창과 메뉴가 있는가? |
| [TabbedWorkspaceView.swift](../../Sources/HwattakPDF/Views/TabbedWorkspaceView.swift) | `TabbedWorkspaceView` | 여러 탭 중 어느 문서를 화면에 보여 주는가? |
| [MultiDocumentWorkspaceState.swift](../../Sources/HwattakPDF/Models/MultiDocumentWorkspaceState.swift) | `MultiDocumentWorkspaceState` | 탭과 작업 공간을 어디에서 관리하는가? |
| [WorkspaceView.swift](../../Sources/HwattakPDF/Views/WorkspaceView.swift) | `WorkspaceView` | 한 문서의 화면은 어떤 요소로 구성되는가? |
| [PDFWorkspaceState.swift](../../Sources/HwattakPDF/Models/PDFWorkspaceState.swift) | `startOCR`, `saveSynchronously`, `undo` | 문서 작업을 어디에서 조정하는가? |
| [OCRPageSelection.swift](../../Sources/HwattakPDF/Models/OCRPageSelection.swift) | `resolve`, `compactDescription` | 입력 문자열을 어떻게 인덱스(index)로 바꾸는가? |
| [PDFEditHistory.swift](../../Sources/HwattakPDF/Models/PDFEditHistory.swift) | `register`, `undo`, `markSaved` | 변경과 저장 지점을 어떻게 기억하는가? |
| [VisionOCRService.swift](../../Sources/HwattakPDF/Services/VisionOCRService.swift) | `recognize` | 오래 걸리는 작업을 화면 처리와 어떻게 분리하는가? |
| [AtomicPDFWriter.swift](../../Sources/HwattakPDF/Services/AtomicPDFWriter.swift) | `AtomicPDFWriter` | 어떤 검사를 마친 뒤 파일을 교체하는가? |
| [PDFSourceFileVersion.swift](../../Sources/HwattakPDF/Services/PDFSourceFileVersion.swift) | `PDFSourceFileVersion` | 다른 앱이 바꾼 파일을 어떻게 알아보는가? |

## 5. 기능 하나를 끝까지 추적하기: ‘현재 페이지만 OCR’

100페이지짜리 PDF에서 화면에 51쪽이 보인다고 가정해 보세요. 사용자가 현재 페이지만 OCR한 뒤 결과를 열린 PDF에 적용합니다.

```text
OCRSheet: 범위·언어 선택
    ↓
OCRPageSelection.resolve: 화면의 선택 → 원본 인덱스 [50]
    ↓
PDFWorkspaceState.startOCR: 권한·상태 확인, 문서 스냅샷, 작업 시작
    ↓
VisionOCRService: 선택한 페이지 인식 → OCRCheckpointStore에 진행 기록
    ↓
PDFWorkspaceState: 결과의 문서·설정·페이지 범위 일치 확인
    ↓ 사용자가 ‘현재 PDF에 적용’을 선택
applySearchableOCRToCurrentDocument → PDFOCRApplication
    ↓
교체할 페이지 반영 + PDFEditHistory 등록 + 화면 상태 갱신
    ↓ 사용자가 저장
원본 외부 변경 검사 → PDF 직렬화·검증·쓰기 → 저장 지점 갱신
```

여기서 배울 점은 다섯 가지입니다.

1. **번호 변환:** 화면의 51쪽은 내부 배열에서 인덱스가 50인 페이지입니다. 현재 페이지는 이미 0부터 시작하는 인덱스로 관리하므로 그대로 사용합니다. 사용자가 직접 입력한 페이지 번호는 입력을 해석하는 파서(parser)에서 인덱스로 변환합니다.
2. **입력 검증:** 페이지가 문서 범위 안인지 확인한 뒤 작업을 시작합니다. 실패를 일찍 발견하면 시간과 자원이 많이 드는 OCR을 불필요하게 실행하지 않습니다.
3. **작업 사본:** 화면이 사용하는 `PDFDocument`를 여러 작업이 동시에 바꾸지 않도록 인식용 스냅샷(snapshot)을 만듭니다. 스냅샷은 특정 시점의 문서 상태를 따로 보관한 사본입니다.
4. **늦게 도착한 결과:** OCR 중 문서나 설정이 달라질 수 있습니다. 작업이 끝났다는 이유만으로 결과를 적용하지 않고, 시작할 때의 대상과 맞는지 다시 확인합니다.
5. **메모리와 파일의 구분:** 현재 문서에 적용하면 되돌릴 수 있는 편집이 생깁니다. 파일에 쓰는 작업은 별도의 저장 절차를 따릅니다.

실제로 따라 읽을 파일은 [OCRSheet](../../Sources/HwattakPDF/Views/OCRSheet.swift), [PDFWorkspaceState](../../Sources/HwattakPDF/Models/PDFWorkspaceState.swift), [PDFOCRApplication](../../Sources/HwattakPDF/Services/PDFOCRApplication.swift)입니다. 처음에는 각 함수의 `guard`, 다음에 호출하는 함수, 성공·실패 상태만 표시해 보세요. 좌표 수식이나 PDF 그리기의 세부 구현을 나중에 읽어도 전체 흐름을 이해할 수 있습니다.

## 6. 연습과 해설

### 연습 1 — 파일을 어디에서 찾을까

“OCR에 `3-5`를 입력했는데 2·3·4쪽이 처리되는 것 같다”는 제보가 왔습니다. 가장 먼저 읽을 파일 하나와, 그다음 확인할 테스트 하나를 골라 보세요.

**해설:** [OCRPageSelection.swift](../../Sources/HwattakPDF/Models/OCRPageSelection.swift)의 `resolve`와 [OCRPageSelectionTests.swift](../../Tests/HwattakPDFTests/OCRPageSelectionTests.swift)의 `testCustomSelectionNormalizesRangesWhitespaceAndDuplicates`부터 읽습니다. `[2, 3, 4]`라는 내부 결과 자체는 올바릅니다. 화면에 다시 보여 줄 때 `+1`을 빠뜨렸는지, 실제 처리 대상이 틀렸는지는 그다음에 구분해야 합니다.

### 연습 2 — 기능 설명을 정확하게 고치기

“우리 앱은 PDF 원문을 Word처럼 수정하고, OCR하면 모든 페이지의 양식과 링크를 그대로 보존한다”를 현재 구현에 맞는 두 문장으로 고쳐 보세요.

**해설:** “PDF 위에 텍스트·이미지 주석을 추가하고 페이지를 편집할 수 있습니다. OCR은 선택한 페이지의 검색 텍스트를 갱신하며, 결과로 교체한 페이지에서는 주석의 모양이 페이지 내용에 합쳐지고 링크·양식·댓글의 조작 기능은 유지되지 않습니다.” 기능을 작은 동작으로 나누어 구체적으로 설명하는 것이 정확한 제품 설명과 테스트 설계의 출발점입니다.

### 연습 3 — 어디가 바뀌었는지 말하기

OCR을 끝내고 현재 문서에 적용했지만 저장 버튼을 누르지 않았습니다. 무엇이 바뀌었으며, 원본을 읽던 다른 앱에도 즉시 같은 결과가 보일지 설명해 보세요.

**해설:** 열린 앱의 메모리에 있는 문서가 바뀌고 편집 이력이 생깁니다. 일반 파일 저장은 아직 하지 않았으므로 다른 앱이 원본 파일에서 즉시 같은 결과를 읽는다고 볼 수 없습니다. 복구 사본은 일반 저장과 목적도 다르고 저장 위치도 다릅니다.

## 다음 읽기

이 장의 지도를 옆에 두고 작은 함수 → 한 문서의 상태 → 오래 걸리는 작업 순서로 읽어 보세요. 더 큰 설계도는 [아키텍처(architecture)](../ARCHITECTURE.md), 제품의 세부 범위는 [제품 정의](../PRODUCT.md)에서 확인할 수 있습니다. 검증 결과를 해석하는 방법은 [06. 테스트와 디버깅](06-TESTING.md)으로 이어집니다.
