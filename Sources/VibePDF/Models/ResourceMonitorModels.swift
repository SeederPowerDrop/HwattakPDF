// SPDX-License-Identifier: MPL-2.0

import Foundation

struct ProcessResourceCounters: Equatable {
    let residentMemoryBytes: UInt64
    let cumulativeCPUTime: TimeInterval
}

struct ProcessResourceSnapshot: Equatable {
    let residentMemoryBytes: UInt64
    /// Activity Monitor-style process usage. 100% means one logical CPU core.
    let cpuPercent: Double?
    let sampledAt: Date
}

struct ProcessResourceTimeSource {
    let now: () -> Date
    let uptime: () -> TimeInterval

    static let system = ProcessResourceTimeSource(
        now: Date.init,
        uptime: { ProcessInfo.processInfo.systemUptime }
    )
}

enum PDFTabFileSizeState: Equatable {
    case available(UInt64)
    /// The source file remains openable but PDFKit's document/cache graph has
    /// been released. The associated value is the on-disk size when known.
    case hibernated(UInt64?)
    case unsaved
    case unavailable
    case empty

    var fileSizeBytes: UInt64? {
        guard case let .available(bytes) = self else { return nil }
        return bytes
    }
}

struct PDFTabResourceInput: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let documentURL: URL?
    let pageCount: Int
    let isDocumentLoaded: Bool
    let isHibernated: Bool
    let isActive: Bool

    @MainActor
    init(session: PDFTabSession, activeTabID: UUID?) {
        id = session.id
        displayName = session.displayName
        documentURL = session.workspace.documentURL
        pageCount = session.workspace.pageCount
        isDocumentLoaded = session.workspace.document != nil
        isHibernated = session.workspace.isHibernated
        isActive = session.id == activeTabID
    }

    init(
        id: UUID,
        displayName: String,
        documentURL: URL?,
        pageCount: Int,
        isDocumentLoaded: Bool,
        isHibernated: Bool = false,
        isActive: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.documentURL = documentURL
        self.pageCount = pageCount
        self.isDocumentLoaded = isDocumentLoaded
        self.isHibernated = isHibernated
        self.isActive = isActive
    }
}

struct PDFTabResourceEstimate: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let pageCount: Int
    let isActive: Bool
    let fileSizeState: PDFTabFileSizeState
    /// A comparison heuristic, not a measured allocation for this tab.
    let estimatedMemoryBytes: UInt64
    /// Share of the heuristic total across the currently supplied tabs.
    let estimatedShare: Double
}

struct PDFTabResourceReport: Equatable {
    let tabs: [PDFTabResourceEstimate]
    let totalEstimatedMemoryBytes: UInt64
}

protocol PDFFileSizeProviding {
    func fileSize(at url: URL) -> UInt64?
}

struct SystemPDFFileSizeProvider: PDFFileSizeProviding {
    func fileSize(at url: URL) -> UInt64? {
        guard
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size >= 0
        else {
            return nil
        }
        return UInt64(size)
    }
}

struct PDFTabResourceEstimator {
    static let documentBaseBytes: UInt64 = 8 * 1_024 * 1_024
    static let bytesPerPage: UInt64 = 384 * 1_024
    static let hibernatedTabMetadataBytes: UInt64 = 256 * 1_024

    private let fileSizeProvider: any PDFFileSizeProviding

    init(fileSizeProvider: any PDFFileSizeProviding = SystemPDFFileSizeProvider()) {
        self.fileSizeProvider = fileSizeProvider
    }

    func report(for inputs: [PDFTabResourceInput]) -> PDFTabResourceReport {
        let partials = inputs.map { input -> PartialEstimate in
            if input.isHibernated {
                let fileSize = input.documentURL.flatMap(fileSizeProvider.fileSize(at:))
                return PartialEstimate(
                    input: input,
                    fileSizeState: .hibernated(fileSize),
                    estimatedBytes: Self.hibernatedTabMetadataBytes
                )
            }
            guard input.isDocumentLoaded else {
                return PartialEstimate(input: input, fileSizeState: .empty, estimatedBytes: 0)
            }

            let fileSizeState: PDFTabFileSizeState
            if let url = input.documentURL {
                if let bytes = fileSizeProvider.fileSize(at: url) {
                    fileSizeState = .available(bytes)
                } else {
                    fileSizeState = .unavailable
                }
            } else {
                fileSizeState = .unsaved
            }

            let fileBytes = fileSizeState.fileSizeBytes ?? 0
            let fileMemoryComponent = saturatingAdd(fileBytes, fileBytes / 2)
            let pageMemoryComponent = saturatingMultiply(
                UInt64(max(0, input.pageCount)),
                Self.bytesPerPage
            )
            let estimate = saturatingAdd(
                Self.documentBaseBytes,
                saturatingAdd(fileMemoryComponent, pageMemoryComponent)
            )
            return PartialEstimate(
                input: input,
                fileSizeState: fileSizeState,
                estimatedBytes: estimate
            )
        }

        let totalEstimatedMemoryBytes = partials.reduce(UInt64(0)) { total, item in
            saturatingAdd(total, item.estimatedBytes)
        }
        let floatingTotal = partials.reduce(0.0) { total, item in
            total + Double(item.estimatedBytes)
        }
        let estimates = partials.map { item in
            let share = floatingTotal > 0 && floatingTotal.isFinite
                ? min(1, max(0, Double(item.estimatedBytes) / floatingTotal))
                : 0
            return PDFTabResourceEstimate(
                id: item.input.id,
                displayName: item.input.displayName,
                pageCount: max(0, item.input.pageCount),
                isActive: item.input.isActive,
                fileSizeState: item.fileSizeState,
                estimatedMemoryBytes: item.estimatedBytes,
                estimatedShare: share
            )
        }

        return PDFTabResourceReport(
            tabs: estimates,
            totalEstimatedMemoryBytes: totalEstimatedMemoryBytes
        )
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private func saturatingMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : value
    }

    private struct PartialEstimate {
        let input: PDFTabResourceInput
        let fileSizeState: PDFTabFileSizeState
        let estimatedBytes: UInt64
    }
}
