// SPDX-License-Identifier: MPL-2.0

import Foundation

/// 번들에 포함된 앱 아이콘 선택지와 표시 메타데이터를 한곳에 묶는다.
/// `Codable` raw value를 UserDefaults에 저장하므로 case 이름 변경은 기존 사용자의
/// 설정 migration이 필요한 호환성 변경이라는 점에 유의한다.
enum AppIconPreference: String, CaseIterable, Identifiable, Codable {
    case stackAndSelect
    case precisionMarkup
    case foldWorkspace

    static let defaultValue: AppIconPreference = .foldWorkspace

    var id: String { rawValue }

    var resourceName: String {
        switch self {
        case .stackAndSelect: "AppIcon-StackAndSelect"
        case .precisionMarkup: "AppIcon-PrecisionMarkup"
        case .foldWorkspace: "AppIcon-FoldWorkspace"
        }
    }

    var title: String {
        switch self {
        case .stackAndSelect: L10n.string("settings.icon.stack.title")
        case .precisionMarkup: L10n.string("settings.icon.markup.title")
        case .foldWorkspace: L10n.string("settings.icon.fold.title")
        }
    }

    var subtitle: String {
        switch self {
        case .stackAndSelect: L10n.string("settings.icon.stack.subtitle")
        case .precisionMarkup: L10n.string("settings.icon.markup.subtitle")
        case .foldWorkspace: L10n.string("settings.icon.fold.subtitle")
        }
    }

    var fallbackSystemImage: String {
        switch self {
        case .stackAndSelect: "rectangle.stack"
        case .precisionMarkup: "pencil.and.outline"
        case .foldWorkspace: "book.pages"
        }
    }
}
