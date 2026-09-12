# HwattakPDF에 기여하기

HwattakPDF에 관심을 가져 주셔서 감사합니다. 이 프로젝트는 PDF를 오래 읽고 공부하는 사람이 핵심 기능을 구독 없이 사용할 수 있게 하려는 macOS 앱입니다. 처음 오픈소스에 기여하는 사람도 따라올 수 있도록 작은 변경의 이유와 검증 방법까지 함께 남기는 것을 중요하게 생각합니다.

HwattakPDF는 [Mozilla Public License 2.0](LICENSE)으로 공개됩니다. Pull Request를 제출하면 자신이 작성했거나 해당 조건으로 제공할 충분한 권리가 있는 기여를 MPL-2.0 조건으로 프로젝트에 제공하는 데 동의하는 것으로 봅니다. 현재 별도 CLA나 DCO 서명은 요구하지 않습니다. 이미지·문서·테스트 자료에는 타인의 저작권이나 개인정보가 포함되지 않도록 하고, 새 자산의 제작자·출처·라이선스를 PR에 기록해 주세요.

## 1. 기여 전에 읽을 문서

- [README](README.md): 지원 기능, 실행법, 중요한 제품 한계
- [제품 정의](Documentation/PRODUCT.md): 사용자 문제와 기능 범위
- [아키텍처](Documentation/ARCHITECTURE.md): 상태 소유권, PDFKit 경계, 저장·OCR 구조
- [처음 기여자를 위한 코드 안내](Documentation/ONBOARDING.md): 폴더별 역할과 변경 순서
- [보안 정책](SECURITY.md): 공개 이슈로 올리면 안 되는 내용
- [행동 강령](CODE_OF_CONDUCT.md): 협업 규칙

버그라면 먼저 같은 증상의 이슈가 있는지 검색해 주세요. 보안 취약점이나 민감한 PDF가 필요한 재현 사례는 공개 이슈에 올리지 말고 `SECURITY.md`의 비공개 절차를 사용합니다.

## 2. 개발 환경

- macOS 14 이상
- Xcode 26.3 또는 그에 포함된 호환 Swift 도구 모음
- Apple Silicon Mac이 권장됩니다. SwiftPM 테스트는 다른 Mac 아키텍처에서도 실행할 수 있지만 현재 `build_app.sh`의 배포 ZIP 검증 대상은 `arm64`입니다.

```bash
swift --version
./scripts/run_test_batches.sh
swift run VibePDF
```

macOS 15의 PDFKit/AppKit 테스트 호스트는 여러 UI 테스트를 한 프로세스에서 연속 실행한 뒤 teardown 중 충돌할 수 있습니다. 전체 검증에는 클래스를 독립 프로세스로 격리하는 `run_test_batches.sh`를 사용하고, 개발 중 관련 클래스 하나만 확인할 때 `swift test --disable-sandbox --filter <TestClass>`를 사용합니다.

`VibePDF`는 초기 프로토타입의 내부 SwiftPM 타깃 이름이고, 사용자에게 보이는 앱 이름은 `HwattakPDF`입니다. 이름이 다른 것은 오류가 아닙니다.

## 3. 권장 작업 흐름

1. 하나의 이슈 또는 하나의 명확한 문제만 고릅니다.
2. 현재 동작을 재현하고, 가능하면 실패하는 작은 테스트를 먼저 추가합니다.
3. [아키텍처 불변 조건](Documentation/ARCHITECTURE.md)을 깨지 않는 가장 작은 변경을 만듭니다.
4. 새 분기·오류·경계값을 테스트하고 앱에서 직접 확인합니다.
5. 사용자 문구가 바뀌면 10개 현지화 파일과 도움말을 함께 갱신합니다.
6. PR 설명에 “무엇”, “왜”, “어떻게 검증했는지”, “남은 한계”를 씁니다.

추천 브랜치 이름 예시:

```text
fix/save-provider-conflict
feat/search-result-filter
docs/explain-ocr-checkpoints
test/rotated-page-fixture
```

## 4. 코드와 주석 원칙

이 저장소의 주석은 코딩을 배우는 사람에게도 도움이 되어야 합니다. 특히 다음 내용은 코드 가까이에 설명합니다.

- 이 타입이 어떤 상태를 **소유**하고 누가 변경할 수 있는지
- `@MainActor`, detached task, 취소 토큰이 필요한 **동시성 이유**
- PDF 좌표, SwiftUI/AppKit 좌표, Vision 정규화 좌표를 바꾸는 방법
- security-scoped resource, Keychain, 원자 교체 우선 저장과 직접 쓰기 fallback의 수명·실패 처리
- 메모리 상한이나 결과 상한이 존재하는 이유
- PDFKit의 동작을 우회할 때 유지해야 하는 불변 조건
- 단순해 보이는 코드가 회귀를 막는 테스트와 연결되는 이유

좋은 주석은 문법을 그대로 읽어 주기보다 선택의 이유를 설명합니다.

```swift
// 나쁨: index에 1을 더한다.
let pageNumber = index + 1

// 좋음: 모델은 0부터 세지만 사용자가 보는 PDF 페이지 번호는 1부터 센다.
let pageNumber = index + 1
```

공개 타입과 독립적으로 이해하기 어려운 알고리즘에는 `///` 문서 주석을 사용합니다. 반대로 모든 괄호나 대입문에 주석을 붙이면 실제 규칙이 묻히고 코드가 바뀔 때 거짓말이 되기 쉽습니다. 코드 변경 시 주변 주석도 테스트처럼 함께 갱신합니다.

## 5. HwattakPDF에서 특히 조심할 점

### PDFKit과 메인 액터

화면이 사용하는 살아 있는 `PDFDocument`, `PDFPage`, `PDFAnnotation`, `PDFSelection`을 임의의 백그라운드 스레드에서 만지지 않습니다. 긴 계산은 메인 액터에서 불변 문자열이나 `Data` 스냅샷을 만든 뒤 worker로 넘깁니다. 늦게 끝난 작업은 문서 revision·query·generation을 다시 확인하고 폐기해야 합니다.

### 저장과 원본 보호

목적지 파일에 직접 조금씩 덮어쓰지 않습니다. 같은 원본을 덮어쓸 때 `PDFSourceFileVersion` baseline을 coordinated accessor 안에서 비교하는 경로와 `AtomicPDFWriter`의 저장 후 재열기 검증을 유지합니다. 외부 변경 충돌에서는 상대 앱이 저장한 bytes와 HwattakPDF의 dirty 메모리 편집을 모두 보존해야 합니다. “저장 성공” UI는 실제 파일 검증보다 먼저 표시하면 안 됩니다.

### 실행 취소

사용자가 만드는 편집은 가능하면 `PDFEditHistory` 명령으로 등록합니다. 적용·역적용이 같은 객체와 좌표를 정확히 복구하는지, 저장 지점으로 되돌아갔을 때 dirty 표시가 사라지는지 테스트합니다. 문서 전체 사본을 명령마다 보관해 22단계 이력을 구현하지 않습니다.

### 보안과 개인정보

API 키, security-scoped bookmark, 실제 사용자 PDF, OCR 원문을 로그나 fixture에 넣지 않습니다. 외부 AI 전송 범위와 MCP 승인 단계를 줄이는 변경은 기능 개선이 아니라 보안 경계 변경이므로 별도 검토가 필요합니다.

### 현지화와 접근성

사용자 문구는 `Resources/Localization/*.lproj/Localizable.strings`에 키로 추가합니다. 한국어를 기준으로 영어·프랑스어·독일어·스페인어·일본어·중국어 간체·아랍어·포르투갈어·베트남어 키 집합을 맞춥니다. 아이콘만 있는 버튼에는 VoiceOver 레이블과 도움말을 제공합니다. 아랍어처럼 오른쪽에서 왼쪽으로 쓰는 환경도 확인합니다.

## 6. 검증

가장 작은 관련 테스트부터 실행한 뒤 전체 테스트를 실행합니다.

```bash
swift test --disable-sandbox --filter PDFDocumentSearchTests
./scripts/run_test_batches.sh
./scripts/validate_project.sh
```

UI 변경은 자동 테스트만으로 충분하지 않습니다. 관련 PDF 유형과 조작을 [릴리스 체크리스트](Documentation/RELEASE-CHECKLIST.md)에서 골라 직접 확인하고, PR에 사용한 macOS·앱 버전·샘플 특성을 기록합니다. 저작권 또는 개인정보가 있는 PDF 자체를 첨부하지 마세요.

## 7. 커밋과 Pull Request

커밋 제목은 짧은 명령형으로 작성하고 필요하면 본문에 이유를 씁니다.

```text
Fix stale search results after page rotation
Document OCR checkpoint ownership
Add regression test for grouped-tab tear-out
```

PR은 가능한 한 작게 유지하고 다음 내용을 포함합니다.

- 사용자에게 달라지는 점
- 원인 또는 설계 판단
- 자동 테스트와 수동 확인 결과
- 성능·메모리·접근성·개인정보 영향
- 의도적으로 남긴 후속 작업

큰 구조 변경, 새 네트워크 공급자, 외부 바이너리·모델·Swift 패키지 추가는 구현 전에 이슈에서 설계를 합의해 주세요. 의존성은 라이선스, 앱 크기, 네트워크·샌드박스 권한, 유지보수 상태까지 함께 검토합니다.

## 8. 문서만 고치는 기여

오탈자, 초보자 설명, 재현 가능한 사용 예시, 접근성 안내도 중요한 기여입니다. 문서에서 현재 구현과 미래 계획을 섞지 말고 다음 표현을 구분해 주세요.

- **구현**: 현재 앱에 동작 경로와 검증 근거가 있음
- **부분 구현**: 제한된 형태로만 동작함
- **다음 단계**: 설계 또는 아이디어이며 아직 동작하지 않음

감사합니다. 작은 재현 사례와 정직한 한계 기록이 HwattakPDF를 오래 유지할 수 있게 만듭니다.

## 플러그인으로 기여하기

앱 전체를 수정하지 않고 명령·템플릿 패키지부터 만들 수 있습니다. [플러그인 제작 가이드](Documentation/PLUGIN-DEVELOPMENT.md), [English](Documentation/PLUGIN-DEVELOPMENT.en.md), [커뮤니티 예제](Examples/Plugins/README.md)를 참고하세요. 지원하지 않는 기능은 [호환성 문서의 API 제안 절차](Documentation/PLUGIN-COMPATIBILITY.md)에 따라 구체적인 입력·결과·권한·취소·Undo·자원 예산을 설명합니다. 일반 이슈 선택 화면의 플러그인 API 제안 양식을 사용할 수 있습니다.

제작 문서의 전체 JSON manifest와 커뮤니티 예제는 `PluginAuthoringTests`에서 앱 검사기로 확인합니다. 지원 계약을 바꾸는 기여는 예제와 문서도 함께 갱신해 주세요. 보안 제보는 기존 비공개 절차를 따릅니다.
