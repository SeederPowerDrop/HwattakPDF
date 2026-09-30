# 로컬 언어팩 번역

화딱PDF의 **페이지 번역 → 로컬 언어팩**은 [Argos Translate](https://github.com/argosopentech/argos-translate)를 사용합니다. 원문은 이 Mac의 `127.0.0.1` 주소로만 전달되고, 실제 추론은 CPU에서 실행됩니다. 번역할 때는 다운로드하지 않습니다. 공식 언어팩 목록 새로고침, 선택한 팩 다운로드, 최초 번역 도우미 설치에는 인터넷이 필요합니다.

앱은 macOS 샌드박스를 유지합니다. 사용자가 별도로 실행하는 도우미가 Python 환경과 언어팩을 관리하며, 앱은 도우미를 자동 설치하거나 자동 실행하지 않습니다.

## 시작하기

1. Python 3.10–3.13을 준비합니다. Python 3.12를 권장합니다. [python.org](https://www.python.org/downloads/macos/) 또는 Homebrew로 설치할 수 있습니다.
2. 페이지 번역 패널에서 로컬 언어팩을 고르고 **도우미 파일 보기**를 누릅니다. 표시된 `start_local_translation.command`를 엽니다. 처음 실행할 때만 전용 Python 환경과 Argos Translate를 설치합니다.
3. 표시되는 터미널 창을 열어 둡니다. 기본 주소는 `http://127.0.0.1:17862`입니다.
4. 앱에서 연결을 확인하고 언어팩 목록을 새로고침합니다. 필요한 **원본 → 대상** 팩을 선택하여 설치합니다. 직접 연결이 없는 언어는 원본 → 영어와 영어 → 대상 팩을 모두 설치하면 Argos가 중간 언어를 거쳐 번역할 수 있습니다.
5. 원본 언어와 대상 언어를 지정하고 번역합니다. 로컬 번역에는 원본 언어를 명시해야 합니다.

도우미를 종료하려면 터미널에서 Control-C를 누릅니다. 다음에 사용할 때 같은 파일을 열면 기존 환경을 재사용합니다. 언어별 지원 여부와 번역 품질은 설치한 공개 모델에 따라 달라집니다.

런타임은 `~/Library/Application Support/HwattakPDF/LocalTranslation/venv`에 설치합니다. 언어팩은 Argos의 사용자 설정에 따른 기본 저장소(보통 `~/.local/share/argos-translate/packages`)를 사용합니다. 기존 Argos 언어팩도 읽을 수 있습니다. 런처는 관리자 권한을 요구하거나 시스템 Python 환경을 변경하지 않습니다.

## 수동 실행

프로젝트 루트에서 다음 명령으로 제공된 런처를 실행할 수 있습니다. 경로에 공백이 있어도 동작합니다.

```sh
bash "./scripts/start_local_translation.command"
```

기존 Argos 가상환경을 사용한다면 해당 환경의 Python을 지정합니다. 앱 안에 포함된 도우미 위치는 `HwattakPDF.app/Contents/Resources/translation_argos_worker.py`이며, 프로젝트에서는 `scripts/translation_argos_worker.py`입니다.

```sh
"/absolute/path/to/venv/bin/python3" "./scripts/translation_argos_worker.py" --serve
```

기본 포트를 다른 프로그램이 사용 중이라면 `--port 17863`처럼 실행하고 앱 주소도 `http://127.0.0.1:17863`으로 바꿉니다. 서버는 항상 `127.0.0.1`에만 연결하며 외부 인터페이스로 변경할 수 없습니다.

## 언어팩 가져오기와 오프라인 사용

파일 선택 창에서 직접 선택한 `.argosmodel` 아카이브를 가져올 수도 있습니다. 도우미가 같은 Mac의 해당 경로를 읽으므로 해당 터미널에 파일 접근 권한이 있어야 합니다. 아카이브는 설치 전에 경로 이동, 심볼릭 링크, 중복 파일, 압축 해제 크기를 검사합니다. 완전히 추출한 새 팩만 저장소에 반영합니다.

공식 목록의 팩 설치는 모델과 필요한 문장 분리 리소스를 준비합니다. 가져온 팩에 보조 모델이 빠져 있으면 번역이 중단되고 준비 안내가 표시됩니다. 사용자의 문서를 번역하면서 파일을 몰래 내려받지 않습니다. 이미 완전히 준비된 팩은 네트워크가 없는 상태에서도 사용할 수 있습니다.

## 구현 경계

- 네이티브 앱은 정확한 `http://127.0.0.1:<port>` 주소만 허용합니다. 요청은 JSON POST이고 원문은 URL, 명령 인자, 도우미 로그에 넣지 않습니다. HTTP 응답 캐시를 사용하지 않습니다.
- macOS 14 이상에서 IP 주소 연결을 허용하기 위해 앱의 ATS 예외를 `127.0.0.1` 한 주소에만 선언합니다. 인터넷 전체나 로컬 네트워크 전체의 HTTP 접속은 허용하지 않습니다. [Apple ATS 주소 예외 문서](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSAppTransportSecurity/NSExceptionDomains).
- 도우미는 `Origin`, 브라우저 Fetch 메타데이터, 잘못된 `Host`, JSON이 아닌 본문을 거부합니다. CORS를 제공하지 않습니다. 같은 사용자 권한으로 실행되는 다른 로컬 프로그램은 별도의 신뢰 경계로 보지 않습니다.
- 번역 프로세스는 Argos의 로컬 OpenNMT 엔진으로 고정합니다. Python 네트워크 감사 훅이 소켓 접속·DNS 조회·데이터그램 전송을 거부합니다. 이는 신뢰하는 Argos 런타임의 우발적인 다운로드를 방지하며, 악성 Python 확장에 대한 운영체제 샌드박스를 대신하지는 않습니다.
- 공식 목록은 고정된 Argos GitHub 주소에서 읽습니다. 설치 요청에는 목록에서 선택한 ID만 전달하고, 외부에서 임의 다운로드 URL을 지정할 수 없습니다. 모델은 목록에 있는 HTTPS `argos-net.com` 링크에서만 받습니다. 다른 호스트나 비보안 주소로의 리디렉션은 거부합니다.
- 한 번에 Unicode 스칼라 16,000개, 문단 256개까지 처리합니다. 요청 128 KiB, 결과 1 MiB, 카탈로그 2 MiB, 언어팩 압축 파일 512 MiB, 압축 해제 총합 2 GiB로 제한합니다. 하나의 도우미에서 무거운 작업은 한 개씩 실행합니다.
- 일반 번역은 180초, 팩 설치는 600초 안에 완료해야 합니다. 앱에서 취소하면 별도 취소 요청으로 작업 프로세스를 종료합니다. 완료 직후 취소하거나 연결 자체가 끊어진 경우 이미 설치된 언어팩은 유지될 수 있습니다.

## 검증

```sh
python3 -m unittest discover -s "scripts/tests" -p "test_translation_argos_worker.py" -v
swift test --filter LocalTranslationServiceTests
```

Python 검사는 가짜 번역 엔진과 임시 로컬 HTTP 서버를 사용해 문단 순서, 오프라인 차단, 아카이브 검증, 브라우저 요청 차단, 취소 요청을 확인합니다. Swift 검사는 원문 전달 방식, 주소 제한, Unicode 입력 제한, 불완전 결과 거부, 명시적인 팩 설치를 확인합니다. 이 검사는 Argos 런타임이나 실제 언어팩을 다운로드하지 않습니다. 실제 모델 품질과 모델별 호환성은 사용자가 선택한 런타임·언어팩으로 별도 확인해야 합니다.

공식 API 참고: [Argos Python 패키지 API](https://github.com/argosopentech/argos-translate/blob/master/argostranslate/package.py), [Argos 번역 API](https://github.com/argosopentech/argos-translate/blob/master/argostranslate/translate.py), [공식 언어팩 목록](https://github.com/argosopentech/argospm-index).
