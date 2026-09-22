// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit

enum PDFOfficeExportFormat: String {
    case word
    case powerpoint

    var fileExtension: String {
        switch self {
        case .word: "docx"
        case .powerpoint: "pptx"
        }
    }
}

/// Produces offline DOCX/PPTX files with one layout-faithful image per page.
/// This intentionally prioritizes visual fidelity over editable text reflow.
enum PDFOfficeExporter {
    private struct RenderedPage {
        let png: Data
        let size: CGSize
    }

    @MainActor
    static func exportResponsive(
        _ document: PDFDocument,
        to destination: URL,
        format: PDFOfficeExportFormat,
        validateDocument: () throws -> Void = {},
        progress: (Double) -> Void = { _ in }
    ) async throws {
        try PDFDocumentSecurityPolicy.validateCanRasterizePages(document)
        guard document.pageCount > 0 else { throw WorkspaceError.noDocument }
        let access = SecurityScopedAccess(url: destination)
        defer { withExtendedLifetime(access) {} }
        let precondition = try PDFDestinationPrecondition(destination: destination)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HwattakPDF-Office-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var pages: [RenderedPage] = []
        var files: [String: URL] = [:]
        let count = document.pageCount
        for index in 0..<count {
            await Task.yield()
            try Task.checkCancellation()
            try validateDocument()
            guard let page = document.page(at: index) else { throw WorkspaceError.noDocument }
            try autoreleasepool {
                let rendered = try render(page, index: index, format: format)
                let file = directory.appendingPathComponent("page-\(index + 1).png")
                try rendered.png.write(to: file)
                let prefix = format == .word ? "word" : "ppt"
                files["\(prefix)/media/page-\(index + 1).png"] = file
                pages.append(RenderedPage(png: Data(), size: rendered.size))
            }
            progress(Double(index + 1) / Double(count) * 0.85)
        }
        let entries = try format == .word ? wordEntries(pages: pages) : powerpointEntries(pages: pages)
        let archive = directory.appendingPathComponent("result.\(format.fileExtension)")
        let payloads = files
        let worker = Task.detached(priority: .utility) {
            try OpenXMLArchiveWriter.write(entries, files: payloads, to: archive)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        try validateDocument()
        try precondition.validate()
        // A fully written ZIP is copied to a sibling, then atomically published.
        // If file-only sandbox access prevents staging, fail without truncating
        // an existing Office document. The user can select another location.
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).office.tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        let staging = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: archive, to: staged)
        }
        try await withTaskCancellationHandler {
            try await staging.value
        } onCancel: { staging.cancel() }
        try Task.checkCancellation()
        try validateDocument()
        try precondition.validate()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: destination) }
        progress(1)
    }

    static func suggestedFileName(
        for sourceURL: URL?,
        format: PDFOfficeExportFormat
    ) -> String {
        let base = SelectedPagePDFExporter.documentBaseName(for: sourceURL)
        return "\(base).\(format.fileExtension)"
    }

    @discardableResult
    static func export(
        _ document: PDFDocument,
        to destination: URL,
        format: PDFOfficeExportFormat
    ) throws -> URL {
        try PDFDocumentSecurityPolicy.validateCanRasterizePages(document)
        guard document.pageCount > 0 else {
            throw WorkspaceError.noDocument
        }

        var pages: [RenderedPage] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                throw WorkspaceError.operationFailed(
                    L10n.format("error.render_page_image", index + 1)
                )
            }
            pages.append(try autoreleasepool { try render(page, index: index, format: format) })
        }

        let entries: [OpenXMLArchiveWriter.Entry] = switch format {
        case .word: try wordEntries(pages: pages)
        case .powerpoint: try powerpointEntries(pages: pages)
        }
        let archive = try OpenXMLArchiveWriter.archive(entries)
        guard archive.starts(with: [0x50, 0x4B, 0x03, 0x04]) else {
            throw WorkspaceError.operationFailed(
                L10n.string("conversion.error.package_invalid")
            )
        }

        let access = SecurityScopedAccess(url: destination)
        try withExtendedLifetime(access) {
            do {
                try archive.write(to: destination, options: [.atomic])
            } catch where AtomicPDFWriter.isPermissionDeniedForFileScopeFallback(error) {
                // A save-panel grant may cover only the selected file and not a
                // sibling used by Data.write(.atomic).
                try archive.write(to: destination, options: [])
            }
        }
        return destination
    }

    private static func render(_ page: PDFPage, index: Int, format: PDFOfficeExportFormat) throws -> RenderedPage {
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        let logicalSize = rotated
            ? CGSize(width: box.height, height: box.width)
            : box.size
        // PDFKit accepts persisted pages with dimensions such as 1e20. A raster
        // budget only bounds the thumbnail; the original size still reaches the
        // Office XML. Reject unsupported geometry before asking PDFKit to draw.
        guard box.origin.x.isFinite, box.origin.y.isFinite,
              box.maxX.isFinite, box.maxY.isFinite,
              box.size.width > 0, box.size.height > 0 else {
            throw pageRenderError(index: index)
        }
        try validatePageSize(logicalSize, format: format, index: index)
        let pixelSize = PDFRasterBudget(
            maximumDimension: 2_400,
            maximumPixelCount: 8_000_000
        ).boundedPixelSize(logicalSize: logicalSize, scale: 2)
        let image = page.thumbnail(of: pixelSize, for: .cropBox)
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw pageRenderError(index: index)
        }
        return RenderedPage(png: png, size: logicalSize)
    }

    private static func wordEntries(pages: [RenderedPage]) throws -> [OpenXMLArchiveWriter.Entry] {
        let canvas = pages.first?.size ?? CGSize(width: 612, height: 792)
        let pageWidth = try dimension(canvas.width, unitsPerPoint: 20, range: 1...31_680, index: 0)
        let pageHeight = try dimension(canvas.height, unitsPerPoint: 20, range: 1...31_680, index: 0)

        let paragraphs = try pages.enumerated().map { index, page in
            let size = fittedSize(page.size, in: canvas)
            let width = try dimension(size.width, unitsPerPoint: 12_700, range: 1...20_116_800, index: index)
            let height = try dimension(size.height, unitsPerPoint: 12_700, range: 1...20_116_800, index: index)
            let pageBreak = index + 1 < pages.count ? #"<w:br w:type="page"/>"# : ""
            return """
            <w:p><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="\(index + 1)" name="PDF page \(index + 1)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="page-\(index + 1).png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId\(index + 1)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>\(pageBreak)</w:r></w:p>
            """
        }.joined()

        let document = xml("""
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(paragraphs)<w:sectPr><w:pgSz w:w="\(pageWidth)" w:h="\(pageHeight)"/><w:pgMar w:top="0" w:right="0" w:bottom="0" w:left="0" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr></w:body></w:document>
        """)
        let relationships = pages.indices.map { index in
            #"<Relationship Id="rId\#(index + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/page-\#(index + 1).png"/>"#
        }.joined()

        var entries = commonEntries(
            mainPath: "word/document.xml",
            mainType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
            application: "Microsoft Office Word"
        )
        entries += [
            .init(path: "word/document.xml", data: document),
            .init(path: "word/_rels/document.xml.rels", data: xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>")),
        ]
        entries += pages.enumerated().map {
            .init(path: "word/media/page-\($0.offset + 1).png", data: $0.element.png)
        }
        return entries
    }

    private static func powerpointEntries(pages: [RenderedPage]) throws -> [OpenXMLArchiveWriter.Entry] {
        let canvas = pages.first?.size ?? CGSize(width: 792, height: 612)
        let slideWidth = try dimension(canvas.width, unitsPerPoint: 12_700, range: 914_400...51_206_400, index: 0)
        let slideHeight = try dimension(canvas.height, unitsPerPoint: 12_700, range: 914_400...51_206_400, index: 0)
        let slideIDs = pages.indices.map { index in
            #"<p:sldId id="\#(256 + index)" r:id="rId\#(index + 2)"/>"#
        }.joined()
        let slideRelationships = pages.indices.map { index in
            #"<Relationship Id="rId\#(index + 2)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\#(index + 1).xml"/>"#
        }.joined()

        let presentation = xml("""
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(slideWidth)" cy="\(slideHeight)" type="custom"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """)
        let presentationRels = xml("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>\(slideRelationships)</Relationships>
        """)

        var overrides = pages.indices.map { index in
            #"<Override PartName="/ppt/slides/slide\#(index + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
        }.joined()
        overrides += #"<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>"#

        var entries = commonEntries(
            mainPath: "ppt/presentation.xml",
            mainType: "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
            application: "Microsoft Office PowerPoint",
            additionalContentTypeOverrides: overrides
        )
        entries += [
            .init(path: "ppt/presentation.xml", data: presentation),
            .init(path: "ppt/_rels/presentation.xml.rels", data: presentationRels),
            .init(path: "ppt/slideMasters/slideMaster1.xml", data: slideMasterXML),
            .init(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", data: slideMasterRelationshipsXML),
            .init(path: "ppt/slideLayouts/slideLayout1.xml", data: slideLayoutXML),
            .init(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", data: slideLayoutRelationshipsXML),
            .init(path: "ppt/theme/theme1.xml", data: themeXML),
        ]

        for (index, page) in pages.enumerated() {
            let number = index + 1
            entries.append(
                .init(
                    path: "ppt/slides/slide\(number).xml",
                    data: try slideXML(
                        number: number,
                        pageSize: page.size,
                        canvasWidth: slideWidth,
                        canvasHeight: slideHeight
                    )
                )
            )
            entries.append(.init(path: "ppt/slides/_rels/slide\(number).xml.rels", data: slideRelationshipsXML(number: number)))
            entries.append(.init(path: "ppt/media/page-\(number).png", data: page.png))
        }
        return entries
    }

    private static func commonEntries(
        mainPath: String,
        mainType: String,
        application: String,
        additionalContentTypeOverrides: String = ""
    ) -> [OpenXMLArchiveWriter.Entry] {
        let contentTypes = xml("""
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/\(mainPath)" ContentType="\(mainType)"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\(additionalContentTypeOverrides)</Types>
        """)
        let rootRelationships = xml("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="\(mainPath)"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """)
        return [
            .init(path: "[Content_Types].xml", data: contentTypes),
            .init(path: "_rels/.rels", data: rootRelationships),
            .init(path: "docProps/core.xml", data: xml("<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:creator>HwattakPDF</dc:creator><dc:title>PDF conversion</dc:title></cp:coreProperties>")),
            .init(path: "docProps/app.xml", data: xml("<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\"><Application>\(application)</Application></Properties>")),
        ]
    }

    private static func slideXML(
        number: Int,
        pageSize: CGSize,
        canvasWidth: Int,
        canvasHeight: Int
    ) throws -> Data {
        let size = fittedSize(
            pageSize,
            in: CGSize(width: CGFloat(canvasWidth) / 12_700, height: CGFloat(canvasHeight) / 12_700)
        )
        let width = try dimension(size.width, unitsPerPoint: 12_700, range: 1...51_206_400, index: number - 1)
        let height = try dimension(size.height, unitsPerPoint: 12_700, range: 1...51_206_400, index: number - 1)
        let x = max(0, (canvasWidth - width) / 2)
        let y = max(0, (canvasHeight - height) / 2)
        return xml("""
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:pic><p:nvPicPr><p:cNvPr id="2" name="PDF page \(number)"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId1"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """)
    }

    private static func validatePageSize(_ size: CGSize, format: PDFOfficeExportFormat, index: Int) throws {
        // Word supports at most 31,680 twips (22 inches) per dimension.
        // PresentationML ST_SlideSizeCoordinate is 914,400...51,206,400 EMU
        // (1...56 inches). Word's zero-margin pages must occupy at least a twip.
        let range: ClosedRange<CGFloat> = format == .word ? (1.0 / 20)...1_584 : 72...4_032
        guard size.width.isFinite, size.height.isFinite,
              range.contains(size.width), range.contains(size.height) else {
            throw pageRenderError(index: index)
        }
    }

    private static func fittedSize(_ size: CGSize, in canvas: CGSize) -> CGSize {
        let scale = min(canvas.width / size.width, canvas.height / size.height)
        return CGSize(
            width: min(canvas.width, size.width * scale),
            height: min(canvas.height, size.height * scale)
        )
    }

    private static func dimension(
        _ points: CGFloat,
        unitsPerPoint: CGFloat,
        range: ClosedRange<Int>,
        index: Int
    ) throws -> Int {
        let value = points * unitsPerPoint
        guard points.isFinite, points > 0, value.isFinite, value > 0,
              let integer = Int(exactly: max(1, value.rounded(.towardZero))),
              range.contains(integer) else {
            throw pageRenderError(index: index)
        }
        return integer
    }

    private static func pageRenderError(index: Int) -> WorkspaceError {
        .operationFailed(L10n.format("error.render_page_image", index + 1))
    }

    private static func slideRelationshipsXML(number: Int) -> Data {
        xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/page-\(number).png\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/></Relationships>")
    }

    private static let slideMasterXML = xml("""
    <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/><p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
    """)
    private static let slideMasterRelationshipsXML = xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"../theme/theme1.xml\"/></Relationships>")
    private static let slideLayoutXML = xml("""
    <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
    """)
    private static let slideLayoutRelationshipsXML = xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>")
    private static let themeXML = xml("""
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="HwattakPDF"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F497D"/></a:dk2><a:lt2><a:srgbClr val="EEECE1"/></a:lt2><a:accent1><a:srgbClr val="4F81BD"/></a:accent1><a:accent2><a:srgbClr val="C0504D"/></a:accent2><a:accent3><a:srgbClr val="9BBB59"/></a:accent3><a:accent4><a:srgbClr val="8064A2"/></a:accent4><a:accent5><a:srgbClr val="4BACC6"/></a:accent5><a:accent6><a:srgbClr val="F79646"/></a:accent6><a:hlink><a:srgbClr val="0000FF"/></a:hlink><a:folHlink><a:srgbClr val="800080"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """)

    private static func xml(_ body: String) -> Data {
        Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\(body)".utf8)
    }
}
