// SPDX-License-Identifier: MPL-2.0

import AppKit
import Dispatch
import PDFKit
import SwiftUI

/// 렌더링된 페이지 썸네일을 재사용하는 메모리 cache다.
///
/// PDFKit thumbnail 생성은 비싸므로 같은 revision·page·width·rotation 조합을
/// 다시 그리지 않는다. `NSCache`는 메모리 압력 때 항목을 자동 방출하며, count와
/// pixel cost 상한이 많은 페이지를 연 문서의 RSS를 제한한다.
@MainActor
private final class PageImageCache {
    static let shared = PageImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var activePolicy: PDFThumbnailRenderingPolicy?

    private init() {
        configure(
            policy: PDFThumbnailRenderingPolicy(
                efficientRenderingEnabled: AppPerformanceSettings.isEfficientRenderingEnabled
            )
        )
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Thumbnail pixels are entirely recreatable. Releasing them before
            // PDF documents gives the active reading surface more headroom.
            self?.cache.removeAllObjects()
        }
        pressureSource = source
        source.resume()
    }

    /// revision이 바뀌면 key도 바뀌므로 회전·편집 뒤 오래된 이미지가 보이지 않는다.
    func image(
        for page: PDFPage,
        pageIndex: Int,
        width: CGFloat,
        revision: UUID,
        efficientRenderingEnabled: Bool
    ) -> NSImage {
        let policy = PDFThumbnailRenderingPolicy(
            efficientRenderingEnabled: efficientRenderingEnabled
        )
        configure(policy: policy)
        let targetSize = policy.targetSize(
            pageBounds: page.bounds(for: .cropBox),
            rotation: page.rotation,
            requestedWidth: width
        )
        let key = "\(revision.uuidString)-\(pageIndex)-\(Int(targetSize.width))-\(Int(targetSize.height))-\(page.rotation)-\(efficientRenderingEnabled)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image = page.thumbnail(of: targetSize, for: .cropBox)
        image.cacheMode = .bySize
        let pixelCost = policy.estimatedBitmapCost(for: targetSize)
        cache.setObject(image, forKey: key, cost: pixelCost)
        return image
    }

    private func configure(policy: PDFThumbnailRenderingPolicy) {
        guard activePolicy != policy else { return }
        activePolicy = policy
        cache.countLimit = policy.cacheCountLimit
        cache.totalCostLimit = policy.cacheCostLimit
        // Switching quality modes must not retain both raster populations.
        cache.removeAllObjects()
    }
}

/// PDFPage를 사이드바/개요에서 사용할 그림과 사람용 1-based 번호로 표시한다.
struct PageThumbnailView: View {
    let page: PDFPage
    let pageIndex: Int
    let width: CGFloat
    let revision: UUID
    var showPageNumber = true
    @State private var renderedImage: NSImage?
    @State private var renderedRequestID: String?

    private var requestID: String {
        "\(revision)-\(pageIndex)-\(width)-\(page.rotation)-\(efficientRenderingEnabled)"
    }

    private var pageAspectRatio: CGFloat {
        let size = page.bounds(for: .cropBox).size
        guard size.width > 0, size.height > 0 else { return 1 }
        return abs(page.rotation % 180) == 90 ? size.height / size.width : size.width / size.height
    }

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppPerformanceSettings.efficientRenderingEnabledKey)
    private var efficientRenderingEnabled = AppPerformanceSettings.defaultEfficientRenderingEnabled

    var body: some View {
        let theme = HwattakPDFTheme(colorScheme: colorScheme)

        return VStack(spacing: 9) {
            Group {
                if renderedRequestID == requestID, let renderedImage {
                    Image(nsImage: renderedImage).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.white).aspectRatio(pageAspectRatio, contentMode: .fit)
                }
            }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), lineWidth: 0.75)
                }
                .shadow(color: theme.elevatedShadow, radius: 10, y: 4)
                .accessibilityLabel(L10n.format("page.number", pageIndex + 1))

            if showPageNumber {
                Text("\(pageIndex + 1)")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .task(id: requestID) { @MainActor in
            // Let visible controls paint first. Fast scrolling cancels transient
            // cells before expensive PDFKit rendering, which stays on its owner actor.
            do { try await Task.sleep(nanoseconds: 35_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            let image = PageImageCache.shared.image(for: page, pageIndex: pageIndex,
                width: width, revision: revision, efficientRenderingEnabled: efficientRenderingEnabled)
            renderedImage = image
            renderedRequestID = requestID
        }
        .onDisappear {
            renderedImage = nil
            renderedRequestID = nil
        }
    }
}
