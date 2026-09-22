// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import HwattakPDF

final class PDFPageDragPayloadTests: XCTestCase {
    func testItemProviderPublishesAndLoadsTheOpaquePageToken() async throws {
        let session = PDFPageDragSession(
            sourceIndex: 1,
            documentRevision: UUID()
        )
        let provider = PDFPageDragPayload.itemProvider(for: session)

        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(PDFPageDragPayload.typeIdentifier)
        )

        let loadedValue: String = try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let value = object as? NSString {
                    continuation.resume(returning: String(value))
                } else {
                    continuation.resume(
                        throwing: NSError(domain: "PDFPageDragPayloadTests", code: 1)
                    )
                }
            }
        }

        XCTAssertEqual(PDFPageDragPayload.decode(loadedValue), session.token)
    }

    func testOpaquePagePayloadRoundTripsButRejectsRawIndexAndForeignText() {
        let token = UUID()
        let encoded = PDFPageDragPayload.encodedValue(for: token)

        XCTAssertEqual(PDFPageDragPayload.decode(encoded), token)
        XCTAssertNil(PDFPageDragPayload.decode("2"))
        XCTAssertNil(PDFPageDragPayload.decode("ordinary text from another app"))
        XCTAssertNil(
            PDFPageDragPayload.decode(PDFTabDragPayload.encodedValue(for: token))
        )
    }

    func testDropRequiresProviderTokenToMatchCurrentLocalSession() {
        let revision = UUID()
        let active = PDFPageDragSession(sourceIndex: 2, documentRevision: revision)
        let stale = PDFPageDragSession(sourceIndex: 1, documentRevision: revision)

        XCTAssertEqual(
            validatedSource(
                encoded: PDFPageDragPayload.encodedValue(for: active.token),
                session: active,
                revision: revision,
                pageCount: 5,
                target: 4
            ),
            2
        )
        XCTAssertNil(
            validatedSource(
                encoded: PDFPageDragPayload.encodedValue(for: stale.token),
                session: active,
                revision: revision,
                pageCount: 5,
                target: 4
            )
        )
    }

    func testCanceledStaleLocalStateAndExternalTextCauseNoMutation() {
        let revision = UUID()
        let canceledSession = PDFPageDragSession(sourceIndex: 1, documentRevision: revision)
        var mutationCount = 0

        if let _ = validatedSource(
            encoded: "1",
            session: canceledSession,
            revision: revision,
            pageCount: 4,
            target: 3
        ) {
            mutationCount += 1
        }
        if let _ = validatedSource(
            encoded: "foreign plain text",
            session: canceledSession,
            revision: revision,
            pageCount: 4,
            target: nil
        ) {
            mutationCount += 1
        }

        XCTAssertEqual(mutationCount, 0)
    }

    func testAsyncDropRejectsChangedDocumentAndInvalidCurrentMembership() {
        let originalRevision = UUID()
        let session = PDFPageDragSession(sourceIndex: 3, documentRevision: originalRevision)
        let encoded = PDFPageDragPayload.encodedValue(for: session.token)

        XCTAssertNil(
            validatedSource(
                encoded: encoded,
                session: session,
                revision: UUID(),
                pageCount: 5,
                target: 1
            )
        )
        XCTAssertNil(
            validatedSource(
                encoded: encoded,
                session: session,
                revision: originalRevision,
                pageCount: 3,
                target: 1
            )
        )
        XCTAssertNil(
            validatedSource(
                encoded: encoded,
                session: session,
                revision: originalRevision,
                pageCount: 5,
                target: 5
            )
        )
    }

    private func validatedSource(
        encoded: String?,
        session: PDFPageDragSession?,
        revision: UUID,
        pageCount: Int,
        target: Int?
    ) -> Int? {
        PDFPageDragPayload.validatedSourceIndex(
            encodedValue: encoded,
            localSession: session,
            currentDocumentRevision: revision,
            currentPageCount: pageCount,
            targetIndex: target
        )
    }
}
