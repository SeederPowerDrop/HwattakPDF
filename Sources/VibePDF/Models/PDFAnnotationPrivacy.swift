// SPDX-License-Identifier: MPL-2.0

import PDFKit

/// Removes author metadata that PDFKit otherwise fills from the macOS account.
///
/// A freshly initialized `PDFAnnotation` inherits the current user's full
/// account name in its `/T` (text-label/author) entry. That behavior is useful
/// in collaborative review software, but HwattakPDF does not currently show an
/// author field or ask for consent to publish one. Silently embedding a real
/// name in every note, stroke, signature, or image would therefore violate the
/// app's local-first privacy promise.
///
/// Call this immediately after creating every app-owned annotation. Do not run
/// it over third-party annotations already present in a PDF: their author is
/// document content and removing it would be an unrelated destructive edit.
enum PDFAnnotationPrivacy {
    static func clearImplicitAuthor(on annotation: PDFAnnotation) {
        annotation.userName = nil
    }
}
