# HwattakPDF 문서 지도

문서가 많아질수록 “어떤 파일이 최신 기준인지” 찾기 어려워집니다. 목적에 맞는 시작점을 아래에서 고르세요. 기능 설명이 서로 다르면 현재 코드와 테스트, `PRODUCT.md`, `ARCHITECTURE.md` 순으로 근거를 확인하고 불일치를 Issue로 남깁니다.

현재 소스 문서 기준은 **HwattakPDF 0.9.0 (build 19) Developer Preview**입니다. 9월 22일 로컬 패키지와 [9월 23일 이름 통일·누적 소스 갱신](SOURCE-UPDATE-2026-09-23.md)을 구분합니다. 마지막 GitHub Release 다운로드 배포본은 **0.8.0 (build 18)**이며, 소스 갱신은 새 Release 자산 공개를 뜻하지 않습니다. 0.9.0은 이미지·HTML 기반 PDF 만들기, Word/PowerPoint 내보내기, 작업 복구, 문서 명령 플러그인과 파일 연결·화면 모드·읽기 조작의 누적 변경을 포함합니다. 실제 검사와 아직 남은 Office·기기별 수동 확인은 배포 검증 기록에서 구분합니다. 과거 날짜의 문서는 당시 상태의 기록입니다.

## 사용자와 기여자

| 문서 | 먼저 읽을 사람 | 내용 |
| --- | --- | --- |
| [프로젝트 README](../README.md) | 모든 사람 | 기능, 실행, 현재 한계 |
| [개발노트](DEVELOPMENT-LOG.md) | 사용자·기여자 | 시작 동기부터 버전별 공개·개발·배포 준비의 문제·변경·검증·한계 |
| [처음 기여자를 위한 코드 안내](ONBOARDING.md) | Swift 초보·첫 기여자 | 폴더, 상태 흐름, 저장·검색·OCR·변환 작업대 예제 |
| [플러그인 가이드](PLUGINS.md) | 사용자·플러그인 개발자·보안 검토자 | 설치·업데이트·비활성화·삭제, manifest schema 1·2·3, 번역·브라우저 패널과 문서 명령, 미배포 YouTube 실험 경계, 권한·상한·위협 모델 |
| [기여 가이드](../CONTRIBUTING.md) | 기여자 | 작업 흐름, 주석, 테스트, PR 규칙 |
| [행동 강령](../CODE_OF_CONDUCT.md) | 커뮤니티 | 협업 태도와 신고 절차 |
| [보안 정책](../SECURITY.md) | 제보자·관리자 | 비공개 취약점 신고와 민감정보 처리 |

## 제품과 설계

| 문서 | 역할 |
| --- | --- |
| [제품 정의](PRODUCT.md) | 사용자 문제, 뷰어·에디팅·학습 모드, 구현/부분 구현/다음 단계, 로드맵 |
| [아키텍처](ARCHITECTURE.md) | 상태 소유권, 모드 capability, 인라인 FreeText·학습 Stamp 경계, 저장·OCR·AI 구조와 불변 조건 |
| [대용량 PDF 성능](LARGE-PDF-PERFORMANCE.md) | resident 예산, LRU 휴면, 측정 결과와 아직 필요한 실물 stress test |
| [외부 AI와 MCP](AI-INTEGRATION.md) | 공급자별 기능, 전송 동의, Keychain, MCP 승인과 개인정보 경계 |
| [품질 점검 보고서](QUALITY_REPORT.md) | 공개 0.8.0의 검증 기준선, 이후 검사 기록의 안내와 수동 확인 필요 항목 |

## 공개와 릴리스 운영

| 문서 | 역할 |
| --- | --- |
| [GitHub 공개 준비 체크리스트](GITHUB-PUBLISHING-CHECKLIST.md) | 저장소 설정·변경 commit·공개 릴리스와 미출시 개발 트리의 남은 확인 |
| [라이선스 결정 기록](LICENSE-CHOICE.md) | MPL-2.0 선택 이유, 저작권 표기와 적용 상태 |
| [자산 및 의존성 공개 기록](ASSET-AND-DEPENDENCY-NOTICES.md) | 소개 그림, 아이콘, fixture와 향후 제3자 의존성 권리 |
| [2026-09-23 소스 갱신](SOURCE-UPDATE-2026-09-23.md) | 제품 방향, HwattakPDF 이름 통일, Finder 제보 대응과 이번 소스 검증 |
| [0.9.0 릴리스 노트](RELEASE-NOTES-0.9.0.md) | 누적 소스 변경·로컬 패키지 설치·알려진 한계 |
| [0.9.0 배포 검증](RELEASE-VALIDATION-0.9.0.md) | 9월 22일 패키지 검사 결과·식별 정보·남은 수동 확인 |
| [0.8.0 릴리스 노트](RELEASE-NOTES-0.8.0.md) | 이전 공개 배포본의 설치·검증·알려진 한계 기록 |
| [릴리스 체크리스트](RELEASE-CHECKLIST.md) | 자동 검사와 실제 PDF·UI·보안·대용량 수동 시나리오 |

## 디자인 자료

`AppIcon-*.prompt.md` 파일은 앱 아이콘 탐색 과정의 프롬프트 기록입니다. 현재 제품 동작이나 구현 명세가 아니며, 공개 재사용 범위와 파일별 checksum은 루트 [ASSETS.md](../ASSETS.md)와 [자산 및 의존성 공개 기록](ASSET-AND-DEPENDENCY-NOTICES.md)을 따릅니다.

## 문서를 고칠 때

- 현재 구현과 아이디어를 섞지 말고 **구현**, **부분 구현**, **다음 단계**를 구분합니다.
- 측정값에는 기기·입력·반복 횟수·날짜를 함께 기록합니다.
- 사용자 데이터나 상업 PDF를 예시로 붙이지 않습니다.
- 버전 변경 시 README, `Info.plist`, 제품·아키텍처·개발노트의 기준을 함께 확인합니다.
- 현지화 키와 프로젝트의 기본 정적 구성은 `./scripts/validate_project.sh`로 검사합니다.
- 상대 링크는 로컬 점검과 공개 후 GitHub 렌더링에서 한 번 더 확인합니다.

- [2026-09-05 안정화 결과](STABILIZATION-2026-09-05.md): 버그 수정, 대용량 검사, 복구와 후보 빌드
- [2026-09-08~09 안정성 재검토](AUDIT-2026-09-08.md): 정규 685건 검사와 추가로 재현한 종료·권한·복구 문제
- [2026-09-09 버그 수정](STABILIZATION-2026-09-09.md): 재검토의 6개 결함 수정, 회귀 검사, 수정된 후보 앱
- [2026-09-13 기본 PDF 앱 연결](DEFAULT-PDF-APP-2026-09-13.md): 설정 화면의 Finder 연결 안내, 실제 기본 앱 상태 확인과 검증 범위
- [2026-09-13 누적 소스 반영](SOURCE-UPDATE-2026-09-13.md): GitHub에 함께 반영하는 기능·개발 기록과 공개 범위
- [문서 명령 플러그인 API](PLUGIN-HOST-API.md): schema 3, 명령 팔레트, 직접 만드는 예제와 태블릿 입력

## 플러그인 개발자 문서

- [플러그인 만들기](PLUGIN-DEVELOPMENT.md): 첫 설치부터 권한·레시피·검증·배포·문제 해결까지
- [English quick start](PLUGIN-DEVELOPMENT.en.md): community author entry point
- [문서 명령 API](PLUGIN-HOST-API.md): schema 3 명령·스타일·기본값·태블릿 입력
- [호환성과 확장 설계](PLUGIN-COMPATIBILITY.md): 앱/schema/플러그인 버전, Obsidian 기능 이식, 코어 기여와 설계 제안
- [보안 가이드](PLUGIN-SECURITY.md): 데이터 흐름·권한·신뢰 경계·배포와 취약점 신고
- [예제 지도](../Examples/Plugins/README.md): 커뮤니티 패키지와 공식/검토용 패키지 구분
