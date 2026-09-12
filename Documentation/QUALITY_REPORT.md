# HwattakPDF 0.8.0 (build 18) 품질 검증 보고서

> 2026-09-05 안정화 후속: [수정·성능·복구 검증](STABILIZATION-2026-09-05.md), [schema 3 문서 명령 API와 태블릿 입력](PLUGIN-HOST-API.md). 아래의 이전 단계 설명보다 후속 기록을 우선한다.

이 문서는 공개된 0.8.0 (build 18), commit `1584312`의 자동 검증과 공개 당시 남은 한계를 기록한 고정 기준선이다. 다음 릴리스용 소스 트리의 미출시 이미지·HTML·Office 변환 작업은 이 문서의 테스트 수·산출물·해시에 포함되지 않으며 [개발노트](DEVELOPMENT-LOG.md)의 2026-09-03 기록을 따른다. 과거 0.7 마일스톤의 테스트 수·성능 측정·산출물 해시는 재사용하지 않았다. 수동 제품 검증은 [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md)를 함께 사용한다.

> 검증 기준일: 2026-09-01
> 상태: **로컬 자동 검증 통과 — 공개 권리 확인 완료, 실제 기기·공증·실서비스 검증은 별도**

## 검증 환경

| 항목 | 값 |
|---|---|
| 기기/아키텍처 | Apple Silicon, `arm64` |
| macOS | 15.7.5 (24G624) |
| Xcode | 26.3 (17C529) |
| Swift | Apple Swift 6.2.4, arm64-apple-macosx15.0 |
| 패키지 | swift-tools 6.0, Swift language mode 5, macOS 14.0+ |
| 앱 | 0.8.0 (build 18), bundle id `com.vibepdf.mac` |
| 소스 기준 | 공개 `v0.8.0`, commit `1584312` |

## 재현 명령

저장소 루트에서 다음을 실행한다.

```zsh
./scripts/validate_project.sh
./scripts/run_test_batches.sh
./scripts/build_app.sh
```

- 정적 검사는 plist·entitlements·최소 OS·현재 문서 버전, Swift package manifest, 필수 이미지와 플러그인, 10개 언어의 strings 문법·키 동등성, 생성물 추적 여부와 스크립트 문법을 확인한다.
- 테스트 스크립트는 모든 `*Tests` 클래스를 manifest와 대조하고 PDFKit/AppKit 상태를 격리한 7개 프로세스로 실행한다.
- 패키징 스크립트는 빌드 경로 prefix-map과 symbol strip을 적용한 release 실행 파일 및 MPL-2.0 법적 고지를 앱으로 묶고 ad-hoc 서명한다. 서명 전 로컬 빌드 경로가 실행 파일에 남지 않았는지 검사하며, ZIP을 새 폴더에 풀어 버전·arm64 아키텍처·서명·4개 entitlements·10개 언어·아이콘·소개 이미지·배포용 기본 플러그인 2종·법적 고지와 AppleDouble 메타데이터 부재를 다시 확인한다.

## 자동 검증 결과

| 검증 | 결과 |
|---|---|
| 정적 검사 | 통과 — 0.8.0 (18), macOS 14.0+ |
| 현지화 | 10개 언어 × 1,310키, 키 누락·추가 없음 |
| Debug 빌드 | 성공 |
| 테스트 | 48개 클래스, 641개 실행, 실패 0, 예상 skip 2 |
| Release 빌드 | 성공, thin arm64 |
| 앱 서명 | `codesign --verify --deep --strict` 통과, ad-hoc |
| ZIP 재개방 | 버전·아키텍처·서명·권한·리소스 전체 재검증 통과, 로컬 경로·AppleDouble 항목 0 |

전체 배치 뒤 패키징 검증을 더 엄격하게 만든 다음, 그 스크립트와 release 전용 리소스 경계를 읽는 About·현지화/아이콘 관련 테스트 14개도 다시 실행해 실패 0을 확인했다.

### 테스트 배치

| 배치 | 클래스 | 실행 | 실패 | skip |
|---|---:|---:|---:|---:|
| Presentation | 21 | 165 | 0 | 2 |
| Image interaction | 1 | 23 | 0 | 0 |
| Native form interaction | 1 | 2 | 0 | 0 |
| Document | 10 | 182 | 0 | 0 |
| Workspace | 7 | 119 | 0 | 0 |
| Assistant | 6 | 108 | 0 | 0 |
| Plugins | 2 | 42 | 0 | 0 |
| **합계** | **48** | **641** | **0** | **2** |

이 저장소의 macOS 15 테스트 환경에서 offscreen `PDFView`의 two-up 및 pointer zoom fixture를 정리할 때 충돌이 관찰되어 아래 두 통합 항목만 로컬에서 예상 건너뛴다.

- `testNativePagedTwoUpShowsOneExactSpreadWithoutBookCoverOffset`
- `testPDFKitZoomKeepsThePDFPointUnderAnOffCenterPointer`

나머지 viewport 계산과 입력 경계는 macOS 15 배치에서 계속 실행된다. CI에는 이 두 항목도 실행되는 `macos-26` 전용 PDFKit job이 별도로 있다. 사용 가능한 이미지 기준은 [GitHub Actions runner-images](https://github.com/actions/runner-images)를 따른다. Workflow의 checkout은 [actions/checkout v6.0.3 전체 commit SHA](https://github.com/actions/checkout/commit/df4cb1c069e1874edd31b4311f1884172cec0e10)로 고정했고 자격 증명 보존을 끈다.

## 이번 보완에서 확인한 경계

- 정보 화면의 소개·후원 문구를 10개 지원 언어로 현지화했다. 840×690 실제 창 크기로 전 언어를 렌더링해 긴 번역과 Arabic RTL 배치를 확인했고, 후원 버튼은 스크롤과 관계없이 항상 보이도록 하단에 고정했다.
- 분리 창 워크스페이스의 변경 알림이 debounce 예약 전에 별도 MainActor 작업을 한 번 더 거치던 지연을 제거했다. 테스트도 고정 sleep 대신 실제 persistence write 완료를 제한 시간 내 확인해 느린 CI에서도 최종 제목·탭 수·창 제거 상태를 검증한다.
- release 빌드에서 개발용 `#filePath` 리소스 fallback을 제외하고 prefix-map·strip·문자열 검사를 적용해 실행 파일의 로컬 사용자 경로를 0건으로 만들었다. ZIP도 확장 속성과 resource fork 없이 생성해 `._*` 및 `__MACOSX` 항목이 0건임을 확인했다.
- 사용자 암호로 연 암호화 PDF는 양식·페이지·주석 등 저장 가능한 변경을 읽기 전용으로 차단한다. 소유자 암호 세션은 정상 편집된다.
- PDF 페이지 추출·병합은 콘텐츠 복사와 문서 조합 권한, PNG는 콘텐츠 복사 권한, 검색 가능한 OCR 사본은 암호화 문서의 소유자 권한을 모델과 서비스 양쪽에서 검사한다.
- PNG 묶음은 숨은 staging 폴더에서 모두 검증한 뒤 고유 폴더로 한 번에 공개한다. 기존 파일을 덮어쓰지 않고 중간 실패 때 부분 결과를 남기지 않는다.
- OCR 사본은 원본·symlink·hardlink·작업 중 alias 변경과 잘못 전달된 원본 URL 우회를 시작과 commit 직전에 모두 차단한다.
- 페이지 이동·삭제·병합 전에 활성 양식 편집기를 확정하고, 페이지 인덱스가 바뀐 뒤 snapshot을 재설정해 실행 취소 순서를 보존한다.
- 파일 명령은 실제 key window에만 전달된다. 설정·정보·도움말·시트가 숨은 PDF 탭을 조작하지 않으며 `⌘W`는 실제 앞 창 또는 탭을 닫는다.
- 검색 결과 선택은 모델과 PDFView가 함께 갱신되며, 검색 선택 해제가 이후 사용자의 새 선택을 지우지 않는다.
- AI 패널 표시 상태는 창별로 분리되고 한 창의 패널 종료가 다른 창의 요청을 취소하지 않는다.

## 배포 산출물

```text
outputs/HwattakPDF.app
outputs/HwattakPDF-0.8.0-macOS-arm64.zip
```

| 항목 | 값 |
|---|---|
| ZIP 크기 | 6,960,784 bytes |
| SHA-256 | `e164620d852da6ebee845b214c324be7b4dddd40e80709bb946576f2aee1f1c8` |
| 아키텍처 | arm64 |
| 최소 macOS | 14.0 |
| 서명 | ad-hoc, `TeamIdentifier=not set` |
| entitlements | App Sandbox, app-scoped bookmark, user-selected read/write, network client |

## 남은 수동 검증과 배포 한계

- 실제 App Sandbox·iCloud/Dropbox 같은 File Provider 위치에서 보안 범위 저장과 장시간 OCR commit을 확인해야 한다.
- VoiceOver/접근성 입력이 사용자 암호 양식을 건드렸을 때 암호 재요청 또는 안전한 휴면 전환 UX를 실기로 확인해야 한다.
- 최소 지원 버전인 macOS 14, 실제 macOS 26, Arabic RTL, 키보드 전용, Sidecar 입력을 자동 테스트가 대체하지 않는다.
- Developer ID 서명, hardened runtime, Apple 공증, Gatekeeper 다운로드 경로와 App Store provisioning은 검증하지 않았다.
- 실제 AI 공급자 계정·과금·rate limit·원격 MCP는 mock 자동 테스트와 별도의 운영 검증 항목이다. YouTube 학습 manifest는 개인정보처리방침·이용약관·동의 UI를 완성하기 전까지 소스 전용 예제로 두고 0.8.0 배포 번들에서 제외했다.
- OCR 체크포인트 텍스트는 Application Support에 평문으로 남는다. 2026-09-05에 앱 설정의 삭제 기능을 추가했으며, 자동 만료 정책은 아직 없다.
- 50~200MB 실문서 다수의 장시간 스크롤·검색, peak RSS, frame pacing, thermal 영향은 Instruments로 별도 측정해야 한다.
- 코드·문서·권리가 확인된 프로젝트 자산은 MPL-2.0으로 공개한다. 결정 근거와 자산 checksum은 [라이선스 결정 기록](LICENSE-CHOICE.md), [자산 기록](ASSET-AND-DEPENDENCY-NOTICES.md), 루트 `ASSETS.md`에 남겼다.
- 앱 정보 화면·README·10개 언어·행동 강령은 공식 저장소 주소로 갱신했다. Private vulnerability reporting은 공개 뒤 활성화되어 2026-09-03 GitHub API로 다시 확인했지만, `SECURITY.md`의 직접 신고 링크가 관리자 권한이 없는 별도 GitHub 계정으로 로그인한 환경에서 실제 제출 화면까지 열리는지는 별도로 확인해야 한다.
