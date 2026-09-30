// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import CoreText
import Foundation

/// A newly typeset reading copy. Original PDF geometry and artwork are not
/// represented by extracted text and are never claimed to be reconstructed.
/// Returning data keeps file destinations under the save panel's control.
enum PageTranslationExporter {
    static func html(
        _ result: PageTranslationResult,
        title: String,
        includeSource: Bool = true
    ) -> String {
        let sourceLabel = L10n.string("translation.export.source", defaultValue: "Original")
        let translatedLabel = L10n.string("translation.export.translated", defaultValue: "Translation")
        let note = L10n.string("translation.export.layout_note", defaultValue: "Reading copy prepared from extracted text. Original page layout and images are not preserved.")
        let sections = result.blocks.map { block in
            let source = includeSource ? "<div class=\"source\"><div class=\"label\">\(escape(sourceLabel))</div><p dir=\"auto\">\(escape(block.source))</p></div>" : ""
            return "<section><div class=\"label\">\(escape(translatedLabel))</div><p class=\"translation\" dir=\"auto\">\(escape(block.translated))</p>\(source)</section>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="\(escape(result.targetLanguageCode))"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light; }
        * { box-sizing: border-box; }
        body { margin: 0 auto; max-width: 860px; padding: 54px 40px; color: #182732; background: #faf9f6; font: 16px/1.75 -apple-system, BlinkMacSystemFont, sans-serif; }
        header { border-bottom: 2px solid #16756b; padding-bottom: 24px; margin-bottom: 32px; }
        h1 { font-size: 30px; line-height: 1.25; font-weight: 650; margin: 0 0 14px; overflow-wrap: anywhere; }
        .meta { color: #536573; font-size: 13px; white-space: pre-wrap; }
        .note { font-size: 12px; color: #536573; margin-top: 10px; }
        section { padding: 0 0 24px; margin-bottom: 24px; border-bottom: 1px solid #d8dfdd; break-inside: avoid; }
        .label { font-size: 10px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: #16756b; }
        p { margin: 5px 0 0; white-space: pre-wrap; overflow-wrap: anywhere; }
        .source { margin-top: 18px; border-left: 2px solid #d8dfdd; padding-left: 16px; }
        .source p { font-size: 13px; line-height: 1.6; color: #536573; }
        .source .label { color: #697a83; }
        @media (max-width: 600px) { body { padding: 28px 20px; } h1 { font-size: 24px; } }
        @media print { body { background: white; max-width: none; padding: 0; } section { break-inside: auto; } @page { size: A4; margin: 19mm; } }
        </style></head><body>
        <header><h1 dir="auto">\(escape(title))</h1><div class="meta">\(escape(metadata(result)))</div><div class="note">\(escape(note))</div></header>
        <main>\(sections)</main></body></html>
        """
    }

    @MainActor
    static func pdfData(
        _ result: PageTranslationResult,
        title: String,
        includeSource: Bool = true
    ) throws -> Data {
        try Task.checkCancellation()
        try validate(result, title: title)
        let content = NSMutableAttributedString(string: "")
        func append(_ string: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, after: CGFloat = 10) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = after
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.baseWritingDirection = .natural
            content.append(NSAttributedString(string: string + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]))
        }
        let ink = NSColor(calibratedRed: 0.09, green: 0.15, blue: 0.19, alpha: 1)
        let muted = NSColor(calibratedRed: 0.30, green: 0.37, blue: 0.42, alpha: 1)
        let accent = NSColor(calibratedRed: 0.06, green: 0.40, blue: 0.36, alpha: 1)
        append(title, size: 24, color: ink, weight: .semibold, after: 12)
        append(metadata(result), size: 10, color: muted, after: 9)
        append(L10n.string("translation.export.layout_note", defaultValue: "Reading copy prepared from extracted text. Original page layout and images are not preserved."), size: 9, color: muted, after: 22)
        var paragraphGroups: [NSRange] = []
        for block in result.blocks {
            let start = content.length
            append(L10n.string("translation.export.translated", defaultValue: "Translation"), size: 9, color: accent, weight: .semibold, after: 4)
            append(block.translated, size: 12, color: ink, after: includeSource ? 8 : 20)
            if includeSource {
                append(L10n.string("translation.export.source", defaultValue: "Original"), size: 8, color: muted, weight: .semibold, after: 3)
                append(block.source, size: 10, color: muted, after: 22)
            }
            paragraphGroups.append(NSRange(location: start, length: content.length - start))
        }

        let data = NSMutableData()
        let pageRect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let textRect = CGRect(x: 54, y: 54, width: pageRect.width - 108, height: pageRect.height - 108)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, [kCGPDFContextTitle: title] as CFDictionary) else {
            throw PageTranslationError.invalidExport
        }
        let framesetter = CTFramesetterCreateWithAttributedString(content as CFAttributedString)
        var offset = 0
        var pageNumber = 0
        while offset < content.length {
            try Task.checkCancellation()
            guard pageNumber < 256 else { throw PageTranslationError.invalidExport }
            var frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: offset, length: 0),
                CGPath(rect: textRect, transform: nil),
                nil
            )
            var visible = CTFrameGetVisibleStringRange(frame)
            let end = visible.location + visible.length
            // Keep a normal bilingual paragraph pair on one page, including
            // its labels. A genuinely longer-than-page paragraph can still
            // flow across pages without dropping text.
            if let group = paragraphGroups.first(where: {
                $0.location > offset && $0.location < end && NSMaxRange($0) > end
            }) {
                let size = CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter,
                    CFRange(location: group.location, length: group.length),
                    nil,
                    CGSize(width: textRect.width, height: .greatestFiniteMagnitude),
                    nil
                )
                if size.height <= textRect.height {
                    frame = CTFramesetterCreateFrame(
                        framesetter,
                        CFRange(location: offset, length: group.location - offset),
                        CGPath(rect: textRect, transform: nil),
                        nil
                    )
                    visible = CTFrameGetVisibleStringRange(frame)
                }
            }
            guard visible.length > 0 else { throw PageTranslationError.invalidExport }
            var mediaBox = pageRect
            context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(pageRect)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            pageNumber += 1
            let footer = NSAttributedString(string: "\(pageNumber)", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: muted])
            let footerLine = CTLineCreateWithAttributedString(footer as CFAttributedString)
            let footerWidth = CTLineGetTypographicBounds(footerLine, nil, nil, nil)
            context.textPosition = CGPoint(x: (pageRect.width - footerWidth) / 2, y: 27)
            CTLineDraw(footerLine, context)
            context.endPDFPage()
            offset += visible.length
        }
        context.closePDF()
        guard pageNumber > 0,
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages == pageNumber else { throw PageTranslationError.invalidExport }
        return data as Data
    }

    private static func metadata(_ result: PageTranslationResult) -> String {
        let source = result.sourceLanguageCode ?? L10n.string("translation.language.auto", defaultValue: "Auto")
        return "\(source) → \(result.targetLanguageCode)  ·  \(result.engineTitle)"
    }

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func validate(_ result: PageTranslationResult, title: String) throws {
        guard !result.blocks.isEmpty, result.blocks.count <= PageTranslationInput.maximumBlockCount,
              title.utf8.count <= 4_096, result.engineTitle.utf8.count <= 4_096,
              PageTranslationInput.isValidLanguageCode(result.targetLanguageCode),
              result.sourceLanguageCode.map(PageTranslationInput.isValidLanguageCode) ?? true else {
            throw PageTranslationError.invalidExport
        }
        var bytes = 0
        for block in result.blocks {
            bytes += block.source.utf8.count + block.translated.utf8.count
            guard bytes <= 2 * 1_024 * 1_024,
                  !block.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PageTranslationError.invalidExport
            }
        }
    }
}
