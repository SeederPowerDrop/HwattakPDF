// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VibePDF

final class PluginWebURLPolicyTests: XCTestCase {
    func testPublicWebScopeAcceptsOnlyBoundedPublicHTTPSOrigins() throws {
        let accepted = [
            "https://example.com/",
            "https://docs.example.com/path?q=pdf#section",
            "https://example.com:443/"
        ]
        for value in accepted {
            XCTAssertTrue(
                PluginWebURLPolicy.allows(try XCTUnwrap(URL(string: value)), scope: .publicWeb),
                value
            )
        }

        let rejected = [
            "http://example.com/",
            "file:///tmp/private.pdf",
            "data:text/html,hello",
            "javascript:alert(1)",
            "about:blank",
            "blob:https://example.com/id",
            "ftp://example.com/file",
            "mailto:person@example.com",
            "tel:+33123456789",
            "wss://example.com/socket",
            "https://localhost/",
            "https://127.0.0.1/",
            "https://127.1/",
            "https://0x7f000001/",
            "https://0177.0.0.1/",
            "https://2130706433/",
            "https://[::1]/",
            "https://printer.local/",
            "https://printer/",
            "https://user:secret@example.com/",
            "https://example.com:444/"
        ]
        for value in rejected {
            XCTAssertFalse(
                PluginWebURLPolicy.allows(try XCTUnwrap(URL(string: value)), scope: .publicWeb),
                value
            )
        }

        let oversized = "https://example.com/" + String(
            repeating: "a",
            count: HwattakPluginLimits.maximumExternalURLUTF8Bytes
        )
        XCTAssertFalse(
            PluginWebURLPolicy.allows(try XCTUnwrap(URL(string: oversized)), scope: .publicWeb)
        )
    }

    func testExactHostScopeDoesNotAcceptSuffixConfusionOrAlternatePorts() throws {
        let scope = PluginWebNavigationScope.exactHosts(["chatgpt.com"])
        XCTAssertTrue(
            PluginWebURLPolicy.allows(
                try XCTUnwrap(URL(string: "https://chatgpt.com/")),
                scope: scope
            )
        )
        for value in [
            "https://evilchatgpt.com/",
            "https://chatgpt.com.evil.example/",
            "https://sub.chatgpt.com/",
            "https://chatgpt.com:8443/",
            "https://name@chatgpt.com/"
        ] {
            XCTAssertFalse(
                PluginWebURLPolicy.allows(try XCTUnwrap(URL(string: value)), scope: scope),
                value
            )
        }
        XCTAssertEqual(
            PluginWebURLPolicy.originDescription(
                for: try XCTUnwrap(URL(string: "https://chatgpt.com/path"))
            ),
            "https://chatgpt.com:443"
        )
        XCTAssertEqual(
            PluginWebURLPolicy.appIdentityReferer(
                bundleIdentifier: "COM.Example.PDF"
            ).absoluteString,
            "https://com.example.pdf/"
        )
        XCTAssertEqual(
            PluginWebURLPolicy.appIdentityReferer(
                bundleIdentifier: "bad/id"
            ).absoluteString,
            "https://com.vibepdf.mac/"
        )
    }

    func testAddressResolverRejectsExplicitUnsafeURLsInsteadOfSearchingForThem() throws {
        XCTAssertEqual(
            PluginWebURLPolicy.publicWebDestination(from: "example.com")?.absoluteString,
            "https://example.com"
        )
        XCTAssertNil(PluginWebURLPolicy.publicWebDestination(from: "http://example.com"))
        XCTAssertNil(PluginWebURLPolicy.publicWebDestination(from: "file:///tmp/private.pdf"))
        let search = try XCTUnwrap(
            PluginWebURLPolicy.publicWebDestination(from: "PDF 공부 방법")
        )
        XCTAssertEqual(search.host, "www.google.com")
        XCTAssertEqual(
            URLComponents(url: search, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value,
            "PDF 공부 방법"
        )

        for engine in PluginWebSearchEngine.allCases {
            let destination = try XCTUnwrap(
                PluginWebURLPolicy.publicWebDestination(
                    from: "논문 읽기",
                    searchEngine: engine
                )
            )
            XCTAssertEqual(destination.host, engine.searchURL.host)
            XCTAssertEqual(
                URLComponents(url: destination, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == engine.queryItemName })?.value,
                "논문 읽기"
            )
            XCTAssertTrue(PluginWebURLPolicy.allows(destination, scope: .publicWeb))
        }
    }

    func testYouTubeVideoURLsCanonicalizeToPrivacyEnhancedASCIIEmbed() throws {
        let videoID = "dQw4w9WgXcQ"
        let inputs = [
            "https://www.youtube.com/watch?v=\(videoID)&feature=share",
            "https://youtu.be/\(videoID)?t=20",
            "https://www.youtube.com/shorts/\(videoID)",
            "https://m.youtube.com/live/\(videoID)"
        ]
        for value in inputs {
            let canonical = try XCTUnwrap(
                PluginWebURLPolicy.privacyEnhancedYouTubeURL(
                    from: try XCTUnwrap(URL(string: value))
                ),
                value
            )
            XCTAssertEqual(canonical.host, "www.youtube-nocookie.com")
            XCTAssertEqual(canonical.path, "/embed/\(videoID)")
            XCTAssertTrue(PluginWebURLPolicy.allows(canonical, scope: .youtube))
        }

        let rejected = [
            "https://youtube.com.evil.example/watch?v=\(videoID)",
            "https://www.youtube.com/watch?v=short",
            "https://www.youtube.com/watch?v=abcdéfghijk",
            "http://www.youtube.com/watch?v=\(videoID)",
            "https://www.youtube.com:444/watch?v=\(videoID)"
        ]
        for value in rejected {
            XCTAssertNil(
                PluginWebURLPolicy.privacyEnhancedYouTubeURL(
                    from: try XCTUnwrap(URL(string: value))
                ),
                value
            )
            XCTAssertNil(PluginWebURLPolicy.youtubeDestination(from: value), value)
        }
    }

    func testYouTubeNavigationPolicyAndManifestPolicyShareTheSameNarrowHosts() throws {
        let allowed = [
            "https://www.youtube.com/",
            "https://www.youtube.com/results?search_query=swift",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0"
        ]
        for value in allowed {
            XCTAssertTrue(
                PluginWebURLPolicy.allows(try XCTUnwrap(URL(string: value)), scope: .youtube),
                value
            )
        }
        let rejected = [
            "https://youtube.com/",
            "https://music.youtube.com/",
            "https://evil.youtube.com/",
            "https://www.youtube.com/account",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?origin=https://evil.example",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?rel=1",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?rel=0&rel=0",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ#fragment",
            "https://www.youtube-nocookie.com/embed/abcdéfghijk"
        ]
        for value in rejected {
            XCTAssertFalse(
                PluginWebURLPolicy.allows(try XCTUnwrap(URL(string: value)), scope: .youtube),
                value
            )
        }
    }

    func testYouTubeUserLinkRoutingKeepsVideosInPanelAndOnlyExportsYouTubeHosts() throws {
        let videoID = "dQw4w9WgXcQ"
        for value in [
            "https://www.youtube.com/watch?v=\(videoID)&feature=share",
            "https://youtu.be/\(videoID)?t=40",
            "https://www.youtube.com/shorts/\(videoID)"
        ] {
            guard case let .playInPanel(destination) =
                PluginWebURLPolicy.youtubeUserLinkRoute(
                    for: try XCTUnwrap(URL(string: value))
                ) else {
                XCTFail("Expected a private in-panel route: \(value)")
                continue
            }
            XCTAssertEqual(destination.host, "www.youtube-nocookie.com")
            XCTAssertEqual(destination.path, "/embed/\(videoID)")
            XCTAssertTrue(PluginWebURLPolicy.allows(destination, scope: .youtube))
        }

        for value in [
            "https://www.youtube.com/channel/UC1234567890",
            "https://www.youtube.com/@creator",
            "https://www.youtube.com/t/terms",
            "https://youtube.com/"
        ] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(
                PluginWebURLPolicy.youtubeUserLinkRoute(for: url),
                .openExternally(url),
                value
            )
        }

        for value in [
            "https://youtube.com.evil.example/channel/test",
            "https://support.google.com/youtube/answer/1",
            "http://www.youtube.com/channel/test",
            "https://www.youtube.com:444/channel/test",
            "https://user:password@www.youtube.com/channel/test",
            "file:///tmp/video"
        ] {
            XCTAssertEqual(
                PluginWebURLPolicy.youtubeUserLinkRoute(
                    for: try XCTUnwrap(URL(string: value))
                ),
                .blocked,
                value
            )
        }
    }

    func testSecureWebViewSourceKeepsCriticalHostOwnedBarriers() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot.appendingPathComponent(
            "Sources/VibePDF/Views/PluginPanelHostView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for required in [
            "configuration.websiteDataStore = .nonPersistent()",
            "configuration.preferences.javaScriptCanOpenWindowsAutomatically = false",
            "configuration.mediaTypesRequiringUserActionForPlayback = .all",
            "pauseAllMediaPlayback",
            ".id(request.id)",
            "PluginSecureWKWebView",
            "override func performDragOperation",
            "revokeFileDropRegistrations",
            "configuration.userContentController.addUserScript",
            "event.stopImmediatePropagation()",
            "PluginWebURLPolicy.appIdentityReferer().absoluteString",
            "navigationAction.navigationType == .linkActivated",
            "PluginWebURLPolicy.youtubeUserLinkRoute(for: url)",
            "confirmOpenYouTubeLinkExternally",
            "completionHandler(nil)",
            "decisionHandler(.deny)",
            "decisionHandler(false)",
            "createWebViewWith configuration",
            "PluginWebURLPolicy.allows(responseURL",
            ".performDefaultHandling",
            "navigationAction.shouldPerformDownload",
            "Content-Disposition",
            "application/octet-stream"
        ] {
            XCTAssertTrue(source.contains(required), "Missing WebKit barrier: \(required)")
        }
        XCTAssertFalse(source.contains("addScriptMessageHandler"))
        XCTAssertFalse(source.contains("evaluateJavaScript"))
        XCTAssertFalse(source.contains("setURLSchemeHandler"))
        XCTAssertFalse(source.contains("callAsyncJavaScript"))

        let workspaceSource = try String(
            contentsOf: projectRoot.appendingPathComponent(
                "Sources/VibePDF/Views/WorkspaceView.swift"
            ),
            encoding: .utf8
        )
        for required in [
            ".onChange(of: isActive)",
            ".onChange(of: scenePhase)",
            ".onChange(of: workspace.mode)",
            ".onChange(of: workspace.revision)",
            ".onReceive(pluginManager.$installedPlugins)",
            "request.manifestDigest",
            "workspace.pluginPanelRequest = nil"
        ] {
            XCTAssertTrue(
                workspaceSource.contains(required),
                "Missing panel revocation boundary: \(required)"
            )
        }
    }

    func testPackagedSandboxGrantsClientNetworkButNoServerCameraOrMicrophone() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlements = try propertyList(
            at: projectRoot.appendingPathComponent("Resources/VibePDF.entitlements")
        )
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.network.client"] as? Bool, true)
        XCTAssertNil(entitlements["com.apple.security.network.server"])
        XCTAssertNil(entitlements["com.apple.security.device.camera"])
        XCTAssertNil(entitlements["com.apple.security.device.audio-input"])

        let info = try propertyList(
            at: projectRoot.appendingPathComponent("Resources/Info.plist")
        )
        XCTAssertNil(info["NSCameraUsageDescription"])
        XCTAssertNil(info["NSMicrophoneUsageDescription"])
        let transport = info["NSAppTransportSecurity"] as? [String: Any]
        XCTAssertNotEqual(transport?["NSAllowsArbitraryLoads"] as? Bool, true)
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(value as? [String: Any])
    }
}
