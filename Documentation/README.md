# HwattakPDF 문서 지도

문서가 많아질수록 “어떤 파일이 최신 기준인지” 찾기 어려워집니다. 목적에 맞는 시작점을 아래에서 고르세요. 기능 설명이 서로 다르면 현재 코드와 테스트, `PRODUCT.md`, `ARCHITECTURE.md` 순으로 근거를 확인하고 불일치를 Issue로 남깁니다.

현재 문서 기준은 **HwattakPDF 0.8.0 (build 18)**입니다. 뷰어·에디팅·학습 모드의 사용자 범위는 제품 정의, capability·PDFKit 저장 한계·schema 2 앱 소유 웹 패널의 신뢰 경계는 아키텍처, 구현 과정은 개발노트에서 확인할 수 있습니다.

## 사용자와 기여자

| 문서 | 먼저 읽을 사람 | 내용 |
| --- | --- | --- |
| [프로젝트 README](../README.md) | 모든 사람 | 기능, 실행, 현재 한계 |
| [개발노트](DEVELOPMENT-LOG.md) | 사용자·기여자 | 시작 동기부터 0.7.0 세 모드 중간 마일스톤까지의 재구성 기록 |
| [처음 기여자를 위한 코드 안내](ONBOARDING.md) | Swift 초보·첫 기여자 | 폴더, 상태 흐름, 저장·검색·OCR 예제 |
| [플러그인 가이드](PLUGINS.md) | 사용자·플러그인 개발자·보안 검토자 | 설치·업데이트·비활성화·삭제, manifest schema 1·2, 배포용 번역·브라우저 패널과 미배포 YouTube 실험 경계, 권한·상한·위협 모델 |
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
| [품질 점검 보고서](QUALITY_REPORT.md) | 자동 검증, 정적 감사, 알려진 위험과 수동 확인 필요 항목 |

## 공개와 릴리스 운영

| 문서 | 역할 |
| --- | --- |
| [GitHub 공개 준비 체크리스트](GITHUB-PUBLISHING-CHECKLIST.md) | 첫 커밋·remote·저장소 설정·공개 릴리스 순서 |
| [라이선스 결정 기록](LICENSE-CHOICE.md) | MPL-2.0 선택 이유, 저작권 표기와 적용 상태 |
| [자산 및 의존성 공개 기록](ASSET-AND-DEPENDENCY-NOTICES.md) | 소개 그림, 아이콘, fixture와 향후 제3자 의존성 권리 |
| [0.8.0 릴리스 노트](RELEASE-NOTES-0.8.0.md) | Apple Silicon 개발자 프리릴리스의 설치·검증·알려진 한계 |
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
