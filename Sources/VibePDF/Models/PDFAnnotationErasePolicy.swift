// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Central authorization for the destructive Eraser tool.
///
/// Hit testing belongs to `InteractivePDFView`, but subtype hit testing alone is
/// not authority to delete a PDF object. In particular, a Stamp can be an
/// imported image, a signature, an app-owned visual Study mark, or an arbitrary
/// third-party annotation. The model therefore repeats this policy immediately
/// before mutation so a stale view event cannot bypass the active workspace mode.
enum PDFAnnotationErasePolicy {
    private static let erasableTypes: Set<String> = [
        "Ink", "FreeText", "Highlight", "Underline", "StrikeOut",
        "Squiggly", "Stamp", "Text", "Square", "Circle", "Line",
    ]
    private static let nativeMarkupTypes: Set<String> = [
        "Highlight", "Underline", "StrikeOut", "Squiggly",
    ]
    private static let appAnnotationNamePrefixes = [
        "HwattakPDF-Annotation-", "VibePDF-Annotation-",
    ]
    private static let appInkNamePrefixes = [
        "HwattakPDF-Ink-", "VibePDF-Ink-",
    ]

    static func allows(
        _ annotation: PDFAnnotation,
        in mode: PDFWorkspaceMode,
        isTrustedRuntimeAnnotation: Bool = false
    ) -> Bool {
        guard let type = normalizedType(of: annotation), erasableTypes.contains(type) else {
            return false
        }

        switch mode {
        case .viewer:
            // Viewer never exposes Eraser. Keeping the model closed as well
            // prevents a stale pointer event from deleting content after a mode
            // switch.
            return false

        case .editing:
            // Editing retains the established general annotation-erasing tool.
            // Widget, Link, Popup and Redact are absent from `erasableTypes`.
            return true

        case .study:
            // Names and custom keys inside a PDF are public, forgeable data.
            // They classify the shape only after the workspace proves that
            // this exact object was created/adopted in the current session.
            return isTrustedRuntimeAnnotation
                && isRecognizedStudyContent(annotation, type: type)
        }
    }

    private static func isRecognizedStudyContent(
        _ annotation: PDFAnnotation,
        type: String
    ) -> Bool {
        // Appearance-backed Study highlights/underlines are standard Stamp
        // annotations carrying the app's public Stamp `/Name` classifier.
        if StudyMarkupAnnotationIdentity.kind(of: annotation) != nil {
            return true
        }

        // Viewer/Study typed notes use the FreeText classifier. Images and
        // signatures have different kinds and remain blocked.
        if EditableAnnotationIdentity.kind(of: annotation) == .freeText {
            return true
        }

        guard let name = annotation.value(forAnnotationKey: .name) as? String else {
            return false
        }
        if type == "Ink" {
            return appInkNamePrefixes.contains(where: name.hasPrefix)
        }
        if nativeMarkupTypes.contains(type) {
            return appAnnotationNamePrefixes.contains(where: name.hasPrefix)
        }
        return false
    }

    private static func normalizedType(of annotation: PDFAnnotation) -> String? {
        annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

@MainActor
extension PDFWorkspaceState {
    /// Non-mutating event-boundary check used while choosing the topmost hit.
    func allowsEraserRemoval(of annotation: PDFAnnotation) -> Bool {
        // `InteractivePDFView.activeTool` is a rendered snapshot and can lag a
        // keyboard/mode change by one SwiftUI update. Consult the live model
        // here so a stale Eraser mouse-down cannot select a deletion target
        // after Select or Text has already become active.
        activeTool == .eraser
            && PDFAnnotationErasePolicy.allows(
                annotation,
                in: mode,
                isTrustedRuntimeAnnotation: isRuntimeTrustedAnnotation(annotation)
            )
    }

    /// The authoritative mutation boundary for an Eraser click.
    ///
    /// The policy is intentionally evaluated again after pending text/form
    /// editors commit because those callbacks can change document state before
    /// the annotation collection is mutated.
    @discardableResult
    func removeAnnotationWithEraser(
        _ annotation: PDFAnnotation,
        from page: PDFPage
    ) -> Bool {
        // Check before deactivation: committing a pending editor is itself a
        // document mutation and must not be triggered by a stale Eraser event.
        guard activeTool == .eraser else { return false }
        prepareForDeactivation()
        guard
            activeTool == .eraser,
            allowsEraserRemoval(of: annotation),
            let document,
            document.index(for: page) != NSNotFound,
            let originalIndex = page.annotations.firstIndex(where: { $0 === annotation })
        else { return false }

        page.removeAnnotation(annotation)
        registerRemovedAnnotation(
            annotation,
            from: page,
            originalIndex: originalIndex,
            message: L10n.string("주석을 삭제했습니다.")
        )
        return true
    }
}
