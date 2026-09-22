# HwattakPDF 자산 라이선스와 출처

Copyright 2026 SeederPowerDrop

SPDX-License-Identifier: MPL-2.0

이 문서에 열거한 시각 자산은 별도 예외 없이
[Mozilla Public License 2.0](LICENSE)의 적용을 받습니다. 앱 번들·탐색 자산에 대해서는 프로젝트 소유자가
2026-08-31에 해당 자산을 공개 저장소, HwattakPDF 앱 번들 및 배포 ZIP에 포함하고
MPL-2.0으로 제공하는 데 필요한 권리를 보유하고 있음을 확인했습니다.

OpenAI ImageGen으로 제작한 자산은 프로젝트 소유자의 지시에 따라 생성되었고,
생성 또는 편집 입력으로 제3자 이미지·로고·기타 시각 자산을 제공하지 않았음을
같은 날 확인했습니다. ImageGen 사용 사실은 OpenAI가 HwattakPDF를 후원하거나
공식적으로 보증한다는 뜻이 아닙니다.

## 앱 번들에 사용하는 자산

| 저장소 파일 | 용도와 출처 | SHA-256 |
| --- | --- | --- |
| `Resources/AppIcon-StackAndSelect.png` | 선택 가능한 앱 아이콘. ImageGen 탐색안 B와 같은 파일 | `c94cd6e1d36c7a7c30e4c1a9366c0255bf0e6ab5a6b3c014c40b7e319c2e0cc7` |
| `Resources/AppIcon-PrecisionMarkup.png` | 선택 가능한 앱 아이콘. ImageGen 탐색안 A와 같은 파일 | `c39919beac3ce65cc1664ff982715cb33dc42e167f711c4bb9158e72b566210c` |
| `Resources/AppIcon-FoldWorkspace.png` | 기본 앱 아이콘. ImageGen 탐색안 C와 같은 파일 | `e9db64c1a79bad8aab7e80311d9c324644588add3c6a33760085f2cf9661d324` |
| `Resources/HwattakPDFDocument.icns` | PDF 연결 파일 아이콘. `scripts/generate_document_icon.swift`의 프로젝트 내 벡터 도형으로 제작한 16–1024px 다중 해상도 자산 | `d05d2bb79878a3c58bc48551c3870ad8d90a4bf4d318724ae9a74205d88b9a45` |
| `Resources/HwattakPDFDocument.png` | PDF 연결 파일 아이콘의 1024px 미리보기. 같은 벡터 생성기로 제작; 앱 번들에는 ICNS만 포함 | `5c92bff76e75a4c84a32472c125c6f7052a984d4ea8ae05ee5feabdfafededc6` |
| `Resources/AboutAuthor-SeederPowerDrop-UserProvided.jpg` | 프로젝트 소유자가 제공한 정보 화면 그림 | `a7bae1f9d82833339173d5c2e17ca490b8acd34f7a1c946d4d028183e90470ae` |

배포 스크립트가 만드는 `AppIcon.png`는
`Resources/AppIcon-FoldWorkspace.png`의 번들용 복사본이며 별도의 원본 자산이
아닙니다. 소개 그림의 개별 기록은
`Resources/AboutAuthor-UserProvided-NOTICE.txt`에도 보존합니다.

## 탐색·제작 기록 자산

아래 파일은 현재 앱 번들에는 들어가지 않는 디자인 탐색 또는 원본 기록입니다.

| 저장소 파일 | 출처 또는 관계 | SHA-256 |
| --- | --- | --- |
| `Resources/AppIcon-Concept-A-ReadMark.png` | OpenAI ImageGen; `AppIcon-PrecisionMarkup.png`와 동일 | `c39919beac3ce65cc1664ff982715cb33dc42e167f711c4bb9158e72b566210c` |
| `Resources/AppIcon-Concept-B-PageStack.png` | OpenAI ImageGen; `AppIcon-StackAndSelect.png`와 동일 | `c94cd6e1d36c7a7c30e4c1a9366c0255bf0e6ab5a6b3c014c40b7e319c2e0cc7` |
| `Resources/AppIcon-Concept-C-SplitWorkspace.png` | OpenAI ImageGen; `AppIcon-FoldWorkspace.png`와 동일 | `e9db64c1a79bad8aab7e80311d9c324644588add3c6a33760085f2cf9661d324` |
| `Resources/AppIcon-Concept-D-TransformCursor.png` | OpenAI ImageGen 탐색안 | `910a0c54e88a508b8ee21a84307917ee05f0c168ee833868ce6e4e4f1f7b72c2` |
| `Resources/AppIcon-Concept-E-LayerSplice.png` | OpenAI ImageGen 탐색안 | `b91861775993dd0aa77d6691fe673c1c83aec9fda3dccd00fa2e4770063ef1c3` |
| `Resources/AppIcon-Concept-F-PrecisionMarker.png` | OpenAI ImageGen 탐색안 | `b82194c64bb73a3f36f5f74ad730d26ec352ee453355aa1f00fc0f09737a7134` |
| `Resources/AppIcon-Concept-G-HingeV.png` | OpenAI ImageGen 탐색안 | `54696764e5bacf4df2f76172a92d6528e89edb8ba45ff1318694dbe13d1cf467` |
| `Resources/AppIcon-Concept-H-ZFoldPrism.png` | OpenAI ImageGen 탐색안 | `fe4387d1e86209d885bbd20bd00969981518502e1670c54681c05153feba8669` |
| `Resources/AppIcon-Concept-I-TitaniumPortal.png` | OpenAI ImageGen 탐색안 | `d62afb626ba6b375ed8a076f2f89d2c39f95245936da8076e4e3ffe6828778fd` |
| `Resources/AppIcon-FreedPage.png` | OpenAI ImageGen 탐색안 | `2f6c5471e82871d165cce87ce6ff2e0385f2affc7c050b7742443b9004d667dc` |
| `Resources/AppIcon-FreedPage-v2.png` | 앞선 Freed Page 자산을 대상으로 한 OpenAI ImageGen 편집안 | `e966df005389b49c8a507e07dff0d0a1b2449cea82990703792500071de155ff` |
| `Resources/AppIcon.svg` | 프로젝트 안에서 제작한 프로젝트 소유 벡터 아이콘 탐색안; 제3자 자산 입력 없음 | `edf6d22a01aece56656c6174fff6217cb23700f27e434d93348f809fc62f5a7e` |

`Documentation/AppIcon-*.prompt.md` 파일은 ImageGen 제작 과정의 출처와 프롬프트
기록이며 이미지 자체를 대신하는 제3자 자산이 아닙니다.

## README 스크린샷

2026-09-13에 HwattakPDF 0.8.0 (build 18) 앱으로 직접 작성한 예제 PDF를
열어 촬영했습니다. 개인 문서나 외부 출판물은 사용하지 않았습니다. 기존 사용자
작업공간과 분리하기 위해 앱 복사본의 번들 식별자를 바꾸고 재서명했으며,
앱 UI 코드는 변경하지 않았습니다. 아래 파일은 화면 합성이나 보정 없이 저장한
실제 창 캡처이며, 프로젝트의 MPL-2.0으로 제공합니다.

| 저장소 파일 | 표시하는 화면 | SHA-256 |
| --- | --- | --- |
| `Documentation/Images/reading-workspace.jpg` | 보기 모드, 페이지 썸네일과 예제 본문 | `4043cf9e9fd7b323315441f41d8f45743a88206d27acc78836e4451c27833b33` |
| `Documentation/Images/study-highlights.jpg` | 학습 모드에서 실제 적용한 하이라이트 | `14dabb1c05eec7c55e40e4c3714ba761974082f8c3bef1c3e94395f6165032ab` |
| `Documentation/Images/document-comparison.jpg` | 두 예제 PDF의 좌우 비교 | `3197578e49cf883559012943ecba0b5ae30881991b19e98bc64694a1b1d13380` |
| `Documentation/Images/page-overview.jpg` | 편집 모드의 2×2 페이지 개요 | `2e3f4dee51bb3d93d269474dd2ee90c9c7bcd4edb68cef15fdce44814ab4d8aa` |

## 상표와 공식성

MPL-2.0은 위 자산에 적용되지만, 그 사실만으로 HwattakPDF의 상표를 사용할
권리나 수정본이 공식 배포본이라는 인상을 줄 권리가 생기지는 않습니다. 정확한
출처 표기와 혼동 방지 원칙은 [TRADEMARKS.md](TRADEMARKS.md)를 참고하세요.

## PDF 문서 아이콘 제작 기록

2026-09-21에 HwattakPDF에 연결된 PDF 파일용으로 제작했습니다. 기존 앱의
남색·아이보리 팔레트와 펼친 두 페이지 모티프를 단순한 벡터 도형으로 그렸으며,
외부 이미지나 상표를 입력하거나 사용하지 않았습니다. 원본 제작 코드는
`scripts/generate_document_icon.swift`이며 이 프로젝트의 MPL-2.0을 적용합니다.

재생성: `swift scripts/generate_document_icon.swift work/document-icon`,
이후 `iconutil -c icns work/document-icon/HwattakPDFDocument.iconset -o Resources/HwattakPDFDocument.icns`.
생성된 `HwattakPDFDocument.png`는 디자인 확인용 미리보기입니다.
