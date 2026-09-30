// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The save panel still grants access and confirms any existing destination.
/// A default directory is a suggestion, never permission to overwrite a file.
struct OCRExportDestination {
    let directoryURL: URL?
    let fileName: String

    init(sourceURL: URL?) {
        directoryURL = sourceURL?.deletingLastPathComponent()
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "HwattakPDF"
        // Leave room for the suffix on filesystems with a 255-byte name limit,
        // without splitting a Unicode grapheme in a long original filename.
        var stem = ""
        for character in base {
            guard stem.utf8.count + String(character).utf8.count <= 247 else { break }
            stem.append(character)
        }
        fileName = "\(stem.isEmpty ? "HwattakPDF" : stem)-ocr.pdf"
    }
}
