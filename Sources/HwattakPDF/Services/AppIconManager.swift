// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

/// 사용자가 고른 앱 아이콘을 기억하고 실행 중 Dock 아이콘에 적용한다.
///
/// 앱 전체에 하나만 있어야 하므로 singleton이며 AppKit UI를 만져 `@MainActor`다.
/// 배포 bundle에서는 Resources를 읽고, `swift run` 개발 환경에서는 소스 트리의
/// Resources를 fallback으로 찾아 두 실행 방식에서 같은 설정 화면을 제공한다.
@MainActor
final class AppIconManager: ObservableObject {
    static let shared = AppIconManager()
    static let selectionDefaultsKey = "preferences.appIcon"

    @Published private(set) var selection: AppIconPreference
    @Published private(set) var currentImage: NSImage?

    private init() {
        if let rawValue = UserDefaults.standard.string(forKey: Self.selectionDefaultsKey),
           let storedSelection = AppIconPreference(rawValue: rawValue) {
            selection = storedSelection
        } else {
            selection = .defaultValue
        }
    }

    /// 선택을 영속화한 뒤 즉시 Dock 아이콘을 바꾼다.
    func select(_ preference: AppIconPreference) {
        selection = preference
        UserDefaults.standard.set(preference.rawValue, forKey: Self.selectionDefaultsKey)
        apply(preference)
    }

    func applySavedSelection() {
        apply(selection)
    }

    /// 배포 앱은 번들만 사용하고, debug SwiftPM 실행은 소스 트리를 fallback으로 쓴다.
    func image(for preference: AppIconPreference) -> NSImage? {
        if let bundledURL = Bundle.main.url(
            forResource: preference.resourceName,
            withExtension: "png"
        ), let image = NSImage(contentsOf: bundledURL) {
            return image
        }

        #if DEBUG
        let sourceURL = Self.sourceResourcesDirectory
            .appendingPathComponent(preference.resourceName)
            .appendingPathExtension("png")
        return NSImage(contentsOf: sourceURL)
        #else
        return nil
        #endif
    }

    private func apply(_ preference: AppIconPreference) {
        guard let image = image(for: preference) else {
            currentImage = NSApplication.shared.applicationIconImage
            return
        }
        image.isTemplate = false
        NSApplication.shared.applicationIconImage = image
        currentImage = image
    }

    #if DEBUG
    private static var sourceResourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }
    #endif
}
