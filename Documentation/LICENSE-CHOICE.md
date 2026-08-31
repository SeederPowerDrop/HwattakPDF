# 오픈소스 라이선스 결정 기록

> 상태: **결정 완료 — MPL-2.0**
> 결정일: 2026-08-31
> 이 문서는 결정 과정의 기록이며, 실제 이용 조건은 저장소 루트의 `LICENSE` 원문을 따른다. 법률 자문을 대신하지 않는다.

## 왜 공개 전에 결정해야 하나

GitHub에서 소스를 볼 수 있다는 사실과 오픈소스 라이선스가 있다는 사실은 다릅니다. 라이선스 없이 공개하면 다른 사람은 코드를 읽고 이슈를 제보할 수는 있어도, 법적으로 안전하게 복제·수정·배포하거나 기여 코드를 결합하기 어렵습니다. “평생 무료”라는 제품 약속도 소스 라이선스의 복제·배포 조건과는 별개입니다.

## 고려할 수 있는 대표 선택지

| 선택지 | 핵심 성격 | HwattakPDF에서 생각할 점 |
| --- | --- | --- |
| [MIT](https://spdx.org/licenses/MIT.html) | 짧고 허용적이며 저작권·허가 고지를 유지하면 상용·비공개 파생물도 허용 | 기여 장벽은 낮지만 제3자가 수정본을 비공개·유료 제품으로 배포할 수 있음 |
| [Apache-2.0](https://spdx.org/licenses/Apache-2.0.html) | 허용적이며 명시적인 특허 허여·종료 조항 포함 | 특허 조항은 더 분명하지만 문서가 길고 NOTICE 운영을 이해해야 함 |
| [MPL-2.0](https://spdx.org/licenses/MPL-2.0.html) | 수정한 MPL 파일의 소스 공개를 요구하는 파일 단위 약한 copyleft | 앱과 별도 모듈을 함께 쓰기 비교적 쉬우면서 핵심 파일 개선의 환원을 원할 때 검토 가능 |
| [GPL-3.0-only](https://spdx.org/licenses/GPL-3.0-only.html) 또는 `GPL-3.0-or-later` | 배포하는 파생 저작물 전체에 강한 copyleft 의무 | `only`와 `or-later`까지 선택해야 하며, 앱 배포·결합 의무를 충분히 검토해야 함 |

어느 것이 “무조건 더 오픈소스답다”는 답은 없습니다. 목표가 넓은 재사용인지, 개선의 공개 환원인지, 상업적 포크 허용인지 먼저 정해야 합니다. 정확한 원문과 호환성은 [Choose a License](https://choosealicense.com/)와 [SPDX License List](https://spdx.org/licenses/)에서 확인하고, 배포 중요도가 크면 법률 전문가에게 검토받으세요.

## 소유자가 확인한 사항

- [x] 기존 MPL 파일의 수정본을 배포할 때 해당 파일의 소스 공개를 요구한다.
- [x] MPL-2.0이 상업적 이용과 판매 자체를 금지하지 않는다는 점을 이해한다.
- [x] 외부 기여는 별도 CLA나 DCO 없이 프로젝트와 같은 MPL-2.0 조건으로 받는다.
- [x] 프로젝트 소유자가 앱 아이콘과 소개 그림의 공개·수정·재배포 권리를 확인했다.
- [x] `HwattakPDF` 이름·서비스표·로고에 대한 권리는 MPL-2.0이 별도로 부여하지 않음을 기록한다.
- [ ] 향후 iOS/iPad 앱, App Store 배포 또는 제3자 PDF 엔진을 추가할 때 호환성을 다시 검토한다.

## 자산은 별도 조건일 수 있다

소스 라이선스를 골라도 이미지의 권리 확인은 별도로 필요합니다. 프로젝트 소유자는 2026-08-31에 `Resources/AboutAuthor-SeederPowerDrop-UserProvided.jpg`와 프로젝트용 ImageGen 아이콘을 MPL-2.0으로 제공할 권리를 확인했습니다. 파일별 제작 방식과 checksum은 [ASSETS.md](../ASSETS.md)와 [자산 및 의존성 기록](ASSET-AND-DEPENDENCY-NOTICES.md)을 참고하세요. MPL-2.0은 프로젝트 이름·서비스표·로고의 사용 권리를 별도로 부여하지 않습니다.

## 결정 적용 상태

1. [x] MPL-2.0 공식 원문을 수정하지 않고 저장소 루트의 `LICENSE`에 추가
2. [x] `Copyright 2026 SeederPowerDrop`을 `NOTICE`와 앱 정보에 기록
3. [x] `README.md`와 `CONTRIBUTING.md`에 라이선스·기여 조건 반영
4. [x] 자산과 프로젝트 표장 범위를 `ASSETS.md`·`TRADEMARKS.md`에 기록
5. [x] 배포 앱의 `Contents/Resources/Legal`에 법적 고지를 포함하도록 패키징
6. [ ] 첫 push 후 GitHub의 MPL-2.0 감지 결과 확인

## 결정란

저장소 소유자가 확인한 최종 결정입니다.

```text
선택한 라이선스: Mozilla Public License 2.0 (MPL-2.0)
결정일: 2026-08-31
저작권 표기: Copyright 2026 SeederPowerDrop
선택 이유: 공식 앱을 무료·후원 기반으로 유지하면서 기존 파일 개선의 공개 환원을 요구하기 위해 선택
기여자 동의 방식: 별도 CLA/DCO 없이 기여를 MPL-2.0으로 제공
코드와 다르게 취급하는 자산: 없음. 권리가 확인된 프로젝트 자산도 MPL-2.0 적용
표장: MPL-2.0은 HwattakPDF 이름·서비스표·로고 사용 권리를 별도로 부여하지 않음
검토자: SeederPowerDrop
```
