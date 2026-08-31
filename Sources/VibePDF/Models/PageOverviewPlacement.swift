// SPDX-License-Identifier: MPL-2.0

import Foundation

/// 페이지/검색 사이드바가 문서 캔버스의 어느 물리적 가장자리에 붙는지 나타낸다.
///
/// `left`와 `right`는 RTL 언어에서도 물리적인 좌·우를 뜻한다. 사용자가 직접
/// 고른 위치가 언어를 바꿨다고 반대로 이동하지 않게 하려는 의도다.
enum PageOverviewPlacement: String, CaseIterable, Identifiable {
    case left
    case right
    case top
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: L10n.string("placement.left")
        case .right: L10n.string("placement.right")
        case .top: L10n.string("placement.top")
        case .bottom: L10n.string("placement.bottom")
        }
    }

    var systemImage: String {
        switch self {
        case .left: "rectangle.leadinghalf.inset.filled"
        case .right: "rectangle.trailinghalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        }
    }

    /// 상단·하단은 썸네일을 가로로 흘려보내므로 폭이 아니라 높이를 조절한다.
    var usesHorizontalPageStrip: Bool {
        self == .top || self == .bottom
    }
}
