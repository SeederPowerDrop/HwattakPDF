// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import UniformTypeIdentifiers

/// Reads the system-wide PDF association. App Sandbox does not permit changing
/// that association, so the user completes it in Finder's Get Info window.
/// Never infer success from opening Finder or persist a local "default" flag.
@MainActor
final class DefaultPDFApplicationModel: ObservableObject {
    enum Feedback: Equatable {
        case finderInstructions
        case failure(String)
    }

    @Published private(set) var currentApplicationURL: URL?
    @Published private(set) var currentApplicationName: String?
    @Published private(set) var isPreparing = false
    @Published private(set) var feedback: Feedback?

    let applicationURL: URL?
    private let lookupApplication: @MainActor () -> URL?
    private let applicationName: @MainActor (URL) -> String
    private let prepareSetupPDF: @MainActor () throws -> URL
    private let revealFile: @MainActor (URL) -> Void

    init(
        applicationURL: URL? = DefaultPDFApplicationModel.bundledApplicationURL(),
        lookupApplication: @escaping @MainActor () -> URL? = {
            NSWorkspace.shared.urlForApplication(toOpen: .pdf)
        },
        applicationName: @escaping @MainActor (URL) -> String = { url in
            let bundle = Bundle(url: url)
            return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        },
        prepareSetupPDF: @escaping @MainActor () throws -> URL = { try DefaultPDFSetupFile.prepare() },
        revealFile: @escaping @MainActor (URL) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        }
    ) {
        self.applicationURL = applicationURL
        self.lookupApplication = lookupApplication
        self.applicationName = applicationName
        self.prepareSetupPDF = prepareSetupPDF
        self.revealFile = revealFile
    }

    var isDefault: Bool {
        guard let applicationURL, let currentApplicationURL else { return false }
        // Several released/candidate copies can share a bundle identifier.
        // Report success only for the copy whose Settings window is in use.
        return applicationURL.resolvingSymlinksInPath().standardizedFileURL
            == currentApplicationURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func refresh() {
        currentApplicationURL = lookupApplication()
        currentApplicationName = currentApplicationURL.map(applicationName)
        feedback = nil
    }

    func showSetupInFinder() {
        guard applicationURL != nil, !isPreparing else { return }
        isPreparing = true
        feedback = nil
        defer { isPreparing = false }

        do {
            let url = try prepareSetupPDF()
            revealFile(url)
            feedback = .finderInstructions
        } catch {
            feedback = .failure(error.localizedDescription)
        }
    }

    /// `swift run` and XCTest are executables, not installable app bundles.
    nonisolated static func bundledApplicationURL(in bundle: Bundle = .main) -> URL? {
        guard bundle.bundleURL.pathExtension.lowercased() == "app",
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty,
              let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        return bundle.bundleURL
    }
}

/// A disposable, one-page PDF lets Finder change the PDF type association
/// without asking the user to locate or modify one of their own documents.
@MainActor
enum DefaultPDFSetupFile {
    static func prepare(cacheDirectory: URL? = nil) throws -> URL {
        let cacheRoot: URL
        if let cacheDirectory {
            cacheRoot = cacheDirectory
        } else {
            cacheRoot = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let directory = cacheRoot.appendingPathComponent("HwattakPDF/DefaultPDFApplication", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("HwattakPDF.pdf")

        // Re-create a valid file if a previous setup PDF was edited or deleted.
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("HwattakPDF" as NSString).draw(
            at: NSPoint(x: 48, y: 742),
            withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
        return url
    }
}
