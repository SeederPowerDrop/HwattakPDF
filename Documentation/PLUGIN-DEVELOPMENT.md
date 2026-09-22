# HwattakPDF 플러그인 만들기

**문서를 읽고 공부하는 나만의 방법을, 다른 사람도 설치할 수 있는 작은 도구로 만들어 보세요.**

이 가이드는 2026-09-05 안정화 소스의 실제 구현을 기준으로 한다. 코드 편집기와 HwattakPDF만 있으면 첫 플러그인을 만들 수 있다. Swift나 JavaScript 빌드는 필요하지 않다. 터미널 검증을 선택할 때만 저장소와 Mac용 Swift 개발 환경이 필요하다.

[English quick start](PLUGIN-DEVELOPMENT.en.md) · [문서 명령 API](PLUGIN-HOST-API.md) · [호환성·확장 설계](PLUGIN-COMPATIBILITY.md) · [보안 가이드](PLUGIN-SECURITY.md) · [전체 예제](../Examples/Plugins/README.md)

## 1. 무엇을 만들 수 있나요?

| 하고 싶은 일 | 지금 사용하는 방식 | 출발점 |
| --- | --- | --- |
| 분야별 색상 체계, 논문 읽기용 강조·밑줄 | `documentCommand`의 주석 명령 | CommunityStarter |
| 세밀한 필기용 펜, 발표 중 페이지 이동 | 펜 설정·모드 전환·탐색 명령 | CommunityStarter |
| 학습 체크리스트, 작업 순서 안내 | 권한 없는 `showText` | OfflineChecklist |
| 선택 문장과 출처를 Markdown으로 옮기기 | 텍스트 토큰 + `copyText` | MarkdownQuote |
| 선택한 용어를 공개 웹사이트에서 검색 | URL 인코딩 + 호출마다 확인하는 `openURL` | ReferenceSearch |
| 새 OCR 엔진, 자동 플래시카드 생성, 사용자 정의 렌더러 | 새 호스트 API 또는 격리된 실행 환경이 필요 | [확장 제안 절차](PLUGIN-COMPATIBILITY.md#5-아직-없는-기능을-추가하는-방법) |

현재 패키지는 **앱이 구현한 명령과 텍스트 템플릿을 선언**한다. 임의 코드, 타이머, 이벤트 구독, 명령 여러 개의 자동 연쇄 실행은 지원하지 않는다. 설치된 플러그인은 메뉴·툴바·명령 팔레트에서 사용자가 실행한다. 스캔 문서에 텍스트 선택을 요구하는 기능은 먼저 텍스트 레이어/OCR이 필요하다.

## 2. 첫 플러그인: 복사 → 수정 → 설치 → 실행

### 준비

- macOS 14 이상과 HwattakPDF 앱. 문서 명령 예제에는 **schema 3을 지원하는 앱**이 필요하다.
- 개인 자료가 없는 시험용 PDF 한 개. 문서 편집 실험은 복사본에서 한다.
- JSON을 UTF-8 일반 텍스트로 저장할 수 있는 편집기.

현재 소스는 0.9.0/build 19이며 schema 1·2·3을 지원한다. 과거에는 0.8.0/build 18 표기가 같은 공개 앱과 안정화 후보가 존재했다. 예제의 최소 버전 숫자만 보지 말고 [정확한 호환성 기준](PLUGIN-COMPATIBILITY.md#1-현재-지원-범위)을 확인한다.

### 패키지 복사

저장소의 [CommunityStarter.hwattakplugin](../Examples/Plugins/CommunityStarter.hwattakplugin)을 복사해 `MyStudy.hwattakplugin`으로 이름을 바꾼다. 저장소를 받은 개발자라면 루트에서 다음을 실행할 수 있다.

```sh
mkdir -p work
cp -R Examples/Plugins/CommunityStarter.hwattakplugin work/MyStudy.hwattakplugin
```

패키지는 **폴더**다. `manifest.json`이 그 폴더 바로 안에 있어야 한다. Git 저장소, 스크린샷, 빌드 도구, 테스트 PDF는 패키지 밖에 둔다.

```text
my-study-project/
├── MyStudy.hwattakplugin/
│   ├── manifest.json
│   ├── README.md
│   └── LICENSE
├── screenshots/          ← 개발 저장소에만 포함
└── test-results.md       ← 개발 저장소에만 포함
```

### 나의 정보로 수정

`manifest.json`에서 다음 값을 바꾼다.

| 필드 | 작성할 내용 |
| --- | --- |
| `identifier` | 배포자가 정하는 고유한 소문자 식별자. 예: `dev.yourname.my-study`. 업데이트 때 유지한다. 예제의 `org.example.*`는 배포 전에 바꾼다. |
| `displayName` / `author` | 사용자에게 표시할 이름과 실제 제작자 |
| `description` | 무엇을 하는지, 어떤 문서·모드에서 쓰는지 |
| `version` | 첫 배포는 `1.0.0`, 변경 후에는 올린다. `1.0.0-beta` 형식은 현재 불가 |
| `minimumHostVersion` | 실제 시험한 최소 앱 버전. 개발자의 플러그인 버전과는 다른 값 |
| `actions` / `capabilities` | 제공할 명령과 그 명령들이 사용하는 권한의 정확한 합집합 |

아래는 하이라이트 하나만 제공하는 **그대로 저장할 수 있는 전체 manifest**다. 시작 예제 대신 이것으로 첫 실험을 해도 된다.

```json
{
  "schemaVersion": 3,
  "identifier": "org.example.my-highlighter",
  "displayName": "My Highlighter",
  "version": "1.0.0",
  "author": "Your name",
  "description": "선택한 문장을 노란색으로 강조합니다. 텍스트를 외부로 보내지 않습니다.",
  "minimumHostVersion": "0.8.0",
  "capabilities": ["annotationWrite"],
  "actions": [
    {
      "id": "highlight-yellow",
      "title": "노란색으로 강조",
      "output": "documentCommand",
      "template": "",
      "command": {"kind": "highlight", "color": "#FFD60A"}
    }
  ]
}
```

하이라이트는 호스트가 현재 선택에 주석을 붙이는 기능이다. 텍스트를 추출하는 `selectedText` 권한은 필요하지 않다. 불필요한 권한까지 넣으면 설치 검증이 실패한다.

### 설치와 첫 실행

1. **플러그인 → 플러그인 관리… → 플러그인 설치…**에서 `MyStudy.hwattakplugin` 폴더를 선택한다. ZIP 자체를 선택하지 않는다.
2. 표시되는 이름·제작자·버전·권한을 확인한다. 하이라이트 하나의 예제라면 `annotationWrite`만 있어야 한다.
3. 설치하고 활성 상태인지 확인한다. 시험용 PDF에서 문장을 선택한다.
4. **⇧⌘P**를 눌러 플러그인/명령 이름을 검색한다. Enter는 첫 번째 실행 가능한 결과를 실행하고 Esc는 닫는다. 메뉴·툴바에서도 선택할 수 있다.
5. 하이라이트가 생기는지 확인하고 **⌘Z → ⇧⌘Z**로 취소·재실행한다. 별도 PDF로 저장한 뒤 다시 열어 확인한다.

권한 없는 체크리스트는 PDF가 없는 창에서도 **플러그인 메뉴**로 실행할 수 있다. 현재 명령 팔레트는 열린 PDF가 있어야 열린다. 관리 창 검색은 설치 목록 검색이고, 명령 팔레트 검색은 실행할 action 검색이다.

### 수정 후 다시 실행

개발 중인 **원본 패키지**를 수정하고 관리 창에서 다시 선택한다. 같은 `identifier`면 업데이트 검토가 열린다. 설치된 플러그인 폴더를 직접 편집하는 hot reload는 지원하지 않는다. 직접 수정한 설치본은 무결성 검사에서 격리될 수 있다.

같은 식별자의 비활성 상태와 호스트 제공 옵션은 업데이트 후에도 유지된다. 문서에 이미 만든 하이라이트는 플러그인을 끄거나 제거해도 남는다. 실행 취소나 PDF 편집으로 지운다.

## 3. 두 번째 기능부터: 권한과 데이터 흐름

| 넣은 기능 | 필요한 권한 | 사용자에게 설명할 내용 |
| --- | --- | --- |
| 정적 `showText` | 없음 | 로컬 안내 표시 |
| `{{selection}}` / `{{selection.urlEncoded}}` | `selectedText` | 선택 문장을 템플릿에 사용 |
| `{{document.name}}`, `.urlEncoded`, `{{page.number}}`, `{{document.pageCount}}` | `documentMetadata` | 문서 이름·현재 페이지·총 페이지 수 사용 |
| `copyText` | `clipboardWrite` + 사용한 토큰 권한 | 시스템 클립보드 내용을 바꿈 |
| `openURL` | `externalURL` + 사용한 토큰 권한 | 공개 HTTPS 링크를 확인 후 외부 브라우저로 엶 |
| 하이라이트·밑줄 | `annotationWrite` | PDF 주석을 추가하고 Undo 가능 |
| 펜·지우개·선택 | `toolControl` | 현재 도구나 펜 설정 변경 |
| 모드·페이지 이동 | `workspaceNavigation` | 열린 문서의 화면 상태 변경 |

여러 action의 권한을 합쳐 루트 `capabilities`에 중복 없이 넣는다. 각 권한을 켜고 끄는 개별 토글은 없고, 현재 동의/비활성화 단위는 플러그인이다. 읽기 기능과 외부 전송 기능을 별도 패키지로 나누면 사용자가 필요한 것만 선택할 수 있다.

`{{page.text}}`와 `currentPageText`는 현재 **공식 번역 패널 전용**이다. 전체 페이지 읽기나 OCR API로 사용할 수 없다. 커뮤니티 웹 패널도 아직 허용되지 않는다.

### 레시피 A — 의미가 있는 색상 규칙

CommunityStarter를 바탕으로 `color`와 `title`을 바꿔 주장·근거·질문을 구별한다. 색만 보지 않아도 뜻을 알 수 있도록 제목을 쓴다. 예: “근거 표시 — 파란 밑줄”. 굵기·투명도·기본값은 [명령 API 표](PLUGIN-HOST-API.md#명령과-스타일-참조)를 따른다.

### 레시피 B — Obsidian에 인용 옮기기

[MarkdownQuote](../Examples/Plugins/MarkdownQuote.hwattakplugin/manifest.json)를 설치한다. PDF의 문장을 선택해 미리보기/복사를 실행하고, Obsidian 노트에 직접 붙여 넣는다. Markdown 문자열을 교환하는 방법이며 vault 파일 접근이나 자동 동기화는 아니다. 여러 줄 선택의 모든 줄에 `>`를 붙이는 반복/필터 언어는 없으므로 붙여 넣은 서식을 확인한다. 페이지 번호는 현재 페이지의 1-based 위치이며 로마 숫자 같은 인쇄 페이지 라벨과 다를 수 있다.

`obsidian://` 링크는 현재 `openURL`의 공개 HTTPS 정책에서 허용되지 않는다. Obsidian의 `main.js`를 복사하거나 manifest 필드 이름만 바꿔도 실행되지 않는다. [기존 Obsidian 기능 옮기기](PLUGIN-COMPATIBILITY.md#3-obsidian에서-가져올-수-있는-것).

### 레시피 C — 논문·용어 검색

[ReferenceSearch](../Examples/Plugins/ReferenceSearch.hwattakplugin/manifest.json)의 공개 HTTPS 주소를 자신의 검색 서비스에 맞게 바꾼다. 검색어는 `{{selection.urlEncoded}}`를 사용한다. URL 인코딩은 문법을 보호하며 **개인정보 익명화나 암호화가 아니다**. 대상 사이트, 전송되는 문장/파일명, 사용자의 확인과 취소 흐름을 README에 설명한다. `fetch`, API 키, POST 요청이나 응답 파싱은 이 API에 없다.

### 레시피 D — 태블릿 필기 프리셋

CommunityStarter의 학습 모드 명령을 먼저 실행하고 펜 명령을 실행한다. 한 action에서 두 명령을 자동 연결할 수 없다. 펜 설정은 macOS가 전달한 입력을 처리하는 호스트 도구에 적용된다. Sidecar/기기 지원 범위와 Stamp 저장 형식은 [태블릿 가이드](PLUGIN-HOST-API.md#ipad태블릿-필기)를 참고한다. 펜 프리셋 제작과 iPad 드라이버 제작은 서로 다른 개발 범위다.

## 4. 검증: 앱에서 확인하고, 필요하면 명령으로 반복하기

터미널 검증은 **macOS용 HwattakPDF 소스 checkout + 저장소가 사용하는 Swift/Xcode 환경**이 필요하다. 첫 실행은 앱과 테스트 모듈을 빌드하므로 오래 걸릴 수 있다. 개발 환경은 [기여 가이드](../CONTRIBUTING.md#2-개발-환경)를 따른다. 일반 플러그인 제작자는 앱의 설치 검토만으로 시작할 수 있다.

저장소 루트에서:

```sh
zsh scripts/validate_plugin.sh work/MyStudy.hwattakplugin
zsh scripts/validate_plugin.sh --examples
```

`PLUGIN VALID: ... schema=3; host=0.9.0; sha256=...`와 실패 없는 테스트 종료를 확인한다. 실패하면 종료 코드는 0이 아니다. 이 명령은 별도 Python 모방 검사기가 아니라 앱의 `PluginPackageValidator`와 `PluginManager` 신뢰 규칙을 호출한다. 사용자 플러그인 폴더에 설치하지 않으며 패키지 코드를 실행하지 않는다. 읽은 파일·검토 bytes·manifest digest만 검사한다.

최소 호스트 버전 선언의 거부 동작도 검사할 수 있다.

```sh
zsh scripts/validate_plugin.sh work/MyStudy.hwattakplugin 0.7.0
```

`minimumHostVersion: 0.8.0`이면 위 명령은 실패해야 한다. 다만 이 인수는 **현재 소스 검사기에 버전 숫자를 주입**하는 기능이다. 0.7.0의 과거 parser·UI·PDFKit을 실행하는 호환성 에뮬레이터는 아니다. 지원을 주장할 실제 구형 앱에서도 설치·실행한다.

공식 예약 식별자나 웹 패널을 검사하면 커뮤니티 검사기는 거부한다. 공식 번들 신뢰 경계를 해제하는 개발 옵션은 제공하지 않는다. JSON 문법 검사만 통과해도 권한·호환성·패키지 검사가 실패할 수 있다.

### 배포 전 시험표

| 시험 | 기대 결과 |
| --- | --- |
| 정상 문서·선택·지원 모드 | 설명한 결과가 한 번 발생 |
| 선택 없음 / 이미지뿐인 페이지 | 해당 명령 사용 불가 또는 안내, 다른 곳에 주석을 붙이지 않음 |
| 문서 변경·탭 전환 후 재실행 | 현재 문서의 조건을 다시 확인 |
| 펜을 보기 모드에서 실행 / 첫·마지막 페이지 탐색 | 실행 불가, 범위 밖으로 이동하지 않음 |
| 주석 추가 → Undo → Redo → 저장 → 재개방 | 주석과 저장 결과 확인 |
| 비활성화·업데이트·제거 | 오래된 메뉴/팔레트 결과로 실행되지 않음 |
| 외부 링크 확인 취소 | 브라우저가 열리지 않음 |
| 다른 앱에서 PDF를 변경한 뒤 저장 | 호스트의 저장 충돌 처리를 따름 |
| 지원할 최소 앱·macOS와 대표 대용량 PDF | 실제 시험한 조합과 한계를 README에 기록 |

숫자로 된 성능 보장은 측정 자료가 있을 때만 쓴다. 패키지 정적 검증은 PDF 결과나 실제 태블릿 지연 검증을 대신하지 않는다.

## 5. 공유·업데이트·유지보수

소스와 배포 폴더를 분리한 공개 저장소로 시작할 수 있다. 현재 앱에는 온라인 카탈로그·자동 업데이트·게시자 서명 검증이 없다. 개발자가 버전별 소스를 공개하고 사용자가 내려받은 패키지를 검토해 설치한다.

README에는 다음을 적는다. [시작 예제 README](../Examples/Plugins/CommunityStarter.hwattakplugin/README.md)를 복사해도 된다.

- 해결하는 문제와 한 번의 사용 예시, 필요 모드/선택/OCR 조건
- 지원하는 schema, 최소 호스트 버전, 실제 시험한 앱 빌드·macOS·기기
- 권한마다 필요한 이유, 클립보드 변경, 외부 대상과 전달되는 데이터
- 설치·명령 실행·업데이트·제거 방법, 알려진 한계
- 작성자, 소스 저장소, 라이선스, 공개 버그와 비공개 보안 제보 경로

`homepage`, `repository`, `supportURL`, `license`, `fundingUrl`, `settings`, `hotkeys`, `minimumHostBuild` 같은 **새 manifest 키를 임의로 추가하지 않는다**. 현재 허용하지 않는 정보는 README에 쓴다. 문서 이미지도 패키지 밖의 저장소에 둔다. 런타임은 README를 실행하거나 플러그인 전용 화면으로 렌더링하지 않는다.

배포 ZIP에는 폴더와 허용한 파일만 넣는다. macOS 숨김 파일이 들어가지 않도록 파일 목록을 명시하는 예:

```sh
cd work
zip -X -r MyStudy-1.0.0.zip MyStudy.hwattakplugin \
  -i 'MyStudy.hwattakplugin/manifest.json' \
     'MyStudy.hwattakplugin/README.md' \
     'MyStudy.hwattakplugin/LICENSE'
unzip -l MyStudy-1.0.0.zip
shasum -a 256 MyStudy-1.0.0.zip
```

ZIP을 새 폴더에 풀어 **풀린 패키지**를 다시 검증한다. 허용되는 `LICENSE.md`나 `icon.png`를 실제 사용했다면 ZIP 목록에도 추가한다. 체크섬은 다운로드된 파일의 동일성을 확인하는 자료다. 제작자의 신원을 인증하지 않는다.

업데이트 때 `identifier`를 유지하고 `version`을 올리며 변경한 권한·동작·호환성·해결한 문제를 릴리스 노트에 기록한다. 현재 앱은 같은 버전이나 낮은 버전으로의 교체도 허용한다. 제작자는 이전 배포 파일을 보관하고 되돌리는 방법을 안내한다. 자체 작성물에 적용할 라이선스를 명시하고, 예제나 타인의 자료를 재사용하면 해당 라이선스와 고지를 따른다. 저장소 예제에는 MPL-2.0이 적용된다.

## 6. 문제가 생겼을 때

| 메시지/증상 | 확인할 것 |
| --- | --- |
| `unsupported schemaVersion` | 앱이 해당 schema를 지원하는지. schema 3 명령을 schema 1이라고 바꾸면 해결되지 않음 |
| `incompatibleHost` / 최소 버전 오류 | 플러그인이 요구하는 앱 버전과 실제 앱 확인 |
| `capability mismatch` | 모든 action의 권한 합집합. 불필요한 권한도 제거 |
| `required fields or field types` | 철자, 필수 `template`, 숫자 대신 문자열을 넣었는지 |
| `unknown ... key` / `duplicate ... key` | 정의되지 않은 필드·JSON 주석·중복 키 제거 |
| `unsupported package entry` | `.DS_Store`, 하위 폴더, `main.js`, `package.json` 등이 들어갔는지 |
| `reserved ... identities` / 웹 패널 신뢰 오류 | 자신의 식별자를 사용하고 커뮤니티가 지원하는 출력만 선언 |
| `installed manifest integrity check failed` | 설치본 직접 수정 여부. 원본을 관리 창에서 다시 검토·업데이트 |
| 설치되지만 실행 불가 | 활성 상태, PDF/선택/모드, 비교 화면의 읽기 전용 문맥, 페이지 경계 |
| 화면에 결과가 잘림/큰 선택에서 실패 | 템플릿·최종 결과·URL 상한. 선택을 줄이고 반복 토큰 줄이기 |

일반 오류는 [버그 제보](https://github.com/SeederPowerDrop/HwattakPDF/issues/new/choose)에 앱/schema/플러그인 버전, 짧은 재현 순서, 실제 오류 문구를 남긴다. 민감한 문서·키·선택 원문은 제거한다. 취약점은 [비공개 보안 제보](../SECURITY.md)를 따른다.

기능이 API에 없다면 내부 파일에 접근하는 우회법을 배포하기보다 [API 제안서](PLUGIN-COMPATIBILITY.md#5-아직-없는-기능을-추가하는-방법)를 작성한다. 사용자 문제, 필요한 입력·결과·권한, 취소·실행 취소와 대용량 조건이 담긴 작은 제안은 다음 API를 검토하는 출발점이 된다.
