// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import PDFKit

/// A private, single-page text geometry source. It is never displayed, saved,
/// or inserted into the user's document. Keep the document alive with its page.
@MainActor
struct PDFNativeSelectionProxy {
    let document: PDFDocument
    let page: PDFPage

    static func makePage(for source: PDFPage) -> Self? {
        if let document = source.document,
           document.isLocked || (document.isEncrypted
                && document.permissionsStatus != .owner && !document.allowsCopying) {
            return nil
        }
        guard let reference = source.pageRef, source.numberOfCharacters > 0,
              source.numberOfCharacters <= 250_000 else { return nil }
        do {
            let writer = PDFSelectionPageWriter()
            let data = try writer.write(page: reference, rotation: source.rotation,
                media: source.bounds(for: .mediaBox), crop: source.bounds(for: .cropBox))
            guard writer.repairedMetricCount > 0,
                  let document = PDFDocument(data: data),
                  let page = document.page(at: 0),
                  let sourceText = source.string, !sourceText.isEmpty,
                  let proxyText = page.string,
                  Self.equivalentText(sourceText, proxyText),
                  Self.hasUsableGeometry(page) else { return nil }
            return Self(document: document, page: page)
        } catch {
            // Unusual resources, limits, or extraction differences preserve
            // the region/OCR fallback instead of guessing at the source text.
            return nil
        }
    }

    private static func equivalentText(_ source: String, _ proxy: String) -> Bool {
        if source == proxy { return true }
        // PDFKit synthesizes line separators from font geometry. Correcting the
        // metrics may change a separator from a space to a newline, but must
        // never change a word, punctuation, Unicode scalar, or word boundary.
        return source.split(whereSeparator: \.isWhitespace)
            .elementsEqual(proxy.split(whereSeparator: \.isWhitespace))
    }

    private static func hasUsableGeometry(_ page: PDFPage) -> Bool {
        let size = page.bounds(for: .cropBox).size
        let limit = max(size.width, size.height) * 4
        guard limit.isFinite, limit > 0 else { return false }
        let count = page.numberOfCharacters
        for sample in 0..<min(count, 48) {
            let index = sample * (count - 1) / max(1, min(count, 48) - 1)
            guard let selection = page.selection(for: NSRange(location: index, length: 1)) else {
                continue
            }
            let box = selection.bounds(for: page)
            if !box.isNull && (!box.width.isFinite || !box.height.isFinite
                || box.width > limit || box.height > limit) { return false }
        }
        return true
    }
}

/// Serializing the original PDF objects preserves the original font encodings,
/// ToUnicode maps, content bytes and coordinates. PDFPage.dataRepresentation()
/// may redraw/re-encode glyphs and change extracted characters, so it cannot
/// serve as the basis of this selection-only repair.
private final class PDFSelectionPageWriter {
    private enum Failure: Error { case invalidObject, limitExceeded }
    private static let maximumBytes = 32 * 1_024 * 1_024
    private static let maximumObjects = 4_096
    private var bodies: [Data?] = [nil, nil, nil]
    private var identifiers: [UInt: Int] = [:]
    private var storedBytes = 0
    private var inlineBytes = 0
    private var visits = 0
    private(set) var repairedMetricCount = 0

    func write(page: CGPDFPage, rotation: Int, media: CGRect, crop: CGRect) throws -> Data {
        guard let dictionary = page.dictionary,
              let contents = object(dictionary, "Contents"),
              let resources = inheritedObject(dictionary, "Resources") else {
            throw Failure.invalidObject
        }
        let contentReference = try encode(contents, depth: 0)
        let resourceReference = try encode(resources, depth: 0)
        guard valid(media), valid(crop) else { throw Failure.invalidObject }
        try setBody(1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        try setBody(2, Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        try setBody(3, Data(("<< /Type /Page /Parent 2 0 R /MediaBox \(rectangle(media))"
            + " /CropBox \(rectangle(crop)) /Rotate \(rotation) /Resources \(resourceReference)"
            + " /Contents \(contentReference) >>").utf8))
        var result = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, body) in bodies.enumerated() {
            guard let body else { throw Failure.invalidObject }
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n".utf8))
            result.append(body)
            result.append(Data("\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            result.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        result.append(Data(("trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>"
            + "\nstartxref\n\(xref)\n%%EOF\n").utf8))
        guard result.count <= Self.maximumBytes else { throw Failure.limitExceeded }
        return result
    }

    private func encode(_ object: CGPDFObjectRef, depth: Int) throws -> String {
        visits += 1
        guard depth < 64, visits < 100_000 else { throw Failure.limitExceeded }
        let type = CGPDFObjectGetType(object)
        switch type {
        case .null: return "null"
        case .boolean:
            var value: CGPDFBoolean = 0
            guard CGPDFObjectGetValue(object, type, &value) else { throw Failure.invalidObject }
            return value == 0 ? "false" : "true"
        case .integer:
            var value: CGPDFInteger = 0
            guard CGPDFObjectGetValue(object, type, &value) else { throw Failure.invalidObject }
            return String(value)
        case .real:
            var value: CGPDFReal = 0
            guard CGPDFObjectGetValue(object, type, &value), value.isFinite else { throw Failure.invalidObject }
            return number(value)
        case .name:
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, type, &value), let value else { throw Failure.invalidObject }
            return try name(value)
        case .string:
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, type, &value), let value else { throw Failure.invalidObject }
            let length = CGPDFStringGetLength(value)
            guard length <= 1_024 * 1_024 else { throw Failure.limitExceeded }
            guard length > 0 else { return "<>" }
            guard let bytes = CGPDFStringGetBytePtr(value) else { throw Failure.invalidObject }
            // Account before hex encoding or accumulating array/dictionary
            // tokens; checking only a completed object would be too late.
            try reserveInlineBytes(length * 2 + 2)
            return "<" + hex(UnsafeBufferPointer(start: bytes, count: length)) + ">"
        case .array, .dictionary, .stream:
            let key = UInt(bitPattern: object.rawValue)
            if let id = identifiers[key] { return "\(id) 0 R" }
            guard bodies.count < Self.maximumObjects else { throw Failure.limitExceeded }
            let id = bodies.count + 1
            identifiers[key] = id
            bodies.append(nil) // Reserve before recursing, including cyclic resources.
            let body: Data
            if type == .array {
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, type, &array), let array else { throw Failure.invalidObject }
                let count = CGPDFArrayGetCount(array)
                guard count < 25_000 else { throw Failure.limitExceeded }
                var values: [String] = []
                for index in 0..<count {
                    var child: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(array, index, &child), let child else { throw Failure.invalidObject }
                    values.append(try encode(child, depth: depth + 1))
                }
                body = Data(("[" + values.joined(separator: " ") + "]").utf8)
            } else if type == .dictionary {
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, type, &dictionary), let dictionary else { throw Failure.invalidObject }
                body = try encodeDictionary(dictionary, depth: depth + 1)
            } else {
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, type, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream) else { throw Failure.invalidObject }
                if dictionaryName(dictionary, "Subtype") == "Image" {
                    // The proxy supplies text geometry only. Skipping image
                    // decoding also bounds the cost of scanned book pages.
                    body = Data("<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Length 0 >>\nstream\n\nendstream".utf8)
                } else {
                    guard self.object(dictionary, "F") == nil else { throw Failure.invalidObject }
                    var format = CGPDFDataFormat.raw
                    // Core Graphics allocates the decoded stream before its
                    // length can be checked. All retained/output data is bounded.
                    guard let decoded = CGPDFStreamCopyData(stream, &format), format == .raw else {
                        throw Failure.invalidObject
                    }
                    let bytes = decoded as Data
                    guard bytes.count <= Self.maximumBytes - storedBytes else { throw Failure.limitExceeded }
                    var output = try encodeDictionary(dictionary, depth: depth + 1,
                        dropping: ["Length", "Filter", "DecodeParms", "F", "FFilter", "FDecodeParms"],
                        additions: ["/Length \(bytes.count)"])
                    output.append(Data("\nstream\n".utf8))
                    output.append(bytes)
                    output.append(Data("\nendstream".utf8))
                    body = output
                }
            }
            try setBody(id, body)
            return "\(id) 0 R"
        @unknown default: throw Failure.invalidObject
        }
    }

    private func encodeDictionary(_ dictionary: CGPDFDictionaryRef, depth: Int,
                                  dropping: Set<String> = [], additions: [String] = []) throws -> Data {
        guard CGPDFDictionaryGetCount(dictionary) < 4_096 else { throw Failure.limitExceeded }
        let repairs = repairedMetrics(dictionary)
        var values = additions
        var error: Error?
        CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
            do {
                guard strnlen(key, 4_096) < 4_096 else { throw Failure.limitExceeded }
                let keyString = String(cString: key)
                if !dropping.contains(keyString) {
                    let encoded = try repairs[keyString].map { number($0) }
                        ?? encode(value, depth: depth)
                    values.append(try name(key) + " " + encoded)
                }
                return true
            } catch let caught {
                error = caught
                return false
            }
        }, nil)
        if let error { throw error }
        repairedMetricCount += repairs.count
        return Data(("<< " + values.joined(separator: " ") + " >>").utf8)
    }

    private func repairedMetrics(_ dictionary: CGPDFDictionaryRef) -> [String: CGFloat] {
        guard dictionaryName(dictionary, "Type") == "FontDescriptor" else { return [:] }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "FontBBox", &array), let array,
              CGPDFArrayGetCount(array) == 4 else { return [:] }
        var box = [CGFloat](repeating: 0, count: 4)
        for index in 0..<4 {
            guard CGPDFArrayGetNumber(array, index, &box[index]), box[index].isFinite,
                  abs(box[index]) <= 100_000 else { return [:] }
        }
        guard box[3] > 0, box[3] > box[1], box[2] > box[0] else { return [:] }
        let limit = max(10_000, (box.map(abs).max() ?? 1_000) * 16)
        var result: [String: CGFloat] = [:]
        for key in ["Ascent", "Descent", "CapHeight", "XHeight"] {
            var metric: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(dictionary, key, &metric),
               !metric.isFinite || abs(metric) > limit {
                result[key] = key == "Descent" ? min(0, box[1]) : box[3]
            }
        }
        return result
    }

    private func setBody(_ id: Int, _ body: Data) throws {
        guard body.count <= Self.maximumBytes - storedBytes else { throw Failure.limitExceeded }
        storedBytes += body.count
        bodies[id - 1] = body
    }

    private func reserveInlineBytes(_ count: Int) throws {
        guard count <= Self.maximumBytes - inlineBytes else { throw Failure.limitExceeded }
        inlineBytes += count
    }

    private func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, key, &value) else { return nil }
        return value
    }

    private func inheritedObject(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var current = dictionary
        for _ in 0..<32 {
            if let value = object(current, key) { return value }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current, "Parent", &parent), let parent else { return nil }
            current = parent
        }
        return nil
    }

    private func dictionaryName(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    private func name(_ pointer: UnsafePointer<CChar>) throws -> String {
        let count = strnlen(pointer, 4_096)
        guard count < 4_096 else { throw Failure.limitExceeded }
        try reserveInlineBytes(count * 3 + 1)
        var result = "/"
        for index in 0..<count {
            let byte = UInt8(bitPattern: pointer[index])
            if byte >= 33 && byte <= 126 && ![35, 37, 40, 41, 47, 60, 62, 91, 93, 123, 125].contains(byte) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += "#" + hex([byte])
            }
        }
        return result
    }

    private func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789ABCDEF".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }

    private func number(_ value: CGFloat) -> String {
        // PDF numbers do not permit scientific notation. Core Graphics supplies
        // doubles; enough fractional digits preserve sub-point text coordinates.
        String(format: "%.10f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    private func valid(_ rectangle: CGRect) -> Bool {
        [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height].allSatisfy(\.isFinite)
            && rectangle.width > 0 && rectangle.height > 0
    }

    private func rectangle(_ rectangle: CGRect) -> String {
        "[\([rectangle.minX, rectangle.minY, rectangle.maxX, rectangle.maxY].map(number).joined(separator: " "))]"
    }
}
