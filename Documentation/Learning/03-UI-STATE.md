# 3장 화면과 상태의 흐름

PDF의 10페이지로 이동하면 본문, 페이지 번호, 사이드바가 함께 달라집니다. 각 화면이 페이지 번호를 따로 저장하면 서로 다른 페이지를 가리키기 쉽습니다. 우리 앱에서는 여러 화면이 문서 모델(model)의 상태(state)를 관찰하고, PDFKit에서 발생한 입력도 그 모델에 전달합니다. 여기서 모델은 문서의 데이터와 편집 상태를 관리하는 객체입니다. 이번 장에서는 모델과 화면 사이를 오가는 경로를 끝까지 따라가 봅니다.

## 학습 목표와 원문

### 작은 예제로 시작하기

여기서 상태(state)는 어려운 장치가 아니라 **프로그램이 지금 기억하는 값**입니다. 현재 페이지를 저장한 `currentPageIndex`도 상태 하나입니다. 화면에 보이는 번호는 이 값에 1을 더해 표시합니다.

| 때 | 기억하는 값 | 사용자에게 보이는 번호 |
| --- | --- | --- |
| 첫 페이지를 보고 있을 때 | `currentPageIndex = 0` | 1쪽 |
| 3쪽으로 이동한 뒤 | `currentPageIndex = 2` | 3쪽 |
| 없는 페이지로 이동하려다 거절된 뒤 | 여전히 `2` | 여전히 3쪽 |

툴바의 번호와 PDF 본문이 서로 다른 값을 기억하면 번호는 3쪽인데 본문은 1쪽인 문제가 생길 수 있습니다. 그래서 한 문서의 현재 페이지를 관리하는 곳을 정하고, 여러 화면이 그 값을 사용하게 합니다. 문서 모델(model)은 이런 값과 그 값을 바꾸는 기능을 모아 둔 객체(object)입니다. 이 장에서는 우선 “현재 페이지를 기억하고 바꾸는 담당자”로 이해해도 충분합니다.

처음에는 **6절의 페이지 번호 입력 → 7절의 PDF 본문 스크롤 → 8절의 중복 갱신 방지**를 읽으세요. `@StateObject`와 `Coordinator`의 자세한 문법은 이 흐름이 이해된 뒤에 읽어도 됩니다. 지금 확인할 것은 세 가지입니다. 어떤 입력이 들어왔는지, 누가 값을 바꾸는지, 바뀐 값을 어느 화면이 보여 주는지입니다.

**확인해 보세요.** 5쪽을 보고 있을 때 내부 값이 4라면, 2쪽으로 이동한 뒤에는 얼마일까요? 답은 1입니다. 이때 바뀌는 것은 현재 위치입니다. 페이지 삭제나 주석 추가를 하지 않았다면 이 이동만으로 문서 내용이 편집되지는 않습니다.

이 장을 마치면 앱·창·탭·문서 모델의 역할을 구분하고, “상태를 바꾸는 코드”와 “상태를 화면에 반영하는 코드”를 찾을 수 있습니다. 화면이 생성되고 사라지기까지의 수명주기(lifecycle)가 편집 내용과 메모리 사용에 왜 영향을 주는지도 설명할 수 있습니다.

| 원문 파일 | 이 장에서 볼 이름 |
|---|---|
| [HwattakPDFApp.swift](../../Sources/HwattakPDF/App/HwattakPDFApp.swift) | `HwattakPDFApp.init`, `body` |
| [MultiDocumentWorkspaceState.swift](../../Sources/HwattakPDF/Models/MultiDocumentWorkspaceState.swift) | `PDFTabSession`, `activeTabID`, `observe(_:)` |
| [PDFWorkspaceState.swift](../../Sources/HwattakPDF/Models/PDFWorkspaceState.swift) | `currentPageIndex`, `setCurrentPage`, `prepareForDeactivation` |
| [TabbedWorkspaceView.swift](../../Sources/HwattakPDF/Views/TabbedWorkspaceView.swift) | `workspaceLayer` |
| [WorkspaceView.swift](../../Sources/HwattakPDF/Views/WorkspaceView.swift) | `documentCanvas`, `@EnvironmentObject` |
| [PDFKitViewer.swift](../../Sources/HwattakPDF/Views/PDFKitViewer.swift) | `makeNSView`, `updateNSView`, `Coordinator` |
| [PageJumpControl.swift](../../Sources/HwattakPDF/Views/PageJumpControl.swift) | `commit()` |

소스의 `[학습 03]` 주석은 이번 장에서 다루는 설계의 이유를 실제 구현 옆에서 설명합니다. 아래 흐름은 일반 문서 화면을 기준으로 합니다. 비교 화면과 여러 페이지를 한눈에 보는 개요 화면은 다른 코드 경로를 사용합니다.

## 1. 같은 “workspace”라는 이름, 서로 다른 관리 범위

먼저 이름이 비슷한 두 모델을 구분해야 합니다. `MultiDocumentWorkspaceState`는 창 안의 여러 탭과 탭 그룹, 이름을 붙여 관리하는 작업 공간(workspace)을 조정합니다. `PDFWorkspaceState`는 PDF 탭 하나의 문서·현재 페이지·선택·검색·OCR·편집 상태를 관리합니다. `PDFTabSession`은 탭 식별자(ID)와 해당 문서 모델을 하나로 묶습니다.

다음 그림은 주로 객체를 소유하거나 전달하는 관계를 나타냅니다. 모든 타입이 하나의 상속 계층을 이룬다는 뜻은 아닙니다.

```text
HwattakPDFApp
  ├─ 주 창의 MultiDocumentWorkspaceState
  │    └─ PDFTabSession 여러 개
  │         └─ 각 탭의 PDFWorkspaceState
  └─ TabbedWorkspaceView
       └─ 활성 session의 WorkspaceView
            ├─ 툴바·페이지 사이드바·검색·보조 패널
            └─ PDFKitViewer
                 ├─ InteractivePDFView (PDFKit의 PDFView 확장)
                 └─ Coordinator (입력·알림 연결)
```

사용자는 여러 탭을 열어 둘 수 있지만, 일반 화면에서는 현재 선택한 활성 탭만 자원을 많이 사용하는 PDF 화면을 유지합니다. 다른 탭의 문서 모델은 남아 있으며, 조건에 따라 문서 객체를 일시적으로 비활성 상태로 두기도 합니다. 창을 분리할 때는 `PDFTabTearOutWindowRoot`와 앱 전체의 세션(session)을 조정하는 객체가 별도 창의 모델과 복원 작업을 연결합니다. 따라서 앱 전체에 문서 모델이 하나만 있다고 이해해서는 안 됩니다.

## 2. 앱의 시작점에서 기능 구성하기

`@main`이 붙은 `HwattakPDFApp`이 앱의 진입점(entry point)입니다. 이 타입은 앱을 사용하는 동안 유지할 객체와 창을 구성합니다. 실제 초기화 코드를 일부 발췌하면 다음과 같습니다.

```swift
let recentDocuments = RecentDocumentsStore()
let sessionStore = WorkspaceSessionStore()
let workspace = MultiDocumentWorkspaceState(
    recentDocumentsStore: recentDocuments,
    sessionStore: sessionStore
)
_workspace = StateObject(wrappedValue: workspace)
```

최근 문서 저장소와 세션 저장소를 먼저 만들고 탭 모델에 전달합니다. 이처럼 객체가 사용할 다른 객체를 외부에서 전달받는 방식을 의존성 주입(dependency injection)이라고 합니다. 쉽게 말해, 객체를 만들 때 필요한 대상을 함께 건네주는 방식입니다. 테스트에서는 이를 이용해 대체 저장소나 검사기를 전달할 수 있습니다.

`@StateObject`는 SwiftUI가 관리하는 수명 동안 모델의 식별성(identity)을 유지하는 데 사용합니다. 여기서 식별성이란 화면이 갱신되어도 같은 모델 객체를 계속 사용한다는 뜻입니다. `body`를 다시 계산할 때 현재 탭 목록까지 새로 만들면 안 되기 때문입니다. `TabbedWorkspaceView`는 이미 만들어진 모델을 `@ObservedObject`로 전달받아 관찰합니다. 객체를 생성하고 유지하는 위치와 전달받아 사용하는 위치를 나누는 것입니다. `@StateObject`와 `@ObservedObject`처럼 속성에 특별한 관리 동작을 더하는 Swift 문법을 프로퍼티 래퍼(property wrapper)라고 합니다. [Apple의 StateObject](https://developer.apple.com/documentation/swiftui/stateobject), [ObservedObject 설명](https://developer.apple.com/documentation/swiftui/observedobject)

`var body: some Scene`은 어떤 종류의 창과 메뉴가 있는지 선언합니다. 그 안의 `WindowGroup`은 주 문서 창과 분리된 창을 구성하고, 별도의 `Window`와 `Settings`는 도움말·플러그인·설정 등의 화면을 구성합니다. 일반 `View.body`가 화면의 내용을 정의한다면, `App.body`는 창과 같은 장면(scene)의 구성을 정의한다고 이해하면 됩니다.

## 3. 모델이 화면으로 전달되는 두 경로

우리 앱에서는 모델을 인자(argument)로 직접 전달하는 방식과 SwiftUI의 환경(environment)에 넣어 전달하는 방식을 함께 사용합니다.

```swift
// 실제 호출의 인자 일부 생략
TabbedWorkspaceView(workspace: workspace, /* … */)
```

이 경우 화면을 만드는 코드에서 어떤 모델을 전달하는지 바로 알 수 있습니다. `TabbedWorkspaceView.workspaceLayer`에서는 활성 탭을 찾고, 그 탭의 문서 모델을 아래처럼 전달합니다.

```swift
// workspaceLayer의 실제 구성에서 다른 인자와 modifier를 생략했다.
if !isComparing, let session = workspace.activeSession {
    WorkspaceView(/* … */)
        .environmentObject(session.workspace)
        .id(session.id)
}
```

`WorkspaceView` 쪽의 실제 선언은 `@EnvironmentObject private var workspace: PDFWorkspaceState`입니다. 화면 계층에서 상위에 있는 화면이 환경에 넣어 둔 같은 타입의 모델을 받습니다. 여기서 `workspace`는 PDF 한 개의 모델을 가리킵니다. 탭 관리자에도 같은 변수 이름을 사용하므로 처음 읽을 때는 둘을 혼동하기 쉽습니다.

`.id(session.id)`는 탭이 바뀌면 화면의 식별성도 바뀐다는 것을 SwiftUI에 알려 줍니다. 이를 통해 새 탭에서 이전 탭의 일시적인 입력이나 패널 상태가 그대로 이어지는 것을 막습니다. 계속 유지해야 하는 문서 상태는 탭 모델에 있으므로 `WorkspaceView`를 다시 생성해도 사라지지 않습니다.

도구 막대(toolbar)의 표시 여부나 잠깐 열어 둔 입력창 같은 화면 상태는 `@State`에 둘 수 있습니다. 앱 설정을 유지하는 곳에는 `@AppStorage`, 창별 표시 상태를 관리하는 곳에는 `@SceneStorage`도 등장합니다. 상태가 어느 범위에 속하고 얼마나 오래 유지되어야 하는지에 따라 저장 방식을 고릅니다.

## 4. SwiftUI와 PDFKit이 화면을 다루는 방식

SwiftUI에서는 현재 상태에 맞는 화면을 선언합니다. 상태가 바뀌면 `body`가 다시 평가될 수 있습니다. 따라서 `body`가 호출될 때마다 PDF를 열거나 저장하도록 작성하면, 작은 화면 변화만으로도 큰 작업을 반복하게 됩니다.

PDFKit의 `PDFView`는 AppKit 객체입니다. 이미 존재하는 객체에 `document`나 `displayMode`를 설정하고 `go(to:)` 같은 메서드(method)를 호출해 화면을 조작합니다. 이 앱의 `InteractivePDFView`는 이 화면을 확장합니다.

`PDFKitViewer: NSViewRepresentable`이 두 방식을 연결합니다. SwiftUI에서는 일반 뷰(view)처럼 사용하며, 내부에서는 AppKit 화면의 생성·갱신·제거를 관리합니다. 이런 연결 역할을 하는 코드를 어댑터(adapter)라고 합니다. PDFKit 내부에서 발생한 변화가 주변 SwiftUI로 자동 전달되지는 않으므로, 코디네이터(coordinator) 역할을 하는 `Coordinator`가 알림과 입력을 모델로 전달합니다. [NSViewRepresentable 안내](https://developer.apple.com/documentation/swiftui/nsviewrepresentable)

`WorkspaceView.documentCanvas`는 `pageColumns <= 2`일 때 이 어댑터를 사용하고, 페이지를 더 많은 열로 배치할 때는 `PDFGridOverview`를 사용합니다. 이 조건을 모르면 모든 화면 동작이 `PDFKitViewer` 안에서 처리된다고 오해하기 쉽습니다.

## 5. 네 단계의 수명주기

`PDFKitViewer`의 함수는 SwiftUI가 필요한 시점에 호출합니다. 앱 코드에서 직접 반복문을 작성해 이 순서대로 실행하는 구조는 아닙니다.

| 단계 | 우리 코드에서 하는 일 | 그 이유 |
|---|---|---|
| `makeCoordinator()` | 연결을 관리할 참조 객체 생성 | SwiftUI 값이 갱신되어도 관찰 상태를 유지 |
| `makeNSView(context:)` | `InteractivePDFView` 생성·초기 설정·연결 | AppKit 화면과 알림을 준비 |
| `updateNSView(_:context:)` | 문서·표시 모드·리비전(`revision`)·페이지의 차이 적용 | 현재 모델과 기존 화면을 맞춤 |
| `dismantleNSView(_:coordinator:)` | 입력 마무리·관찰 해제·제스처 정리 | 떠난 화면이 계속 반응하거나 초안을 잃지 않게 함 |

SwiftUI 안에 배치한 AppKit 뷰(hosted view)는 한 번 생성된 뒤 여러 번 갱신될 수 있습니다. 식별성이 바뀌어 새 뷰가 필요하면 생성 단계부터 다시 시작합니다. 따라서 `makeNSView`가 앱 전체에서 딱 한 번만 호출된다는 뜻은 아닙니다. 이 수명주기는 Apple의 [SwiftUI와 AppKit 연결 설명](https://developer.apple.com/videos/play/wwdc2022/10075/)에서도 다룹니다.

`Coordinator`는 `NSObject`를 상속하는 클래스(class)입니다. PDFKit 알림과 `@objc` 메서드를 선택자(selector)로 연결하고, 마지막 페이지·리비전·검색 선택 등을 보관합니다. 선택자는 Objective-C에서 호출할 메서드를 지정하는 데 쓰입니다. `state`와 `pdfView`는 약한 참조(weak reference)이므로 이 참조만으로 대상 객체의 수명이 늘어나지는 않습니다. 값이 `nil`이 되는 상황도 정상적인 종료 과정의 일부입니다.

## 6. 실제 사례 A: 페이지 번호에 10 입력하기

문서가 10페이지 이상이라고 가정합니다. 사용자가 페이지 입력창에 `10`을 입력하고 확정하면 다음 순서로 진행됩니다.

1. `PageJumpControl.commit()`이 입력 문자열을 `PDFPageJumpRequest.resolve`에 전달합니다.
2. 유효한 목적지라면 내부 인덱스(index) 9와 표시 번호 10을 받습니다.
3. `workspace.setCurrentPage(pageIndex)`가 문서 모델을 바꿉니다.
4. 모델의 변경 알림을 관찰하는 화면이 갱신됩니다.
5. `PDFKitViewer.updateNSView`가 대상 페이지와 기존 화면을 비교한 뒤 `pdfView.go(to: page)`를 호출합니다.

모델의 실제 함수는 다음과 같습니다.

```swift
func setCurrentPage(_ index: Int) {
    guard index >= 0, index < pageCount else { return }
    currentPageIndex = index
    if selectedPages.isEmpty {
        selectedPages = [index]
    }
}
```

이 함수는 PDF 화면 객체를 직접 찾지 않고 문서 상태만 바꿉니다. 따라서 버튼·메뉴·사이드바처럼 입력 수단이 달라도 같은 함수를 재사용할 수 있습니다. `updateNSView`는 `requiresNavigation` 등의 조건으로 이동이 실제로 필요한지 확인합니다. 모델이 갱신될 때마다 같은 페이지로 다시 이동하면 스크롤 위치가 튀거나 불필요한 알림이 반복될 수 있기 때문입니다.

다만 현재 프로젝트에서 페이지 번호를 바꾸려면 반드시 이 함수를 거쳐야 하는 것은 아닙니다. `currentPageIndex` 자체도 값을 대입할 수 있는 설정자(setter)를 공개한 `@Published var`입니다. 교재에서는 해당 페이지 입력창이 실제로 사용하는 호출 경로를 설명합니다. 설계상 의도한 사용법과 코드가 강제로 보장하는 범위를 구분하며 읽어 보세요.

## 7. 실제 사례 B: PDF 본문 스크롤하기

이번에는 사용자가 PDFKit 화면 자체를 스크롤합니다. 화면의 변화에서 처리가 시작됩니다.

```text
사용자 스크롤
  → PDFKit이 현재 페이지 변경
  → PDFViewPageChanged 알림
  → Coordinator.pageChanged(_:)
  → PDFWorkspaceState.setCurrentPage(_:)
  → 관찰 중인 페이지 번호·사이드바 갱신
```

`attach(to:)`는 알림에 `object: pdfView`를 지정합니다. 여러 PDF 창이 있더라도 연결한 PDF 화면에서 나온 알림만 받겠다는 뜻입니다. `pageChanged`는 PDFKit의 현재 페이지를 문서 인덱스로 바꾸고, 모델의 현재 인덱스와 다를 때만 `setCurrentPage`를 호출합니다.

두 페이지를 묶어 보는 모드에는 추가 규칙이 있습니다. PDFKit이 왼쪽 페이지를 현재 페이지로 알려 주더라도, 사용자가 직접 선택한 오른쪽 페이지가 여전히 보인다면 사용자가 요청한 인덱스를 유지합니다. 사용자가 선택한 위치를 보존하기 위해 필요한 규칙입니다.

텍스트 선택은 `PDFViewSelectionChanged` → `selectionChanged(_:)` → `state.currentSelection`으로 이어집니다. 검색으로 만든 선택에는 `observeActiveSearchSelection()`도 관여합니다. 이처럼 페이지, 선택, 배율이 각각 어떤 이벤트(event)를 기준으로 갱신되는지 확인해야 합니다.

## 8. 왕복 경로에서 되먹임으로 인한 중복 갱신 막기

두 사례를 합치면 모델 → 화면 → 모델로 돌아오는 되먹임 고리(feedback loop)가 생깁니다. 프로그램이 호출한 `go(to:)`도 PDFKit 알림을 발생시킬 수 있습니다. 이를 사용자의 새로운 입력으로 해석하면 중복 갱신이나 원치 않는 이동이 생깁니다.

실제 `updateNSView`의 앞부분에서는 이 문제를 다음처럼 처리합니다.

```swift
coordinator.isApplyingState = true
defer { coordinator.isApplyingState = false }
```

상태를 적용 중이라는 표시를 켜고, 함수가 끝날 때 `defer`로 다시 끕니다. 이벤트를 받는 `pageChanged`, `selectionChanged`는 `guard !isApplyingState`로 이 구간의 알림을 건너뜁니다. 이 표시 하나로 모든 상황의 알림을 처리하지는 않습니다. 후속 갱신에서는 현재 페이지 비교, 복원 세대 번호 등 다른 조건도 함께 사용합니다.

문서의 변경 여부를 검사할 때도 두 종류의 변화를 구분합니다. `pdfView.document !== state.document`는 문서 객체 자체가 바뀌었는지 검사합니다. 같은 `PDFDocument` 안에서 주석이나 페이지 내용만 바뀌면 참조는 그대로입니다. 그래서 문서의 변경 단계를 구분하는 별도의 리비전(revision)을 비교해 `layoutDocumentView()` 호출과 화면 다시 그리기를 요청합니다. 같은 객체인지 확인하는 것과 객체 안의 내용이 바뀌었는지 확인하는 것은 서로 다른 검사입니다.

## 9. 탭을 바꿀 때 진행 중인 입력 마무리하기

편집 중인 텍스트가 아직 PDF 주석에 반영되지 않았는데 화면부터 없애면 초안이 사라질 수 있습니다. `MultiDocumentWorkspaceState.activeTabID`의 `willSet`은 전환하기 전 탭의 `prepareForDeactivation()`을 호출합니다. 문서 모델과 연결된 화면은 처리 중이던 입력을 먼저 마무리합니다.

`dismantleNSView`도 문서 위에서 직접 편집하는 인라인 입력(inline input)을 마무리하고 `prepareForDismantling()`과 `detach()`를 실행합니다. `detach()`는 Combine 구독(subscription)을 취소하고, 알림 관찰과 AppKit 이벤트 모니터를 제거하며, 연결에 사용한 참조를 비웁니다. 구독은 이후 발생하는 변경을 계속 전달받도록 연결해 두는 것입니다. 연결할 때 `attach()`가 먼저 `detach()`를 부르는 이유도 같은 알림을 중복 구독하지 않기 위해서입니다.

이때 “입력 확정”은 화면의 초안을 문서 모델에 반영하는 일입니다. 디스크에 PDF 파일을 저장하는 일과는 구분해야 합니다. 문서가 수정되었다면 파일을 저장하고 닫을 때 어떻게 처리할지도 정해야 합니다. 화면의 수명, 문서 상태의 변경, 파일 저장을 구분해 생각해야 입력이 사라지는 이유를 이해할 수 있습니다.

탭 관리자에는 또 하나의 연결이 있습니다. `observe(_:)`는 각 문서 모델의 `objectWillChange`를 구독해 탭 관리자의 변경 알림으로 전달하고 세션 저장을 예약합니다. 탭 배열 자체는 그대로여도 탭 안의 문서 제목이나 수정 상태는 바뀔 수 있기 때문입니다. 배열 안에 객체를 넣는 것만으로 객체 내부의 변경이 탭 관리자의 변경 알림으로 자동 전달되지는 않습니다.

## 연습 1. 상태를 관리할 모델 정하기

현재 PDF의 수정 여부, 현재 창에서 선택한 탭 ID, OCR 설정창의 표시 여부를 각각 어디에 둘지 설명해 보세요.

**해설:** 수정 여부는 한 문서에 속하므로 `PDFWorkspaceState.isDirty`가 맡습니다. 활성 탭 ID는 한 창에 있는 여러 탭의 관계를 나타내므로 `MultiDocumentWorkspaceState.activeTabID`가 맡습니다. `WorkspaceView`의 `@State private var showingOCR`는 설정창을 표시하기 위한 일시적인 상태입니다. 오래 유지해야 하는 문서 편집 상태와 화면의 일시적인 표시 상태를 구분합니다.

## 연습 2. 무한 갱신을 막는 조건 찾기

`PDFKitViewer.updateNSView`와 `Coordinator.pageChanged`에서 `isApplyingState`를 찾아보세요. 이 표시를 제거하면 어떤 왕복 경로가 생길 수 있는지, 같은 인덱스인지 검사하는 조건도 함께 필요한 이유는 무엇인지 설명해 보세요.

**해설:** 모델의 페이지 변경 → `go(to:)` → PDFKit 페이지 알림 → 모델 페이지 변경이라는 고리가 생길 수 있습니다. 적용 중이라는 표시는 동기적으로 발생하는 알림을 새 사용자 입력처럼 처리하지 않게 합니다. 값 비교는 이미 맞춰진 상태를 다시 변경하지 않게 합니다. 두 장치는 변경의 원인과 결과를 구분하고 불필요한 중복 작업을 막는 역할을 함께 합니다. 이 실습에서는 실제 앱에서 표시를 지우지 않아도 됩니다. 종이에 호출 순서를 그려 보세요.

## 연습 3. 화면이 사라져도 문서 상태 유지하기

`TabbedWorkspaceView.workspaceLayer`의 `.environmentObject(session.workspace)`와 `.id(session.id)`를 찾아보세요. 탭을 바꿀 때 `WorkspaceView` 안에서 매번 `PDFWorkspaceState()`를 새로 만든다면 어떤 문제가 생길지 생각해 보세요.

**해설:** 각 화면이 기존 탭의 모델 대신 빈 문서 모델을 새로 만들면 현재 페이지, 선택, 수정 상태, 편집 기록이 원래 탭과 분리됩니다. 새 화면이 기존 `session.workspace`를 받으면 화면의 수명과 문서 상태의 수명을 따로 관리할 수 있습니다. 화면이 사라졌다는 사실만으로 문서를 닫거나 저장했다고 판단해서는 안 됩니다.
