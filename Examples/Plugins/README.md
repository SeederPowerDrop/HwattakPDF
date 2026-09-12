# HwattakPDF 플러그인 예제 / Plugin examples

[제작 시작](../../Documentation/PLUGIN-DEVELOPMENT.md) · [English](../../Documentation/PLUGIN-DEVELOPMENT.en.md) · [API](../../Documentation/PLUGIN-HOST-API.md) · [호환성](../../Documentation/PLUGIN-COMPATIBILITY.md)

## 복사해서 만드는 커뮤니티 예제

| 패키지 | schema | 배울 내용 |
| --- | --- | --- |
| [OfflineChecklist](OfflineChecklist.hwattakplugin/manifest.json) | 1 | 권한 없이 텍스트 표시. 첫 설치에 적합 |
| [CommunityStarter](CommunityStarter.hwattakplugin/manifest.json) | 3 | 하이라이트·밑줄·펜·학습 모드·페이지 이동 |
| [MarkdownQuote](MarkdownQuote.hwattakplugin/manifest.json) | 1 | 선택 문장을 Markdown으로 미리보기/복사 |
| [ReferenceSearch](ReferenceSearch.hwattakplugin/manifest.json) | 1 | 선택 문장의 공개 HTTPS 검색과 호출별 동의 |
| [QuickCitation](QuickCitation.hwattakplugin/manifest.json) | 1 | 텍스트 출력·복사·링크의 종합 예 |

복사 후 **identifier·작성자·이름을 바꾸고** 기능과 권한을 수정한다. `org.example.*`와 `dev.example.*`는 예제용이며 제작자 인증이 아니다. schema 3은 2026-09-05 안정화 후보 또는 실제 지원을 확인한 빌드가 필요하다. 이전 0.8.0/build 18과 구별하는 방법은 호환성 문서를 따른다.

이 커뮤니티 예제는 앱의 기본 번들 목록에 자동 추가되지 않는다. 개발 소스/검증 예제이며 사용자가 자신의 패키지를 설치하는 경로를 보여 준다.

## 앱에 포함하는 공식 검토 패키지

TranslationCompanion, WebBrowser, StudyMarkup, TabletTools, ReadingNavigation은 앱 번들 검토본과 **identifier 및 manifest digest**가 일치해야 설치된다. 이 예제를 수정해 독자 배포하려면 커뮤니티 허용 출력인지 확인하고 자신의 identifier를 사용해야 한다. 공식 패널 출력은 ID만 바꿔도 커뮤니티 패키지로 배포할 수 없다.

**YouTubeStudy는 검토용 소스 전용**이다. 현재 배포 후보의 기본 패키지에 포함되지 않으며 커뮤니티 검사기로 설치 가능하다고 판정하지 않는다.

## 검증

저장소 루트의 Mac 터미널에서:

```sh
zsh scripts/validate_plugin.sh --examples
zsh scripts/validate_plugin.sh Examples/Plugins/CommunityStarter.hwattakplugin
```

앱 검사기를 사용하는 이 명령은 커뮤니티 배포 규칙을 검사하며, 사용자 설치 폴더에 쓰지 않는다. 처음에는 Swift 테스트 빌드가 필요하다. 테스트 PDF나 스크린샷, 이 인덱스 README 자체를 `.hwattakplugin` 안에 넣지 않는다.

English: start with OfflineChecklist or CommunityStarter, replace the example identity, then
validate and install through the manager. The other community examples demonstrate Markdown
copying and confirmed HTTPS searches. Official bundles use a separate exact-digest trust gate;
YouTubeStudy is source-only. See the English author guide for packaging and compatibility details.
