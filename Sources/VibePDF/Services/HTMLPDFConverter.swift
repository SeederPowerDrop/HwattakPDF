// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import Foundation
import PDFKit
import WebKit

enum HTMLPDFConversionMode: String, CaseIterable, Sendable {
    case fast
    case reliable
}

enum HTMLPDFNetworkPolicy: Sendable {
    /// Prevents an untrusted local document from sending neighbouring assets
    /// over the network while WebKit has temporary read access to its folder.
    case localFilesOnly
    /// Allows HTTP(S) subresources. Main-frame navigation away from the local
    /// source is still refused, and WebKit continues to use an ephemeral store.
    case allowRemoteResources
}

struct HTMLPDFPageMargins: Equatable, Sendable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    init(
        top: CGFloat = 36,
        leading: CGFloat = 36,
        bottom: CGFloat = 36,
        trailing: CGFloat = 36
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

struct HTMLPDFConversionConfiguration: Sendable {
    var pageSize: CGSize
    var margins: HTMLPDFPageMargins
    var navigationTimeout: TimeInterval
    var resourceWaitTimeout: TimeInterval
    var layoutSettleDelay: TimeInterval
    var captureTimeout: TimeInterval
    var totalTimeout: TimeInterval
    var maximumPageCount: Int
    var maximumSourceByteCount: Int
    var networkPolicy: HTMLPDFNetworkPolicy

    init(
        pageSize: CGSize = CGSize(width: 595.28, height: 841.89),
        margins: HTMLPDFPageMargins = HTMLPDFPageMargins(),
        navigationTimeout: TimeInterval = 30,
        resourceWaitTimeout: TimeInterval = 12,
        layoutSettleDelay: TimeInterval = 0.35,
        captureTimeout: TimeInterval = 30,
        totalTimeout: TimeInterval = 180,
        maximumPageCount: Int = 500,
        maximumSourceByteCount: Int = 64 * 1_024 * 1_024,
        networkPolicy: HTMLPDFNetworkPolicy = .localFilesOnly
    ) {
        self.pageSize = pageSize
        self.margins = margins
        self.navigationTimeout = navigationTimeout
        self.resourceWaitTimeout = resourceWaitTimeout
        self.layoutSettleDelay = layoutSettleDelay
        self.captureTimeout = captureTimeout
        self.totalTimeout = totalTimeout
        self.maximumPageCount = maximumPageCount
        self.maximumSourceByteCount = maximumSourceByteCount
        self.networkPolicy = networkPolicy
    }

    static func preset(
        _ mode: HTMLPDFConversionMode,
        networkPolicy: HTMLPDFNetworkPolicy = .localFilesOnly
    ) -> Self {
        switch mode {
        case .fast:
            // A shorter asset-settle window improves latency. Captures remain
            // page-by-page so neither profile can split a line of text.
            return Self(
                navigationTimeout: PDFProcessingProfile.speed.htmlNavigationTimeout,
                resourceWaitTimeout: 2,
                layoutSettleDelay: PDFProcessingProfile.speed.htmlSettlingDelay,
                captureTimeout: 15,
                totalTimeout: 75,
                networkPolicy: networkPolicy
            )
        case .reliable:
            // One output page per capture bounds peak WebKit memory. A longer
            // wait lets fonts and asynchronously decoded images settle first.
            return Self(
                navigationTimeout: PDFProcessingProfile.stability.htmlNavigationTimeout,
                layoutSettleDelay: PDFProcessingProfile.stability.htmlSettlingDelay,
                networkPolicy: networkPolicy
            )
        }
    }
}

struct HTMLPDFConversionOutput: Sendable {
    let data: Data
    let pageCount: Int
    let sourceByteCount: Int
    let outputByteCount: Int
    let elapsedTime: TimeInterval

    @MainActor
    func makeDocument() throws -> PDFDocument {
        guard
            let document = PDFDocument(data: data),
            document.pageCount == pageCount,
            pageCount > 0
        else {
            throw HTMLPDFConversionError.invalidGeneratedPDF
        }
        return document
    }
}

enum HTMLPDFConversionError: LocalizedError {
    case unsupportedSource(URL)
    case unreadableSource(URL)
    case sourceTooLarge(actual: Int, limit: Int)
    case invalidConfiguration
    case unsafeNavigation(URL?)
    case navigationTimedOut
    case resourceInspectionTimedOut
    case captureTimedOut(page: Int)
    case webContentProcessTerminated
    case webKitFailure(String)
    case invalidContentSize
    case tooManyPages(actual: Int, limit: Int)
    case invalidGeneratedPDF

    var errorDescription: String? {
        switch self {
        case let .unsupportedSource(url):
            L10n.format("builder.error.html.unsupported", url.lastPathComponent)
        case let .unreadableSource(url):
            L10n.format("builder.error.html.unreadable", url.lastPathComponent)
        case let .sourceTooLarge(actual, limit):
            L10n.format("builder.error.html.too_large", Int64(actual), Int64(limit))
        case .invalidConfiguration:
            L10n.string("builder.error.html.invalid_size")
        case let .unsafeNavigation(url):
            L10n.format("builder.error.html.unsafe_navigation", url?.absoluteString ?? "-")
        case .navigationTimedOut:
            L10n.string("builder.error.html.timeout")
        case .resourceInspectionTimedOut:
            L10n.string("builder.error.html.timeout")
        case .captureTimedOut:
            L10n.string("builder.error.html.timeout")
        case .webContentProcessTerminated:
            L10n.string("builder.error.html.process_terminated")
        case let .webKitFailure(message):
            L10n.format("builder.error.html.rendering", message)
        case .invalidContentSize:
            L10n.string("builder.error.html.invalid_size")
        case let .tooManyPages(actual, limit):
            L10n.format("builder.error.html.too_many_pages", actual, limit)
        case .invalidGeneratedPDF:
            L10n.string("builder.error.html.invalid_pdf")
        }
    }
}

/// Renders a local HTML document in an isolated WKWebView and paginates its
/// vector PDF captures onto fixed-size pages. Relative CSS, fonts, scripts and
/// images are available only beneath the HTML file's containing directory.
enum HTMLPDFConverter {
    static let supportedExtensions: Set<String> = ["html", "htm"]

    static func suggestedFileName(for sourceURL: URL) -> String {
        "\(sourceURL.deletingPathExtension().lastPathComponent).pdf"
    }

    @MainActor
    static func makePDFData(
        from sourceURL: URL,
        configuration: HTMLPDFConversionConfiguration = .preset(.reliable)
    ) async throws -> Data {
        try await render(from: sourceURL, configuration: configuration).data
    }

    @MainActor
    static func makeDocument(
        from sourceURL: URL,
        configuration: HTMLPDFConversionConfiguration = .preset(.reliable)
    ) async throws -> PDFDocument {
        try await render(from: sourceURL, configuration: configuration).makeDocument()
    }

    @MainActor
    @discardableResult
    static func export(
        from sourceURL: URL,
        to destination: URL,
        configuration: HTMLPDFConversionConfiguration = .preset(.reliable)
    ) async throws -> URL {
        let output = try await render(from: sourceURL, configuration: configuration)
        try Task.checkCancellation()
        let document = try output.makeDocument()
        let destinationAccess = SecurityScopedAccess(url: destination)
        defer { withExtendedLifetime(destinationAccess) {} }
        return try AtomicPDFWriter.write(
            document,
            to: destination,
            validateSerializedDocument: { reopened, expectedPageCount in
                guard reopened.pageCount == expectedPageCount else {
                    throw HTMLPDFConversionError.invalidGeneratedPDF
                }
            }
        )
    }

    @MainActor
    static func render(
        from sourceURL: URL,
        configuration: HTMLPDFConversionConfiguration = .preset(.reliable)
    ) async throws -> HTMLPDFConversionOutput {
        let startedAt = ProcessInfo.processInfo.systemUptime
        try validate(configuration)
        try Task.checkCancellation()

        let sourceAccess = SecurityScopedAccess(url: sourceURL)
        // Folder selections/bookmarks can grant the wider scope needed by
        // relative assets. A file-only grant simply returns false and WebKit's
        // own sandbox still limits access to what the OS authorized.
        let directoryAccess = SecurityScopedAccess(url: sourceURL.deletingLastPathComponent())
        defer {
            withExtendedLifetime(sourceAccess) {}
            withExtendedLifetime(directoryAccess) {}
        }
        let normalizedSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let sourceByteCount = try validateSource(
            normalizedSource,
            maximumByteCount: configuration.maximumSourceByteCount
        )
        let readRoot = normalizedSource.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()

        let deadline = HTMLPDFDeadline(timeout: configuration.totalTimeout)
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webConfiguration.suppressesIncrementalRendering = true
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webConfiguration.mediaTypesRequiringUserActionForPlayback = .all
        webConfiguration.allowsAirPlayForMediaPlayback = false
        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = true
        webConfiguration.defaultWebpagePreferences = webpagePreferences

        if configuration.networkPolicy == .localFilesOnly {
            let timeout = try deadline.remaining(
                limitedTo: configuration.navigationTimeout,
                timeoutError: .navigationTimedOut
            )
            let ruleList = try await localFilesOnlyRuleList(timeout: timeout)
            webConfiguration.userContentController.add(ruleList)
        }

        let printableSize = CGSize(
            width: configuration.pageSize.width
                - configuration.margins.leading
                - configuration.margins.trailing,
            height: configuration.pageSize.height
                - configuration.margins.top
                - configuration.margins.bottom
        )
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: printableSize),
            configuration: webConfiguration
        )
        webView.underPageBackgroundColor = .white
        webView.pageZoom = 1
        webView.setFrameSize(printableSize)
        webView.layoutSubtreeIfNeeded()

        let navigationCoordinator = HTMLPDFNavigationCoordinator(
            sourceURL: normalizedSource,
            readRoot: readRoot,
            networkPolicy: configuration.networkPolicy
        )
        webView.navigationDelegate = navigationCoordinator
        webView.uiDelegate = navigationCoordinator
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        do {
            let timeout = try deadline.remaining(
                limitedTo: configuration.navigationTimeout,
                timeoutError: .navigationTimedOut
            )
            try await navigationCoordinator.load(
                webView,
                sourceURL: normalizedSource,
                readRoot: readRoot,
                timeout: timeout
            )
            try Task.checkCancellation()

            let measurementTimeout = try deadline.remaining(
                limitedTo: configuration.resourceWaitTimeout
                    + configuration.layoutSettleDelay + 5,
                timeoutError: .resourceInspectionTimedOut
            )
            let contentSize = try await measureSettledContent(
                in: webView,
                resourceWaitTimeout: configuration.resourceWaitTimeout,
                settleDelay: configuration.layoutSettleDelay,
                operationTimeout: measurementTimeout
            )
            let fixedPlan = try capturePlan(
                contentSize: contentSize,
                printableSize: printableSize,
                maximumPageCount: configuration.maximumPageCount
            )
            let paginationTimeout = try deadline.remaining(
                limitedTo: 12,
                timeoutError: .resourceInspectionTimedOut
            )
            let safeRanges = try await safePageRanges(
                in: webView,
                contentSize: contentSize,
                idealPageHeight: fixedPlan.capturePageHeight,
                maximumPageCount: configuration.maximumPageCount,
                timeout: paginationTimeout
            )
            let plan = CapturePlan(
                contentSize: fixedPlan.contentSize,
                captureWidth: fixedPlan.captureWidth,
                capturePageHeight: fixedPlan.capturePageHeight,
                pageRanges: safeRanges
            )
            let batches = try await capture(
                webView,
                plan: plan,
                captureTimeout: configuration.captureTimeout,
                deadline: deadline
            )
            try Task.checkCancellation()
            let data = try compose(
                batches,
                pageSize: configuration.pageSize,
                margins: configuration.margins,
                expectedPageCount: plan.pageCount
            )
            guard
                let document = PDFDocument(data: data),
                document.pageCount == plan.pageCount,
                document.pageCount > 0
            else {
                throw HTMLPDFConversionError.invalidGeneratedPDF
            }

            return HTMLPDFConversionOutput(
                data: data,
                pageCount: document.pageCount,
                sourceByteCount: sourceByteCount,
                outputByteCount: data.count,
                elapsedTime: ProcessInfo.processInfo.systemUptime - startedAt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTMLPDFConversionError {
            throw error
        } catch {
            throw HTMLPDFConversionError.webKitFailure(error.localizedDescription)
        }
    }

    private static func validate(
        _ configuration: HTMLPDFConversionConfiguration
    ) throws {
        let numbers = [
            configuration.pageSize.width,
            configuration.pageSize.height,
            configuration.margins.top,
            configuration.margins.leading,
            configuration.margins.bottom,
            configuration.margins.trailing,
            configuration.navigationTimeout,
            configuration.resourceWaitTimeout,
            configuration.layoutSettleDelay,
            configuration.captureTimeout,
            configuration.totalTimeout,
        ]
        guard
            numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
            configuration.pageSize.width > 0,
            configuration.pageSize.height > 0,
            configuration.navigationTimeout > 0,
            configuration.captureTimeout > 0,
            configuration.totalTimeout > 0,
            configuration.pageSize.width
                > configuration.margins.leading + configuration.margins.trailing,
            configuration.pageSize.height
                > configuration.margins.top + configuration.margins.bottom,
            configuration.maximumPageCount > 0,
            configuration.maximumSourceByteCount > 0
        else {
            throw HTMLPDFConversionError.invalidConfiguration
        }
    }

    private static func validateSource(
        _ url: URL,
        maximumByteCount: Int
    ) throws -> Int {
        guard
            url.isFileURL,
            supportedExtensions.contains(url.pathExtension.lowercased())
        else {
            throw HTMLPDFConversionError.unsupportedSource(url)
        }
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isReadableKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isReadable != false else {
                throw HTMLPDFConversionError.unreadableSource(url)
            }
            let byteCount = values.fileSize ?? 0
            guard byteCount <= maximumByteCount else {
                throw HTMLPDFConversionError.sourceTooLarge(
                    actual: byteCount,
                    limit: maximumByteCount
                )
            }
            return byteCount
        } catch let error as HTMLPDFConversionError {
            throw error
        } catch {
            throw HTMLPDFConversionError.unreadableSource(url)
        }
    }

    private struct CapturePlan {
        let contentSize: CGSize
        let captureWidth: CGFloat
        let capturePageHeight: CGFloat
        let pageRanges: [Range<CGFloat>]

        var pageCount: Int { pageRanges.count }
    }

    private struct CapturedBatch {
        let data: Data
    }

    private static func capturePlan(
        contentSize: CGSize,
        printableSize: CGSize,
        maximumPageCount: Int
    ) throws -> CapturePlan {
        guard
            contentSize.width.isFinite,
            contentSize.height.isFinite,
            contentSize.width > 0,
            contentSize.height > 0,
            // Avoid asking a compromised WebContent process to allocate a
            // pathological capture surface even though PDF output is vector.
            contentSize.width <= 14_400,
            contentSize.height <= 10_000_000
        else {
            throw HTMLPDFConversionError.invalidContentSize
        }
        let captureWidth = max(printableSize.width, contentSize.width)
        let scale = min(1, printableSize.width / captureWidth)
        let capturePageHeight = printableSize.height / scale
        let pageCount = max(1, Int(ceil(contentSize.height / capturePageHeight)))
        guard pageCount <= maximumPageCount else {
            throw HTMLPDFConversionError.tooManyPages(
                actual: pageCount,
                limit: maximumPageCount
            )
        }
        let pageRanges = (0..<pageCount).map { pageIndex in
            let lowerBound = CGFloat(pageIndex) * capturePageHeight
            let upperBound = min(
                contentSize.height,
                lowerBound + capturePageHeight
            )
            return lowerBound..<upperBound
        }
        return CapturePlan(
            contentSize: contentSize,
            captureWidth: captureWidth,
            capturePageHeight: capturePageHeight,
            pageRanges: pageRanges
        )
    }

    /// Finds page boundaries in DOM coordinates without bisecting rendered
    /// text lines. Images, tables, figures and CSS break-inside blocks are
    /// treated as softer constraints so a large element cannot create a nearly
    /// empty page or prevent forward progress.
    @MainActor
    private static func safePageRanges(
        in webView: WKWebView,
        contentSize: CGSize,
        idealPageHeight: CGFloat,
        maximumPageCount: Int,
        timeout: TimeInterval
    ) async throws -> [Range<CGFloat>] {
        let script = """
        const measureDocument = () => {
          const root = document.documentElement;
          const body = document.body;
          return {
            width: Math.ceil(Math.max(
              1,
              root ? root.scrollWidth : 0,
              root ? root.clientWidth : 0,
              body ? body.scrollWidth : 0,
              body ? body.clientWidth : 0
            )),
            height: Math.ceil(Math.max(
              1,
              root ? root.scrollHeight : 0,
              root ? root.clientHeight : 0,
              body ? body.scrollHeight : 0,
              body ? body.clientHeight : 0
            ))
          };
        };
        const startingSize = measureDocument();
        const contentHeight = startingSize.height;
        const pageHeight = Math.max(1, Number(idealHeight));
        const maximumPages = Math.max(1, Math.floor(Number(pageLimit)));
        const scrollOffset = Number(window.scrollY || window.pageYOffset || 0);
        const hardIntervals = [];
        const softIntervals = [];
        const forcedBreaks = [];
        const visibleTextNodeLimit = 50000;
        const inspectedElementLimit = 20000;
        const renderedTextRectLimit = 100000;
        const inspectionDeadline = performance.now() + 6000;
        let inspectionIncomplete = false;

        const finiteInterval = (top, bottom) =>
          Number.isFinite(top) && Number.isFinite(bottom) && bottom - top > 0.25;
        const elementIsVisible = element => {
          if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;
          const style = window.getComputedStyle(element);
          return style.display !== 'none'
            && style.visibility !== 'hidden'
            && Number(style.opacity || 1) !== 0;
        };
        const appendClientRect = (destination, rect, padding = 0) => {
          const top = rect.top + scrollOffset - padding;
          const bottom = rect.bottom + scrollOffset + padding;
          if (rect.width > 0.25 && finiteInterval(top, bottom)) {
            destination.push([Math.max(0, top), Math.min(contentHeight, bottom)]);
          }
        };

        const walker = document.createTreeWalker(
          document.body || document.documentElement,
          NodeFilter.SHOW_TEXT
        );
        let inspectedTextNodes = 0;
        let renderedTextRects = 0;
        let textNode;
        while ((textNode = walker.nextNode()) && inspectedTextNodes < visibleTextNodeLimit) {
          inspectedTextNodes += 1;
          if ((inspectedTextNodes & 127) === 0 && performance.now() > inspectionDeadline) {
            inspectionIncomplete = true;
            break;
          }
          if (!textNode.nodeValue || !textNode.nodeValue.trim()) continue;
          const parent = textNode.parentElement;
          if (!elementIsVisible(parent)) continue;
          const range = document.createRange();
          range.selectNodeContents(textNode);
          const rects = range.getClientRects();
          for (let rectIndex = 0; rectIndex < rects.length; rectIndex += 1) {
            const rect = rects[rectIndex];
            appendClientRect(hardIntervals, rect, 1);
            renderedTextRects += 1;
            if (renderedTextRects >= renderedTextRectLimit) {
              inspectionIncomplete = true;
              break;
            }
          }
          range.detach();
          if (inspectionIncomplete) break;
        }
        if (textNode && inspectedTextNodes >= visibleTextNodeLimit) {
          inspectionIncomplete = true;
        }

        const protectedTags = new Set([
          'IMG', 'SVG', 'CANVAS', 'TABLE', 'TR', 'THEAD', 'TFOOT', 'PRE',
          'FIGURE', 'BLOCKQUOTE', 'IFRAME', 'OBJECT', 'EMBED', 'VIDEO'
        ]);
        const forcedValues = new Set(['always', 'page', 'left', 'right', 'recto', 'verso']);
        const elementWalker = document.createTreeWalker(
          document.body || document.documentElement,
          NodeFilter.SHOW_ELEMENT
        );
        let inspectedElements = 0;
        let element;
        while ((element = elementWalker.nextNode()) && inspectedElements < inspectedElementLimit) {
          inspectedElements += 1;
          if ((inspectedElements & 127) === 0 && performance.now() > inspectionDeadline) {
            inspectionIncomplete = true;
            break;
          }
          if (!elementIsVisible(element)) continue;
          const style = window.getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          const top = rect.top + scrollOffset;
          const bottom = rect.bottom + scrollOffset;
          if (!finiteInterval(top, bottom)) continue;

          const breakInside = String(style.breakInside || style.pageBreakInside || '').toLowerCase();
          const shouldStayTogether = protectedTags.has(element.tagName)
            || breakInside === 'avoid'
            || breakInside === 'avoid-page';
          if (shouldStayTogether && rect.height <= pageHeight * 0.95) {
            softIntervals.push([Math.max(0, top), Math.min(contentHeight, bottom)]);
          }

          const breakBefore = String(style.breakBefore || style.pageBreakBefore || '').toLowerCase();
          const breakAfter = String(style.breakAfter || style.pageBreakAfter || '').toLowerCase();
          if (forcedValues.has(breakBefore) && top > 0 && top < contentHeight) {
            forcedBreaks.push(top);
          }
          if (forcedValues.has(breakAfter) && bottom > 0 && bottom < contentHeight) {
            forcedBreaks.push(bottom);
          }
        }
        if (element && inspectedElements >= inspectedElementLimit) {
          inspectionIncomplete = true;
        }

        const sortedIntervals = intervals => intervals
          .filter(interval => finiteInterval(interval[0], interval[1]))
          .sort((left, right) => left[0] - right[0]);
        const hard = sortedIntervals(hardIntervals);
        const soft = sortedIntervals(softIntervals);
        forcedBreaks.sort((left, right) => left - right);

        const firstCrossingTop = (intervals, boundary, start) => {
          let candidate = boundary;
          for (const interval of intervals) {
            if (interval[0] >= boundary) break;
            if (interval[0] > start + 0.5 && interval[1] > boundary) {
              candidate = Math.min(candidate, interval[0]);
            }
          }
          return candidate;
        };

        const ranges = [];
        let start = 0;
        while (start < contentHeight - 0.25 && ranges.length < maximumPages) {
          const idealBoundary = Math.min(contentHeight, start + pageHeight);
          if (idealBoundary >= contentHeight - 0.25) {
            ranges.push([start, contentHeight]);
            start = contentHeight;
            break;
          }

          let boundary = idealBoundary;
          const forcedBoundary = forcedBreaks.find(position =>
            position > start + 0.5 && position <= idealBoundary
          );
          if (Number.isFinite(forcedBoundary)) boundary = forcedBoundary;

          const minimumSoftFill = start + pageHeight * 0.55;
          for (let adjustment = 0; adjustment < 8; adjustment += 1) {
            const previousBoundary = boundary;
            boundary = firstCrossingTop(hard, boundary, start);
            const softBoundary = firstCrossingTop(soft, boundary, start);
            if (softBoundary >= minimumSoftFill) boundary = softBoundary;
            if (Math.abs(previousBoundary - boundary) < 0.01) break;
          }
          // A final hard pass guarantees that a soft keep-together interval
          // can never move the boundary back into a rendered line of text.
          boundary = firstCrossingTop(hard, boundary, start);

          // Oversized glyphs or pathological CSS may cover an entire page.
          // In that case the ideal boundary is the only bounded way forward.
          if (!Number.isFinite(boundary) || boundary <= start + 0.5) {
            boundary = idealBoundary;
          }
          boundary = Math.min(contentHeight, Math.max(start + 0.5, boundary));
          ranges.push([start, boundary]);
          start = boundary;
        }

        const endingSize = measureDocument();
        return JSON.stringify({
          ranges,
          overflow: start < contentHeight - 0.25,
          incomplete: inspectionIncomplete,
          layoutChanged: Math.abs(startingSize.width - Number(expectedWidth)) > 1
            || Math.abs(startingSize.height - Number(expectedHeight)) > 1
            || Math.abs(endingSize.width - startingSize.width) > 1
            || Math.abs(endingSize.height - startingSize.height) > 1
        });
        """
        let gate = HTMLPDFAsyncGate<Any>()
        let value = try await gate.wait(
            timeout: timeout,
            timeoutError: .resourceInspectionTimedOut,
            onAbort: { [weak webView] in webView?.stopLoading() }
        ) {
            webView.callAsyncJavaScript(
                script,
                arguments: [
                    "expectedWidth": contentSize.width,
                    "expectedHeight": contentSize.height,
                    "idealHeight": idealPageHeight,
                    "pageLimit": maximumPageCount,
                ],
                in: nil,
                in: .defaultClient,
                completionHandler: { result in
                    gate.resolve(result)
                }
            )
        }
        guard
            let json = value as? String,
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawRanges = object["ranges"] as? [[Any]],
            let overflow = object["overflow"] as? Bool,
            let incomplete = object["incomplete"] as? Bool,
            let layoutChanged = object["layoutChanged"] as? Bool,
            !rawRanges.isEmpty
        else {
            throw HTMLPDFConversionError.invalidContentSize
        }
        if overflow {
            throw HTMLPDFConversionError.tooManyPages(
                actual: maximumPageCount + 1,
                limit: maximumPageCount
            )
        }
        guard !incomplete, !layoutChanged else {
            throw HTMLPDFConversionError.invalidContentSize
        }

        var ranges: [Range<CGFloat>] = []
        ranges.reserveCapacity(rawRanges.count)
        var expectedLowerBound: CGFloat = 0
        for rawRange in rawRanges {
            guard
                rawRange.count == 2,
                let lowerNumber = rawRange[0] as? NSNumber,
                let upperNumber = rawRange[1] as? NSNumber
            else {
                throw HTMLPDFConversionError.invalidContentSize
            }
            let lowerBound = CGFloat(lowerNumber.doubleValue)
            let upperBound = min(contentSize.height, CGFloat(upperNumber.doubleValue))
            guard
                lowerBound.isFinite,
                upperBound.isFinite,
                abs(lowerBound - expectedLowerBound) <= 1,
                upperBound > expectedLowerBound,
                upperBound - expectedLowerBound <= idealPageHeight + 1
            else {
                throw HTMLPDFConversionError.invalidContentSize
            }
            ranges.append(expectedLowerBound..<upperBound)
            expectedLowerBound = upperBound
        }
        guard
            ranges.count <= maximumPageCount,
            abs(expectedLowerBound - contentSize.height) <= 1
        else {
            throw HTMLPDFConversionError.invalidContentSize
        }
        return ranges
    }

    @MainActor
    private static func capture(
        _ webView: WKWebView,
        plan: CapturePlan,
        captureTimeout: TimeInterval,
        deadline: HTMLPDFDeadline
    ) async throws -> [CapturedBatch] {
        var batches: [CapturedBatch] = []
        batches.reserveCapacity(plan.pageCount)

        for (pageIndex, range) in plan.pageRanges.enumerated() {
            try Task.checkCancellation()
            let height = range.upperBound - range.lowerBound
            let pdfConfiguration = WKPDFConfiguration()
            pdfConfiguration.rect = CGRect(
                x: 0,
                y: range.lowerBound,
                width: plan.captureWidth,
                height: height
            )
            pdfConfiguration.allowTransparentBackground = false

            let timeout = try deadline.remaining(
                limitedTo: captureTimeout,
                timeoutError: .captureTimedOut(page: pageIndex + 1)
            )
            let gate = HTMLPDFAsyncGate<Data>()
            let data = try await gate.wait(
                timeout: timeout,
                timeoutError: .captureTimedOut(page: pageIndex + 1),
                onAbort: { [weak webView] in webView?.stopLoading() }
            ) {
                webView.createPDF(configuration: pdfConfiguration) { result in
                    gate.resolve(result)
                }
            }
            guard
                let provider = CGDataProvider(data: data as CFData),
                let captured = CGPDFDocument(provider),
                captured.numberOfPages == 1
            else {
                throw HTMLPDFConversionError.invalidGeneratedPDF
            }
            batches.append(CapturedBatch(data: data))
        }
        return batches
    }

    private static func compose(
        _ batches: [CapturedBatch],
        pageSize: CGSize,
        margins: HTMLPDFPageMargins,
        expectedPageCount: Int
    ) throws -> Data {
        let output = NSMutableData()
        guard
            let consumer = CGDataConsumer(data: output as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw HTMLPDFConversionError.invalidGeneratedPDF
        }
        let mediaBox = CGRect(origin: .zero, size: pageSize)
        let printableRect = CGRect(
            x: margins.leading,
            y: margins.bottom,
            width: pageSize.width - margins.leading - margins.trailing,
            height: pageSize.height - margins.top - margins.bottom
        )
        var renderedPageCount = 0

        for batch in batches {
            guard
                let provider = CGDataProvider(data: batch.data as CFData),
                let document = CGPDFDocument(provider),
                document.numberOfPages == 1,
                let page = document.page(at: 1)
            else {
                throw HTMLPDFConversionError.invalidGeneratedPDF
            }
            let sourceBox = page.getBoxRect(.mediaBox)
            guard
                sourceBox.width.isFinite,
                sourceBox.height.isFinite,
                sourceBox.width > 0,
                sourceBox.height > 0
            else {
                throw HTMLPDFConversionError.invalidGeneratedPDF
            }
            let scale = min(
                printableRect.width / sourceBox.width,
                printableRect.height / sourceBox.height
            )
            var pageMediaBox = mediaBox
            let pageInfo = [
                kCGPDFContextMediaBox as String: Data(
                    bytes: &pageMediaBox,
                    count: MemoryLayout<CGRect>.size
                ),
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)

            // Every WebKit capture already ends at a safe DOM boundary. Keep
            // its visual top aligned to A4 and leave any remainder blank.
            context.saveGState()
            context.clip(to: printableRect)
            context.translateBy(
                x: printableRect.minX - sourceBox.minX * scale,
                y: printableRect.maxY - sourceBox.maxY * scale
            )
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
            renderedPageCount += 1
        }
        context.closePDF()

        guard renderedPageCount == expectedPageCount else {
            throw HTMLPDFConversionError.invalidGeneratedPDF
        }
        return output as Data
    }

    @MainActor
    private static func measureSettledContent(
        in webView: WKWebView,
        resourceWaitTimeout: TimeInterval,
        settleDelay: TimeInterval,
        operationTimeout: TimeInterval
    ) async throws -> CGSize {
        let script = """
        const resourceWait = Math.max(0, Number(resourceWaitMilliseconds));
        const settleWait = Math.max(0, Number(settleMilliseconds));
        const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
        if (!document.getElementById('hwattak-pdf-stable-layout')) {
          const stableStyle = document.createElement('style');
          stableStyle.id = 'hwattak-pdf-stable-layout';
          stableStyle.textContent = `
            *, *::before, *::after {
              animation-play-state: paused !important;
              animation-delay: 0s !important;
              transition-property: none !important;
              caret-color: transparent !important;
            }
          `;
          (document.head || document.documentElement).appendChild(stableStyle);
        }
        for (const image of Array.from(document.images || []).slice(0, 10000)) {
          image.loading = 'eager';
        }
        for (const media of Array.from(document.querySelectorAll('video, audio')).slice(0, 1000)) {
          try { media.pause(); } catch (_) {}
        }
        const pendingImages = Array.from(document.images || []).map(image => {
          if (image.complete) return Promise.resolve();
          return new Promise(resolve => {
            image.addEventListener('load', resolve, { once: true });
            image.addEventListener('error', resolve, { once: true });
          });
        });
        const fonts = document.fonts && document.fonts.ready
          ? Promise.resolve(document.fonts.ready).catch(() => undefined)
          : Promise.resolve();
        await Promise.race([
          Promise.allSettled([...pendingImages, fonts]),
          sleep(resourceWait)
        ]);
        await sleep(settleWait);
        const root = document.documentElement;
        const body = document.body;
        const width = Math.ceil(Math.max(
          1,
          root ? root.scrollWidth : 0,
          root ? root.clientWidth : 0,
          body ? body.scrollWidth : 0,
          body ? body.clientWidth : 0
        ));
        const height = Math.ceil(Math.max(
          1,
          root ? root.scrollHeight : 0,
          root ? root.clientHeight : 0,
          body ? body.scrollHeight : 0,
          body ? body.clientHeight : 0
        ));
        return JSON.stringify({ width, height });
        """
        let gate = HTMLPDFAsyncGate<Any>()
        let value = try await gate.wait(
            timeout: operationTimeout,
            timeoutError: .resourceInspectionTimedOut,
            onAbort: { [weak webView] in webView?.stopLoading() }
        ) {
            webView.callAsyncJavaScript(
                script,
                arguments: [
                    "resourceWaitMilliseconds": resourceWaitTimeout * 1_000,
                    "settleMilliseconds": settleDelay * 1_000,
                ],
                in: nil,
                in: .defaultClient,
                completionHandler: { result in
                gate.resolve(result)
                }
            )
        }
        guard
            let json = value as? String,
            let data = json.data(using: String.Encoding.utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let width = (object["width"] as? NSNumber)?.doubleValue,
            let height = (object["height"] as? NSNumber)?.doubleValue,
            width.isFinite,
            height.isFinite,
            width > 0,
            height > 0
        else {
            throw HTMLPDFConversionError.invalidContentSize
        }
        return CGSize(width: width, height: height)
    }

    @MainActor
    private static var cachedLocalFilesOnlyRuleList: WKContentRuleList?

    @MainActor
    private static func localFilesOnlyRuleList(
        timeout: TimeInterval
    ) async throws -> WKContentRuleList {
        if let cachedLocalFilesOnlyRuleList {
            return cachedLocalFilesOnlyRuleList
        }
        let encodedRules = """
        [
          {"trigger":{"url-filter":"^http://.*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https://.*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^ws://.*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^wss://.*"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^ftp://.*"},"action":{"type":"block"}}
        ]
        """
        let ruleStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-HTMLContentRules", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: ruleStoreURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw HTMLPDFConversionError.webKitFailure(error.localizedDescription)
        }
        guard let ruleStore = WKContentRuleListStore(url: ruleStoreURL) else {
            throw HTMLPDFConversionError.invalidConfiguration
        }
        let gate = HTMLPDFAsyncGate<WKContentRuleList>()
        let list = try await gate.wait(
            timeout: timeout,
            timeoutError: .navigationTimedOut,
            onAbort: {}
        ) {
            ruleStore.compileContentRuleList(
                forIdentifier: "com.hwattakpdf.local-html-pdf.v1",
                encodedContentRuleList: encodedRules
            ) { ruleList, error in
                if let ruleList {
                    gate.resolve(.success(ruleList))
                } else {
                    gate.resolve(
                        .failure(
                            error ?? HTMLPDFConversionError.invalidConfiguration
                        )
                    )
                }
            }
        }
        cachedLocalFilesOnlyRuleList = list
        return list
    }
}

private struct HTMLPDFDeadline {
    let end: TimeInterval

    init(timeout: TimeInterval) {
        end = ProcessInfo.processInfo.systemUptime + timeout
    }

    func remaining(
        limitedTo phaseLimit: TimeInterval,
        timeoutError: HTMLPDFConversionError
    ) throws -> TimeInterval {
        let remaining = end - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw timeoutError }
        return min(remaining, phaseLimit)
    }
}

@MainActor
private final class HTMLPDFAsyncGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var onAbort: (() -> Void)?
    private var isFinished = false

    func wait(
        timeout: TimeInterval,
        timeoutError: HTMLPDFConversionError,
        onAbort: @escaping () -> Void,
        start: () -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let pendingResult {
                    self.pendingResult = nil
                    continuation.resume(with: pendingResult)
                    return
                }
                self.continuation = continuation
                self.onAbort = onAbort
                let workItem = DispatchWorkItem { [weak self] in
                    self?.timeOut(with: timeoutError)
                }
                timeoutWorkItem = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + max(0.001, timeout),
                    execute: workItem
                )
                start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        complete(result, shouldAbort: false)
    }

    private func cancel() {
        complete(.failure(CancellationError()), shouldAbort: true)
    }

    private func timeOut(with error: HTMLPDFConversionError) {
        complete(.failure(error), shouldAbort: true)
    }

    private func complete(
        _ result: Result<Value, Error>,
        shouldAbort: Bool
    ) {
        guard !isFinished else { return }
        isFinished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if shouldAbort {
            onAbort?()
        }
        onAbort = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            pendingResult = result
        }
    }
}

@MainActor
private final class HTMLPDFNavigationCoordinator: NSObject,
    WKNavigationDelegate,
    WKUIDelegate
{
    private let sourceURL: URL
    private let readRoot: URL
    private let networkPolicy: HTMLPDFNetworkPolicy
    private let gate = HTMLPDFAsyncGate<Void>()

    init(
        sourceURL: URL,
        readRoot: URL,
        networkPolicy: HTMLPDFNetworkPolicy
    ) {
        self.sourceURL = sourceURL
        self.readRoot = readRoot
        self.networkPolicy = networkPolicy
    }

    func load(
        _ webView: WKWebView,
        sourceURL: URL,
        readRoot: URL,
        timeout: TimeInterval
    ) async throws {
        try await gate.wait(
            timeout: timeout,
            timeoutError: .navigationTimedOut,
            onAbort: { [weak webView] in webView?.stopLoading() }
        ) {
            guard webView.loadFileURL(sourceURL, allowingReadAccessTo: readRoot) != nil else {
                gate.resolve(.failure(HTMLPDFConversionError.unreadableSource(sourceURL)))
                return
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            gate.resolve(.failure(HTMLPDFConversionError.unsafeNavigation(nil)))
            decisionHandler(.cancel)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame != false
        if isAllowed(url, isMainFrame: isMainFrame) {
            decisionHandler(.allow)
        } else {
            if isMainFrame {
                gate.resolve(.failure(HTMLPDFConversionError.unsafeNavigation(url)))
            }
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let isMainFrame = navigationResponse.isForMainFrame
        guard
            let url = navigationResponse.response.url,
            isAllowed(url, isMainFrame: isMainFrame),
            navigationResponse.canShowMIMEType
        else {
            if isMainFrame {
                gate.resolve(
                    .failure(
                        HTMLPDFConversionError.unsafeNavigation(
                            navigationResponse.response.url
                        )
                    )
                )
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        gate.resolve(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        gate.resolve(.failure(HTMLPDFConversionError.webKitFailure(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        gate.resolve(.failure(HTMLPDFConversionError.webKitFailure(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        gate.resolve(.failure(HTMLPDFConversionError.webContentProcessTerminated))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        completionHandler(nil)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    private func isAllowed(_ url: URL, isMainFrame: Bool) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "file" {
            let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
            return candidate == sourceURL || isWithinReadRoot(candidate)
        }
        if scheme == "about" || scheme == "data" || scheme == "blob" {
            return !isMainFrame || scheme == "about"
        }
        if !isMainFrame,
           networkPolicy == .allowRemoteResources,
           scheme == "http" || scheme == "https" {
            return true
        }
        return false
    }

    private func isWithinReadRoot(_ candidate: URL) -> Bool {
        let rootPath = readRoot.path.hasSuffix("/") ? readRoot.path : readRoot.path + "/"
        return candidate.path.hasPrefix(rootPath)
    }
}
