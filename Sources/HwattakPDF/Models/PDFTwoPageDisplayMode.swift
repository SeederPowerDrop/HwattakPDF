// SPDX-License-Identifier: MPL-2.0

import Foundation

/// 두 페이지를 나란히 읽을 때 다음 펼침을 같은 스크롤 면에 이어 붙일지,
/// 현재 펼침만 화면에 둘지를 나타낸다.
///
/// `pageColumns`는 두 경우 모두 2로 유지한다. 페이지 수와 표시 방식을 분리해
/// 1~12 범위라고 가정하는 개요·세션 코드를 깨뜨리지 않고 탭마다 선택을 기억한다.
enum PDFTwoPageDisplayMode: String, CaseIterable, Identifiable, Codable {
    /// 다음 두 페이지가 아래로 이어지는 기존 PDFKit 연속 보기다.
    case continuous
    /// 현재 펼침 하나만 표시하고 다음/이전 펼침으로 페이지 단위 이동한다.
    case paged

    var id: String { rawValue }
}
