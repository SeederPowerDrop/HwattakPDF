// SPDX-License-Identifier: MPL-2.0

import AppKit
import XCTest
@testable import HwattakPDF

@MainActor
final class AppAppearanceTests: XCTestCase {
    func testFirstLaunchAndUnrecognizedSavedValueFollowSystem() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppPreferences(defaults: defaults, appearanceDidChange: { _ in }).appearance, .system)
        defaults.set("obsolete", forKey: AppPreferences.appearanceDefaultsKey)
        XCTAssertEqual(AppPreferences(defaults: defaults, appearanceDidChange: { _ in }).appearance, .system)
    }

    func testEachChoiceAppliesImmediatelyAndSurvivesRelaunch() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var applied: [AppAppearance] = []
        let preferences = AppPreferences(defaults: defaults) { applied.append($0) }

        for appearance in [AppAppearance.dark, .light, .system] {
            preferences.appearance = appearance
            XCTAssertEqual(applied.last, appearance)
            XCTAssertEqual(defaults.string(forKey: AppPreferences.appearanceDefaultsKey), appearance.rawValue)
            var restored: AppAppearance?
            let relaunched = AppPreferences(defaults: defaults) { restored = $0 }
            relaunched.applyAppearance()
            XCTAssertEqual(restored, appearance)
        }
        XCTAssertEqual(applied, [.dark, .light, .system])
    }

    func testSelectingCurrentModeDoesNotReapplyOrAffectLanguage() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppLanguage.french.rawValue, forKey: AppPreferences.languageDefaultsKey)
        defaults.set(AppAppearance.dark.rawValue, forKey: AppPreferences.appearanceDefaultsKey)
        var calls = 0
        let preferences = AppPreferences(defaults: defaults) { _ in calls += 1 }
        preferences.appearance = .dark
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(preferences.language, .french)
        XCTAssertEqual(defaults.string(forKey: AppPreferences.languageDefaultsKey), "fr")
    }

    func testAppOverrideReachesExistingAndNewNativeWindowsAndCanReturnToSystem() async throws {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }
        let existing = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        existing.contentView = NSView(frame: existing.contentRect(forFrameRect: existing.frame))

        AppAppearance.dark.apply()
        try await waitForAppearance(.darkAqua, in: existing)
        XCTAssertEqual(existing.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(existing.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)

        AppAppearance.light.apply()
        try await waitForAppearance(.aqua, in: existing)
        try await waitForAppearance(.aqua, in: panel)
        XCTAssertEqual(existing.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        AppAppearance.system.apply()
        try await waitForAppearance(
            app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])!, in: existing
        )
        XCTAssertNil(app.appearance)
        XCTAssertEqual(existing.effectiveAppearance.name, app.effectiveAppearance.name)
        XCTAssertNil(existing.appearance)
        XCTAssertNil(panel.appearance)
    }

    private func waitForAppearance(_ name: NSAppearance.Name, in window: NSWindow) async throws {
        // AppKit propagates an app-wide change on the next event-loop pass.
        for _ in 0..<100 {
            if window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "HwattakPDF.AppAppearanceTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}
