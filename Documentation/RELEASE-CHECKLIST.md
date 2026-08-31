# HwattakPDF 중간 마일스톤·릴리스 체크리스트

이 목록은 “버튼이 보인다”가 아니라 데이터 손실 없이 실제 작업을 끝낼 수 있는지 확인하기 위한 것입니다. 모든 항목을 매 PR마다 실행할 필요는 없지만, 공개 릴리스 전에는 영향 영역을 골라 결과와 사용한 fixture 특성을 기록합니다.

## 자동 검증

- [ ] `./scripts/validate_project.sh`
- [ ] `./scripts/run_test_batches.sh`
- [ ] `./scripts/build_app.sh`
- [ ] 생성된 앱의 `codesign --verify --deep --strict`
- [ ] ZIP을 새 폴더에 풀어 앱·버전·아키텍처·리소스 재검증

## 열기·탭·복원

- [ ] 열기 패널, Finder drop, 명령행 인자로 PDF 열기
- [ ] 같은 파일을 다시 열 때 중복 탭 대신 기존 탭 활성화
- [ ] 탭 재정렬, 새 스택 생성, 기존 스택 합류, 스택 밖으로 꺼내기
- [ ] 탭 tear-out 새 창에서 미저장 편집과 현재 페이지 유지
- [ ] workspace 생성·이름 변경·탭 이동·삭제
- [ ] 앱 재실행 뒤 workspace, 탭 순서, 스택, 활성 페이지, 비교 구성 복원
- [ ] 이동·삭제된 최근 파일은 이해 가능한 오류를 보이고 나머지 세션은 복원

## 보기·검색·접근성

- [ ] 1페이지, 책 펼침 2페이지, 4페이지와 3~12열 개요 전환
- [ ] 페이지 번호 직접 이동의 1, 마지막, 0, 전체보다 큰 값 처리
- [ ] 좌·우·상·하 페이지 패널 크기 조절과 최소 크기
- [ ] 확대 수정키 설정, 포인터 중심 확대, `⇧+휠` 가로 이동, 핀치·일반 스크롤
- [ ] `⌘F`, Enter, Shift+Enter, Esc와 검색 사이드바 결과 클릭
- [ ] 설정·정보·도움말 창과 시트가 앞에 있을 때 `⌘T`·`⌘O`가 숨은 PDF 창을 조작하지 않고, `⌘W`가 실제 앞 창이나 시트를 닫음
- [ ] 한국어·영어·일본어·중국어·아랍어, 줄바꿈 문장, 결과 없음, 20,000건 상한
- [ ] 텍스트 없는 스캔 문서와 일부 페이지만 텍스트 없는 문서의 OCR 안내 차이
- [ ] 키보드만으로 툴바·구분선·사이드바 이동
- [ ] VoiceOver 레이블과 Arabic RTL에서 순서·잘림 확인

## 뷰어·에디팅·학습 모드

- [ ] `⌃1`·`⌃2`·`⌃3`과 상단 선택기가 같은 탭의 모드를 바꾸고 재실행 뒤 복원
- [ ] 뷰어에서는 읽기·선택·주석·서명·번역·AI·메모 공유만 보이고 페이지/이미지 편집은 숨김
- [ ] 에디팅에서는 인라인 FreeText, 이미지·서명 이미지, 펜과 페이지 편집을 사용할 수 있음
- [ ] 학습에서는 번역·용어·요약·풀이·학습 포인트·퀴즈와 타이핑/펜 메모·조절형 표식만 보임
- [ ] 모드를 바꾸는 순간 진행 중이던 펜·지우개·이미지 drag와 열린 서명 창이 새 권한을 우회하지 않음
- [ ] 학습 지우개가 학습 메모·필기·표식만 지우고 이미지·서명·외부 앱 주석은 보존
- [ ] 비교 창에서는 원본 탭의 선택 도구와 무관하게 펜·텍스트·지우개·양식 편집·변이 메뉴가 모두 차단
- [ ] 에디팅 인라인 텍스트의 한국어·일본어·중국어 IME, 붙여넣기 상한, Return/Shift-Return/Esc, 저장·닫기·모드 전환 commit 확인
- [ ] 시각적 텍스트 교체 뒤 원문이 검색·복사에 남아 secure redaction이 아님을 화면과 도움말이 안내
- [ ] 조절형 학습 표식이 Preview와 외부 뷰어에서 같은 외형으로 보이고 semantic Highlight/Underline이 아닌 Stamp임을 안내
- [ ] 메모 공유 미리보기와 실제 payload가 일치하고 파일명·경로·페이지 metadata·선택하지 않은 텍스트가 포함되지 않음

## 편집·실행 취소

- [ ] 펜, 하이라이트, 자유 텍스트, 서명, 이미지, 양식 값 편집
- [ ] 추가한 텍스트·이미지·서명 선택과 이동
- [ ] 이미지·서명 크기 조절, 이미지 crop·삭제·레이어 변경
- [ ] 선택 장식과 삭제 `×`가 저장된 서명/이미지에 포함되지 않음
- [ ] 이미지를 자른 뒤 저장 PDF에서 잘라낸 바깥 픽셀을 원본 raster/XObject로 복구할 수 없음
- [ ] 각 기능을 `⌘Z`로 되돌리고 `⇧⌘Z`로 다시 실행
- [ ] 서로 다른 탭의 이력이 섞이지 않음
- [ ] 22단계 경계와 저장 지점까지 되돌렸을 때 dirty 표시
- [ ] 페이지 재정렬·회전·삭제·추출·병합 후 페이지 수와 순서
- [ ] 사용자 암호로 연 암호화 PDF는 양식·페이지·주석 변경이 모두 읽기 전용이며, 소유자 암호로 연 문서는 정상 편집됨
- [ ] 양식 입력 도중 페이지 이동·삭제·병합을 실행해도 입력이 원래 페이지에 한 번만 기록되고 실행 취소 순서가 유지됨

## 저장과 데이터 손실 방지

- [ ] 새 파일로 저장, 원본 덮어쓰기, 취소
- [ ] 미저장 탭 닫기·창 닫기·앱 종료에서 저장/버리기/취소
- [ ] 읽기 전용 폴더, 공간 부족, File Provider 오류를 흉내 냈을 때 원본 유지
- [ ] 저장한 PDF를 Apple Preview와 한 개 이상의 외부 뷰어에서 다시 열기
- [ ] 원본을 연 뒤 Preview가 atomic replacement로 먼저 저장했을 때 HwattakPDF 덮어쓰기 차단, 외부 bytes와 dirty 메모리 편집 보존
- [ ] 외부 변경 충돌 뒤 별도 저장으로 편집본을 복구하고 새 파일의 다음 덮어쓰기 baseline 갱신
- [ ] 원본이 삭제됐을 때 조용히 재생성하지 않고 dirty 편집 유지
- [ ] 주석·이미지·서명 appearance, 회전, 페이지 순서, 양식 값 확인
- [ ] 제한된 암호화 PDF의 페이지 PDF/PNG 추출·병합·OCR 사본이 권한에 맞게 차단되고, UI 우회 호출도 같은 결과를 냄
- [ ] PNG 여러 장 내보내기가 기존 폴더·파일을 덮어쓰지 않고, 중간 페이지 실패 때 일부 결과를 남기지 않음
- [ ] OCR 사본 목적지가 원본·symlink·hardlink이거나 작업 중 원본 alias로 바뀌면 원본 bytes를 유지한 채 실패함
- [ ] sibling 임시 파일 교체 경로에서 저장 중 앱 종료/실패 뒤 목적지에 부분 PDF가 남지 않음
- [ ] 파일 단위 샌드박스 권한의 직접 쓰기 fallback에서는 강제 종료·공간 부족 시 원본이 손상될 수 있음을 릴리스 한계와 원본 백업 안내에 포함하고, 실제 File Provider 위치별 결과 기록

## 서명·Keychain

- [ ] 트랙패드와 마우스 입력, 감도·스무딩·굵기 경계
- [ ] 기본 서명 저장·재실행 로드·교체·삭제
- [ ] 다른 macOS 사용자 계정에서 서명이 보이지 않음
- [ ] 잠긴 Keychain과 접근 거부에서 안전한 오류 처리
- [ ] ad-hoc과 정식 서명 빌드의 Keychain migration 계획 확인

## 선언형 플러그인

- [ ] `Examples/Plugins/QuickCitation.hwattakplugin`을 설치할 때 이름·버전·작성자·네 권한·파일 수·크기·manifest digest가 검토 화면과 일치함
- [ ] `showText`, `copyText`, `openURL` action이 각각 bounded 대화상자, 일반 클립보드, 확인 후 기본 브라우저 효과만 수행함
- [ ] 문서 metadata action은 열린 PDF가 없을 때, selection action은 공백이 아닌 선택이 없을 때 비활성화되거나 안전한 오류를 보임
- [ ] 외부 URL마다 host와 선택문·문서 metadata 포함 여부를 다시 보여 주며 취소하면 브라우저를 열지 않음
- [ ] HTTP, embedded credential, IP literal, localhost·단일 label·예약 local suffix URL을 거부하고 raw 선택문·문서 이름을 넣은 `openURL` manifest도 설치하지 않음
- [ ] 같은 identifier 업데이트 성공, 잘못된 업데이트의 이전 버전 보존, 중단된 staging/backup 복구와 비활성 상태 유지 확인. 현재 version 순서 비교·자동 업데이트가 없다는 안내도 확인
- [ ] 비활성화 뒤 메뉴에서 action이 사라지고 재실행 뒤 유지되며, 다시 활성화하면 돌아옴. 삭제 확인 뒤 package와 disabled identifier가 제거됨
- [ ] BOM, 64단계 초과 nesting, escape 후 같은 것을 포함한 중복·알 수 없는 JSON key, 알 수 없는 token·output·capability, capability 누락/미사용·중복, 제어·bidi 방향 위장 문자, 예약된 `com.vibepdf.`/`com.hwattakpdf.` identifier를 거부함
- [ ] symlink·하위 디렉터리·추가 파일·가짜 PNG와 file metadata/실제 byte 수 불일치를 거부함
- [ ] 검증 실패 항목도 차지하는 32 visible package slot·각 24 action, 5 file·2 MiB source payload, 별도 32 KiB 설치 기록, 128 KiB manifest, 16 KiB template, 16,000자/64 KiB 렌더 결과와 4 KiB URL의 경계값·초과값 확인
- [ ] 설치된 manifest만 바꾸면 digest 불일치로 action registry에서 제외되며, SHA-256이 게시자 인증·서명으로 표시되지 않음
- [ ] 32 visible slot·각 24 action fixture에서 launch·새로 고침·action latency와 RSS를 기록하고, 유휴 플러그인이 worker·timer·네트워크·지속 CPU/GPU 작업을 만들지 않음을 Instruments로 확인

### schema 2 기본 웹 패널 수동 확인

> 0.8.0에서는 번역·웹 브라우저만 배포한다. 아래 YouTube 항목은 비활성 실험 기능의 향후 배포 조건이며 현재 ZIP의 출고 조건이 아니다.

- [ ] 플러그인 관리의 기본 목록에서 번역·웹 브라우저 검토본만 보이고, 설치 화면에 action별 데이터 출처·외부 연결·분리 권한이 표시됨. 앱 업데이트로 bundled digest가 바뀐 기존 설치본은 격리하되 새 검토본을 `업데이트`로 복구할 수 있음
- [ ] Google 번역은 선택문/현재 페이지와 문자·byte 수·host를 확인하기 전 요청이 0회이고 승인 뒤에만 전송함. ChatGPT·Claude는 승인 전 클립보드 쓰기와 WebView 생성이 0회이며, 승인 뒤 prompt 복사와 사용자의 붙여넣기·보내기 사이를 구분해 안내함
- [ ] YouTube 검색과 direct watch/share/shorts/live URL이 동작하고 유효 ID는 `youtube-nocookie.com` embed로 바뀜. 플레이어가 최소 200×200이고 HwattakPDF overlay가 player controls를 가리지 않으며 자동 재생하지 않음
- [ ] 사용자가 누른 YouTube 로고·채널·관련 링크는 검증과 확인 뒤 시스템 브라우저로 열리고, script popup·비YouTube popup·download는 계속 차단됨
- [ ] 영상·오디오 재생 중 패널 닫기, 탭 전환·휴면, 집중 보기, scene 비활성화, 플러그인 비활성화·업데이트·제거 각각에서 즉시 재생이 멈춤
- [ ] popup, custom/file/data/javascript scheme, navigation download·attachment, file input, 카메라·마이크, deprecated TLS가 차단됨. 웹 패널 위에 canary PDF/텍스트 파일을 놓아 페이지의 drop/FileReader handler가 파일명과 bytes를 받지 못하고, 문서 화면·사이드바 drop은 새 PDF 탭을 정상적으로 엶
- [ ] 패널을 닫고 다시 열거나 앱을 재실행했을 때 비영구 WebKit 쿠키·storage·방문 기록이 복원되지 않음. 단, 열린 세션 중 원격 JavaScript·쿠키·추적·하위 리소스 요청은 가능하고 완전한 방화벽/추적 방지기로 안내되지 않음
- [ ] 좁은 창, 키보드만 사용, VoiceOver 아이콘 레이블, 10개 언어와 Arabic RTL에서 주소창·전송 검토·닫기·외부 열기 UI가 잘리지 않음
- [ ] **YouTube 연동을 향후 배포할 때의 차단 조건:** 제품 소유자가 실제 데이터 수집·보존·삭제를 반영한 앱 개인정보처리방침과 이용약관을 확정하고, YouTube 기능 접근 전 동의 및 항상 접근 가능한 [YouTube Terms](https://www.youtube.com/t/terms)·[Google Privacy Policy](https://policies.google.com/privacy) 링크를 앱에 넣음. 이후 [필수 최소 기능](https://developers.google.com/youtube/terms/required-minimum-functionality), [개발자 정책](https://developers.google.com/youtube/terms/developer-policies), [임베드·개인정보 보호 강화 모드 안내](https://support.google.com/youtube/answer/171780)를 다시 검토함. 고정 Referer가 현재 bundle identifier에서 파생되고 PDF·사용자 텍스트를 포함하지 않는지 확인함

## OCR

- [ ] 한국어·영어·일본어 단일/혼합 스캔 페이지
- [ ] 기존 텍스트 페이지 건너뛰기
- [ ] 작업 취소 후 같은 설정으로 재개
- [ ] 설정 변경·문서 변경 시 오래된 체크포인트 재사용 방지
- [ ] Application Support에 남는 평문 OCR 텍스트와 현재 삭제·보존 한계를 릴리스 노트에 고지
- [ ] 체크포인트 정리 기능이 추가되기 전에는 수동 삭제가 진행 중 재개 정보도 지운다는 안내 확인
- [ ] 회전·crop box·혼합 크기 페이지의 텍스트 위치
- [ ] 검색 가능한 사본을 Preview와 외부 뷰어에서 검색·선택
- [ ] 원본과 출력의 링크·폼·주석·북마크 차이를 사용자에게 안내

## 대용량·메모리

- [ ] 50~200MB 문서 20개 이상 열기 동안 UI 응답성과 peak RSS 기록
- [ ] 100개 탭에서 resident 예산과 clean 탭 LRU 휴면 확인
- [ ] dirty·OCR·비교 문서는 휴면하지 않음
- [ ] warning/critical 메모리 압력 뒤 활성 문서가 안전하게 유지됨
- [ ] 대형 탭 재개 후 페이지·선택·검색 상태가 유효함
- [ ] Instruments Allocations·Time Profiler·Core Animation/System Trace·Energy 결과와 기기 사양을 기록하고 GPU·frame pacing·thermal 회귀 확인

## 외부 AI·MCP

- [ ] API 키 저장·삭제, 공식 키가 공식 endpoint에만 전송
- [ ] 사용자 지정 endpoint가 별도 자격 증명을 사용
- [ ] 선택/현재/선택 페이지/대표 문서 범위와 문자 상한
- [ ] 전송 미리보기에서 로컬 경로와 불필요한 원문이 빠짐
- [ ] 취소·timeout·비정상 JSON·16MiB 응답 상한
- [ ] 웹 검색 전 안내와 검증된 `http`/`https` 출처만 열기
- [ ] MCP 서버·도구·인자를 호출마다 승인·거부
- [ ] PDF prompt injection 문구만으로 웹/MCP가 자동 실행되지 않음
- [ ] AI 초안이 확인 없이 PDF를 변경하지 않음
- [ ] 두 PDF 창에서 AI를 실행할 때 한 창의 패널 숨김·탭 전환이 다른 창의 요청을 취소하지 않음

## 릴리스 판정 기록

```text
버전 / build:
commit:
macOS / Mac 모델:
자동 테스트 결과:
사용한 합성·공개 fixture 특성:
실행한 수동 항목:
발견한 문제와 연결된 Issue:
출시를 막는 문제:
검토자와 날짜:
```
