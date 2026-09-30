// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PageTranslationExportPolicyTests: XCTestCase {
    func testSourceCannotBeOverwrittenThroughItsPathSymlinkOrHardLink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        let symlink = directory.appendingPathComponent("alias.pdf")
        let hardlink = directory.appendingPathComponent("hardlink.pdf")
        try Data("source".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardlink)
        for target in [source, symlink, hardlink] {
            XCTAssertTrue(PageTranslationExportPolicy.replacesSource(target, sourceURL: source))
        }
        let different = directory.appendingPathComponent("translation.pdf")
        XCTAssertFalse(PageTranslationExportPolicy.replacesSource(different, sourceURL: source))
        try Data("separate".utf8).write(to: different)
        XCTAssertFalse(PageTranslationExportPolicy.replacesSource(different, sourceURL: source))
        XCTAssertFalse(PageTranslationExportPolicy.replacesSource(different, sourceURL: nil))
    }
}
