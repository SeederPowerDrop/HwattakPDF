// SPDX-License-Identifier: MPL-2.0

import AppKit
import XCTest
@testable import HwattakPDF

final class SignatureCaptureConfigurationTests: XCTestCase {
    @MainActor
    func testCanvasAcceptsLightIndirectTrackpadTouches() {
        let canvas = SignatureCanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 280)
        )

        XCTAssertTrue(canvas.allowedTouchTypes.contains(.indirect))
        XCTAssertTrue(canvas.wantsRestingTouches)
    }

    @MainActor
    func testCaptureStateIsResetWhenCanvasIsRemoved() {
        let canvas = SignatureCanvasNSView(
            frame: CGRect(x: 0, y: 0, width: 700, height: 280)
        )

        canvas.setTrackpadCaptureActive(true)
        XCTAssertTrue(canvas.isTrackpadCaptureActive)

        canvas.prepareForRemoval()
        XCTAssertFalse(canvas.isTrackpadCaptureActive)
    }
}
