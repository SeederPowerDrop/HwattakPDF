// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Explains two intentionally different measurements:
///
/// * process RSS/CPU are real Darwin counters for the whole application;
/// * per-tab values are lightweight estimates used only for relative ranking.
///
/// They must not be presented as if individual PDF tabs could be measured
/// exactly—PDFKit shares caches and rendering surfaces across views.
@MainActor
struct ResourceMonitorView: View {
    let sessions: [PDFTabSession]
    let activeTabID: UUID?
    let onSelect: (UUID) -> Void

    @StateObject private var monitor: ProcessResourceMonitor
    @State private var report = PDFTabResourceReport(
        tabs: [],
        totalEstimatedMemoryBytes: 0
    )
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    private let estimator: PDFTabResourceEstimator

    init(
        sessions: [PDFTabSession],
        activeTabID: UUID?,
        onSelect: @escaping (UUID) -> Void
    ) {
        self.init(
            sessions: sessions,
            activeTabID: activeTabID,
            onSelect: onSelect,
            monitor: ProcessResourceMonitor(),
            estimator: PDFTabResourceEstimator()
        )
    }

    init(
        sessions: [PDFTabSession],
        activeTabID: UUID?,
        onSelect: @escaping (UUID) -> Void,
        monitor: ProcessResourceMonitor,
        estimator: PDFTabResourceEstimator = PDFTabResourceEstimator()
    ) {
        self.sessions = sessions
        self.activeTabID = activeTabID
        self.onSelect = onSelect
        _monitor = StateObject(wrappedValue: monitor)
        self.estimator = estimator
    }

    private var theme: HwattakPDFTheme {
        HwattakPDFTheme(colorScheme: colorScheme)
    }

    private var reportInputs: [PDFTabResourceInput] {
        // Convert reference-type sessions into small value snapshots. The
        // estimator can then remain deterministic and independent of SwiftUI.
        sessions.map {
            PDFTabResourceInput(session: $0, activeTabID: activeTabID)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    processSummary
                    tabEstimateSummary
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 590)
        .foregroundStyle(theme.primaryText)
        .background(theme.panel)
        .onAppear {
            refreshReport(using: reportInputs)
            monitor.start()
        }
        .onChange(of: reportInputs) { _, inputs in
            refreshReport(using: inputs)
        }
        .onDisappear { monitor.stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("리소스 모니터")
                    .font(.headline)
                Text("앱 프로세스 실측 · PDF 탭별 추정")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Label(
                L10n.string(monitor.isRunning ? "1초마다" : "중지됨"),
                systemImage: monitor.isRunning ? "dot.radiowaves.left.and.right" : "pause.circle"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(monitor.isRunning ? theme.success : theme.secondaryText)
            .accessibilityLabel(
                L10n.string(monitor.isRunning ? "1초마다 측정 중" : "리소스 측정 중지됨")
            )

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(theme.card, in: Circle())
            }
            .buttonStyle(.plain)
            .help("리소스 모니터 닫기")
            .accessibilityLabel("리소스 모니터 닫기")
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
    }

    private var processSummary: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("현재 앱 프로세스", badge: "실측")

            HStack(spacing: 12) {
                metricCard(
                    title: "상주 메모리 (RSS)",
                    value: monitor.snapshot.map { formatBytes($0.residentMemoryBytes) }
                        ?? L10n.string("resource.measuring"),
                    systemImage: "memorychip"
                )
                metricCard(
                    title: "CPU",
                    value: formattedCPUPercent,
                    systemImage: "cpu"
                )
            }

            Text("위 값은 HwattakPDF 프로세스 전체의 실제 RSS와 CPU 사용량입니다. CPU 100%는 논리 코어 1개를 뜻합니다.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            if let sampledAt = monitor.snapshot?.sampledAt {
                Text(L10n.format("resource.last_sample", formatTime(sampledAt)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }

            if let error = monitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.ribbonSoft, in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var tabEstimateSummary: some View {
        // Capture once for this render pass. Sorting directly from a mutating
        // @State value in several subexpressions can produce inconsistent rows.
        let resourceReport = report

        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("PDF 탭별 부담", badge: "추정")
                Spacer()
                Text(
                    L10n.format(
                        "resource.estimated_total",
                        formatBytes(resourceReport.totalEstimatedMemoryBytes)
                    )
                )
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }

            Text("파일 크기×1.5 + 페이지당 384KiB + 열린 문서 기본 8MiB로 계산한 상대적 예상 부담입니다. 실제 RSS를 탭별로 배분한 값이 아닙니다.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            LazyVStack(spacing: 9) {
                ForEach(resourceReport.tabs.sorted { lhs, rhs in
                    if lhs.estimatedMemoryBytes == rhs.estimatedMemoryBytes {
                        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                    }
                    return lhs.estimatedMemoryBytes > rhs.estimatedMemoryBytes
                }) { tab in
                    tabRow(tab)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, badge: String) -> some View {
        HStack(spacing: 8) {
            Text(L10n.string(title))
                .font(.subheadline.weight(.semibold))
            Text(L10n.string(badge))
                .font(.caption2.weight(.bold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(theme.ribbonSoft, in: Capsule())
        }
    }

    private func metricCard(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.string(title), systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
    }

    private func tabRow(_ tab: PDFTabResourceEstimate) -> some View {
        Button {
            onSelect(tab.id)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: tab.isActive ? "doc.fill" : "doc")
                        .foregroundStyle(tab.isActive ? theme.accent : theme.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text(tab.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if tab.isActive {
                                Text("활성")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(theme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.ribbonSoft, in: Capsule())
                            }
                        }
                        Text(tabMetadataDescription(tab))
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L10n.format("resource.estimated", formatBytes(tab.estimatedMemoryBytes)))
                            .font(.caption.weight(.semibold).monospacedDigit())
                        Text(formatShare(tab.estimatedShare))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                ProgressView(value: tab.estimatedShare, total: 1)
                    .progressViewStyle(.linear)
                    .tint(tab.isActive ? theme.accent : theme.ribbon.opacity(0.62))
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(
                tab.isActive ? theme.dropHighlight : theme.card,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(tab.isActive ? theme.accent.opacity(0.7) : theme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tabAccessibilityDescription(tab))
        .accessibilityHint("이 탭으로 전환합니다.")
    }

    private var formattedCPUPercent: String {
        guard let percent = monitor.snapshot?.cpuPercent else {
            return L10n.string("resource.baseline_measuring")
        }
        return percent.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    private func tabMetadataDescription(_ tab: PDFTabResourceEstimate) -> String {
        switch tab.fileSizeState {
        case let .available(bytes):
            return L10n.format("resource.file_pages", formatBytes(bytes), tab.pageCount)
        case let .hibernated(bytes):
            if let bytes {
                return "메모리 절약 탭 · \(formatBytes(bytes)) · \(tab.pageCount)페이지"
            }
            return "메모리 절약 탭 · \(tab.pageCount)페이지"
        case .unsaved:
            return L10n.format("resource.unsaved_pages", tab.pageCount)
        case .unavailable:
            return L10n.format("resource.unavailable_pages", tab.pageCount)
        case .empty:
            return L10n.string("resource.no_pdf")
        }
    }

    private func tabAccessibilityDescription(_ tab: PDFTabResourceEstimate) -> String {
        let key = tab.isActive
            ? "resource.tab_accessibility_active"
            : "resource.tab_accessibility"
        return L10n.format(
            key,
            tab.displayName,
            tabMetadataDescription(tab),
            formatBytes(tab.estimatedMemoryBytes),
            formatShare(tab.estimatedShare)
        )
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: clampedInt64(bytes), countStyle: .memory)
    }

    private func clampedInt64(_ bytes: UInt64) -> Int64 {
        bytes > UInt64(Int64.max) ? Int64.max : Int64(bytes)
    }

    private func formatShare(_ share: Double) -> String {
        (share * 100).formatted(.number.precision(.fractionLength(1))) + "%"
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.currentLanguage.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func refreshReport(using inputs: [PDFTabResourceInput]) {
        // Recompute only when tab metadata changes, not on every one-second
        // process sample. This keeps the monitor itself from becoming load.
        report = estimator.report(for: inputs)
    }
}
