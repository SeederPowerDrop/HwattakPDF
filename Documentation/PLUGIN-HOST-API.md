# 문서 명령 플러그인 API — schema 3

2026-09-05 안정화 작업에서 추가했다. 기존 schema 1·2 패키지는 계속 읽을 수 있다.

이 문서는 **문서 명령의 참조**다. 처음 제작한다면 [플러그인 만들기](PLUGIN-DEVELOPMENT.md)를 먼저 읽는다. [English quick start](PLUGIN-DEVELOPMENT.en.md), [보안](PLUGIN-SECURITY.md), [호환성·코어 확장 절차](PLUGIN-COMPATIBILITY.md)도 함께 제공한다. 복사 후 바로 수정할 수 있는 커뮤니티 패키지는 [CommunityStarter](../Examples/Plugins/CommunityStarter.hwattakplugin/manifest.json)다.

## 사용하기

1. **플러그인 → 플러그인 관리…**에서 기본 플러그인을 검토·설치한다.
2. `Study Markup`: 텍스트를 선택하고 노란색/초록색 하이라이트 또는 파란색 밑줄을 실행한다.
3. `Tablet Tools`: 학습 모드 전환, 가는 파란 펜, 굵은 빨간 펜, 지우개, 선택 도구를 제공한다. 펜은 학습 또는 에디팅 모드에서 사용할 수 있다.
4. `Reading Navigation`: 앞뒤 페이지 이동과 보기·에디팅·학습 모드 전환을 제공한다.
5. **⇧⌘P**로 명령 팔레트를 열고 명령/플러그인 이름을 검색한다. Enter는 첫 번째 실행 가능한 결과를 실행하고 Esc는 닫는다. 메뉴와 툴바에서도 실행할 수 있다.

새 패키지 세 개와 기존 번역·웹 브라우저 패키지를 앱에 포함한다. 설치와 활성화는 사용자가 선택한다. 설치·업데이트·비활성화·삭제와 변조 검사에는 기존 플러그인 관리 경로를 사용한다.

## 직접 만들기

`MyStudy.hwattakplugin` 디렉터리 안에 다음 `manifest.json`을 넣는다. ZIP으로 공유했다면 설치 전에 압축을 푼다. `README.md`도 넣을 수 있다.

```json
{
  "schemaVersion": 3,
  "identifier": "org.example.my-study",
  "displayName": "My Study",
  "version": "1.0.0",
  "author": "Your name",
  "description": "My PDF annotation presets",
  "minimumHostVersion": "0.8.0",
  "capabilities": ["annotationWrite", "toolControl"],
  "actions": [
    {
      "id": "underline-blue",
      "title": "파란색 밑줄",
      "output": "documentCommand",
      "template": "",
      "command": {"kind": "underline", "color": "#007AFF", "width": 1.5, "opacity": 1}
    },
    {
      "id": "fine-pen",
      "title": "가는 파란 펜",
      "output": "documentCommand",
      "template": "",
      "command": {"kind": "pen", "color": "#007AFF", "width": 1.2}
    }
  ]
}
```

자신의 식별자를 사용한다. `dev.hwattakpdf.*`는 앱에 포함한 원본과 digest가 일치해야 하는 공식 영역이므로 예제를 수정할 때는 식별자도 바꾼다. 구형 0.8.0 바이너리는 schema 3을 지원하지 않으므로 2026-09-05 안정화 후보 또는 이후 빌드가 필요하다.

## 명령과 스타일 참조

한 action은 한 command를 실행한다. 모든 문서 명령에는 열린 PDF가 필요하다. 일반 PDF의 보기·에디팅·학습 모드는 모두 markup을 허용하지만, 암호화 문서의 실제 편집 권한과 선택 객체 소유권은 실행 경계에서 다시 확인한다.

| `command.kind` | 필요한 권한 | 입력과 조건 | 결과 |
| --- | --- | --- | --- |
| `highlight` | `annotationWrite` | 현재 문서의 텍스트 선택과 markup 권한. 색·굵기·투명도 선택 가능 | 주석 추가, Undo/Redo |
| `underline` | `annotationWrite` | 위와 같음 | 밑줄 appearance 추가, Undo/Redo |
| `pen` | `toolControl` | 필기 가능한 학습/에디팅 모드. 색·굵기 선택 가능 | 펜 선택과 설정. 현재 3열 이상이면 최대 2열로 조정 |
| `eraser` | `toolControl` | 모드가 지우개를 허용하고 markup 권한이 있어야 함 | 지우개 선택. 명령 자체가 주석을 지우지는 않음 |
| `selection` | `toolControl` | 열린 문서 | 선택 도구로 전환 |
| `viewerMode`, `editingMode`, `studyMode` | `workspaceNavigation` | 열린 문서 | 모드 전환. 문서의 암호/권한을 확대하지 않음 |
| `nextPage`, `previousPage` | `workspaceNavigation` | 다음/이전 페이지가 문서 범위 안에 있어야 함 | 현재 페이지 한 칸 이동 |

| 스타일 | 허용 값 | 생략하면 |
| --- | --- | --- |
| `color` | ASCII `#RRGGBB`; 알파·색상 이름 미지원 | 강조/밑줄은 현재 학습 팔레트 색, 펜은 기존 펜 색 |
| `width` | 유한한 숫자 0.2~32, PDF 페이지 좌표의 pt | 밑줄 1.5, 펜은 기존 굵기, 하이라이트는 선택 줄 전체 높이 |
| `opacity` | 유한한 숫자 0.1~1. 강조/밑줄에만 허용 | 굵기를 지정한 강조는 0.42, 그 외 강조/밑줄은 1 |

하이라이트에 굵기를 주면 선택 줄 높이를 넘지 않는 중앙 강조 띠를 만든다. 펜에는 opacity를 지정하지 않는다. 나머지 종류에는 스타일 필드를 넣지 않는다. `pressure`, `pressureEnabled`, `commands`, `onload`, `script`, `shortcut`은 지원 필드가 아니다.

일반 하이라이트(굵기 없음, 불투명도 약 1)는 native Highlight로 저장한다. 굵기/투명도를 지정한 강조와 밑줄은 Stamp appearance로 저장될 수 있다. PDF에 보이는 결과와 다른 앱의 native 편집 도구 호환성을 구분한다.

`template`은 필수이며 `documentCommand`에서는 빈 문자열이다. 나머지 출력에는 `command`를 넣지 않는다. 한 패키지에서 텍스트 출력과 문서 명령을 함께 사용할 수 있으며 권한은 모든 action의 합집합이다. 정확한 파일·문자열·최종 출력 상한은 [공통 형식 참조](PLUGINS.md)에 있다.

명령이 문서를 수정해도 원본 파일을 직접 덮어쓰지 않는다. 호스트의 저장·복구·충돌 감지 정책이 적용된다. 실행 직전에 활성 상태, 현재 registry의 digest, action 소유권을 확인하며 주석에는 문서 권한·선택 페이지 소유권과 Undo 경계를 적용한다. 비활성화·제거는 이미 생성한 PDF 주석을 삭제하지 않는다.

## iPad·태블릿 필기

Mac의 Sidecar로 iPad에 앱 창을 표시하고 학습/에디팅 모드에서 펜을 선택한다. 펜 설정의 **태블릿 필압 사용**이 켜져 있으면 macOS의 tablet-point 이벤트와 pressure를 읽는다. 마우스는 기존 고정 굵기 Ink 경로를 사용한다.

필압 획은 표준 PDF appearance를 가진 Stamp로 저장한다. 한 획의 샘플 수는 8,192개로 제한하고 긴 획은 간소화한다. 현재 세션에서 생성한 획은 학습 모드의 신뢰 경계 안에서 지울 수 있다. 저장 후 재개방한 Stamp를 지우려면 에디팅 모드를 사용한다. 외부 PDF가 같은 이름을 붙였다고 학습 모드에서 자동 편집 권한을 얻지는 않는다.

앱 이벤트 처리와 저장 결과는 합성 테스트로 확인했다. 실제 iPad/Wacom의 필압·지연·팜 리젝션은 기기 검증이 남아 있다. 별도 iPad 앱, 무선 펜 전송 프로토콜, 기기 페어링은 이번 구현에 포함하지 않는다. Apple이 설명하는 Sidecar 입력 범위는 [공식 안내](https://support.apple.com/en-us/102597)를 참고한다.

## 확장 범위

이번 API는 앱이 제공하는 문서 명령을 조합하는 확장이다. Obsidian의 JavaScript API와 바이너리 호환되지 않으며 임의 코드, 자동 실행 훅, 커스텀 패널 코드, 외부 디바이스 드라이버는 실행하지 않는다. 사용자가 검토한 패키지와 검색형 명령 실행이라는 흐름을 먼저 마련했다.

향후 사용자 정의 도구·렌더러·이벤트 구독까지 늘리려면 프로세스 격리, 버전 협상, 실행 시간/메모리 예산, 문서 변경 transaction API를 함께 설계해야 한다. 현재 지원하지 않는 기능을 manifest에 써 넣으면 무시하지 않고 거부한다. 비교 자료: [Obsidian 공식 플러그인 시작 문서](https://docs.obsidian.md/Plugins/Getting%20started/Build%20a%20plugin), [공식 API 타입](https://github.com/obsidianmd/obsidian-api).
