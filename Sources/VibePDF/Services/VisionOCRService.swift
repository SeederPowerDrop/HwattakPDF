// SPDX-License-Identifier: MPL-2.0

import AppKit
import CryptoKit
import Foundation
import PDFKit
import Vision

/// PDF 페이지를 이미지로 렌더링한 뒤 Apple Vision으로 글자를 인식하는 서비스다.
///
/// 처리 흐름은 `PDF -> 페이지 이미지 -> Vision 관찰값 -> 체크포인트`다.
/// 페이지마다 결과를 저장하므로 사용자가 취소하거나 앱이 종료되어도 다음 실행에서
/// 끝난 페이지를 건너뛸 수 있다. 무거운 PDFKit/Vision 작업은 detached task에서
/// 실행하고, 호출자는 `Progress` 값만 받아 UI를 갱신한다.
enum VisionOCRService {
    /// UI에 전달하는 진행률 snapshot. 값 타입이라 스레드 사이 전달이 단순하다.
    struct Progress: Equatable {
        let completed: Int
        let total: Int
        let currentPage: Int
    }

    /// 같은 원본인지 판단하기 위한 SHA-256 식별자를 만든다.
    /// 암호화 목적이 아니라 잘못된 OCR 체크포인트 재사용을 막기 위한 값이다.
    static func fingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 대용량 파일 전체를 한 번에 메모리에 올리지 않고 1 MiB씩 해시한다.
    static func fingerprint(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func configurationFingerprint(for configuration: OCRConfiguration) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(configuration) else {
            return "configuration-encoding-failed"
        }
        return fingerprint(for: data)
    }

    /// Uses a trusted source-baseline identity when available; otherwise hashes
    /// the exact PDF snapshot that OCR is about to read. Keeping this small seam
    /// explicit makes the dirty-document privacy/integrity fallback testable
    /// without running Vision recognition.
    static func resolveDocumentFingerprint(
        for pdfURL: URL,
        suppliedFingerprint: String?
    ) throws -> String {
        try suppliedFingerprint ?? fingerprint(for: pdfURL)
    }

    /// 메모리에 있는 PDF를 임시 파일로 옮겨 URL 기반 공통 경로를 사용한다.
    static func recognize(
        pdfData: Data,
        configuration: OCRConfiguration,
        checkpointStore: OCRCheckpointStore = OCRCheckpointStore(),
        progress: @escaping (Progress) -> Void
    ) async throws -> OCRCheckpoint {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-OCR-\(UUID().uuidString).pdf")
        try pdfData.write(to: temporary, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try await recognize(
            pdfURL: temporary,
            configuration: configuration,
            checkpointStore: checkpointStore,
            progress: progress
        )
    }

    /// OCR의 주 진입점. 취소는 바깥 Task에서 detached worker로 명시 전달된다.
    static func recognize(
        pdfURL: URL,
        documentFingerprint suppliedDocumentFingerprint: String? = nil,
        configuration: OCRConfiguration,
        checkpointStore: OCRCheckpointStore = OCRCheckpointStore(),
        progress: @escaping (Progress) -> Void
    ) async throws -> OCRCheckpoint {
        let worker = Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: pdfURL) else {
                throw WorkspaceError.operationFailed(L10n.string("error.ocr_pdf_data"))
            }

            let documentFingerprint = try resolveDocumentFingerprint(
                for: pdfURL,
                suppliedFingerprint: suppliedDocumentFingerprint
            )
            let configurationFingerprint = configurationFingerprint(for: configuration)
            var checkpoint = checkpointStore.load(
                fingerprint: documentFingerprint,
                pageCount: document.pageCount,
                configurationFingerprint: configurationFingerprint
            ) ?? OCRCheckpoint(
                documentFingerprint: documentFingerprint,
                pageCount: document.pageCount,
                configurationFingerprint: configurationFingerprint
            )

            let total = document.pageCount
            for index in 0..<total {
                try Task.checkCancellation()

                if checkpoint.pages[index] != nil {
                    progress(Progress(completed: checkpoint.pages.count, total: total, currentPage: index + 1))
                    continue
                }

                guard let page = document.page(at: index) else {
                    throw WorkspaceError.operationFailed(
                        L10n.format("error.ocr_page_load", index + 1)
                    )
                }

                let existingText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let visibleCharacterCount = existingText.filter { !$0.isWhitespace }.count
                let result: OCRPageResult

                if configuration.skipPagesWithText,
                   visibleCharacterCount >= configuration.minimumExistingCharacters {
                    result = OCRPageResult(
                        pageIndex: index,
                        text: existingText,
                        observations: [],
                        completedAt: Date(),
                        skippedBecauseTextExists: true
                    )
                } else {
                    let observations = try autoreleasepool {
                        let image = try render(page: page, dpi: configuration.renderDPI)
                        return try recognize(
                            image: image,
                            configuration: configuration
                        )
                    }
                    result = OCRPageResult(
                        pageIndex: index,
                        text: observations.map(\.text).joined(separator: "\n"),
                        observations: observations,
                        completedAt: Date(),
                        skippedBecauseTextExists: false
                    )
                }

                try Task.checkCancellation()
                checkpoint.pages[index] = result
                checkpoint.updatedAt = result.completedAt
                try checkpointStore.savePage(result, for: checkpoint)
                progress(Progress(completed: checkpoint.pages.count, total: total, currentPage: index + 1))
            }
            return checkpoint
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            // Detached work does not inherit parent cancellation. Forward it so
            // a closed document cannot keep OCR running invisibly.
            worker.cancel()
        }
    }

    /// PDF 좌표(72dpi)를 Vision이 읽을 bitmap으로 변환한다.
    private static func render(page: PDFPage, dpi: CGFloat) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        let logicalSize = rotated
            ? CGSize(width: box.height, height: box.width)
            : box.size
        let scale = max(1, dpi.isFinite ? dpi / 72 : 1)
        let processInfo = ProcessInfo.processInfo
        let constrained = AppPerformanceSettings.isEfficientRenderingEnabled
            || processInfo.isLowPowerModeEnabled
            || processInfo.thermalState == .serious
            || processInfo.thermalState == .critical
        let budget = constrained
            ? PDFRasterBudget(maximumDimension: 4_200, maximumPixelCount: 12_000_000)
            : PDFRasterBudget(maximumDimension: 5_200, maximumPixelCount: 20_000_000)
        let pixelSize = budget.boundedPixelSize(logicalSize: logicalSize, scale: scale)

        let image = page.thumbnail(of: pixelSize, for: .cropBox)
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            throw WorkspaceError.operationFailed(L10n.string("error.ocr_page_image"))
        }
        return cgImage
    }

    /// Vision이 실제 지원한다고 보고한 언어만 요청해 OS 버전 차이를 견딘다.
    private static func recognize(
        image: CGImage,
        configuration: OCRConfiguration
    ) throws -> [OCRWordBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = configuration.useLanguageCorrection
        request.automaticallyDetectsLanguage = true

        let supported = Set(try request.supportedRecognitionLanguages())
        let requested = configuration.languages.filter(supported.contains)
        if !requested.isEmpty {
            request.recognitionLanguages = requested
        }

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRWordBox(
                text: candidate.string,
                confidence: candidate.confidence,
                x: box.origin.x,
                y: box.origin.y,
                width: box.width,
                height: box.height
            )
        }
    }
}

/// Resolves a reusable OCR identity from the source's exact bytes without ever
/// trusting a metadata-only key.
///
/// `NSFileCoordinator` keeps cooperative editors from committing during the
/// read in the packaged app. The version checks on both sides also catch an
/// uncoordinated atomic replacement or in-place save. If any step is uncertain,
/// returning nil intentionally asks `VisionOCRService` to hash the already
/// created OCR snapshot instead.
enum OCRSourceFingerprintResolver {
    typealias StreamingFingerprinter = (URL) throws -> String

    /// Runs the potentially large streaming read away from the main actor.
    ///
    /// A detached task does not inherit cancellation from its creator. Keeping
    /// the forwarding here (instead of at each caller) makes it impossible for
    /// a future OCR entry point to accidentally leave a large source read alive
    /// after its parent operation has been cancelled.
    static func resolveInBackground(
        sourceURL: URL,
        expectedVersion: PDFSourceFileVersion,
        fingerprinter: @escaping StreamingFingerprinter = VisionOCRService.fingerprint(for:)
    ) async throws -> String? {
        let worker = Task.detached(priority: .utility) {
            resolve(
                sourceURL: sourceURL,
                expectedVersion: expectedVersion,
                fingerprinter: fingerprinter
            )
        }

        return try await withTaskCancellationHandler {
            let result = await worker.value
            // `validatedFingerprint` deliberately converts read errors to nil
            // so OCR can hash its snapshot. Cancellation is different: the OCR
            // run itself must stop rather than continue on the fallback path.
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    static func resolve(
        sourceURL: URL,
        expectedVersion: PDFSourceFileVersion,
        fingerprinter: StreamingFingerprinter = VisionOCRService.fingerprint(for:)
    ) -> String? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var resolvedFingerprint: String??

        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            resolvedFingerprint = validatedFingerprint(
                sourceURL: coordinatedURL,
                expectedVersion: expectedVersion,
                fingerprinter: fingerprinter
            )
        }

        if coordinationError != nil {
            // Some sandboxed SwiftPM/XCTest hosts cannot reach macOS
            // filecoordinationd. They still exercise the exact production
            // before/hash/after algorithm. A packaged .app never falls back
            // when coordination itself fails.
            guard !requiresSystemFileCoordination else { return nil }
            return validatedFingerprint(
                sourceURL: sourceURL,
                expectedVersion: expectedVersion,
                fingerprinter: fingerprinter
            )
        }
        return resolvedFingerprint ?? nil
    }

    private static var requiresSystemFileCoordination: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private static func validatedFingerprint(
        sourceURL: URL,
        expectedVersion: PDFSourceFileVersion,
        fingerprinter: StreamingFingerprinter
    ) -> String? {
        guard
            let before = try? PDFSourceFileVersion.capture(at: sourceURL),
            before == expectedVersion,
            let fingerprint = try? fingerprinter(sourceURL),
            let after = try? PDFSourceFileVersion.capture(at: sourceURL),
            after == expectedVersion
        else {
            return nil
        }
        return fingerprint
    }
}
