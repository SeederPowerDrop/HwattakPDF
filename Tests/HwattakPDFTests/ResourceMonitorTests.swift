// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import HwattakPDF

final class ResourceMonitorTests: XCTestCase {
    func testEfficientThumbnailPolicyBoundsUntrustedPageGeometryAndCache() {
        let efficient = PDFThumbnailRenderingPolicy(efficientRenderingEnabled: true)
        let quality = PDFThumbnailRenderingPolicy(efficientRenderingEnabled: false)

        let extreme = efficient.targetSize(
            pageBounds: CGRect(x: 0, y: 0, width: 1, height: 1_000_000),
            rotation: 0,
            requestedWidth: .greatestFiniteMagnitude
        )
        XCTAssertTrue(extreme.width.isFinite)
        XCTAssertTrue(extreme.height.isFinite)
        XCTAssertLessThanOrEqual(max(extreme.width, extreme.height), efficient.maximumDimension)
        XCTAssertLessThanOrEqual(
            extreme.width * extreme.height,
            efficient.maximumPixelCount + 1
        )

        let invalid = efficient.targetSize(
            pageBounds: CGRect(
                x: 0,
                y: 0,
                width: CGFloat.infinity,
                height: CGFloat.nan
            ),
            rotation: 90,
            requestedWidth: CGFloat.nan
        )
        XCTAssertGreaterThanOrEqual(invalid.width, 1)
        XCTAssertGreaterThanOrEqual(invalid.height, 1)
        XCTAssertTrue(invalid.width.isFinite)
        XCTAssertTrue(invalid.height.isFinite)
        XCTAssertLessThan(efficient.cacheCostLimit, quality.cacheCostLimit)
        XCTAssertLessThan(efficient.cacheCountLimit, quality.cacheCountLimit)
    }

    func testRasterBudgetAppliesDimensionAndPixelAreaCeilings() {
        let budget = PDFRasterBudget(
            maximumDimension: 4_000,
            maximumPixelCount: 10_000_000
        )
        let result = budget.boundedPixelSize(
            logicalSize: CGSize(width: 100_000, height: 100_000),
            scale: 12
        )

        XCTAssertLessThanOrEqual(max(result.width, result.height), 4_000)
        XCTAssertLessThanOrEqual(result.width * result.height, 10_000_000)
        XCTAssertEqual(
            budget.boundedPixelSize(
                logicalSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity),
                scale: CGFloat.infinity
            ),
            CGSize(width: 1, height: 1)
        )
        let overflowCandidate = budget.boundedPixelSize(
            logicalSize: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude / 2
            ),
            scale: CGFloat.greatestFiniteMagnitude
        )
        XCTAssertTrue(overflowCandidate.width.isFinite)
        XCTAssertTrue(overflowCandidate.height.isFinite)
        XCTAssertLessThanOrEqual(max(overflowCandidate.width, overflowCandidate.height), 4_000)
        XCTAssertLessThanOrEqual(
            overflowCandidate.width * overflowCandidate.height,
            10_000_000
        )
    }

    func testOnlyActiveOCRStatesPinDocumentWork() {
        XCTAssertFalse(OCRRunState.idle.isActivelyProcessing)
        XCTAssertTrue(OCRRunState.running(completed: 1, total: 2, page: 2).isActivelyProcessing)
        XCTAssertTrue(OCRRunState.cancelling.isActivelyProcessing)
        XCTAssertFalse(
            OCRRunState.finished(recognizedPages: 1, skippedPages: 1).isActivelyProcessing
        )
        XCTAssertFalse(OCRRunState.failed("failed").isActivelyProcessing)
    }

    @MainActor
    func testMonitorSamplesImmediatelyThenComputesCPUFromOneSecondDelta() {
        let reader = StubProcessResourceReader(
            counters: ProcessResourceCounters(
                residentMemoryBytes: 100,
                cumulativeCPUTime: 10
            )
        )
        let clock = MutableResourceMonitorClock(now: Date(timeIntervalSince1970: 100), uptime: 50)
        let scheduler = StubResourceMonitorScheduler()
        let monitor = ProcessResourceMonitor(
            reader: reader,
            timeSource: clock.timeSource,
            scheduler: scheduler,
            logicalProcessorCount: 4
        )

        monitor.start()

        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(scheduler.scheduledInterval, 1)
        XCTAssertEqual(monitor.snapshot?.residentMemoryBytes, 100)
        XCTAssertNil(monitor.snapshot?.cpuPercent)

        reader.counters = ProcessResourceCounters(
            residentMemoryBytes: 240,
            cumulativeCPUTime: 10.25
        )
        clock.now = Date(timeIntervalSince1970: 101)
        clock.uptime = 51
        scheduler.fire()

        XCTAssertEqual(monitor.snapshot?.residentMemoryBytes, 240)
        XCTAssertEqual(monitor.snapshot?.cpuPercent ?? -1, 25, accuracy: 0.0001)
        XCTAssertEqual(monitor.snapshot?.sampledAt, Date(timeIntervalSince1970: 101))
        XCTAssertNil(monitor.lastError)
    }

    @MainActor
    func testStartIsIdempotentAndStopCancelsTimerAndResetsCPUBaseline() {
        let reader = StubProcessResourceReader(
            counters: ProcessResourceCounters(residentMemoryBytes: 1, cumulativeCPUTime: 1)
        )
        let clock = MutableResourceMonitorClock(now: Date(), uptime: 1)
        let scheduler = StubResourceMonitorScheduler()
        let monitor = ProcessResourceMonitor(
            sampleInterval: .nan,
            reader: reader,
            timeSource: clock.timeSource,
            scheduler: scheduler
        )

        monitor.start()
        monitor.start()
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(scheduler.scheduleCount, 1)
        XCTAssertEqual(monitor.sampleInterval, 1)

        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(scheduler.token.isCancelled)

        reader.counters = ProcessResourceCounters(residentMemoryBytes: 2, cumulativeCPUTime: 2)
        clock.uptime = 2
        monitor.start()
        XCTAssertNil(monitor.snapshot?.cpuPercent)
        XCTAssertEqual(scheduler.scheduleCount, 2)
    }

    @MainActor
    func testMonitorClampsCPUToLogicalCoreCapacityAndHandlesCounterReset() {
        let reader = StubProcessResourceReader(
            counters: ProcessResourceCounters(residentMemoryBytes: 1, cumulativeCPUTime: 2)
        )
        let clock = MutableResourceMonitorClock(now: Date(), uptime: 10)
        let monitor = ProcessResourceMonitor(
            reader: reader,
            timeSource: clock.timeSource,
            scheduler: StubResourceMonitorScheduler(),
            logicalProcessorCount: 2
        )

        monitor.sampleNow()
        reader.counters = ProcessResourceCounters(residentMemoryBytes: 1, cumulativeCPUTime: 12)
        clock.uptime = 11
        monitor.sampleNow()
        XCTAssertEqual(monitor.snapshot?.cpuPercent, 200)

        reader.counters = ProcessResourceCounters(residentMemoryBytes: 1, cumulativeCPUTime: 1)
        clock.uptime = 12
        monitor.sampleNow()
        XCTAssertNil(monitor.snapshot?.cpuPercent)
    }

    @MainActor
    func testSamplingFailureKeepsLastGoodSnapshotAndReportsError() {
        let reader = StubProcessResourceReader(
            counters: ProcessResourceCounters(residentMemoryBytes: 42, cumulativeCPUTime: 1)
        )
        let clock = MutableResourceMonitorClock(now: Date(), uptime: 1)
        let monitor = ProcessResourceMonitor(
            reader: reader,
            timeSource: clock.timeSource,
            scheduler: StubResourceMonitorScheduler()
        )

        monitor.sampleNow()
        let lastGood = monitor.snapshot
        reader.error = StubResourceError.failed
        clock.uptime = 2
        monitor.sampleNow()

        XCTAssertEqual(monitor.snapshot, lastGood)
        XCTAssertEqual(monitor.lastError, StubResourceError.failed.localizedDescription)
    }

    @MainActor
    func testMonitorDeinitCancelsScheduledTimer() {
        let scheduler = StubResourceMonitorScheduler()
        weak var releasedMonitor: ProcessResourceMonitor?

        do {
            let monitor = ProcessResourceMonitor(
                reader: StubProcessResourceReader(
                    counters: ProcessResourceCounters(residentMemoryBytes: 1, cumulativeCPUTime: 1)
                ),
                scheduler: scheduler
            )
            releasedMonitor = monitor
            monitor.start()
        }

        XCTAssertNil(releasedMonitor)
        XCTAssertTrue(scheduler.token.isCancelled)
    }

    func testSystemReaderReturnsSelfProcessCounters() throws {
        let counters = try SystemProcessResourceCountersReader().readCounters()
        XCTAssertGreaterThan(counters.residentMemoryBytes, 0)
        XCTAssertGreaterThanOrEqual(counters.cumulativeCPUTime, 0)
    }

    func testTabEstimatorUsesDocumentFileAndPageHeuristicAndShares() {
        let mebibyte: UInt64 = 1_024 * 1_024
        let firstURL = URL(fileURLWithPath: "/tmp/resource-first.pdf")
        let secondURL = URL(fileURLWithPath: "/tmp/resource-second.pdf")
        let firstID = UUID()
        let secondID = UUID()
        let estimator = PDFTabResourceEstimator(
            fileSizeProvider: StubPDFFileSizeProvider(
                sizes: [firstURL: 10 * mebibyte, secondURL: 20 * mebibyte]
            )
        )
        let inputs = [
            PDFTabResourceInput(
                id: firstID,
                displayName: "first.pdf",
                documentURL: firstURL,
                pageCount: 10,
                isDocumentLoaded: true,
                isActive: true
            ),
            PDFTabResourceInput(
                id: secondID,
                displayName: "second.pdf",
                documentURL: secondURL,
                pageCount: 2,
                isDocumentLoaded: true,
                isActive: false
            )
        ]

        let report = estimator.report(for: inputs)
        let firstExpected = 8 * mebibyte + 15 * mebibyte + 10 * 384 * 1_024
        let secondExpected = 8 * mebibyte + 30 * mebibyte + 2 * 384 * 1_024

        XCTAssertEqual(report.tabs.map(\.id), [firstID, secondID])
        XCTAssertEqual(report.tabs[0].fileSizeState, .available(10 * mebibyte))
        XCTAssertEqual(report.tabs[0].estimatedMemoryBytes, firstExpected)
        XCTAssertEqual(report.tabs[1].estimatedMemoryBytes, secondExpected)
        XCTAssertEqual(report.totalEstimatedMemoryBytes, firstExpected + secondExpected)
        XCTAssertEqual(
            report.tabs[0].estimatedShare,
            Double(firstExpected) / Double(firstExpected + secondExpected),
            accuracy: 0.000_001
        )
        XCTAssertTrue(report.tabs[0].isActive)
    }

    func testTabEstimatorDistinguishesUnsavedUnavailableAndEmptyDocuments() {
        let missingURL = URL(fileURLWithPath: "/tmp/definitely-missing-resource.pdf")
        let estimator = PDFTabResourceEstimator(
            fileSizeProvider: StubPDFFileSizeProvider(sizes: [:])
        )
        let inputs = [
            PDFTabResourceInput(
                id: UUID(),
                displayName: "unsaved",
                documentURL: nil,
                pageCount: 3,
                isDocumentLoaded: true,
                isActive: false
            ),
            PDFTabResourceInput(
                id: UUID(),
                displayName: "missing",
                documentURL: missingURL,
                pageCount: -20,
                isDocumentLoaded: true,
                isActive: false
            ),
            PDFTabResourceInput(
                id: UUID(),
                displayName: "empty",
                documentURL: nil,
                pageCount: 99,
                isDocumentLoaded: false,
                isActive: false
            )
        ]

        let report = estimator.report(for: inputs)

        XCTAssertEqual(report.tabs[0].fileSizeState, .unsaved)
        XCTAssertEqual(
            report.tabs[0].estimatedMemoryBytes,
            PDFTabResourceEstimator.documentBaseBytes + 3 * PDFTabResourceEstimator.bytesPerPage
        )
        XCTAssertEqual(report.tabs[1].fileSizeState, .unavailable)
        XCTAssertEqual(report.tabs[1].pageCount, 0)
        XCTAssertEqual(
            report.tabs[1].estimatedMemoryBytes,
            PDFTabResourceEstimator.documentBaseBytes
        )
        XCTAssertEqual(report.tabs[2].fileSizeState, .empty)
        XCTAssertEqual(report.tabs[2].estimatedMemoryBytes, 0)
    }

    func testTabEstimatorSaturatesOverflowWithoutInvalidShare() {
        let url = URL(fileURLWithPath: "/tmp/huge-resource.pdf")
        let report = PDFTabResourceEstimator(
            fileSizeProvider: StubPDFFileSizeProvider(sizes: [url: .max])
        ).report(
            for: [
                PDFTabResourceInput(
                    id: UUID(),
                    displayName: "huge.pdf",
                    documentURL: url,
                    pageCount: .max,
                    isDocumentLoaded: true,
                    isActive: false
                )
            ]
        )

        XCTAssertEqual(report.tabs[0].estimatedMemoryBytes, .max)
        XCTAssertEqual(report.totalEstimatedMemoryBytes, .max)
        XCTAssertEqual(report.tabs[0].estimatedShare, 1)
        XCTAssertTrue(report.tabs[0].estimatedShare.isFinite)
    }
}

private final class StubProcessResourceReader: ProcessResourceCountersReading {
    var counters: ProcessResourceCounters
    var error: Error?
    private(set) var readCount = 0

    init(counters: ProcessResourceCounters) {
        self.counters = counters
    }

    func readCounters() throws -> ProcessResourceCounters {
        readCount += 1
        if let error { throw error }
        return counters
    }
}

private final class MutableResourceMonitorClock {
    var now: Date
    var uptime: TimeInterval

    init(now: Date, uptime: TimeInterval) {
        self.now = now
        self.uptime = uptime
    }

    var timeSource: ProcessResourceTimeSource {
        ProcessResourceTimeSource(
            now: { [weak self] in self?.now ?? .distantPast },
            uptime: { [weak self] in self?.uptime ?? 0 }
        )
    }
}

@MainActor
private final class StubResourceMonitorScheduler: ResourceMonitorScheduling {
    let token = StubResourceMonitorToken()
    private(set) var scheduledInterval: TimeInterval?
    private(set) var scheduleCount = 0
    private var action: (@MainActor () -> Void)?

    func schedule(
        every interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any ResourceMonitorScheduleToken {
        scheduledInterval = interval
        scheduleCount += 1
        token.isCancelled = false
        self.action = action
        return token
    }

    func fire() {
        guard !token.isCancelled else { return }
        action?()
    }
}

private final class StubResourceMonitorToken: ResourceMonitorScheduleToken {
    var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

private struct StubPDFFileSizeProvider: PDFFileSizeProviding {
    let sizes: [URL: UInt64]

    func fileSize(at url: URL) -> UInt64? {
        sizes[url]
    }
}

private enum StubResourceError: LocalizedError {
    case failed

    var errorDescription: String? { "stub resource failure" }
}
