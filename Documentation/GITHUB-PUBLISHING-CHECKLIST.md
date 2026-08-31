# GitHub 공개 준비 체크리스트

> 현재 확인 상태: 공식 공개 저장소는 `https://github.com/SeederPowerDrop/HwattakPDF`이며, 로컬 `main`의 첫 공개 커밋과 0.8.0 개발자 프리릴리스를 검증했다.

## 1. 공개를 막는 필수 결정

- [x] [라이선스 결정 기록](LICENSE-CHOICE.md)을 소유자가 작성하고 루트 `LICENSE`에 MPL-2.0 공식 원문 추가
- [x] 외부 기여를 별도 CLA/DCO 없이 MPL-2.0으로 받는 조건을 `CONTRIBUTING.md`에 확정
- [x] `AboutAuthor-SeederPowerDrop-UserProvided.jpg`의 공개 저장소·앱 재배포 권리 확인
- [x] 앱 아이콘·프롬프트 등 모든 프로젝트 자산의 공개 권리와 MPL-2.0 적용 확인
- [x] GitHub 저장소 이름과 최종 URL 결정
- [x] README와 앱 정보 화면의 프로필 링크를 실제 저장소 링크로 교체
- [ ] GitHub Private vulnerability reporting을 활성화하고 보안 정책의 신고 링크 확인
- [x] 공개 저장소에 올리는 무료 지원 약속과 자발적 후원 문구를 소유자가 최종 확인

이 항목은 코드 테스트가 통과해도 대신 결정할 수 없습니다.

## 2. 저장소 내용

- [x] `.gitignore`에 `.build`, `work`, `outputs`, `.DS_Store`와 사용자별 Xcode 상태 제외
- [x] `.gitattributes`에 텍스트 줄바꿈과 바이너리 자산 처리 기록
- [x] README에 실행·검증·한계 문서화
- [x] 제품·아키텍처·성능·AI 경계 문서화
- [x] 초보자 onboarding, 기여 가이드, 보안 정책, 행동 강령 준비
- [x] 버그·기능 Issue 양식과 Pull Request 양식 준비
- [x] 현재 소유자의 CODEOWNERS와 자발적 후원 링크 준비
- [x] GitHub Actions 기본 검증 workflow 준비
- [x] `LICENSE`, `NOTICE`, `ASSETS.md`, `TRADEMARKS.md` 최종본 추가
- [x] 저장소 전체에서 로컬 절대 경로, API 키·token·private key, 실제 사용자 PDF 원문 검색
- [x] `git status --ignored`로 빌드 산출물이 추적 대상이 아닌지 확인
- [x] 첫 커밋 전에 10MB 초과 파일·symlink 부재와 자산 checksum 검토

추천 점검 명령:

```bash
./scripts/validate_project.sh
git status --short --ignored
find . -type f -size +10M -not -path './.git/*' -not -path './.build/*' -not -path './outputs/*' -not -path './work/*'
```

비밀 탐지 전용 도구를 사용한다면 설치·출처를 검토한 뒤 전체 Git history와 현재 파일을 모두 검사합니다. 현재는 history가 없지만 첫 커밋 이후 잘못 들어간 비밀을 삭제하는 것보다 commit 전에 막는 편이 안전합니다.

## 3. 검증 기준선

- [x] `./scripts/validate_project.sh` 성공
- [x] `./scripts/run_test_batches.sh` 전체 성공 — 48개 클래스, 641개 테스트, 실패 0, 예상 skip 2
- [x] Release configuration 빌드와 ZIP 재개방 검증 성공
- [ ] [릴리스 체크리스트](RELEASE-CHECKLIST.md)의 해당 수동 시나리오 성공
- [ ] 저장 실패, 미저장 종료, `⌘Z`/`⇧⌘Z`, 세션 복원을 실제 파일로 확인
- [ ] VoiceOver, 키보드 전용 조작, 긴 번역, Arabic RTL 확인
- [ ] 민감정보를 제거한 대형·스캔·회전·양식 PDF로 smoke test

테스트 개수는 코드가 늘 때 바뀌므로 README에 고정 숫자를 약속하기보다 각 commit의 GitHub Actions 결과를 기준으로 삼습니다.

## 4. GitHub 저장소 설정

- [ ] 기본 브랜치를 `main`으로 지정
- [x] Actions CI workflow에 최소 `contents: read` 권한만 부여됐는지 확인
- [ ] `main` branch protection 또는 ruleset에서 CI 통과와 review 요구
- [x] CODEOWNERS가 전체 파일의 `@SeederPowerDrop` 검토를 요청하도록 설정
- [ ] force push와 branch deletion 제한
- [ ] Private vulnerability reporting 활성화
- [ ] Issue와 Discussion 사용 범위 결정
- [ ] `bug`, `enhancement`, `documentation`, `security`, `good first issue`, `help wanted` label 정리
- [ ] 저장소 설명, 주제(`swift`, `macos`, `pdf`, `pdfkit`, `ocr`)와 홈페이지 설정
- [ ] 라이선스가 감지되는지, 보안 정책과 행동 강령이 Community Standards에 잡히는지 확인

## 5. 첫 커밋과 push

라이선스·자산 권리가 해결된 뒤에만 아래 명령의 URL을 실제 저장소로 바꾸어 실행합니다. 이 문서는 명령 예시이며 자동으로 push하지 않습니다.

```bash
git add .
git status --short
git commit -m "Prepare HwattakPDF 0.8.0 open-source milestone"
git remote add origin https://github.com/SeederPowerDrop/HwattakPDF.git
git push -u origin main
```

첫 push 후 GitHub에서 빠진 파일, 무시되지 않은 산출물, 렌더링되지 않는 Mermaid·상대 링크를 웹 UI로 다시 확인합니다.

## 6. 첫 공개 릴리스

- [x] 버전과 build 번호가 `Info.plist`, README, 제품·아키텍처 문서에서 일치
- [x] Developer ID 미서명·미공증 ad-hoc 개발자 프리릴리스임을 README와 릴리스 노트에 명시
- [x] 첫 공개 배포 대상을 Apple Silicon `arm64`, macOS 14 이상으로 결정
- [ ] ZIP을 Git에 commit하지 않고 GitHub Release asset으로 업로드
- [x] 빌드가 `.sha256` 자산을 생성하며 최소 macOS, Gatekeeper 안내와 알려진 한계를 릴리스 노트에 포함
- [x] 0.8.0 릴리스 노트에 보안·개인정보·편집 경계 포함
- [ ] 깨끗한 별도 사용자 계정 또는 Mac에서 다운로드→압축 해제→실행→저장 smoke test

## 7. 공개 후 운영

- [ ] 새 Issue에 재현 정보와 개인정보가 충분히 제거됐는지 triage
- [ ] “good first issue”에는 파일 위치·기대 동작·검증 방법을 구체적으로 작성
- [ ] 월 1회 의존성 없음 상태, 외부 API 변경, macOS/Xcode 호환성 확인
- [ ] 릴리스마다 DEVELOPMENT-LOG에 문제·변경·검증·남은 한계 기록
- [ ] 지원이 어려워질 때 README에 유지보수 상태와 응답 기대치를 정직하게 갱신
