// SPDX-License-Identifier: MPL-2.0

import Combine
import Darwin
import Foundation

/// Abstraction around Darwin counters. Tests inject a fake reader so CPU/RSS
/// math is deterministic and does not depend on the developer's machine load.
protocol ProcessResourceCountersReading {
    func readCounters() throws -> ProcessResourceCounters
}

enum ProcessResourceReadingError: LocalizedError {
    case taskInfo(kern_return_t)
    case processUsage(Int32)
    case invalidCounter

    var errorDescription: String? {
        switch self {
        case let .taskInfo(code):
            L10n.format("error.resource_memory", code)
        case let .processUsage(code):
            L10n.format("error.resource_cpu", code)
        case .invalidCounter:
            L10n.string("error.resource_counter")
        }
    }
}

struct SystemProcessResourceCountersReader: ProcessResourceCountersReading {
    func readCounters() throws -> ProcessResourceCounters {
        ProcessResourceCounters(
            residentMemoryBytes: try residentMemoryBytes(),
            cumulativeCPUTime: try cumulativeCPUTime()
        )
    }

    private func residentMemoryBytes() throws -> UInt64 {
        // `resident_size` is physical memory currently mapped into this
        // process. It is not the sum of PDF file sizes and can include PDFKit's
        // decoded pages, Core Animation surfaces, caches and app UI objects.
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw ProcessResourceReadingError.taskInfo(result)
        }
        return UInt64(info.resident_size)
    }

    private func cumulativeCPUTime() throws -> TimeInterval {
        // getrusage returns a cumulative counter. A percentage only becomes
        // meaningful after comparing two samples over a wall-clock interval.
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw ProcessResourceReadingError.processUsage(errno)
        }
        let user = seconds(from: usage.ru_utime)
        let system = seconds(from: usage.ru_stime)
        let total = user + system
        guard total.isFinite, total >= 0 else {
            throw ProcessResourceReadingError.invalidCounter
        }
        return total
    }

    private func seconds(from value: timeval) -> TimeInterval {
        TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
    }
}

protocol ResourceMonitorScheduleToken: AnyObject {
    func cancel()
}

protocol ResourceMonitorScheduling {
    @MainActor
    func schedule(
        every interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any ResourceMonitorScheduleToken
}

struct RunLoopResourceMonitorScheduler: ResourceMonitorScheduling {
    @MainActor
    func schedule(
        every interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any ResourceMonitorScheduleToken {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }
        // Sampling is informational, not a real-time control loop. Tolerance
        // lets macOS coalesce wakeups with nearby UI work and reduces idle CPU.
        timer.tolerance = min(0.25, interval * 0.2)
        // `.common` keeps sampling while the user drags or scrolls, when the
        // run loop temporarily switches out of its default mode.
        RunLoop.main.add(timer, forMode: .common)
        return RunLoopResourceMonitorToken(timer: timer)
    }
}

private final class RunLoopResourceMonitorToken: ResourceMonitorScheduleToken {
    private var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

@MainActor
final class ProcessResourceMonitor: ObservableObject {
    @Published private(set) var snapshot: ProcessResourceSnapshot?
    @Published private(set) var lastError: String?
    @Published private(set) var isRunning = false

    let sampleInterval: TimeInterval

    private let reader: any ProcessResourceCountersReading
    private let timeSource: ProcessResourceTimeSource
    private let scheduler: any ResourceMonitorScheduling
    private let logicalProcessorCount: Int
    private var scheduledTask: (any ResourceMonitorScheduleToken)?
    private var previousCPUCounter: (cpuTime: TimeInterval, uptime: TimeInterval)?

    init(
        sampleInterval: TimeInterval = 1,
        reader: any ProcessResourceCountersReading = SystemProcessResourceCountersReader(),
        timeSource: ProcessResourceTimeSource = .system,
        scheduler: any ResourceMonitorScheduling = RunLoopResourceMonitorScheduler(),
        logicalProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.sampleInterval = sampleInterval.isFinite && sampleInterval > 0
            ? sampleInterval
            : 1
        self.reader = reader
        self.timeSource = timeSource
        self.scheduler = scheduler
        self.logicalProcessorCount = max(1, logicalProcessorCount)
    }

    deinit {
        scheduledTask?.cancel()
    }

    func start() {
        guard scheduledTask == nil else { return }
        previousCPUCounter = nil
        isRunning = true
        sampleNow()
        scheduledTask = scheduler.schedule(every: sampleInterval) { [weak self] in
            self?.sampleNow()
        }
    }

    func stop() {
        scheduledTask?.cancel()
        scheduledTask = nil
        previousCPUCounter = nil
        isRunning = false
    }

    func sampleNow() {
        let uptime = timeSource.uptime()
        let sampledAt = timeSource.now()
        guard uptime.isFinite, uptime >= 0 else {
            lastError = ProcessResourceReadingError.invalidCounter.localizedDescription
            previousCPUCounter = nil
            return
        }

        do {
            let counters = try reader.readCounters()
            guard counters.cumulativeCPUTime.isFinite, counters.cumulativeCPUTime >= 0 else {
                throw ProcessResourceReadingError.invalidCounter
            }
            let cpuPercent = resolvedCPUPercent(
                currentCPUTime: counters.cumulativeCPUTime,
                currentUptime: uptime
            )
            snapshot = ProcessResourceSnapshot(
                residentMemoryBytes: counters.residentMemoryBytes,
                cpuPercent: cpuPercent,
                sampledAt: sampledAt
            )
            previousCPUCounter = (counters.cumulativeCPUTime, uptime)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            previousCPUCounter = nil
        }
    }

    private func resolvedCPUPercent(
        currentCPUTime: TimeInterval,
        currentUptime: TimeInterval
    ) -> Double? {
        guard let previousCPUCounter else { return nil }
        let elapsed = currentUptime - previousCPUCounter.uptime
        let consumedCPU = currentCPUTime - previousCPUCounter.cpuTime
        guard elapsed > 0, consumedCPU >= 0 else { return nil }
        // CPU time can advance on several cores simultaneously. Therefore a
        // busy 8-core process may report up to 800%, matching Activity Monitor.
        let percent = consumedCPU / elapsed * 100
        guard percent.isFinite else { return nil }
        return min(Double(logicalProcessorCount) * 100, max(0, percent))
    }
}
