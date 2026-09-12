# Community Study — starter package

## 한국어

이 패키지는 복사해서 수정할 수 있는 커뮤니티 예제입니다. `manifest.json`의
`identifier`를 자신의 고유 식별자로, `author`와 `displayName`을 실제 정보로 바꾸세요.
`org.example.*`는 학습용 예시 이름이며 제작자 신원을 인증하지 않습니다.

- 호환: macOS 14+, HwattakPDF **schema 3 지원 빌드**. 2026-09-05 안정화 후보로 검사했습니다.
  이전 0.8.0/build 18은 schema 3을 지원하지 않을 수 있습니다.
- 설치: 디렉터리 자체를 `플러그인 → 플러그인 관리… → 플러그인 설치…`에서 선택합니다.
- 사용: 시험용 PDF를 열고 학습 모드 명령을 실행한 뒤 텍스트 선택 → 하이라이트/밑줄,
  또는 펜 명령 → 직접 필기합니다. ⇧⌘P로 검색할 수도 있습니다.
- 권한: `annotationWrite`는 주석 추가, `toolControl`은 도구 설정,
  `workspaceNavigation`은 모드/페이지 이동에 필요합니다. 편집은 Undo/Redo를 지원합니다.
- 데이터: 이 예제는 텍스트 추출·클립보드·외부 전송 권한을 요청하지 않습니다.
  파일은 사용자가 별도로 저장합니다. 자동 복구 설정이 켜져 있으면 호스트의 로컬 복구 정책이 적용됩니다.
- 업데이트: 원본 패키지를 수정하고 `version`을 올린 뒤 관리 창에서 다시 선택합니다.
  설치된 디렉터리를 직접 고치면 무결성 검사에 걸립니다.
- 한계: 한 action은 한 명령입니다. 학습 모드 전환과 펜 선택은 별도로 실행합니다.
  필압 입력은 호스트의 Sidecar/태블릿 지원을 사용하며 독자적인 iPad 연결 기능은 아닙니다.
- 라이선스: 포함된 LICENSE의 MPL-2.0. 배포 시 이름·설명·지원 연락처·호환 테스트 결과를 자신의 정보로 갱신하세요.

전체 제작 가이드: https://github.com/SeederPowerDrop/HwattakPDF/blob/main/Documentation/PLUGIN-DEVELOPMENT.md

## English

Copy this directory and replace `identifier`, `author`, and `displayName` with your own values.
Requires a **schema 3 capable** HwattakPDF build on macOS 14+; tested against the 2026-09-05
stabilization candidate. Earlier builds labeled 0.8.0/build 18 may reject schema 3.

Install the directory through the plugin manager. Open a test PDF, choose Study mode, then
select text to mark or select the pen to draw. Command palette: Shift–Command–P.

Permissions: annotation changes, tool settings, and workspace navigation. This example does
not request text extraction, clipboard, or network access. Annotation edits support Undo/Redo;
saving remains a host/user operation. Host automatic recovery settings still apply.

Edit the source package and reinstall through the reviewed update flow. Do not edit the
installed copy. Commands run separately; this package has no code, events, or device driver.
Licensed under MPL-2.0; see LICENSE. Before publishing, add your support contact and verified
host/OS versions to this README.
