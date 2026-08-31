// SPDX-License-Identifier: MPL-2.0

import CoreGraphics

/// Corner identifiers are shared by the overlay and the pure geometry model.
enum ImageAnnotationHandle: CaseIterable, Equatable {
    case bottomLeft
    case bottomRight
    case topLeft
    case topRight
}

enum ImageLayerOrderCommand: Equatable {
    case bringToFront
    case bringForward
    case sendBackward
    case sendToBack
}

/// Side-effect-free geometry rules for moving, resizing and cropping stamps.
///
/// Keeping these calculations free of `PDFView` makes coordinate bugs testable
/// without launching AppKit. Callers convert the pointer to PDF page space
/// first; every returned rectangle is clamped to the supplied page limits.
enum ImageAnnotationGeometry {
    static let minimumDisplaySize: CGFloat = 24

    static func movedBounds(
        _ original: CGRect,
        translation: CGSize,
        within limits: CGRect
    ) -> CGRect {
        guard !original.isNull, !original.isEmpty, !limits.isNull, !limits.isEmpty else {
            return original
        }

        let proposed = CGPoint(
            x: original.minX + translation.width,
            y: original.minY + translation.height
        )
        let maximumX = max(limits.minX, limits.maxX - original.width)
        let maximumY = max(limits.minY, limits.maxY - original.height)
        return CGRect(
            origin: CGPoint(
                x: min(max(proposed.x, limits.minX), maximumX),
                y: min(max(proposed.y, limits.minY), maximumY)
            ),
            size: original.size
        )
    }

    static func resizedBounds(
        _ original: CGRect,
        handle: ImageAnnotationHandle,
        draggedTo point: CGPoint,
        within limits: CGRect,
        minimumSize: CGFloat = minimumDisplaySize,
        preservingAspectRatio: Bool
    ) -> CGRect {
        guard !original.isNull, !original.isEmpty, !limits.isNull, !limits.isEmpty else {
            return original
        }

        // The corner opposite the dragged handle is the fixed anchor. Width and
        // height grow away from it and are then limited by the page boundary.
        let anchor = anchorPoint(for: handle, in: original)
        let growsLeft = handle == .bottomLeft || handle == .topLeft
        let growsDown = handle == .bottomLeft || handle == .bottomRight
        let maximumWidth = growsLeft ? anchor.x - limits.minX : limits.maxX - anchor.x
        let maximumHeight = growsDown ? anchor.y - limits.minY : limits.maxY - anchor.y
        let effectiveMinimumWidth = min(maximumWidth, max(1, minimumSize))
        let effectiveMinimumHeight = min(maximumHeight, max(1, minimumSize))

        var width = min(max(abs(point.x - anchor.x), effectiveMinimumWidth), maximumWidth)
        var height = min(max(abs(point.y - anchor.y), effectiveMinimumHeight), maximumHeight)

        if preservingAspectRatio, original.width > 0, original.height > 0 {
            let widthScale = width / original.width
            let heightScale = height / original.height
            let requestedScale = abs(widthScale - 1) >= abs(heightScale - 1)
                ? widthScale
                : heightScale
            let minimumScale = max(
                effectiveMinimumWidth / original.width,
                effectiveMinimumHeight / original.height
            )
            let maximumScale = min(
                maximumWidth / original.width,
                maximumHeight / original.height
            )
            let scale = min(max(requestedScale, minimumScale), maximumScale)
            width = original.width * scale
            height = original.height * scale
        }

        return CGRect(
            x: growsLeft ? anchor.x - width : anchor.x,
            y: growsDown ? anchor.y - height : anchor.y,
            width: width,
            height: height
        ).intersection(limits)
    }

    static func cropRect(
        _ currentCrop: CGRect,
        displayedIn originalBounds: CGRect,
        croppedTo newBounds: CGRect
    ) -> CGRect {
        guard originalBounds.width > 0, originalBounds.height > 0 else {
            return unitRect(currentCrop)
        }

        let clippedBounds = newBounds.intersection(originalBounds)
        guard !clippedBounds.isNull, !clippedBounds.isEmpty else {
            return unitRect(currentCrop)
        }

        // Crop rectangles are normalized to 0...1 inside the *source image*,
        // whereas `originalBounds` is measured in PDF points on the page.
        // Convert the displayed fraction into the current source-image window.
        let current = unitRect(currentCrop)
        let horizontalOffset = (clippedBounds.minX - originalBounds.minX) / originalBounds.width
        let verticalOffset = (clippedBounds.minY - originalBounds.minY) / originalBounds.height
        return unitRect(
            CGRect(
                x: current.minX + horizontalOffset * current.width,
                y: current.minY + verticalOffset * current.height,
                width: current.width * clippedBounds.width / originalBounds.width,
                height: current.height * clippedBounds.height / originalBounds.height
            )
        )
    }

    static func unitRect(_ rect: CGRect) -> CGRect {
        let standardized = rect.standardized
        let minimumX = min(max(standardized.minX, 0), 1)
        let minimumY = min(max(standardized.minY, 0), 1)
        let maximumX = min(max(standardized.maxX, minimumX), 1)
        let maximumY = min(max(standardized.maxY, minimumY), 1)
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private static func anchorPoint(
        for handle: ImageAnnotationHandle,
        in bounds: CGRect
    ) -> CGPoint {
        switch handle {
        case .bottomLeft:
            CGPoint(x: bounds.maxX, y: bounds.maxY)
        case .bottomRight:
            CGPoint(x: bounds.minX, y: bounds.maxY)
        case .topLeft:
            CGPoint(x: bounds.maxX, y: bounds.minY)
        case .topRight:
            CGPoint(x: bounds.minX, y: bounds.minY)
        }
    }
}

/// Generic array reorder helper used to calculate annotation z-order.
/// It deliberately returns a new array; mutation of `PDFPage.annotations` is
/// handled by the workspace where undo and dirty-state bookkeeping live.
enum ImageLayerOrder {
    static func reordered<Value>(
        _ values: [Value],
        selectedIndex: Int,
        command: ImageLayerOrderCommand
    ) -> [Value] {
        guard values.indices.contains(selectedIndex), values.count > 1 else { return values }

        let destination: Int
        switch command {
        case .bringToFront:
            destination = values.count - 1
        case .bringForward:
            destination = min(values.count - 1, selectedIndex + 1)
        case .sendBackward:
            destination = max(0, selectedIndex - 1)
        case .sendToBack:
            destination = 0
        }
        guard destination != selectedIndex else { return values }

        var result = values
        let selected = result.remove(at: selectedIndex)
        result.insert(selected, at: destination)
        return result
    }
}
