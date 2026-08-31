# HwattakPDF 보안 정책

PDF와 플러그인 패키지는 복잡한 외부 입력이고, HwattakPDF는 파일 쓰기·Keychain·security-scoped bookmark·외부 AI API를 다룹니다. 보안 문제는 일반 버그와 분리해 제보해 주세요.

## 지원 범위

현재 프로젝트는 공개 개발자 프리뷰 단계입니다. 기본적으로 다음 범위를 최선의 노력으로 조사합니다.

- 기본 브랜치의 최신 코드
- 가장 최근에 공개된 릴리스

오래된 빌드에만 존재하는 문제는 최신 빌드 재현 여부를 먼저 확인할 수 있습니다. 아직 상용 SLA나 수정 기한을 보장하지는 않습니다.

## 비공개 제보 방법

취약점은 공개 GitHub Issue, Discussion, PR에 쓰지 마세요.

1. GitHub의 **Private vulnerability reporting**을 사용합니다.
2. 저장소의 [`Report a vulnerability`](https://github.com/SeederPowerDrop/HwattakPDF/security/advisories/new)를 사용합니다.
3. 아직 해당 버튼이 없다면 [프로젝트 소유자의 GitHub 프로필](https://github.com/SeederPowerDrop)로 최소한의 내용만 전달해 비공개 연락 경로를 요청합니다. 취약점 세부 정보, API 키, PDF 원문은 공개 프로필·이슈에 남기지 않습니다.

Private vulnerability reporting이 일시적으로 보이지 않으면 취약점 세부 내용을 공개 Issue에 쓰지 말고 프로젝트 소유자에게 비공개 연락 방법만 요청해 주세요.

## 제보에 포함할 내용

- 영향을 받는 HwattakPDF 버전과 빌드 번호
- macOS 버전과 Mac 아키텍처
- 공격에 필요한 조건과 예상 영향
- 가능한 한 작은 재현 단계
- 비식별화한 로그 또는 최소 fixture
- 이미 공개되었는지 여부와 희망 공개 일정

실제 계약서·의료 기록·학생 정보·서명 이미지·API 키·Keychain 덤프는 보내지 마세요. 원본 없이 재현하기 어렵다면 먼저 합성 PDF를 만들거나, 어떤 특성이 필요한지만 설명하고 안전한 전달 방법을 합의합니다.

## 우선 조사하는 사례

- 조작된 PDF를 열었을 때 임의 코드 실행, 앱 샌드박스나 파일 접근 범위 이탈
- 저장 대상이 아닌 파일을 덮어쓰거나 원본을 손상시키는 경로
- security-scoped bookmark 또는 최근 문서 정보의 권한·경로 누출
- 기본 서명이나 AI API 키가 다른 사용자·앱·기기로 의도치 않게 노출되는 문제
- 공식 공급자 키가 사용자 지정 호스트로 전송되는 문제
- 사용자 승인 없이 PDF 텍스트, 대화, 웹 질의 또는 MCP 도구 호출이 외부로 나가는 문제
- 모델 응답이나 PDF의 prompt injection이 승인 경계를 우회하는 문제
- `.hwattakplugin`이 선언형 경계를 벗어나 임의 코드·셸·Keychain·원본 PDF bytes·파일·GPU 또는 패키지 소유 네트워크/백그라운드 작업에 접근하는 문제
- 플러그인 package의 symlink·경로·검토/설치 경쟁으로 허용 범위 밖 파일을 읽거나 쓰는 문제
- 플러그인 action이 선언하지 않은 문서 metadata·선택문·현재 페이지 텍스트·클립보드·번역·YouTube·웹 브라우저 권한을 사용하거나, 사용자 확인 없이 외부 URL 또는 앱 내 원격 페이지를 여는 문제
- 악성 문서·응답으로 인한 통제되지 않는 메모리 또는 디스크 사용
- 작은 플러그인 package나 bounded action으로 재현되는 통제되지 않는 CPU·GPU·메모리·디스크 사용

단순 앱 종료, 렌더링 오류, 번역 오류는 일반적으로 버그 이슈입니다. 다만 작은 파일로도 반복 가능한 서비스 거부, 데이터 손실, 비밀 노출과 결합되면 보안 문제로 제보해 주세요.

## 처리 원칙

관리자는 제보를 확인한 뒤 재현 가능성, 영향 범위, 완화 방법을 정리합니다. 수정이 준비되기 전에는 불필요한 세부 정보를 공개하지 않습니다. 릴리스가 가능해지면 제보자와 공개 시점을 조율하고, 보안 권고에 영향 버전·수정 버전·완화책을 기록합니다. 선의의 연구와 책임 있는 공개를 존중하며, 사용자의 실제 데이터를 침해하거나 서비스를 방해하는 검증은 요청하지 않습니다.

## 플러그인 schema 1·2 보안 경계

현재 `.hwattakplugin`은 실행 가능한 번들이 아니라 엄격히 검증한 JSON manifest와 선택적
문서 파일로 이루어진 디렉터리다. BOM·과도한 nesting·중복/알 수 없는 key와 source
metadata/실제 bytes 불일치를 fail closed로 거부한다. 2 MiB source payload는 상한보다
한 바이트만 더 읽는 bounded read로 캡처한 실제 bytes 합계이며 host-owned 설치 기록은
별도 32 KiB 상한을 쓴다. 두 schema 모두 패키지 자체 코드, thread·timer, 셸, Keychain,
원본 PDF bytes, 직접 파일·네트워크·GPU API를 허용하지 않는다.

Schema 1은 허용된 token으로 bounded 텍스트를 만들고 `showText`, `copyText`, `openURL`
세 host action만 수행한다. 외부 URL은 공개 HTTPS host인지 다시 검사하고 대상 host와
포함될 문서 데이터 종류를 매 호출마다 승인받은 뒤 기본 브라우저에 전달한다.

Schema 2는 패키지 코드를 실행하는 대신 앱이 소유한 `translatePanel`, `youtubePanel`,
`browserPanel`만 선택한다. 이 웹 패널을 가진 패키지 또는 `dev.hwattakpdf.` 식별자
영역을 주장하는 모든 패키지는 검토 UI 전부터 앱 번들에 포함된 검토본과 identifier 및
manifest SHA-256이 모두 정확히 일치해야 설치·로드된다. 따라서 schema 1 패키지도
공식 이름으로 사칭·교체할 수 없다. 번역·YouTube·
일반 브라우저 capability는 서로 대체할 수 없고, 문서 텍스트는 번역 패널에만 제한된
불변 snapshot으로 전달된다. 앱 내 원격 페이지를 열기 전에 대상과 원격 JavaScript·
쿠키·추적·하위 요청 가능성을 고지하고 매번 확인받는다.

웹 패널은 비영구 WebKit 저장소를 사용하고 상위 이동을 다시 검사하며 script popup·
download·upload·카메라/마이크·파일 drop·폐기된 TLS를 차단한다. 사용자가 실제로 누른
표준 YouTube 링크만 exact host 검사와 확인 뒤 패널 또는 시스템 브라우저로 보낸다.
하지만 process-level network
firewall은 아니다. 허용된 원격 페이지의 JavaScript, 메모리 내 쿠키·저장소, 추적,
iframe·fetch·WebSocket·하위 리소스와 DNS의 실제 목적지를 모두 통제하거나 서비스의
보존 정책을 보증하지 않는다. 문서·탭·scene·플러그인 identity가 달라지거나 패널을
닫으면 요청을 폐기하고 WebView의 loading과 media playback을 중지한다.

설치 기록의 SHA-256은 현재 `manifest.json`이 설치 시 기록과 같은지 확인하는
**변경 감지 값일 뿐 게시자 인증, 디지털 서명, notarization이 아니다.** 같은 macOS
사용자 권한을 가진 공격자가 manifest와 설치 기록을 함께 바꾸는 상황이나 README,
LICENSE, icon의 진위를 막지 못한다. schema 1에는 서명된 catalog나 자동 악성 패키지 검사가
없으므로 권한·작성자·출처를 검토하고 신뢰하지 않는 패키지를 설치하지 않아야 한다.
기만적인 대화상자·클립보드 내용과 사용자가 승인한 외부 사이트의 동작도 앱이 신뢰성을
보증하지 않는다.

installer는 검증 실패·격리 항목도 플러그인 폴더의 visible `.hwattakplugin` entry로
세어 32개 slot 상한 우회를 막는다. 같은 사용자 권한으로 폴더에 entry를 직접 더 넣을
수는 있으나 새로 고침은 정렬된 첫 32개만 검증·로드하고 초과 항목을 문제로 표시한다.
따라서 Application Support를 hostile filesystem으로 완전히 격리하는 경계는 아니다.

패키지 규칙, 상한, 설치 복구와 전체 위협 모델은
[플러그인 가이드](Documentation/PLUGINS.md)에 있다. 향후 실행형 플러그인은 현재
프로세스에 코드를 직접 로드하지 않고 별도 서명·notarization 정책, 최소 entitlement의
sandboxed XPC, bounded versioned IPC, capability broker, timeout·취소·리소스 예산과
crash 격리를 갖추기 전에는 지원 범위로 간주하지 않는다.

## 로컬 OCR 체크포인트의 현재 개인정보 한계

중단한 OCR을 재개하기 위해 앱은 인식한 페이지 텍스트와 위치 상자를 사용자 계정의 `~/Library/Application Support/HwattakPDF/OCR Checkpoints/` 아래 JSON 파일로 저장합니다. 이 파일은 외부 서버로 자동 전송되지는 않지만 Keychain 항목도 아니고 앱 수준에서 별도 암호화하지 않은 평문입니다. FileVault와 macOS 사용자 계정 보호 범위에 의존합니다.

현재 버전에는 체크포인트 자동 보존 기한, 전체 삭제 버튼, 문서별 정리 UI가 없습니다. 활성 세대 안의 이전 generation은 정리하지만 다른 문서·설정의 체크포인트와 이전 형식 파일은 사용자가 앱 데이터를 지우기 전까지 남을 수 있습니다. 공용 Mac이나 민감한 문서에서는 이 잔존 데이터를 고려해야 하며, 정리 기능을 구현하기 전 수동 삭제는 진행 중 OCR의 재개 정보도 함께 잃는다는 점을 먼저 확인해야 합니다.

## 사용자가 지켜야 할 기본 수칙

- 신뢰할 수 없는 PDF는 최신 macOS와 최신 HwattakPDF에서 엽니다.
- API 키는 최소 권한·사용량 제한을 적용하고 정기적으로 교체합니다.
- 민감한 PDF를 AI에 보낼 때 전송 미리보기와 공급자 정책을 확인합니다.
- OCR 내보내기와 편집 저장 전 원본을 별도로 보관합니다.
- 민감한 문서를 OCR한 뒤에는 위 Application Support 경로에 남는 평문 체크포인트를 조직의 보존 정책에 맞게 처리합니다.
- 플러그인은 작성자 표기나 SHA-256만 믿지 말고 출처와 요청 권한을 확인하며, 외부 URL·앱 내 웹 패널 확인창의 대상 host와 전송 데이터가 예상과 다르면 취소합니다. 앱 내 웹 화면은 비영구 세션이지만 무추적·무저장 또는 완전한 네트워크 격리를 뜻하지 않습니다.
- 현재 배포 번들은 개발용 ad-hoc 서명이므로 정식 배포 전 Developer ID 서명과 공증 상태를 확인합니다.
