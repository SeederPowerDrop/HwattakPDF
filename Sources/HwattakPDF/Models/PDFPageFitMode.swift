// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Axis fitting is independent of the number of pages in a spread.
enum PDFPageFitMode: String, Codable, CaseIterable {
    case width
    case height

    func scaleFactor(
        viewportSize: CGSize,
        pageSizes: [CGSize],
        horizontalInsets: CGFloat = 0,
        verticalInsets: CGFloat = 0,
        pageSpacing: CGFloat = 0
    ) -> CGFloat? {
        guard !pageSizes.isEmpty,
              viewportSize.width.isFinite, viewportSize.height.isFinite,
              viewportSize.width > 0, viewportSize.height > 0,
              pageSizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 })
        else { return nil }

        let available: CGFloat
        let extent: CGFloat
        switch self {
        case .width:
            available = viewportSize.width
            extent = pageSizes.reduce(0) { $0 + $1.width }
                + horizontalInsets + pageSpacing * CGFloat(pageSizes.count - 1)
        case .height:
            available = viewportSize.height
            extent = (pageSizes.map(\.height).max() ?? 0) + verticalInsets
        }
        guard available.isFinite, available > 0, extent.isFinite, extent > 0 else { return nil }
        return min(20, max(0.05, available / extent))
    }
}
