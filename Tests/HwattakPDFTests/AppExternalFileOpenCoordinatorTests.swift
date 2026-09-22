// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import HwattakPDF

@MainActor
final class AppExternalFileOpenCoordinatorTests: XCTestCase {
    func testColdLaunchRequestWaitsForWindowBindingAndPresentsBeforeLoading() {
        let coordinator = AppExternalFileOpenCoordinator()
        let pdf = URL(fileURLWithPath: "/tmp/HwattakPDF-external-open.pdf")
        var events: [String] = []
        var opened: [URL] = []

        coordinator.enqueue([pdf])
        coordinator.flushPendingOpenRequests()
        coordinator.configure(
            presentMainWindow: { events.append("present") },
            openFiles: { urls in
                events.append("load")
                opened += urls
            }
        )
        coordinator.flushPendingOpenRequests()

        XCTAssertEqual(events, ["present", "load"])
        XCTAssertEqual(opened, [pdf])
    }

    func testNativeArrayAndIndividualURLBurstOpenEveryDistinctFileOnce() {
        let coordinator = AppExternalFileOpenCoordinator()
        let first = URL(fileURLWithPath: "/tmp/HwattakPDF-first.pdf")
        let second = URL(fileURLWithPath: "/tmp/HwattakPDF-second.pdf")
        let third = URL(fileURLWithPath: "/tmp/HwattakPDF-third.png")
        var batches: [[URL]] = []
        coordinator.configure(presentMainWindow: {}, openFiles: { batches.append($0) })

        coordinator.enqueue([first, second])
        coordinator.enqueue([second])
        coordinator.enqueue([third, URL(string: "https://example.com/remote.pdf")!])
        coordinator.flushPendingOpenRequests()
        coordinator.flushPendingOpenRequests()

        XCTAssertEqual(batches, [[first, second, third]])
    }

    func testRebindingWindowDoesNotLoseQueuedFilesOrOpenThemTwice() {
        let coordinator = AppExternalFileOpenCoordinator()
        let pdf = URL(fileURLWithPath: "/tmp/HwattakPDF-reopened.pdf")
        var firstLoads = 0
        var reopenedLoads: [[URL]] = []
        coordinator.configure(presentMainWindow: {}, openFiles: { _ in firstLoads += 1 })
        coordinator.enqueue([pdf])

        // Simulate the newly shown scene replacing its presentation callbacks
        // before the initial URL burst has reached its loading deadline.
        coordinator.configure(presentMainWindow: {}, openFiles: { reopenedLoads.append($0) })
        coordinator.flushPendingOpenRequests()
        coordinator.configure(presentMainWindow: {}, openFiles: { reopenedLoads.append($0) })
        coordinator.flushPendingOpenRequests()

        XCTAssertEqual(firstLoads, 0)
        XCTAssertEqual(reopenedLoads, [[pdf]])
    }

    func testWindowClosingDuringCoalescingIsPresentedAgainBeforeLoading() {
        let coordinator = AppExternalFileOpenCoordinator()
        let pdf = URL(fileURLWithPath: "/tmp/HwattakPDF-window-closed.pdf")
        var events: [String] = []
        var opened: [URL] = []
        coordinator.configure(
            presentMainWindow: { events.append("present") },
            openFiles: {
                events.append("load")
                opened += $0
            }
        )

        coordinator.enqueue([pdf])
        coordinator.mainWindowDidDisappear()
        XCTAssertEqual(events, ["present"])
        coordinator.flushPendingOpenRequests()

        XCTAssertEqual(events, ["present", "present", "load"])
        XCTAssertEqual(opened, [pdf])
    }

    func testNonFileURLsDoNotShowWindowOrReachDocumentLoader() {
        let coordinator = AppExternalFileOpenCoordinator()
        var presentations = 0
        var loads = 0
        coordinator.configure(
            presentMainWindow: { presentations += 1 },
            openFiles: { _ in loads += 1 }
        )

        coordinator.enqueue([URL(string: "https://example.com/document.pdf")!])
        coordinator.flushPendingOpenRequests()

        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(loads, 0)
    }

    func testTimerDeliversCoalescedRequestsAndAllowsLaterReopenOfSameFile() async throws {
        let coordinator = AppExternalFileOpenCoordinator(coalescingDelay: .milliseconds(5))
        let pdf = URL(fileURLWithPath: "/tmp/HwattakPDF-timer.pdf")
        var batches: [[URL]] = []
        coordinator.configure(presentMainWindow: {}, openFiles: { batches.append($0) })

        coordinator.enqueue([pdf])
        coordinator.enqueue([pdf])
        try await waitUntil { batches.count == 1 }
        XCTAssertEqual(batches, [[pdf]])

        coordinator.enqueue([pdf])
        try await waitUntil { batches.count == 2 }
        XCTAssertEqual(batches, [[pdf], [pdf]])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "The application-level URL queue did not drain.")
    }
}
