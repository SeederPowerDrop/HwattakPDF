# HwattakPDF 플러그인 설치와 형식 참조

처음 제작한다면 [제작 가이드](PLUGIN-DEVELOPMENT.md)에서 시작한다. [English](PLUGIN-DEVELOPMENT.en.md) · [schema 3 명령](PLUGIN-HOST-API.md) · [보안](PLUGIN-SECURITY.md) · [호환성/확장 제안](PLUGIN-COMPATIBILITY.md) · [예제 지도](../Examples/Plugins/README.md). 이 문서는 기존 설치 관리와 schema 1·2의 상세 형식을 유지한다.

> 0.9.0 배포 경계: 앱 번들에는 번역 도우미·웹 브라우저와 문서 명령 플러그인 3종의 검토본을 포함한다. YouTube 학습 manifest는 보안 검토용 소스 전용 예제이고 호스트 지원 코드는 활성화할 번들 검토본 없이 대기한다. 앱 개인정보처리방침·이용약관·사전 동의와 상시 정책 링크를 완성하기 전에는 공식 기본 플러그인으로 배포·설치하지 않는다.

HwattakPDF 0.9.0 (build 19)은 manifest schema 1·2·3을 함께 지원한다. 모든 스키마는
네이티브 번들·JavaScript·Wasm 같은 **패키지 코드를 실행하지 않는다**.
`.hwattakplugin`의 `manifest.json`을 호스트 앱이 엄격하게 검증하고, 사용자가 메뉴에서
고른 순간에만 제한된 host action을 실행한다.

- schema 1(v1)은 기존 선언형 텍스트 템플릿과 `showText`·`copyText`·`openURL`을 그대로
  지원한다. 패키지는 백그라운드 작업, 셸, Keychain, 원본 PDF 바이트, 직접 네트워크
  요청과 GPU 접근을 할 수 없으며 `openURL`은 기본 브라우저로만 넘긴다.
- schema 2 구현은 앱이 소유한 번역·웹 브라우저 패널과 미배포 YouTube 호스트 경계를
  선택한다. 0.9.0 번들은 앞의 두 패널만 활성화할 검토본을 제공한다. 패키지에 패널
  코드나 HTML은 없지만, 열린 패널의 원격 사이트는 WebKit 안에서 네트워크와
  JavaScript를 사용한다. 따라서 v1의 “직접 네트워크 없음” 경계를 v2 원격 웹 세션까지
  확대해 해석하면 안 된다.

- schema 3은 현재 문서에 하이라이트·밑줄을 추가하고 펜·모드·페이지 이동을 요청한다. 일반 커뮤니티 패키지도 사용할 수 있으며 새 코드를 실행하지 않는다. [명령 참조](PLUGIN-HOST-API.md).

이 문서는 현재 `Sources/HwattakPDF/Plugins/`와 `Views/PluginPanelHostView.swift` 구현의
schema 1·2 규칙과 공통 관리 기능을 설명한다. schema 3의 문서 명령, ⇧⌘P 팔레트, 필압 입력과 직접 만드는 예제는 [문서 명령 API 가이드](PLUGIN-HOST-API.md)에 있다.

## 사용자 가이드

### 설치

1. 배포자가 제공한 **디렉터리 형태**의 `이름.hwattakplugin` 패키지를 준비한다. ZIP은
   먼저 풀어야 하며, 일반 파일이나 심볼릭 링크는 패키지로 인정하지 않는다.
2. 앱의 `플러그인 > 플러그인 관리…`(`⇧⌘,`) 또는 설정의 플러그인 영역을 연다.
3. `플러그인 설치…`(`⇧⌘I`)를 눌러 패키지 디렉터리를 고른다.
4. 앱이 표시하는 이름·버전·작성자·설명, 요청 권한, 파일 수·크기와 매니페스트
   SHA-256 앞부분을 검토한 뒤 설치한다.
5. PDF 창 상단의 `플러그인` 버튼 또는 macOS 메뉴 막대의 `플러그인`에서 실행한다.
   action이 하나뿐인 배포 패키지(현재 웹 브라우저)는 플러그인 이름을 누르면 바로 PDF
   오른쪽 패널로 열린다. 문서나 텍스트 선택이 필요한 액션은 조건이 갖춰지기 전까지
   비활성화되며, 읽기 전용 비교 화면에서도 문서 문맥 action은 실행할 수 없다.

설치 위치는 현재 사용자 Application Support의 `HwattakPDF/Plugins` 디렉터리다.
샌드박스 배포에서는 이 경로가 앱 컨테이너 안에 있을 수 있으므로 경로를 추측하지 말고
관리 창의 `플러그인 폴더 열기`를 사용한다.

설치 검토 화면의 SHA-256은 선택한 `manifest.json` 바이트를 식별하고 설치 후 변경을
감지하기 위한 값이다. **게시자 신원, 코드 서명, 공증, 패키지의 신뢰성을 인증하지
않는다.** 신뢰할 수 있는 출처인지 사용자가 별도로 판단해야 한다.

웹 패널 출력(`translatePanel`·`youtubePanel`·`browserPanel`)이 있거나 HwattakPDF의
`dev.hwattakpdf.` 식별자 영역을 주장하는 패키지에는 더 좁은 설치 규칙이 적용된다.
앱 번들의 `Contents/Resources/BundledPlugins`에 들어 있는 검토본 중 **같은
`identifier`와 같은 `manifest.json` SHA-256 digest**를 가진 패키지만 설치되고,
검토 화면을 띄우기 전과 설치·시작·새로 고침 때 같은 조건을 다시 확인한다. 이름만
같거나 manifest가 한 바이트라도 다른 외부 패키지는 schema 1이어도 거부된다. 이
allowlist는 앱이 검토한 패널 선택지와 공식 이름의 사칭을 막지만, 일반 SHA-256 자체가
게시자 서명으로 바뀌는 것은 아니다.

### 0.9.0 기본 플러그인 검토 및 설치

0.9.0 (build 19) 앱 번들은 다음 다섯 검토본을 포함하지만 자동 설치하거나 자동
활성화하지 않는다.

| 기본 플러그인 | 식별자 | 분리된 핵심 권한 |
| --- | --- | --- |
| 번역 도우미 | `dev.hwattakpdf.plugins.translation-companion` | `translationService`와 선택한 입력에 따른 `selectedText` 또는 `currentPageText`; ChatGPT·Claude 흐름 때문에 `clipboardWrite`도 명시 |
| 웹 브라우저 | `dev.hwattakpdf.plugins.web-browser` | `embeddedWebBrowser` |
| Study Markup | `dev.hwattakpdf.plugins.study-markup` | `annotationWrite` |
| Tablet Tools | `dev.hwattakpdf.plugins.tablet-tools` | `toolControl`, `workspaceNavigation` |
| Reading Navigation | `dev.hwattakpdf.plugins.reading-navigation` | `workspaceNavigation` |

`Examples/Plugins/YouTubeStudy.hwattakplugin`은 소스 검토용 예제다. 0.9.0 앱에도 같은
identifier와 digest를 가진 번들 검토본이 없으므로 설치·실행할 수 없다.

설치 순서는 다음과 같다.

1. 앱에서 `플러그인 > 플러그인 관리…`를 연다.
2. `HwattakPDF 기본 플러그인`에서 원하는 항목의 설명과 권한을 읽는다.
3. `검토 및 설치`를 누르고 identifier, 버전, 권한, 파일 정보와 SHA-256을 다시 확인한다.
4. 설치 후 PDF 툴바의 `플러그인`에서 이름을 선택한다. 단일 action 기본 플러그인은
   별도 하위 메뉴 없이 바로 오른쪽 패널을 연다. 모든 v2 패널은 열린 PDF가 있어야 하며,
   번역은 보기 또는 학습 모드에서만 시작할 수 있다.

### 검색과 플러그인별 설정

관리 창의 설치 목록은 이름·설명·제작자·식별자·버전으로 검색할 수 있다. 각 행의
톱니바퀴를 누르면 활성 상태, 선언된 권한, 제공 action, 버전·제작자·식별자·설치일을
한 화면에서 확인한다. 일반 schema 1 플러그인은 별도의 임의 설정 UI를 만들 수 없고,
호스트가 제공하는 이 공통 정보와 활성 상태만 관리한다.

현재 앱 번들과 identifier 및 manifest digest가 정확히 일치하는 두 기본 플러그인에는
호스트가 소유한 다음 옵션이 추가된다.

- 번역 도우미: 기본 서비스(Google 번역·ChatGPT·Claude), 기본 대상 언어, 원문 영역을
  펼친 상태로 시작할지 선택
- 웹 브라우저: 기본 검색 엔진(Google·DuckDuckGo·Bing), 검색 시작 페이지를 자동으로
  불러올지 선택

옵션은 PDF나 플러그인 패키지의 `manifest.json`에 쓰지 않고 현재 사용자 설정에
identifier별로 저장한다. 비활성화와 검토된 업데이트 뒤에는 유지되며, 명시적으로
제거하면 함께 삭제된다. API 키나 로그인 쿠키를 저장하는 용도가 아니다. 공개 HTTPS
제한, 비영구 WebKit 세션, 업로드·다운로드 차단, 외부 링크 확인, YouTube 개인정보
보호 강화 재생 같은 보안 정책은 설정으로 끌 수 없다. 같은 identifier를 사칭한 외부
패키지에는 기본 플러그인 전용 옵션이 나타나거나 적용되지 않는다.

### 업데이트

같은 `identifier`를 가진 새 `.hwattakplugin`을 다시 선택하면 설치 검토 화면이
`업데이트`로 바뀐다. 앱은 검토할 때 읽은 최대 2 MiB의 허용 파일 바이트를 보관했다가
그 **동일한 바이트**를 staging 디렉터리에 쓰고 재검증한 뒤 기존 패키지를 교체한다.
교체 중 실패하면 임시 backup에서 이전 패키지를 복원하려고 시도하고, 다음 실행의
새로 고침에서도 중단된 staging·backup 상태를 정리한다.

서드파티 패키지에는 카탈로그, 자동 다운로드, 업데이트 알림, 배포자 서명 검증이 없다. 또한
`version`이 `major.minor.patch` 형식인지만 확인하며 새 버전이 기존 버전보다 큰지는
검사하지 않는다. 따라서 같은 버전이나 낮은 버전으로도 교체할 수 있으므로 검토 화면의
버전을 직접 확인해야 한다. 같은 식별자의 비활성 상태는 업데이트 뒤에도 유지된다.

### 비활성화와 다시 활성화

관리 창에서 플러그인 오른쪽의 스위치를 끄면 패키지는 남아 있지만 액션이 플러그인
메뉴에서 빠진다. 상태는 식별자 기준으로 사용자 설정에 저장되어 앱을 다시 실행해도
유지된다. 스위치를 다시 켜면 별도 재설치 없이 액션이 돌아온다. 현재 UI는 권한별 토글을
제공하지 않으므로 일부 권한만 철회하려면 플러그인을 비활성화하거나 제거해야 한다.

### 삭제

관리 창의 더보기(`…`) 메뉴에서 `플러그인 제거`를 누르고 확인하면 설치 디렉터리를 즉시
삭제하고 저장된 비활성 상태와 플러그인 옵션도 지운다. 이 작업은 휴지통으로 이동하는
복구형 삭제가 아니다. 손상되거나 수동으로
변경되어 `격리된 패키지` 목록에만 나타나는 항목은 액션으로 로드되지 않는다. 같은
식별자의 정상 패키지로 업데이트해 교체할 수 있으며, 그것이 불가능하면 관리 창의
`플러그인 폴더 열기`에서 정확한 패키지 이름을 확인한 뒤 앱을 종료하고 수동으로
정리한다. 격리된 항목도 아래의 32개 설치 slot을 차지한다.

## v1 개발자 빠른 시작

최소 패키지는 다음과 같다.

```text
QuickCitation.hwattakplugin/
└── manifest.json
```

동작하는 schema 1 전체 예시는 다음과 같다. 모두 빌드 단계 없이 디렉터리 자체를
설치한다.

- [Quick Citation](../Examples/Plugins/QuickCitation.hwattakplugin/manifest.json):
  세 가지 출력과 네 가지 권한을 한 번에 보여 주는 종합 예시
- [Markdown Quote](../Examples/Plugins/MarkdownQuote.hwattakplugin/manifest.json):
  선택 문장과 문서·페이지 정보를 Markdown 인용문으로 미리보기·복사하는 예시
- [Reference Search](../Examples/Plugins/ReferenceSearch.hwattakplugin/manifest.json):
  URL 인코딩한 선택 문장을 Wikipedia·Google Scholar에서 호출별 승인 후 검색하는 예시

확장자 검사는 대소문자를 구분하지 않지만 배포 패키지는 정규 표기인
`.hwattakplugin`을 사용한다.

선택 가능한 루트 파일은 아래 다섯 개뿐이다. 대소문자를 구분하고, 하위 디렉터리·숨김
파일·심볼릭 링크·추가 실행 파일은 거부한다.

```text
manifest.json   필수
README.md       선택, 현재 런타임 동작에 사용하지 않음
LICENSE         선택, 현재 런타임 동작에 사용하지 않음
LICENSE.md      선택, 현재 런타임 동작에 사용하지 않음
icon.png        선택, PNG signature만 검사하며 현재 UI에는 표시하지 않음
```

파일명은 Unicode NFC(precomposed) 형식이어야 한다. 설치할 때 앱이
`installation.json`을 추가하고 패키지 디렉터리를
`<identifier>.hwattakplugin`으로 바꾼다. 개발자가 `installation.json`을 원본
패키지에 넣으면 허용되지 않는다.

## manifest v1 스키마

`manifest.json`은 BOM 없는 UTF-8이어야 한다. JSON 루트와 각 action에서 알 수 없는
키를 무시하지 않고 설치를 거부하며, 모든 object의 중복 key도 거부한다. escape를 풀면
같아지는 key도 중복으로 취급하고 JSON nesting은 최대 64단계다. 아래의 모든 필드는
`minimumHostVersion`과 action의 `description`을 제외하면 필수다.

### 루트 필드

| 필드 | 형식과 규칙 |
| --- | --- |
| `schemaVersion` | 정수 `1` |
| `identifier` | UTF-8 1~128 bytes. ASCII 소문자로 시작하고 `[a-z0-9._-]`만 사용하며 점을 하나 이상 포함한다. `..`, 끝의 `.`·`-`는 허용하지 않는다. `com.vibepdf.`, `com.hwattakpdf.`, `dev.hwattakpdf.` prefix는 호스트용으로 예약되어 있다. 마지막 prefix의 검토본은 identifier+manifest digest가 앱 번들과 정확히 같아야 한다. 예: `dev.example.hwattakpdf.quick-citation` |
| `displayName` | 비어 있지 않은 일반 텍스트, 최대 160 UTF-8 bytes |
| `version` | `major.minor.patch`. 각 성분은 `0...999999`, `0` 외에는 앞에 0을 붙이지 않는다. prerelease/build suffix는 지원하지 않는다. |
| `author` | 비어 있지 않은 일반 텍스트, 최대 160 UTF-8 bytes |
| `description` | 비어 있지 않은 일반 텍스트, 최대 4,096 UTF-8 bytes. 줄바꿈과 tab을 허용한다. |
| `minimumHostVersion` | 선택. 같은 세 성분 버전 형식이며 현재 앱 버전보다 높으면 설치를 거부한다. |
| `capabilities` | 중복 없는 권한 문자열 배열. 모든 action이 실제로 요구하는 권한의 합집합과 **정확히 같아야** 한다. |
| `actions` | 1~24개의 action 객체 |

`displayName`·`author`·제목 같은 한 줄 필드에는 제어 문자를 사용할 수 없다. 설명은
LF(`\n`)와 tab만 예외로 허용한다. NUL, 좌우 표시 문자(U+200E/U+200F), bidi
embedding/override(U+202A~U+202E)와 isolate(U+2066~U+2069)는 모든 일반 텍스트
필드에서 거부해 검토 화면의 방향 위장을 줄인다.

### action 필드

| 필드 | 형식과 규칙 |
| --- | --- |
| `id` | 플러그인 안에서 고유한 UTF-8 1~128 bytes 식별자. ASCII 소문자로 시작하고 `[a-z0-9._-]`만 사용한다. 점은 필수가 아니며 `..`, 끝의 `.`·`-`는 금지한다. |
| `title` | 비어 있지 않은 한 줄 일반 텍스트, 최대 240 UTF-8 bytes |
| `description` | 선택. 비어 있지 않은 일반 텍스트, 최대 1,024 UTF-8 bytes. 메뉴 도움말로 사용한다. |
| `output` | `showText`, `copyText`, `openURL` 중 하나 |
| `template` | 비어 있지 않은 UTF-8 최대 16 KiB 문자열. LF와 tab 외의 제어 문자, 위 bidi format control과 알 수 없는 `{{...}}` 토큰을 허용하지 않는다. |

### 토큰

| 토큰 | 값 | 필요한 권한 |
| --- | --- | --- |
| `{{selection}}` | 현재 PDF에서 사용자가 선택한 텍스트. 실행 전에 공백이 아닌 선택이 필요하며 최대 4,000자로 snapshot한다. | `selectedText` |
| `{{selection.urlEncoded}}` | 선택 텍스트를 RFC 3986 unreserved 문자 외에는 percent-encode한 값 | `selectedText` |
| `{{document.name}}` | 현재 탭의 표시 이름. 최대 512자·2,048 UTF-8 bytes로 제한한다. | `documentMetadata` |
| `{{document.name.urlEncoded}}` | 표시 이름의 percent-encoded 값 | `documentMetadata` |
| `{{page.number}}` | 현재 페이지의 1부터 시작하는 번호 | `documentMetadata` |
| `{{document.pageCount}}` | 문서 전체 페이지 수 | `documentMetadata` |

문서 metadata나 선택 토큰을 쓰는 액션에는 열린 PDF가 필요하다. `openURL` 템플릿에
문서 이름이나 선택문을 넣을 때는 반드시 `.urlEncoded` 형태를 써야 한다. 숫자 페이지
토큰은 그대로 사용할 수 있다. 호스트는 **원본 template만 한 번 스캔**하며 가장 긴
허용 token을 일치시킨다. 원본 template에 알 수 없는 `{{...}}` 또는 짝이 맞지 않는
`}}`가 있으면 거부한다. 선택문·페이지 텍스트·문서 이름 같은 치환값은 불투명한 일반
텍스트로 한 번만 붙이므로, 그 값 안의 `{{selection}}`·`{{page.text}}` 같은 글자는 다시
token으로 해석하거나 거부하지 않고 그대로 보존한다. 최종 문자·UTF-8·UTF-16 크기는
출력 문자열을 만들기 전에 overflow를 포함해 계산하며 예산을 넘으면 전체 action을
거부한다.

### 출력과 권한

| `output` | 호스트가 수행하는 동작 | 자동으로 필요한 권한 |
| --- | --- | --- |
| `showText` | 제한된 일반 텍스트를 표준 대화상자에 표시 | 없음 |
| `copyText` | 제한된 일반 텍스트를 macOS 일반 클립보드에 기록 | `clipboardWrite` |
| `openURL` | 공개적으로 보이는 HTTPS URL인지 다시 검사하고, 매 실행마다 대상 host와 포함되는 문서 정보의 종류를 보여 준 뒤 기본 브라우저로 열기 | `externalURL` |

지원하는 capability 문자열은 다음 네 개뿐이다.

- `documentMetadata`: 문서 표시 이름·현재 페이지 번호·페이지 수 읽기
- `selectedText`: 사용자가 현재 선택한 제한된 텍스트 읽기
- `clipboardWrite`: 일반 클립보드에 결과 쓰기
- `externalURL`: 확인 후 기본 브라우저에서 외부 HTTPS URL 열기

권한은 action의 토큰과 출력에서 자동 계산한다. 누락된 권한뿐 아니라 사용하지 않는
권한을 추가 선언해도 `capability mismatch`로 설치를 거부한다. 이는 나중에 몰래 쓰기
위해 넓은 권한을 미리 요청하는 매니페스트를 막는다.

`openURL`은 템플릿 자체가 `https://`로 시작해야 하며, 최종 URL도 HTTPS여야 한다.
사용자명·비밀번호가 들어간 URL, IP literal, `localhost`, 단일 label host와
`.local`·`.localhost`·`.internal`·`.lan`·`.home`·`.home.arpa` 같은 로컬 DNS
이름은 거부한다. 앱은 네트워크 요청을 직접 만들지 않고 사용자가 승인한 URL을 기본
브라우저에 넘긴다. 브라우저가 연 페이지의 동작과 개인정보 정책은 별도 신뢰 경계다.

## manifest v2 앱 소유 패널

Schema 2는 schema 1을 대체하지 않는다. v1 패키지와 action은 계속 같은 의미로
읽히며, v2도 같은 루트/action 필드, 엄격한 JSON 검사, 크기 상한과 capability 정확 일치
규칙을 사용한다. 차이는 앱이 구현한 세 패널 output과 이에 대응하는 권한을 추가한다는
점이다. 패키지는 Swift·JavaScript·HTML을 포함하거나 실행하지 않고, 매니페스트가
호스트의 고정된 패널 UI 중 하나를 요청할 뿐이다.

### v2 output·token·capability

| `output` | 허용 `template` | 자동으로 필요한 권한 | 데이터 경계 |
| --- | --- | --- | --- |
| `translatePanel` | 정확히 `{{selection}}` 또는 `{{page.text}}` 하나 | 각각 `selectedText` 또는 `currentPageText`, 그리고 `clipboardWrite` + `translationService` | 호스트가 제한된 문자열 snapshot만 번역 패널에 전달 |
| `youtubePanel` | PDF token이 전혀 없는 허용된 YouTube 공개 HTTPS URL | `youtubeContent` | 초기 URL에 PDF 이름·텍스트·페이지 정보 없음 |
| `browserPanel` | PDF token이 전혀 없는 공개 HTTPS URL | `embeddedWebBrowser` | 초기 URL에 PDF 이름·텍스트·페이지 정보가 없고 PDF bridge도 없음 |

`{{page.text}}`와 `currentPageText`는 v2 `translatePanel` 전용이다. 텍스트 층이 없는
스캔 페이지는 먼저 로컬 OCR로 검색 가능한 사본을 만들어야 한다. 선택문과 현재 페이지
텍스트는 실행 시 불변 값으로 snapshot하고, 렌더 결과의 16,000자·64 KiB UTF-8 상한을
넘으면 일부만 보내지 않고 action 전체를 거부한다.

`translationService`, `youtubeContent`, `embeddedWebBrowser`는 의도적으로 서로 다른
권한이다. 예를 들어 `youtubeContent`만 승인한 패키지가 일반 웹 브라우저나 PDF 번역
문맥을 열 수 없고, 사용하지 않는 권한까지 선언해도 capability mismatch로 설치가
실패한다. 세 패널 output 중 하나라도 포함하거나 `dev.hwattakpdf.` 식별자 영역을
주장하는 package는 앞서 설명한 앱 번들 identifier+manifest digest exact-match gate를
통과해야 한다.

### 기본 패널별 데이터 흐름

#### 번역 도우미

1. `선택 문장 번역` 또는 `현재 페이지 번역`을 실행하면 호스트가 제한된 텍스트
   snapshot을 패널의 편집 가능한 미리보기에 놓는다. 이때는 웹 화면을 만들거나 PDF
   텍스트를 전송하지 않는다.
2. 사용자가 공급자·대상 언어·텍스트를 확인하고 `번역 열기`를 누르면 문자 수와 UTF-8
   byte 수, 대상 host, 클립보드 사용 여부를 다시 고지하고 승인을 받는다.
3. Google 번역은 승인한 텍스트를 `translate.google.com` HTTPS query에 넣어 전송한다.
   완성된 URL도 4 KiB 상한을 지켜야 하므로 긴 페이지는 이 흐름을 사용할 수 없다.
4. ChatGPT는 승인한 텍스트와 번역 지시를 macOS 일반 클립보드에 복사하고
   `chatgpt.com`을 열며 로그인에는 `auth.openai.com`도 허용한다. Claude도 같은 방식으로
   일반 클립보드에 복사하고 `claude.ai`를 연다. 두 경우 실제 서비스 전송은 사용자가
   웹 입력창에 붙여넣고 보내기를 누를 때 일어나며, 그 전에도 다른 앱이 일반
   클립보드를 읽을 수 있다는 점을 고지한다.
5. 새 공급자/요청을 열 때 별도 exact-host WebView session을 만든다. 공급자 사이트의
   계정, 응답 정확성, 보존·학습·개인정보 정책은 HwattakPDF가 통제하지 않는다.

#### YouTube 학습

검색어는 `www.youtube.com/results`로 보내고, 유효한 watch·share·shorts·live·embed
영상 주소에서 안전한 11자 video ID만 추출할 수 있으면
`https://www.youtube-nocookie.com/embed/<video-id>`로 새 URL을 만든다. 원래 URL의
나머지 query는 전달하지 않는다. `youtube-nocookie.com`은 개인정보 보호 강화 재생
경로이지 네트워크·추적이 전혀 없다는 뜻은 아니다. 검색 결과 페이지와 재생 페이지는
여전히 원격 JavaScript·쿠키·하위 리소스를 사용할 수 있다.

사용자가 실제로 누른 영상 링크는 위 패널 재생 경로를 유지한다. 채널·YouTube 로고·
약관 같은 다른 exact YouTube-host 링크는 대상을 확인받은 뒤 시스템 기본 브라우저로
연다. script가 만든 popup과 비YouTube 링크는 계속 차단한다.

#### 웹 브라우저

주소나 검색어에서 만든 공개 HTTPS 상위 URL만 임시 패널에 연다. 일반 브라우저 패널은
선택문, 현재 페이지 텍스트, 문서 metadata, PDFKit 객체, 로컬 경로 또는 파일을
JavaScript에 전달하는 message handler/bridge를 등록하지 않는다. 사이트가 제공하는
로그인과 폼 입력은 사용자가 직접 하는 별도 웹 상호작용이다.

### WebKit 보안 경계와 남는 위험

각 패널은 별도 `WKWebView`와 `.nonPersistent()` website data store를 사용한다. 이
설정은 패널을 폐기한 뒤 WebKit의 쿠키·웹 저장소·방문 기록을 영구 profile에 남기지 않기
위한 것이지, 열린 동안 쿠키나 저장소가 없거나 사이트가 추적할 수 없다는 뜻이 아니다.

호스트가 적용하는 방어는 다음과 같다.

- 최초 URL, 상위 frame navigation과 최종 response URL을 패널 scope에 맞춰 다시
  검사한다. 공용 브라우저는 최대 4 KiB의 공개 HTTPS, 기본/명시 443 port만 허용하고
  credentials·IP literal·localhost·단일 label·알려진 local DNS suffix를 거부한다.
  번역은 공급자별 exact host, YouTube는 제한된 YouTube host/path로 더 좁힌다.
- 새 창/popup, navigation download와 attachment/binary/표시 불가 응답, HTML file
  upload picker, 웹 패널 위의 file drag-and-drop, 카메라·마이크 capture, AirPlay와
  deprecated TLS 승인을 차단한다. 예외적으로 사용자가 직접 누른 표준 YouTube 링크만
  위의 exact-host 분기와 확인을 거친다. 서버 인증서는 운영 체제 기본 trust 평가를 따른다.
- 일반 브라우저에는 PDF bridge가 없고 YouTube embed의 고정 Referer에도 PDF나 사용자
  텍스트를 넣지 않는다.

이 검사는 **상위 navigation 정책이지 완전한 네트워크 방화벽이나 브라우저 sandbox가
아니다.** 허용된 페이지의 원격 JavaScript, session cookie·storage, analytics,
iframe·image·script·fetch·WebSocket 같은 하위 리소스 요청과 DNS가 실제로 해석된 뒤의
주소까지 모두 allowlist하지 않는다. 사이트의 로그인 상태와 보안·개인정보 정책도
호스트가 보증하지 않는다. 민감한 문서를 보는 동안 필요 없는 패널은 닫아야 한다.

### 패널 수명과 권한 폐기

`PluginPanelRequest`에는 plugin identifier, 검토된 manifest digest, document revision,
action ID와 제한된 입력 snapshot을 넣고 live `PDFDocument`나 `PDFSelection`은 넣지
않는다. 다음 상황에서는 요청을 지우고 WebView loading/delegate를 해제한다.

- 사용자가 패널을 닫거나 AI 패널·집중 보기로 전환할 때
- 문서를 열기·교체·reset·hibernate하거나 revision이 달라질 때
- 탭 또는 scene이 비활성화되거나 문서 화면이 사라질 때
- 번역을 허용하지 않는 작업 모드로 바꿀 때
- 해당 플러그인이 비활성화·업데이트·제거되거나 identifier+digest 검사가 더는 맞지 않을 때

## 강제 상한

| 항목 | schema 1·2 상한 |
| --- | ---: |
| 플러그인 폴더의 visible `.hwattakplugin` entry | 32개 slot. 검증 실패·격리 항목도 포함 |
| 플러그인당 action | 24개 |
| 원본 패키지 루트 파일 | 5개 |
| source package payload 전체 | 2 MiB |
| `manifest.json` | 128 KiB |
| 각 보조 파일 | 1 MiB |
| 앱이 생성하는 `installation.json` | source payload와 별도로 32 KiB |
| action template | 16 KiB UTF-8 |
| 렌더된 결과 | 16,000자, 64 KiB UTF-8, 128,000 UTF-16 code units를 모두 만족 |
| 최종 외부 URL | 4 KiB UTF-8 |

렌더 결과가 상한을 넘으면 일부를 조용히 잘라 실행하지 않고 action 전체를 실패시킨다.
설치 검토 때 source package의 허용 파일을 실제로 읽은 `Data.count` 합계가 2 MiB인지
확인하고, 사전 file metadata와 실제 byte 수가 다르면 동시 변경으로 거부한다. 앱이
생성하는 `installation.json`은 source payload가 아니므로 2 MiB 합계에서 제외하고
별도 32 KiB 상한을 적용한다. 일반 시작·새로 고침 때는 설치된 보조 파일을 메모리에
유지하지 않고 manifest와 작은 설치 기록만 읽는다.

## 설치 무결성과 복구

설치 흐름은 다음 불변 조건을 지킨다.

1. 파일 패널에서 고른 security-scoped 디렉터리를 연 상태로 허용된 각 파일을 크기
   상한 안에서 읽고, 검토 이후에는 원본 경로를 다시 읽지 않는다.
2. 캡처한 바이트를 권한 `0700`의 임시 디렉터리에 쓰고 각 파일을 `0600`으로 설정한다.
3. 앱이 `installation.json`에 설치 시각과 `manifest.json` SHA-256을 기록한다.
4. 최종 식별자 이름을 가진 별도 staging 패키지를 설치 패키지 규칙으로 다시 검사한다.
5. 업데이트는 기존 디렉터리를 숨은 backup으로 옮긴 뒤 staging을 이동하며, 실패하면
   backup 복원을 시도한다. 앱 시작 시 남은 임시 설치·staging·backup을 정리한다.
6. 다음 로드 때 디렉터리 이름, 설치 기록 버전, 기록된 digest와 현재 manifest digest가
   모두 맞아야 action registry에 들어간다. 실패한 패키지는 실행 목록에서 제외하고 관리
   창에 문제로 표시한다.
7. 웹 패널 output이 하나라도 있거나 `dev.hwattakpdf.` 식별자 영역을 주장하면 앱
   번들의 검토본 목록에서 같은 identifier와 같은 manifest digest를 다시 찾아야 한다.
   설치 검토 전·직접 설치·앱 재실행 모두에서 일치하지 않으면 registry에 들어가지 않는다.

이 SHA-256은 비밀키가 없는 일반 해시다. 실수로 바뀐 manifest나 기록과 manifest의
불일치를 찾지만, 공격자가 현재 사용자 권한으로 `manifest.json`과
`installation.json`을 함께 바꾸는 상황을 막지 못한다. 해시는 manifest에만 적용되며
README·LICENSE·icon의 게시자나 무결성을 인증하지 않는다.

## 위협 모델

### v1이 줄이는 위험

- 패키지 안 임의 실행 파일, 스크립트, 동적 라이브러리와 하위 디렉터리를 허용하지 않아
  플러그인이 호스트 프로세스에서 코드를 실행하지 못하게 한다.
- BOM·과도한 nesting·중복/알 수 없는 키를 포함한 엄격한 JSON, 타입·식별자·토큰·권한
  일치 검증으로 parser 해석 차이나 오타가 권한 우회와 조용한 부분 설치로 이어지지 않게
  한다.
- 실제 디렉터리·일반 파일만 받고 심볼릭 링크를 거부해 설치 범위 밖 파일 읽기와 경로
  바꿔치기 표면을 줄인다.
- 검토 중 캡처한 bounded bytes만 설치해 검토와 설치 사이 source package 변경 경쟁을
  줄인다.
- 검증 실패 항목까지 포함해 installer의 visible `.hwattakplugin` slot을 32개로 세고,
  파일 수·크기·action 수·입출력 크기를 제한하며 상주 작업을 제공하지 않아 단순한
  메모리·CPU·디스크 고갈 표면을 제한한다.
- 외부 URL의 scheme·host를 다시 검증하고 문서 데이터 종류를 매번 고지·승인받아
  무의식적인 로컬 서비스 접근과 정보 반출을 줄인다.

### v1이 보장하지 않는 것

- 게시자 인증, notarization, 인증서 서명, 투명성 로그, 온라인 악성 패키지 검사
- 비슷한 이름·식별자에 의한 사칭이나, 설득력 있는 출력·클립보드 내용·외부 사이트를
  이용한 social engineering 방지
- 사용자가 외부 URL 전송을 승인한 뒤 브라우저와 대상 사이트가 수행하는 추적·저장 방지
- 현재 macOS 사용자 권한을 이미 가진 다른 프로세스나 악성코드로부터 Application
  Support 파일 보호
- 현재 사용자 권한으로 플러그인 폴더에 32개를 넘는 entry를 installer 밖에서 직접
  넣어 directory 열거·문제 목록을 부풀리는 hostile-filesystem 공격의 완전한 격리.
  정상 installer는 invalid entry도 slot으로 세어 이 우회를 허용하지 않고, 새로 고침은
  정렬된 첫 32개만 검증·로드하며 나머지를 문제로 표시한다.
- 앱·PDFKit 자체의 취약점, 운영 체제나 브라우저의 취약점 방어

### v2 웹 패널이 추가로 줄이는 위험

- 패널 package와 `dev.hwattakpdf.` 식별자 package를 앱 번들의 검토본
  identifier+manifest digest와 대조해 임의의 외부 package가 host-owned WebKit 권한을
  요청하거나 schema 1 package로 공식 플러그인을 사칭·교체하지 못하게 한다.
- 번역·YouTube·일반 웹을 별도 capability와 navigation scope로 나눠 한 기능의 승인이
  다른 기능의 PDF 문맥이나 사이트 범위로 확대되지 않게 한다.
- PDF text를 불변·제한된 문자열로만 번역 UI에 넘기고 일반 브라우저·YouTube에는 PDF
  bridge와 PDF token을 제공하지 않는다.
- top-level request/response 재검증과 script popup·download·upload·media capture·file
  drop·deprecated TLS 차단으로 흔한 우발적 권한 확대와 로컬 파일 노출 표면을 줄인다.
  사용자 클릭인 표준 YouTube 링크만 exact host 검사와 확인을 거쳐 처리한다.
- 문서/플러그인 identity와 lifecycle이 달라질 때 패널을 폐기해 오래된 권한과 snapshot이
  다른 문서나 업데이트된 manifest에 남지 않게 한다.

### v2 웹 패널이 보장하지 않는 것

- `.nonPersistent()` session 안에서 실행되는 원격 JavaScript, 메모리 내 쿠키·storage,
  fingerprinting·analytics와 하위 리소스 네트워크 요청의 차단
- top-level URL 문자열 검사를 넘은 뒤 DNS가 해석되는 실제 목적지, 모든 redirect·iframe·
  fetch·WebSocket을 process-level network firewall처럼 통제하는 것
- Google·YouTube·OpenAI·Anthropic 또는 일반 사이트의 계정 보안, 콘텐츠 정확성,
  개인정보 보존·학습·추적 정책
- 일반 클립보드에 복사한 ChatGPT·Claude 번역 prompt를 다른 앱이 읽지 못하게 하는 것
- 앱 번들 allowlist가 Developer ID 서명·notarization 또는 독립적인 게시자 인증을
  대신하는 것. 현재 build script 산출물은 개발용 ad-hoc 서명이다.

신뢰하지 않는 패키지는 설치하지 않고, 예상치 못한 권한·URL을 요구하면 취소한다.
취약점 제보 범위는 [보안 정책](../SECURITY.md)을 따른다.

## 리소스와 안정성

v1 action은 사용자의 메뉴 클릭에 반응해 한 번 템플릿을 치환하는 동기 작업이다. 자체
스레드, timer, launch agent, 파일 감시, 지속 네트워크 세션, PDF 렌더링 또는 GPU
command를 만들 수 없다. installer는 검증 실패 항목도 포함한 visible package slot을
32개로 제한하고, 실행 registry의 각 정상 manifest는 최대 24개 action만 가진다.
따라서 비활성 플러그인은 메뉴와 registry의 작은 값 객체 외에 실행 비용이 없고,
활성 플러그인도 사용자가 action을 누르기 전에는 작업하지 않는다.

v2 package도 상주 코드를 만들지 않는다. 다만 사용자가 panel action을 실행한 뒤에는
host-owned WebView가 원격 JavaScript와 네트워크 세션을 수행하므로 페이지가 소비하는
CPU·메모리·네트워크를 v1 템플릿 action처럼 고정된 비용으로 볼 수 없다. 패널을 닫거나
위의 lifecycle 조건이 발생하면 loading을 중지하고 WebView를 해제한다.

이 정책은 플러그인으로 인한 상주 CPU·GPU와 무제한 메모리를 구조적으로 줄이기 위한
것이지, 앱 전체 성능이 측정 없이 항상 일정함을 보증하는 문장은 아니다. PDFKit 탭,
OCR, 검색과 렌더링을 포함한 호스트 앱의 메모리·CPU 정책과 남은 실물 측정은
[대용량·다중 PDF 성능 설계](LARGE-PDF-PERFORMANCE.md)를 따른다.

## 향후 실행형 플러그인의 XPC 경계

schema 1·2에는 XPC 실행형 플러그인이 **구현되어 있지 않다**. 나중에 현재 host-owned
panel로 표현할 수 없는 기능이 꼭 필요해도 다운로드한 코드를 HwattakPDF 프로세스에
`dlopen`하거나 임의
스크립트 엔진에 바로 넣지 않는다. 별도 설계·위협 모델·배포 서명 정책을 통과한 다음과
같은 프로세스 경계를 선행 조건으로 삼는다.

- 플러그인별 또는 신뢰 영역별 sandboxed XPC service와 최소 entitlement
- 버전형 Codable IPC, 메시지·파일·문자열 크기 상한과 capability broker
- 네트워크·파일·Keychain·클립보드·GPU 기본 거부, 사용자 동의가 있는 좁은 host API만
  중개
- 요청 timeout·취소, 동시성 제한, 메모리/CPU 예산 감시, 반복 crash 시 자동 비활성화
- 게시자 코드 서명·notarization·업데이트 서명과 rollback/폐기 정책
- PDF 원본 대신 최소화한 immutable snapshot 또는 host-owned file descriptor 전달,
  응답 검증과 감사 가능한 동의 기록

이 경계가 구현되고 공격·고장·성능 테스트를 통과하기 전까지 “임의 코드를 실행하는
플러그인”은 제품 범위로 표시하지 않는다.
