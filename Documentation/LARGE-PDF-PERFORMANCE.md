# 대용량·다중 PDF 성능 설계

## 현재 병목과 대응

50–200 MB PDF를 20–100개 열 때의 지배적인 비용은 Swift 계산이 아니라 PDFKit의
`PDFDocument`/`PDFPage` 객체 그래프, 렌더 타일 캐시, 숨은 `PDFView`, 파일 I/O다.
이번 구현은 해당 객체들의 수명을 직접 줄인다.

- SwiftUI에는 활성 탭의 `WorkspaceView`/`PDFView`만 생성한다. 탭 전환 시 이전
  `PDFView`는 dismantle되어 PDFKit 렌더 캐시와 이벤트 관찰자가 해제된다.
- 기본 3개(설정에서 1–12개)의 PDF 문서만 메모리에 유지한다. 깨끗한 비활성 탭은
  URL, 페이지 수, 현재 페이지와 선택 상태만 남기고 `PDFDocument`를 해제한다.
- 탭을 선택하면 해당 문서만 다시 만들고 보던 페이지로 이동한다. 편집 중인 문서와
  OCR 상태가 있는 문서는 파일에서 무손실 재생성할 수 없으므로 절대 휴면하지 않는다.
- 대량 열기는 Core Graphics로 컨테이너와 페이지 수만 먼저 검사해 비활성 탭을 경량
  descriptor로 만든다. 최종 활성 탭 하나만 `PDFDocument`를 생성하므로 SwiftUI 알림이
  배치 끝에 합쳐져도 20개 전체의 PDFKit 그래프를 만드는 피크가 없다. 각 탭은 자체
  security-scoped access를 유지해 나중에 선택됐을 때 안전하게 재개된다.
- 열기 패널, Finder 탭 드롭, launch arguments의 다중 파일 검사는 메인 actor 밖에서
  최대 3개(정책상 2–4개)만 동시에 수행한다. Finder/Dock의 개별 open-URL 이벤트도
  짧게 묶어 같은 배치로 보낸다. 결과는 원래 파일 순서로 한 번에 설치하며, 화면 소멸,
  새 배치, 워크스페이스 전환으로 취소된 검사는 탭·최근 문서·활성 선택을 변경하지 않는다.
- Darwin memory-pressure warning에서는 재생성 가능한 비활성 문서의 LRU 절반을,
  critical에서는 가능한 모든 깨끗한 비활성 문서를 즉시 해제한다.
- 열기/재개/저장 시 메인 스레드에서 50–200 MB 전체 SHA-256을 계산하던 경로를
  제거했다. 해시는 OCR을 실제 실행할 때만 detached 작업에서 계산한다.
- 열기 시 모든 페이지의 AcroForm 주석을 순회하지 않는다. 사용자가 본 페이지를
  상호작용 전에 prime하고, 저장·휴면 시 그 페이지들만 비교한다.
- 탭 선택 변경 전에 해당 `PDFView`가 소유한 field editor만 first responder에서
  내려 AcroForm 값을 확정하고, 모델 동기화가 끝난 뒤에만 휴면 정책이 실행된다.
  다른 컨트롤이나 다른 창의 편집 세션은 건드리지 않는다.

`PDFTabMemoryMetrics`는 현재 resident/hibernated/pinned 문서 수, 누적 휴면·재개 수,
마지막 처리 시간을 제공한다. 프로세스 RSS/CPU는 기존 `ProcessResourceMonitor`가
실측하며, 탭 리소스 화면에서 휴면 탭은 256 KiB의 경량 메타데이터 상태로 구분한다.

현재 리소스 모니터는 GPU 사용률이나 PDF별 CPU/RSS를 실측하지 않는다. GPU 렌더링과
타일 cache는 PDFKit·WindowServer가 함께 소유해 앱이 문서별 예산을 직접 배정할 수
없다. 대신 활성 탭 하나에만 `PDFView`를 만들고, 개요는 화면에 필요한 카드만 lazy
render하며 비용 상한이 있는 `NSCache`를 사용해 동시에 살아 있는 렌더 surface와
off-screen 작업을 줄인다. 실제 GPU·frame pacing·energy·thermal 회귀는 Instruments의
Core Animation, System Trace와 Energy 계측으로 별도 확인해야 한다.

## 플러그인 리소스 정책

플러그인 schema 1·2 package는 위의 호스트 앱 생명주기 정책을 우회하지 않는다.
`.hwattakplugin`은 실행 코드가 아니라 bounded manifest이므로 자체 `PDFDocument`·
`PDFView`, worker thread, timer, 파일 감시, 백그라운드 큐, 직접 네트워크 세션이나 GPU
작업을 만들 수 없다. 활성 플러그인도 사용자가 메뉴 action을 누르기 전에는 계산을
시작하지 않는다. Schema 2가 요청하는 번역·YouTube·브라우저 화면은 package 코드가
아니라 앱이 소유한 임시 `WKWebView`다.

- installer는 검증 실패·격리 항목까지 플러그인 폴더의 visible `.hwattakplugin` slot으로
  세어 최대 32개만 허용하고, 새로 고침은 정렬된 첫 32개 entry만 검증·로드한다. 각 정상
  manifest는 최대 24개 action이다. 같은 사용자 권한으로 entry를 직접 더 넣는 것은
  별도 hostile-filesystem 경계이며 문제 목록에는 표시하지만 action으로 로드하지 않는다.
- source package는 최대 5개 파일이며 실제 캡처한 payload `Data.count` 합계가 최대
  2 MiB다. 앱이 생성하는 `installation.json`은 이 합계에서 제외하고 별도 32 KiB
  상한을 쓴다. 설치 검토 동안만 source bytes를 캡처하고, 일반 시작과 새로 고침은 보조
  파일 payload를 유지하지 않고 패키지마다 최대 128 KiB의 manifest와 최대 32 KiB의
  설치 기록만 행동 검증에 읽는다.
- 선택문은 기존 bounded selection 경로로 최대 4,000자만 snapshot한다. 현재 페이지
  번역도 렌더 결과 상한 안의 불변 텍스트만 사용하며, live `PDFSelection`이나
  `PDFDocument`를 action 뒤까지 보관하지 않는다.
- 템플릿은 최대 16 KiB, 렌더 결과는 16,000자·64 KiB UTF-8, 외부 URL은 4 KiB다.
  상한을 넘으면 일부를 출력하거나 복사·열기 전에 action 전체를 실패시킨다.
- `openURL`도 앱 안에서 HTTP client를 돌리는 작업이 아니라 매번 사용자가 승인한 공개
  HTTPS URL을 기본 브라우저에 전달하는 host effect다.

이 구조는 package 자체의 상주 메모리와 지속 CPU/GPU 사용을 제한한다. 다만 schema 2
패널이 열린 동안에는 원격 페이지의 JavaScript·media·network가 CPU·메모리·네트워크를
소비하며 그 비용은 고정할 수 없다. 패널 닫기, 문서·탭·scene 변경, 플러그인 비활성화·
업데이트·제거 때 loading과 media를 중지하고 비영구 WebView를 폐기한다. 메뉴 registry
scan과 action latency도 실제 기기에서 0이라는 뜻은 아니므로, 릴리스 전에는 32개 visible
slot·각 24 action fixture와 패널 반복 열기/닫기로 launch·refresh·action latency, RSS와
WebContent process 정리를 함께 측정한다. 상세 스키마와 위협 모델은
[플러그인 가이드](PLUGINS.md)를 따른다.

## Rust 또는 Go를 지금 넣지 않은 이유

현 단계에서 Rust/Go 엔진은 성능 문제를 해결하지 않는다. 렌더링·페이지 해석·주석은
macOS PDFKit이 수행하므로 다른 언어로 감싸도 동일한 PDFKit 객체와 캐시를 유지한다.
오히려 C ABI 변환, 이중 데이터 복사, 수명 동기화가 추가된다. Go는 별도 런타임과 GC
힙까지 프로세스 RSS에 더하며 AppKit/PDFKit의 main-thread 제약도 없애지 못한다.

0.7.0 최종 검증에서 정책 자체의 100탭 벤치마크는 1,000회 실행 묶음 평균 약
0.093초, 즉 계획 1회당 약 0.093ms였다(2026-08-21 개발 머신의 XCTest wall-clock
계측). 이 부분을 네이티브 언어로 다시
작성하는 것은 체감 개선 여지가 없다.

Rust 도입은 Instruments/signpost 측정에서 다음 조건이 확인될 때 다시 검토한다.

1. PDFKit 밖의 자체 알고리즘(예: 전 문서 색인, 압축/디코딩)이 지속 CPU의 20% 이상을
   차지한다.
2. 입력과 출력이 불변 byte buffer로 명확해 FFI에서 PDFKit 객체를 넘기지 않는다.
3. 복사 비용을 포함한 end-to-end 벤치마크가 Swift 구현보다 유의미하게 빠르다.

그 전에는 Swift에서 객체 생명주기, lazy I/O, background 작업과 PDFKit 캐시 수를
관리하는 편이 더 작고 안전하며 실제 병목을 직접 해결한다.

## 검증

- `PDFTabMemoryManagerTests`: LRU/예산, warning/critical, dirty 보호, 실패 재개,
  경량 메타데이터 검사, 제한 동시성·순서·취소, 8개 배치에서 PDFDocument 1개만 생성,
  100탭 정책 벤치마크
- `PDFWorkspaceSafetyTests`: lazy AcroForm baseline, 탭 전환 전 field-editor 커밋과
  dirty 보호, PDFView 범위의 responder 판별
- `WorkspaceSessionStoreTests`: 휴면 탭을 포함한 워크스페이스/탭 스택 복원
- `ResourceMonitorTests`: 프로세스 RSS/CPU와 탭별 휴리스틱 계측
- 플러그인 32 visible slot·각 24 action fixture: launch/refresh/action latency,
  RSS 변화와 유휴
  CPU/GPU 작업 부재를 Instruments에서 수동 확인

자동 테스트는 객체 수명과 정책을 결정론적으로 검증하지만, 실제 50–200 MB 문서
20–100개를 GUI에서 스크롤·검색하는 RSS, 렌더 latency, thermal 영향은 fixture에 해당
문서가 없어 이번 환경에서 재현하지 못했다. 릴리스 전 실제 자료(민감정보 제거본)로
Instruments의 Allocations/Time Profiler/signpost를 측정하는 검증 단계가 남아 있다.
