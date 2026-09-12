// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

/// 현재 포인터 입력을 어떤 문서 편집 동작으로 해석할지 정한다.
/// 보기 열 수가 3개 이상이면 PDFKit 직접 편집 대신 개요 화면을 쓰므로 UI에서
/// 이 도구 선택을 비활성화한다.
enum WorkspaceTool: String, CaseIterable, Identifiable {
    case select
    case text
    case pen
    case eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: L10n.string("tool.select")
        case .text: L10n.string("tool.text")
        case .pen: L10n.string("tool.pen")
        case .eraser: L10n.string("tool.eraser")
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "character.cursor.ibeam"
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        }
    }
}

/// PDF ink annotation을 그릴 때 적용하는 시각 속성이다.
struct InkSettings: Equatable {
    var pressureEnabled = true
    var color = NSColor.systemRed
    var width: CGFloat = 2.4

    /// Native PDFKit Ink drops color alpha while serializing. Until the app
    /// authors a dedicated appearance stream for handwriting, preview and saved
    /// output must both use an opaque color instead of advertising a value that
    /// cannot survive save/reopen.
    var pdfInkColor: NSColor {
        color.withAlphaComponent(1)
    }
}

/// 원시 포인터 이동을 자연스러운 서명 stroke로 바꾸는 필터 설정이다.
/// 값 자체는 민감정보가 아니며, 실제 서명 좌표와 분리해 저장한다.
struct SignatureSettings: Equatable {
    var movementSensitivity: CGFloat = 1.0
    var smoothing: CGFloat = 0.58
    var pressureSensitivity: CGFloat = 1.2
    var minimumPressure: CGFloat = 0.12
    var minimumWidth: CGFloat = 0.8
    var maximumWidth: CGFloat = 4.5
    var velocityInfluence: CGFloat = 0.32
    /// Use a fixed PDF ink color. Dynamic system colors such as labelColor can
    /// serialize as white while the app is in Dark Mode.
    var color = NSColor.black
}

/// Lightweight PDFView state retained when an inactive tab tears down its
/// AppKit view. It contains no PDFKit objects and is safe to keep for hundreds
/// of tabs.
enum PDFViewerViewportContext: Hashable {
    case normal
    case comparison
}

/// PDFView를 해제해도 남기는 확대율과 정규화된 스크롤 위치다.
/// normal/comparison context가 각각 별도 값을 사용해 좁은 비교 panel의 확대가
/// 일반 읽기 화면을 덮어쓰지 않는다.
struct PDFViewerViewportState: Equatable {
    var autoScales = true
    var scaleFactor: CGFloat?
    var horizontalScrollProgress: CGFloat?
    var verticalScrollProgress: CGFloat?
    var capturedPageIndex: Int?

    var scrollProgress: PDFScrollProgress? {
        guard
            let horizontalScrollProgress,
            let verticalScrollProgress
        else { return nil }
        return PDFScrollProgress(
            horizontal: horizontalScrollProgress,
            vertical: verticalScrollProgress
        )
    }

    func scrollProgress(forPageIndex pageIndex: Int) -> PDFScrollProgress? {
        guard capturedPageIndex == pageIndex else { return nil }
        return scrollProgress
    }

    mutating func invalidateScrollPosition() {
        horizontalScrollProgress = nil
        verticalScrollProgress = nil
        capturedPageIndex = nil
    }
}

/// 한 시점의 서명 좌표·압력·상대 시간을 나타내는 직렬화 가능한 값이다.
struct SignaturePoint: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var pressure: CGFloat
    var timestamp: TimeInterval

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// 펜을 누른 순간부터 뗄 때까지의 연속된 점 집합이다.
struct SignatureStroke: Codable, Equatable, Identifiable {
    var id = UUID()
    var points: [SignaturePoint]
}

/// PDF에 쓰기 전 sheet에서 편집 중인 자유 텍스트 초안이다.
///
/// `initialText`라는 이름은 sheet가 처음 표시될 때의 seed라는 뜻이다.
/// 화면이 열린 뒤에는 매 입력을 이 값에 다시 동기화한다. 덕분에 탭 전환으로
/// SwiftUI view가 재생성돼도 초안이 사라지지 않는다. 이 값은 저장이나 탭 전환
/// 때 자동으로 PDF에 들어가지 않으며, 사용자가 Apply를 눌러야만 하나의 undoable
/// edit가 된다. Cancel은 초안만 버리고, close/open은 미결 초안이 있으면 거부한다.
struct PendingTextEdit: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let point: CGPoint
    let isEditingExistingAnnotation: Bool
    var initialText: String
}

/// OCR 비동기 작업의 유한 상태 머신이다. 화면은 Task 자체를 관찰하지 않고
/// 이 값을 관찰하므로 실행·취소·완료·실패를 빠짐없이 표시할 수 있다.
enum OCRRunState: Equatable {
    case idle
    case running(completed: Int, total: Int, page: Int)
    case cancelling
    case finished(recognizedPages: Int, skippedPages: Int)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            L10n.string("ocr.state.idle")
        case let .running(completed, total, page):
            L10n.format("ocr.state.running", completed, total, page)
        case .cancelling:
            L10n.string("ocr.state.cancelling")
        case let .finished(recognized, skipped):
            L10n.format("ocr.state.finished", recognized, skipped)
        case let .failed(message):
            L10n.format("ocr.state.failed", message)
        }
    }

    var fraction: Double? {
        guard case let .running(completed, total, _) = self, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }

    /// Completed/failed OCR keeps only bounded value checkpoints and no worker.
    /// Those states must not permanently pin an otherwise clean PDFKit graph.
    var isActivelyProcessing: Bool {
        switch self {
        case .running, .cancelling:
            true
        case .idle, .finished, .failed:
            false
        }
    }
}

/// OCR 결과를 바꾸는 입력값. 체크포인트 fingerprint에도 포함되므로 이 설정이
/// 바뀌면 예전 결과를 잘못 재사용하지 않는다.
enum OCRRecognitionQuality: String, Codable, Equatable {
    case accurate
    case fast
}

struct OCRConfiguration: Codable, Equatable {
    var languages = ["ko-KR", "en-US", "ja-JP"]
    var skipPagesWithText = true
    var minimumExistingCharacters = 24
    var renderDPI: CGFloat = 220
    var useLanguageCorrection = true
    var recognitionQuality: OCRRecognitionQuality = .accurate
}

/// Vision이 인식한 문자열과 페이지 안의 정규화된 위치다.
struct OCRWordBox: Codable, Equatable {
    let text: String
    let confidence: Float
    /// Vision normalized coordinates, origin at the lower-left.
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

/// 한 페이지가 끝날 때 원자적으로 저장할 수 있는 OCR 결과 단위다.
struct OCRPageResult: Codable, Equatable {
    let pageIndex: Int
    let text: String
    let observations: [OCRWordBox]
    let completedAt: Date
    let skippedBecauseTextExists: Bool
}

/// 중단 후 재개를 위한 문서 단위 manifest다. schemaVersion은 미래 migration을,
/// 두 fingerprint는 다른 문서/설정 결과의 혼합을 막는다.
struct OCRCheckpoint: Codable, Equatable {
    let schemaVersion: Int
    let documentFingerprint: String
    let configurationFingerprint: String
    let pageCount: Int
    var pages: [Int: OCRPageResult]
    var updatedAt: Date

    init(
        documentFingerprint: String,
        pageCount: Int,
        configurationFingerprint: String = "default"
    ) {
        schemaVersion = 2
        self.documentFingerprint = documentFingerprint
        self.configurationFingerprint = configurationFingerprint
        self.pageCount = pageCount
        pages = [:]
        updatedAt = Date()
    }
}

/// 모델·서비스가 UI 문구와 분리된 의미 있는 오류를 전달하는 공통 타입이다.
/// `LocalizedError` 구현 덕분에 alert에서는 `localizedDescription`을 사용할 수 있다.
enum WorkspaceError: LocalizedError {
    case cannotOpen(URL)
    case cannotSave(URL)
    case externalModification(URL)
    case invalidPDF(URL)
    case noDocument
    case noPagesSelected
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .cannotOpen(url):
            L10n.format("error.cannot_open_file", url.lastPathComponent)
        case let .cannotSave(url):
            L10n.format("error.cannot_save_file", url.lastPathComponent)
        case let .externalModification(url):
            L10n.format("error.external_file_modified", url.lastPathComponent)
        case let .invalidPDF(url):
            L10n.format("error.invalid_pdf", url.lastPathComponent)
        case .noDocument:
            L10n.string("error.no_document")
        case .noPagesSelected:
            L10n.string("error.no_pages_selected")
        case let .operationFailed(message):
            message
        }
    }
}
