// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Local state for one page drag. The random token is the only identifier
/// placed on the provider; page indexes never cross the drag boundary as raw
/// text. The document revision prevents an asynchronously delivered drop from
/// moving whichever page later happens to occupy the old index.
struct PDFPageDragSession: Equatable {
    let token: UUID
    let sourceIndex: Int
    let documentRevision: UUID

    init(
        token: UUID = UUID(),
        sourceIndex: Int,
        documentRevision: UUID
    ) {
        self.token = token
        self.sourceIndex = sourceIndex
        self.documentRevision = documentRevision
    }
}

enum PDFPageDragPayload {
    static let typeIdentifier = UTType.utf8PlainText.identifier

    private static let kind = "pdf-page"
    private static let suggestedNamePrefix = "hwattak-page-"

    static func encodedValue(for token: UUID) -> String {
        InternalDragPayload.encodedValue(for: token, kind: kind)
    }

    static func decode(_ value: String) -> UUID? {
        InternalDragPayload.decode(value, expectedKind: kind)
    }

    static func suggestedName(for token: UUID) -> String {
        suggestedNamePrefix + token.uuidString.lowercased()
    }

    static func itemProvider(for session: PDFPageDragSession) -> NSItemProvider {
        let provider = NSItemProvider(
            object: encodedValue(for: session.token) as NSString
        )
        provider.suggestedName = suggestedName(for: session.token)
        return provider
    }

    /// Provider contents are authoritative at drop time. The local session is
    /// used only after its random token, document revision, and current page
    /// membership have all been revalidated.
    static func validatedSourceIndex(
        encodedValue: String?,
        localSession: PDFPageDragSession?,
        currentDocumentRevision: UUID,
        currentPageCount: Int,
        targetIndex: Int? = nil
    ) -> Int? {
        guard
            let encodedValue,
            let providerToken = decode(encodedValue),
            let localSession,
            providerToken == localSession.token,
            localSession.documentRevision == currentDocumentRevision,
            currentPageCount > 0,
            (0..<currentPageCount).contains(localSession.sourceIndex)
        else {
            return nil
        }

        if let targetIndex, !(0..<currentPageCount).contains(targetIndex) {
            return nil
        }
        return localSession.sourceIndex
    }

    /// Loads and decodes the provider asynchronously. Returning `true` only
    /// means that a load was scheduled; callers must still validate the token,
    /// revision, source, and target in the completion before mutating a PDF.
    @discardableResult
    static func loadEncodedValue(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor (String?) -> Void
    ) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            let encodedValue = (object as? NSString).map(String.init)
            Task { @MainActor in
                completion(encodedValue)
            }
        }
        return true
    }
}
