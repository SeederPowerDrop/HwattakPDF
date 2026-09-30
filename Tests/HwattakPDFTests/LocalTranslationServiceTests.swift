// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class LocalTranslationServiceTests: XCTestCase {
    func testEndpointOnlyAcceptsLiteralLoopbackAndExplicitPort() {
        XCTAssertTrue(LocalTranslationService.isValidEndpoint(URL(string: "http://127.0.0.1:17862")!))
        XCTAssertTrue(LocalTranslationService.isValidEndpoint(URL(string: "http://127.0.0.1:3000/")!))
        for value in ["https://127.0.0.1:17862", "http://localhost:17862", "http://127.1:17862", "http://2130706433:17862", "http://example.com:17862", "http://user@127.0.0.1:17862", "http://127.0.0.1:17862/path", "http://127.0.0.1:17862?next=remote", "http://127.0.0.1:17862#fragment", "http://127.0.0.1"] {
            XCTAssertFalse(LocalTranslationService.isValidEndpoint(URL(string: value)!), value)
        }
    }

    func testTranslationUsesJSONPostWithNoSourceInURL() async throws {
        let transport = LocalTranslationTestTransport(json: ["ok": true, "translations": ["안녕하세요", "다음 문단"]])
        let result = try await LocalTranslationService.translate(texts: ["Hello confidential text", "Next paragraph"], sourceLanguage: "en", targetLanguage: "ko", configuration: .init(), transport: transport)
        XCTAssertEqual(result, ["안녕하세요", "다음 문단"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:17862/v1/translation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["texts"] as? [String], ["Hello confidential text", "Next paragraph"])
        XCTAssertEqual(body["action"] as? String, "translate")
        XCTAssertNotNil(UUID(uuidString: body["requestID"] as? String ?? ""))
    }

    func testOversizedInputRejectedBeforeSending() async {
        let transport = LocalTranslationTestTransport(json: ["ok": true])
        do {
            _ = try await LocalTranslationService.translate(texts: [String(repeating: "a", count: 16_001)], sourceLanguage: "en", targetLanguage: "ko", configuration: .init(), transport: transport)
            XCTFail("Oversized input accepted")
        } catch {
            XCTAssertEqual(error as? LocalTranslationError, .invalidInput)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testGraphemeCombiningMarksCannotBypassScalarLimit() async {
        let transport = LocalTranslationTestTransport(json: ["ok": true])
        do {
            _ = try await LocalTranslationService.translate(texts: ["a" + String(repeating: "\u{0301}", count: 16_000)], sourceLanguage: "en", targetLanguage: "ko", configuration: .init(), transport: transport)
            XCTFail("Oversized scalar input accepted")
        } catch {
            XCTAssertEqual(error as? LocalTranslationError, .invalidInput)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRemoteEndpointRejectedBeforeSendingPDFText() async {
        let transport = LocalTranslationTestTransport(json: ["ok": true])
        do {
            _ = try await LocalTranslationService.translate(texts: ["Secret"], sourceLanguage: "en", targetLanguage: "ko", configuration: .init(baseURL: URL(string: "https://example.com:17862")!), transport: transport)
            XCTFail("Remote endpoint accepted")
        } catch {
            XCTAssertEqual(error as? LocalTranslationError, .invalidEndpoint)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMissingOrEmptyParagraphResultCannotBecomeSuccess() async {
        for values in [[], [""], ["   "], ["one", "extra"]] {
            let transport = LocalTranslationTestTransport(json: ["ok": true, "translations": values])
            do {
                _ = try await LocalTranslationService.translate(texts: ["Source"], sourceLanguage: "en", targetLanguage: "ko", configuration: .init(), transport: transport)
                XCTFail("Incomplete translation accepted")
            } catch {
                XCTAssertEqual(error as? LocalTranslationError, .invalidResponse)
            }
        }
    }

    func testWorkerErrorUsesStableCodeWithoutRawHelperMessage() async {
        let transport = LocalTranslationTestTransport(json: ["ok": false, "error": "pairMissing", "message": "secret text"])
        do {
            _ = try await LocalTranslationService.translate(texts: ["Source"], sourceLanguage: "en", targetLanguage: "ko", configuration: .init(), transport: transport)
            XCTFail("Error response accepted")
        } catch {
            XCTAssertEqual(error as? LocalTranslationError, .worker("pairMissing"))
            XCTAssertFalse(error.localizedDescription.contains("secret text"))
        }
    }

    func testCatalogAndInstallAreExplicitSeparateOperations() async throws {
        let pack = LocalTranslationPack(id: "en_ko@1.9", sourceLanguage: "en", targetLanguage: "ko", sourceName: "English", targetName: "Korean", version: "1.9")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pack))
        let transport = LocalTranslationTestTransport(json: ["ok": true, "packs": [object]])
        let installed = try await LocalTranslationService.installedPacks(configuration: .init(), transport: transport)
        let available = try await LocalTranslationService.availablePacks(configuration: .init(), transport: transport)
        try await LocalTranslationService.installPack(pack, configuration: .init(), transport: transport)
        XCTAssertEqual(installed, [pack])
        XCTAssertEqual(available, [pack])
        let bodies = try transport.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any]) }
        XCTAssertEqual(bodies.compactMap { $0["action"] as? String }, ["installed", "available", "install"])
        XCTAssertEqual(bodies[2]["packID"] as? String, "en_ko@1.9")
        XCTAssertNil(bodies[2]["url"])
    }
}

private final class LocalTranslationTestTransport: AIHTTPTransporting {
    var requests: [URLRequest] = []
    let json: [String: Any]
    init(json: [String: Any]) { self.json = json }
    func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        return AIHTTPResponse(data: try JSONSerialization.data(withJSONObject: json), response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
