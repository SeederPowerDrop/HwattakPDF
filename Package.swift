// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

// Swift Package Manager(SwiftPM)는 이 파일을 읽어 어떤 운영 체제에서,
// 어떤 실행 파일과 테스트를 빌드할지 결정한다. Xcode 프로젝트 파일을 따로
// 커밋하지 않아도 `swift build`, `swift run`, `swift test`가 같은 구성을
// 공유하는 이유가 바로 이 선언형 manifest 덕분이다.
let package = Package(
    name: "HwattakPDF",
    // 번역 키가 누락되었을 때 기준이 되는 언어다. 실제 앱에서는 사용자가
    // 설정에서 선택한 언어 bundle을 `L10n`이 명시적으로 사용한다.
    defaultLocalization: "ko",
    platforms: [
        // PDFKit/SwiftUI API와 보안 bookmark 동작을 이 최소 버전에 맞춘다.
        .macOS(.v14)
    ],
    products: [
        // 앱 번들, 개발 실행 명령과 Swift 모듈에 같은 제품 이름을 사용한다.
        .executable(name: "HwattakPDF", targets: ["HwattakPDF"])
    ],
    targets: [
        // Sources/HwattakPDF 아래의 앱 코드를 하나의 macOS 실행 파일로 묶는다.
        .executableTarget(
            name: "HwattakPDF",
            swiftSettings: [
                // 도구 체인은 Swift 6이지만 기존 AppKit/PDFKit delegate와의
                // 점진적 동시성 마이그레이션을 위해 언어 모드는 Swift 5다.
                .swiftLanguageMode(.v5)
            ]
        ),
        // Tests/HwattakPDFTests의 테스트가 앱 target을 `@testable import`하여
        // 내부 상태 머신과 보안 경계를 실제 제품 코드 그대로 검증한다.
        .testTarget(
            name: "HwattakPDFTests",
            dependencies: ["HwattakPDF"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
