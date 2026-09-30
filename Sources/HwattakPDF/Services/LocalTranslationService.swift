// SPDX-License-Identifier: MPL-2.0

import Foundation

struct LocalTranslationConfiguration: Codable, Equatable, Sendable {
    var baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:17862")!) {
        self.baseURL = baseURL
    }
}

struct LocalTranslationPack: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let sourceLanguage: String
    let targetLanguage: String
    let sourceName: String
    let targetName: String
    let version: String
}

enum LocalTranslationError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case invalidInput
    case helperUnavailable
    case invalidResponse
    case worker(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return L10n.string("translation.local.error.invalidEndpoint", defaultValue: "Use only this Mac’s loopback address and port, such as http://127.0.0.1:17862.")
        case .invalidInput:
            return L10n.string("translation.local.error.invalidInput", defaultValue: "Local translation supports up to 16,000 Unicode scalars and 256 paragraphs per request. Check the text and source and target languages.")
        case .helperUnavailable:
            return L10n.string("translation.local.error.helperUnavailable", defaultValue: "Could not connect to the local translation helper. Start the helper in a Python environment with Argos Translate installed, then check its address.")
        case .invalidResponse:
            return L10n.string("translation.local.error.invalidResponse", defaultValue: "The local helper returned an invalid response. Use the helper included with this version of the app.")
        case .worker(let code):
            switch code {
            case "runtimeMissing":
                return L10n.string("translation.local.error.runtimeMissing", defaultValue: "Argos Translate is missing from the helper’s Python environment. Install it in that environment and restart the helper.")
            case "pairMissing":
                return L10n.string("translation.local.error.pairMissing", defaultValue: "This language pair is not installed. Install its direct language pack or both packs needed to translate through English.")
            case "offlineResourcesMissing":
                return L10n.string("translation.local.error.offlineResourcesMissing", defaultValue: "Some offline model files are missing. Install the language pack from the catalog to prepare its tokenizer too. Translation never downloads files.")
            case "catalogFailed", "downloadFailed":
                return L10n.string("translation.local.error.downloadFailed", defaultValue: "Could not download the official language pack catalog or model. Check your internet connection and try again.")
            case "packMissing":
                return L10n.string("translation.local.error.packMissing", defaultValue: "This language pack is no longer in the official catalog. Refresh the catalog.")
            case "invalidArchive", "archiveConflict":
                return L10n.string("translation.local.error.invalidArchive", defaultValue: "The language pack is invalid or conflicts with an existing pack. Choose an official .argosmodel archive.")
            case "busy":
                return L10n.string("translation.local.error.busy", defaultValue: "The local translation helper is busy. Try again when its current operation finishes.")
            case "timedOut":
                return L10n.string("translation.local.error.timedOut", defaultValue: "The local translation operation timed out. Try again with less text.")
            case "cancelled":
                return L10n.string("translation.local.error.cancelled", defaultValue: "Local translation was cancelled.")
            case "inputTooLarge", "invalidInput":
                return LocalTranslationError.invalidInput.errorDescription
            default:
                return L10n.string("translation.local.error.failed", defaultValue: "Local translation failed. Check the language packs and Argos Translate installation.")
            }
        }
    }
}

/// The signed app stays sandboxed. The user's separately launched helper owns
/// Python and its language packs; PDF text only crosses literal loopback HTTP.
enum LocalTranslationService {
    static let maximumTextScalars = 16_000
    static let maximumParagraphs = 256
    static let maximumResponseBytes = 1_024 * 1_024

    static var bundledWorkerURL: URL? { bundledScriptURL(name: "translation_argos_worker", extension: "py") }
    static var bundledLauncherURL: URL? { bundledScriptURL(name: "start_local_translation", extension: "command") }

    private static func bundledScriptURL(name: String, extension suffix: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: suffix) {
            return url
        }
        #if DEBUG
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/\(name).\(suffix)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
        #else
        return nil
        #endif
    }

    static func translate(
        texts: [String], sourceLanguage: String, targetLanguage: String,
        configuration: LocalTranslationConfiguration,
        transport: any AIHTTPTransporting = URLSessionAIHTTPTransport()
    ) async throws -> [String] {
        guard !texts.isEmpty, texts.count <= maximumParagraphs,
              validLanguage(sourceLanguage), validLanguage(targetLanguage) else {
            throw LocalTranslationError.invalidInput
        }
        var scalarCount = 0
        for text in texts {
            guard text.utf8.count <= maximumTextScalars * 4 else { throw LocalTranslationError.invalidInput }
            scalarCount += text.unicodeScalars.count
            guard scalarCount <= maximumTextScalars else { throw LocalTranslationError.invalidInput }
        }
        guard scalarCount > 0 else { throw LocalTranslationError.invalidInput }
        let response = try await send(
            Request(action: "translate", texts: texts, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage),
            configuration: configuration, timeout: 185, transport: transport
        )
        guard let translations = response.translations, translations.count == texts.count,
              translations.enumerated().allSatisfy({ index, value in
                  value.utf8.count <= 128_000 && (texts[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              }) else {
            throw LocalTranslationError.invalidResponse
        }
        return translations
    }

    static func installedPacks(
        configuration: LocalTranslationConfiguration,
        transport: any AIHTTPTransporting = URLSessionAIHTTPTransport()
    ) async throws -> [LocalTranslationPack] {
        try validatedPacks(await send(Request(action: "installed"), configuration: configuration, timeout: 65, transport: transport))
    }

    /// This is an explicitly requested network operation. Translation never
    /// refreshes the catalog or installs a missing model implicitly.
    static func availablePacks(
        configuration: LocalTranslationConfiguration,
        transport: any AIHTTPTransporting = URLSessionAIHTTPTransport()
    ) async throws -> [LocalTranslationPack] {
        try validatedPacks(await send(Request(action: "available"), configuration: configuration, timeout: 95, transport: transport))
    }

    static func installPack(
        _ pack: LocalTranslationPack, configuration: LocalTranslationConfiguration,
        transport: any AIHTTPTransporting = URLSessionAIHTTPTransport()
    ) async throws {
        guard pack.id.utf8.count <= 160, !pack.id.isEmpty else { throw LocalTranslationError.invalidInput }
        _ = try await send(Request(action: "install", packID: pack.id), configuration: configuration, timeout: 605, transport: transport)
    }

    /// Call only with an archive explicitly selected by the user. The helper
    /// reads this local path directly; the app never uploads archive contents.
    static func importPack(
        at url: URL, configuration: LocalTranslationConfiguration,
        transport: any AIHTTPTransporting = URLSessionAIHTTPTransport()
    ) async throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "argosmodel", url.path.utf8.count <= 4_096 else {
            throw LocalTranslationError.invalidInput
        }
        _ = try await send(Request(action: "import", archivePath: url.path), configuration: configuration, timeout: 185, transport: transport)
    }

    static func isValidEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", components.host == "127.0.0.1",
              let port = components.port, (1...65_535).contains(port),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return false }
        // Reject percent-escaped host spelling and other authority ambiguities.
        return components.percentEncodedHost == "127.0.0.1"
    }

    private static func validLanguage(_ language: String) -> Bool {
        guard (2...24).contains(language.utf8.count) else { return false }
        return language.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private static func validatedPacks(_ response: Response) throws -> [LocalTranslationPack] {
        guard let packs = response.packs, packs.count <= 2_048,
              Set(packs.map(\.id)).count == packs.count,
              packs.allSatisfy({ pack in
                  !pack.id.isEmpty && pack.id.utf8.count <= 160 && validLanguage(pack.sourceLanguage)
                  && validLanguage(pack.targetLanguage) && pack.sourceName.utf8.count <= 256
                  && pack.targetName.utf8.count <= 256 && pack.version.utf8.count <= 64
              }) else { throw LocalTranslationError.invalidResponse }
        return packs
    }

    private struct Request: Encodable {
        var requestID = UUID().uuidString
        let action: String
        var texts: [String]? = nil
        var sourceLanguage: String? = nil
        var targetLanguage: String? = nil
        var packID: String? = nil
        var archivePath: String? = nil
    }

    private struct Response: Decodable {
        let ok: Bool
        var error: String?
        var translations: [String]?
        var packs: [LocalTranslationPack]?
    }

    private static func send(
        _ payload: Request, configuration: LocalTranslationConfiguration, timeout: TimeInterval,
        transport: any AIHTTPTransporting
    ) async throws -> Response {
        guard isValidEndpoint(configuration.baseURL) else { throw LocalTranslationError.invalidEndpoint }
        try Task.checkCancellation()
        let endpoint = configuration.baseURL.appendingPathComponent("v1/translation")
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)
        guard request.httpBody!.count <= 128 * 1_024 else { throw LocalTranslationError.invalidInput }
        return try await withTaskCancellationHandler {
            do {
                let result = try await transport.send(request)
                try Task.checkCancellation()
                guard result.data.count <= maximumResponseBytes,
                      let response = try? JSONDecoder().decode(Response.self, from: result.data) else {
                    throw LocalTranslationError.invalidResponse
                }
                guard response.ok else { throw LocalTranslationError.worker(response.error ?? "failed") }
                guard result.response.statusCode == 200 else { throw LocalTranslationError.invalidResponse }
                return response
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if error is LocalTranslationError { throw error }
                throw LocalTranslationError.helperUnavailable
            }
        } onCancel: {
            // Cancellation also terminates model inference in the helper. It
            // must use a fresh task/session because the original is cancelled.
            Task.detached {
                var cancel = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/cancel"), timeoutInterval: 3)
                cancel.httpMethod = "POST"
                cancel.setValue("application/json", forHTTPHeaderField: "Content-Type")
                cancel.httpBody = try? JSONEncoder().encode(["requestID": payload.requestID])
                _ = try? await URLSessionAIHTTPTransport().send(cancel)
            }
        }
    }
}
