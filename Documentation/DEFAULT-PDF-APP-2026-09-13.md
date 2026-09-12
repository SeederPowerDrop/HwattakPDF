# 기본 PDF 앱 연결 설정 — 2026-09-13

> 후속: GitHub 소스 반영 전의 전체 732건 검사 결과는 [누적 개발 변경 통합 기록](SOURCE-UPDATE-2026-09-13.md)에 정리했다. 아래 18건은 이 기능 구현 직후의 관련 검사 결과다.

미출시 개발 트리에 **설정 > 기본 PDF 앱**을 추가했다. Finder에서 PDF를 이중 클릭할 때 HwattakPDF로 열도록 연결하는 사용자 요청에 따른 변경이다. 공개 버전 번호 0.8.0 (build 18)은 유지하며 기존 공개 배포본에 이 기능이 포함되었다는 의미는 아니다.

## 사용 방법

1. 사용할 `HwattakPDF.app`을 응용 프로그램 폴더에 두고 실행한다. 이전 버전이 실행 중이면 작업을 저장하고 종료한 뒤 새 앱을 실행한다.
2. **HwattakPDF > 설정… (⌘,) > 기본 PDF 앱 > Finder에서 연결 설정…**을 누른다.
3. Finder에서 선택된 설정용 PDF의 **정보 가져오기 (⌘I)**를 연다.
4. **다음으로 열기**에서 **HwattakPDF**를 선택하고 **모두 변경**을 누른다. 목록에 앱이 없으면 **기타…**에서 설치한 앱을 선택한다.
5. HwattakPDF로 돌아오면 시스템의 기본 연결을 다시 조회한다. **연결 상태 새로고침**으로 직접 확인할 수도 있다.

사용자 문서를 선택하거나 수정할 필요가 없다. 설정용 PDF는 앱 캐시에 만드는 작은 1페이지 PDF이며, 삭제하거나 손상해도 다음 설정 시 다시 만든다. 개별 PDF에 별도 연결이 지정되어 있다면 해당 파일의 정보 가져오기에서도 확인한다. 앱을 이동·삭제하면 다시 연결해야 할 수 있다.

## Finder에서 마무리하는 이유

현재 배포 앱은 App Sandbox를 사용한다. Apple DTS는 샌드박스 앱에서 `NSWorkspace.setDefaultApplication`으로 전역 파일 연결을 변경할 수 없다고 명시했다. 따라서 샌드박스를 유지하고 Finder가 제공하는 연결 설정 경로를 사용한다. 추가 자동화 권한, 외부 실행 도우미, 시스템 설정 파일 수정, 샌드박스 해제는 도입하지 않았다. [Apple DTS 설명](https://developer.apple.com/forums/thread/731555), [Apple의 기본 앱 변경 안내](https://support.apple.com/ko-kr/guide/mac-help/mh35597/mac)

## 구현

- `DefaultPDFApplicationModel`은 `NSWorkspace.urlForApplication(toOpen: .pdf)`로 현재 기본 앱을 조회한다. Finder 표시 성공이나 로컬 저장값을 연결 완료로 간주하지 않는다.
- 같은 bundle ID의 이전 버전·다른 경로 앱을 현재 실행 중인 앱으로 오인하지 않도록 심볼릭 링크를 정규화한 앱 경로를 비교한다. 현재 앱 표시 위에 포인터를 두면 연결된 앱 경로를 확인할 수 있다.
- 설정 표시, 앱 재활성화, 수동 새로고침 때 상태를 갱신한다. 현재 앱이 실제 기본 연결인 경우에만 완료 상태를 표시한다.
- `DefaultPDFSetupFile`은 앱 캐시의 `HwattakPDF/DefaultPDFApplication/HwattakPDF.pdf`만 원자적으로 다시 작성한다. Finder에는 `activateFileViewerSelecting`으로 파일을 선택해 보여준다.
- 설정 파일 준비 실패는 화면에 표시하고 다시 시도할 수 있다. 중복 준비를 막는다.
- 실행 가능한 `.app` 번들만 설정 기능을 제공한다. `swift run`과 XCTest 같은 개발 실행 파일에서는 현재 연결 조회만 가능하다.
- PDF `Editor`/`com.adobe.pdf`/`Alternate` 선언과 기존 Finder 파일 열기 경로는 이미 있으므로 변경하지 않았다. 10개 언어에 새 설정 문구 14개를 추가했다.

## 검증

- `DefaultPDFApplicationTests` **11건 통과**: 연결 없음/다른 앱/현재 앱, 같은 ID의 다른 사본, 심볼릭 링크, Finder 표시와 실제 연결 완료의 구분, 준비 실패와 재시도, 개발 실행 제한, 중복 요청, 설정용 PDF의 실제 재개방·렌더링·재생성, 기존 파일 보호, 실제 시스템 PDF 연결의 읽기 전용 조회.
- `LocalizationAndIconSettingsTests` **7건 통과**: 10개 언어의 키와 형식 자리표시자 일치, 현지화 및 기존 설정 동작.
- 프로젝트 정적 검증과 변경 공백 검사 통과.
- Release 앱 빌드, arm64 실행 파일, ad-hoc 서명·샌드박스 권한 유지, ZIP 재압축 해제 후 번들·현지화·리소스 검사 통과.
- 이번 변경은 설정 화면과 새 연결 안내 서비스에 한정되어 관련 18건을 실행했다. 9월 9일 전체 안정화 검사 결과를 이번에 다시 실행한 결과로 표시하지 않는다.

테스트는 실제 Mac의 기본 PDF 앱을 변경하거나 Finder의 **모두 변경**을 누르지 않았다. 현재 서명된 앱에서의 Finder 선택·정보창 조작, 연결 변경 후 앱 미실행/실행 중/모든 문서 창을 닫은 상태의 이중 클릭 열기는 사용자 환경에서 확인할 수동 항목이다. 코드 검토에서 기존 열기 경로의 추가 결함은 발견하지 못했다.

검증 로그는 `work/default-pdf-2026-09-13/targeted-tests.log`, `static-validation.log`, `release-build.log`에 저장한다. 후보 앱은 `outputs/default-pdf-2026-09-13/HwattakPDF.app`이며, 같은 폴더의 ZIP은 기존 공개 0.8.0 배포 파일과 구분해야 한다.

후보 ZIP `HwattakPDF-0.8.0-macOS-arm64.zip`의 SHA-256: `d923199c74e252e3cd241e9e5a71d35fd2b23d01985df78c581237db42cc0b59`.
