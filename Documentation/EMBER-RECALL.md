# Ember Recall · 복습 카드 플러그인

Ember Recall은 PDF를 읽으며 선택한 문장을 질문·답 카드로 바꾸는 로컬 학습 플러그인입니다. 읽은 내용을 떠올리고 원문으로 돌아가는 짧은 복습 흐름을 제공합니다.

## 제공 기능

| 기능 | 사용 방법 |
| --- | --- |
| 선택문으로 카드 만들기 | 현재 PDF 페이지의 문장을 선택하고 질문·답 작성 |
| 답 가리기 | 질문부터 보고 ‘답 보기’로 답·원문을 확인, ‘답 숨기기’로 다시 가리기 |
| 오늘 복습 | 복습 시간이 된 카드만 표시, ‘다시 복습’은 10분 뒤, ‘알겠음’은 1·3·7·14·30일 간격으로 예약 |
| 원문 페이지 이동 | 같은 창에 열려 있는 원문 탭과 인용문을 확인한 뒤 해당 페이지로 이동 |
| 카드함 | 질문·답 수정, 개별 삭제, 로컬 저장과 여러 창의 변경 병합 |

AI나 계정 없이 동작하고 PDF 파일을 수정하지 않습니다. 원문 인용과 복습 기록은 플러그인 전용 로컬 저장소에 보관합니다.

## 설치 조건과 공개 상태

**2026-10-16 공개 범위는 플러그인 소스 미리보기입니다.** GitHub 기본 앱 소스의 공개 기준은 HwattakPDF **0.9.0 build 20 / schema 1~3**이며, 이 호스트에는 실행형 플러그인 API가 없어 Ember Recall을 설치할 수 없습니다.

실행하려면 **schema 6을 명시적으로 지원하는 EmberPDF 개발 빌드(0.9.0 build 27 이상)**가 필요합니다. 버전 번호 `0.9.0`만으로 호환성을 판단하지 마세요. 이번 플러그인 공개는 호환 앱 실행 파일·호스트 SDK의 공개 또는 새 앱 릴리스 배포를 포함하지 않습니다.

호환 호스트에서는 다음 순서로 사용합니다.

1. 이 저장소의 **Code → Download ZIP**으로 소스를 내려받아 압축을 풉니다.
2. **플러그인 → 플러그인 관리… → 플러그인 설치…**에서 `Examples/Plugins/EmberRecall.hwattakplugin` 폴더를 선택합니다.
3. **⇧⌘P**에서 `Ember Recall`을 검색합니다.
4. PDF 문장을 선택해 카드를 만들거나 **오늘 복습**을 실행합니다.

[플러그인 패키지](../Examples/Plugins/EmberRecall.hwattakplugin) · [자세한 사용 설명과 권한](../Examples/Plugins/EmberRecall.hwattakplugin/README.md)

## 현재 범위

- 최대 50개 카드와 60,000바이트 JSON 예산을 사용합니다. 긴 답·원문을 많이 저장하면 카드 수보다 먼저 저장 한도에 도달할 수 있습니다.
- 원문 자동 이동은 카드를 만든 창에 원문 탭이 계속 열려 있을 때 지원합니다. 제한된 열린 문서 검색에서 인용문을 확인하지 못하면 이동하지 않고 파일명·페이지를 안내합니다.
- 저장한 카드·복습 기록은 앱 재실행 후에도 유지됩니다. 닫았다가 다시 연 문서의 자동 재연결, 앱 밖 복습 알림, Anki 연동과 AI 자동 출제는 제공하지 않습니다.

## 검증

- [Node 동작 검사](../scripts/tests/test_ember_recall.mjs): 32개 통과. 카드 작성·수정·삭제, 답 가림, 일정 계산, 동시 저장·충돌, 저장 실패, 원문 이동 경합과 저장 한도를 확인했습니다.
- [JavaScriptCore 실행기 검사](../scripts/tests/smoke_ember_recall_worker.mjs): schema 6 개발 호스트에서 6개 통과. 실제 실행기의 코드 로드, 카드 저장, 답 가리기, 원문 이동, 복습 일정과 재시작 복구를 확인했습니다.
- schema 6 개발 호스트의 네이티브 패키지 검사기에서 1개 통과. GUI를 통한 설치 전체 시나리오는 별도 확인 대상입니다.

공개 저장소에서 독립 실행할 수 있는 동작 검사는 다음과 같습니다. Node.js 20 이상을 사용합니다.

```sh
node --test scripts/tests/test_ember_recall.mjs
```

## English

Ember Recall turns selected PDF sentences into local flashcards with editable questions and answers, hidden answers, a due-review queue and verified source-page navigation. Cards can be edited or deleted and remain stored across app restarts.

**This is a plugin source preview requiring a schema 6 EmberPDF development host.** The public host baseline at publication is HwattakPDF 0.9.0 build 20 (schema 1–3), which cannot install the extension. The plugin publication does not include a host application or SDK release. See the [package README](../Examples/Plugins/EmberRecall.hwattakplugin/README.md) for installation, permissions and limits.
