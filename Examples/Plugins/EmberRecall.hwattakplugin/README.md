# Ember Recall · 복습 카드

EmberPDF에서 선택한 문장으로 질문·답 카드를 만들고, 답을 가린 채 복습하는 독립 플러그인입니다. AI나 계정 없이 이 Mac에 카드를 저장합니다.

> **GitHub 공개 범위 (2026-10-16):** 이 패키지는 **schema 6 호스트용 플러그인 소스 미리보기**입니다. 공개 기준의 GitHub 기본 앱 소스는 0.9.0 build 20 / schema 1~3이며 이 플러그인을 실행하지 못합니다. 아래 기능은 schema 6을 지원하는 EmberPDF 개발 빌드에서 검증했습니다. 플러그인 소스 공개와 호환 앱·SDK 공개는 별개입니다.

## 설치

1. **EmberPDF 0.9.0 build 27 이상**에서 **플러그인 → 플러그인 관리… → 플러그인 설치…**를 엽니다. schema 6 실행형 확장을 지원하는 빌드가 필요합니다.
2. `EmberRecall.hwattakplugin` 폴더를 선택합니다. ZIP으로 받았다면 먼저 압축을 풉니다.
3. 이름 **Ember Recall · 복습 카드**와 아래 권한을 확인하고 설치·활성화합니다.
4. **⇧⌘P**에서 `Ember Recall`을 검색합니다. 플러그인 메뉴와 확장 패널에서도 명령을 실행할 수 있습니다.

호환되는 schema 6 호스트가 설치되어 있다면 앱 본체를 다시 빌드할 필요가 없습니다. 이 패키지는 직접 설치하는 확장이며 앱의 기본 번들 목록에는 추가하지 않습니다.

## 카드 만들기

1. PDF의 현재 페이지에서 한 페이지 안의 문장을 선택합니다. 선택문은 1,000자 이내여야 합니다.
2. **Ember Recall · 선택문으로 카드 만들기**를 실행합니다.
3. 질문을 적고, 선택문으로 미리 채워진 답을 필요하면 내 말로 고칩니다. 질문은 240자, 답은 1,000자까지입니다. 입력란은 현재 SDK의 한 줄 텍스트 필드입니다.
4. **카드 저장**을 누릅니다. 원문·파일명·페이지와 카드가 함께 저장되며 즉시 복습할 수 있습니다.

선택문이 현재 페이지의 텍스트에 있는지 확인합니다. 여러 페이지에 걸친 선택, 다른 페이지에 남아 있는 선택, 읽을 수 없는 텍스트는 저장 전에 안내합니다. 스캔 PDF는 먼저 EmberPDF의 OCR로 텍스트를 인식해야 합니다.

## 오늘 복습

**Ember Recall · 오늘 복습**은 새 카드와 복습 시간이 된 카드를 보여 줍니다. 시작할 때는 질문만 보이며, 답과 선택 원문은 가립니다.

- **답 보기 / 답 숨기기**: 답을 떠올린 뒤 확인합니다. 답을 보기 전에는 복습 평가 버튼을 표시하지 않습니다.
- **다시 복습 · 10분 뒤**: 10분 뒤 다시 복습할 수 있게 합니다.
- **알겠음 · 다음 복습일로**: 성공할 때마다 1일 → 3일 → 7일 → 14일 → 30일 간격으로 늘립니다. 이후에는 30일 간격입니다. ‘다시 복습’을 누르면 간격이 초기화됩니다.
- **이전 카드 / 다음 카드**: 평가하지 않고 다른 카드로 이동합니다. 다음 카드의 답은 다시 가려집니다.
- **새로고침**: 현재 시간과 다른 창에서 저장한 카드를 다시 읽습니다.

복습일은 평가할 때의 Mac 현지 날짜와 자정을 기준으로 계산합니다. 패널을 열거나 새로고침할 때 복습 목록을 갱신합니다. 앱 밖 알림이나 타이머는 실행하지 않습니다.

## 카드함과 원문 이동

**Ember Recall · 전체 카드함**에서 아직 복습일이 오지 않은 카드도 볼 수 있습니다. 질문과 답을 수정하고, 확인을 거쳐 개별 카드를 삭제할 수 있습니다.

**원문 페이지로 이동**은 카드를 만들었던 **같은 앱 창에 원문 탭이 계속 열려 있을 때** 사용합니다. 이동하기 전에 탭 ID, 파일명, 페이지 수와 해당 페이지의 인용문을 열린 PDF 검색으로 확인합니다. 파일 이름만 보고 다른 문서로 이동하지 않습니다.

현재 SDK의 열린 문서 검색은 최대 8개 PDF, 문서당 3개 결과로 제한됩니다. 원문이 검색 범위 밖이거나 내용이 바뀌었으면 파일명·페이지를 안내합니다. 원문 탭을 닫았다가 다시 열었거나 앱을 재실행한 뒤에는 직접 해당 파일·페이지를 열어 주세요. **카드와 복습 기록은 재실행 후에도 유지되지만 원문 자동 재연결은 제공하지 않습니다.**

## 저장과 권한

최대 **50개 카드**, 플러그인 JSON 저장 예산 **60,000바이트**를 사용합니다. 긴 질문·답·원문을 많이 저장하면 50개보다 먼저 한도에 도달할 수 있습니다. 한도에 도달하면 기존 카드를 지우거나 잘라내지 않고 저장을 멈추며 초안을 유지합니다. 여러 창의 변경은 원자적 비교·교체로 병합하고, 같은 카드의 동시 수정은 안내합니다.

| 권한 | 사용하는 이유 |
| --- | --- |
| `backgroundExecution` | 창이 열려 있는 동안 명령과 패널, 작성 중 초안을 유지 |
| `documentMetadata` | 출처 파일명·페이지·복사 허용 상태 확인 |
| `selectedText` | 사용자가 선택한 문장을 카드에 삽입 |
| `currentPageText` | 선택문이 현재 페이지에 있는지 확인 |
| `openDocumentsRead` | 원문 이동 시 열린 탭과 해당 페이지의 인용문 확인 |
| `workspaceNavigation` | 확인한 원문 탭·페이지로 이동 |
| `pluginStorage` | 카드·답·원문과 복습 기록을 로컬에 저장 |

선택 원문도 로컬 카드 데이터에 저장됩니다. PDF를 수정하지 않으며 네트워크 연결·외부 AI·임의 파일 접근은 사용하지 않습니다. 플러그인을 재시작하거나 앱 창을 닫으면 저장하지 않은 초안은 사라집니다.

## 개발 및 검증

저장소 루트에서 실행합니다.

```sh
node --test scripts/tests/test_ember_recall.mjs
node scripts/tests/smoke_ember_recall_worker.mjs
zsh scripts/validate_plugin.sh Examples/Plugins/EmberRecall.hwattakplugin
```

Node 동작 검사는 이 저장소의 플러그인 파일만으로 실행할 수 있습니다. worker smoke에는 schema 6 개발 호스트의 빌드된 `EmberPluginWorker`가 필요하고, 네이티브 패키지 검증도 schema 6 호스트 소스에서 실행해야 합니다. 현재 공개된 이전 호스트로는 두 검증을 실행할 수 없습니다.

코드를 변경하면 `main.js`의 SHA-256을 `manifest.json`의 `runtime.sha256`에 갱신한 뒤 패키지를 다시 검증·설치합니다. 테스트 코드는 설치 패키지 밖에 둡니다.

## English

Ember Recall is a local flashcard extension: select a sentence, write a question and answer, hide/reveal the answer, review due cards, and return to a verified source page in an existing PDF tab. Successful reviews use 1, 3, 7, 14 and 30 calendar-day intervals; “Again” schedules another review in ten minutes. Cards persist locally, with a maximum of 50 cards within a 60,000-byte JSON budget.

**Source preview for schema 6 hosts.** The public host baseline at publication is HwattakPDF 0.9.0 build 20 with schema 1–3; that host cannot install this extension. A compatible EmberPDF development host (0.9.0 build 27 or later, explicitly supporting schema 6) is required. Publishing this plugin does not publish or update the host application.

Install the unzipped `EmberRecall.hwattakplugin` folder through the host's plugin manager, then search for `Ember Recall` with **⇧⌘P**. Source navigation requires the original tab to remain open in the same app window; cards and review schedules survive relaunch, but automatic source reconnection does not. No PDF modification, external AI, network access or arbitrary file access is used.
