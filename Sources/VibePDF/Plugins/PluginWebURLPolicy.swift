// SPDX-License-Identifier: MPL-2.0

import Foundation

enum PluginWebNavigationScope: Equatable {
    case publicWeb
    case youtube
    case exactHosts(Set<String>)
}

enum PluginYouTubeUserLinkRoute: Equatable {
    case playInPanel(URL)
    case openExternally(URL)
    case blocked
}

/// Pure URL policy shared by manifest validation, the action runner, address
/// bars, and WebKit's final navigation delegate.
enum PluginWebURLPolicy {
    static func appIdentityReferer(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL {
        let fallback = "com.vibepdf.mac"
        let candidate = (bundleIdentifier ?? fallback).lowercased()
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-"
        )
        let safeIdentifier = candidate.unicodeScalars.allSatisfy(allowed.contains)
            && candidate.contains(".")
            && !candidate.contains("..")
            ? candidate
            : fallback
        return URL(string: "https://\(safeIdentifier)/")!
    }

    static func originDescription(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased() ?? "https"
        let host = components?.percentEncodedHost
            ?? url.host?.lowercased()
            ?? "unknown-host"
        let effectivePort = components?.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(effectivePort)"
    }

    static func allows(_ url: URL, scope: PluginWebNavigationScope) -> Bool {
        guard
            url.absoluteString.utf8.count <= HwattakPluginLimits.maximumExternalURLUTF8Bytes,
            url.scheme?.lowercased() == "https",
            url.port == nil || url.port == 443,
            AIEndpointPolicy.isValidExternalWebURL(url)
        else {
            return false
        }
        switch scope {
        case .publicWeb:
            return true
        case .youtube:
            return allowsYouTubeTopLevelURL(url)
        case let .exactHosts(hosts):
            return hosts.contains(url.host?.lowercased() ?? "")
        }
    }

    static func publicWebDestination(
        from input: String,
        searchEngine: PluginWebSearchEngine = .google
    ) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let explicit = URL(string: trimmed), explicit.scheme != nil {
            return allows(explicit, scope: .publicWeb) ? explicit : nil
        }
        if !trimmed.contains(where: \.isWhitespace), trimmed.contains(".") {
            let candidate = URL(string: "https://\(trimmed)")
            if let candidate, allows(candidate, scope: .publicWeb) {
                return candidate
            }
        }
        var components = URLComponents(
            url: searchEngine.searchURL,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: searchEngine.queryItemName, value: trimmed)
        ]
        guard let searchURL = components?.url,
              allows(searchURL, scope: .publicWeb) else {
            return nil
        }
        return searchURL
    }

    static func youtubeDestination(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: URL?
        if let explicit = URL(string: trimmed), explicit.scheme != nil {
            candidate = explicit
        } else if !trimmed.contains(where: \.isWhitespace), trimmed.contains(".") {
            candidate = URL(string: "https://\(trimmed)")
        } else {
            candidate = nil
        }

        if let candidate {
            return privacyEnhancedYouTubeURL(from: candidate)
        }

        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: trimmed)]
        guard let searchURL = components?.url,
              allows(searchURL, scope: .youtube) else {
            return nil
        }
        return searchURL
    }

    /// Routes only links that WebKit has identified as an actual user click.
    /// Video links stay in the privacy-enhanced in-app player; other links on
    /// an exact YouTube host can be handed to the system browser after host UI
    /// obtains confirmation. Script-created navigation must never call this
    /// helper and continues through the narrower in-panel policy.
    static func youtubeUserLinkRoute(for url: URL) -> PluginYouTubeUserLinkRoute {
        guard allowsYouTubeExternalLink(url) else { return .blocked }
        if let privateURL = privacyEnhancedYouTubeURL(from: url) {
            return .playInPanel(privateURL)
        }
        return .openExternally(url)
    }

    /// Converts ordinary watch/share/short URLs to YouTube's documented
    /// privacy-enhanced embed host. Only the validated 11-character video ID
    /// is carried into the resulting URL.
    static func privacyEnhancedYouTubeURL(from url: URL) -> URL? {
        guard
            url.scheme?.lowercased() == "https",
            url.port == nil || url.port == 443,
            AIEndpointPolicy.isValidExternalWebURL(url),
            isYouTubeHost(url.host?.lowercased() ?? "")
        else {
            return nil
        }
        let host = url.host?.lowercased() ?? ""
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let videoID: String?

        if host == "youtu.be" {
            videoID = pathComponents.first
        } else if pathComponents.first == "watch" {
            videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "v" })?
                .value
        } else if let first = pathComponents.first,
                  ["embed", "shorts", "live"].contains(first),
                  pathComponents.count > 1 {
            videoID = pathComponents[1]
        } else {
            videoID = nil
        }

        guard let videoID, isSafeYouTubeVideoID(videoID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube-nocookie.com"
        components.path = "/embed/\(videoID)"
        components.queryItems = [
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0")
        ]
        return components.url
    }

    static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtu.be"
            || host == "youtube.com"
            || host == "www.youtube.com"
            || host == "m.youtube.com"
            || host == "youtube-nocookie.com"
            || host == "www.youtube-nocookie.com"
    }

    private static func allowsYouTubeExternalLink(_ url: URL) -> Bool {
        guard
            url.absoluteString.utf8.count <= HwattakPluginLimits.maximumExternalURLUTF8Bytes,
            url.scheme?.lowercased() == "https",
            url.port == nil || url.port == 443,
            AIEndpointPolicy.isValidExternalWebURL(url)
        else {
            return false
        }
        return isYouTubeHost(url.host?.lowercased() ?? "")
    }

    private static func allowsYouTubeTopLevelURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if host == "www.youtube-nocookie.com" || host == "youtube-nocookie.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2,
                  parts[0] == "embed",
                  isSafeYouTubeVideoID(parts[1]),
                  url.fragment == nil else {
                return false
            }
            let queryItems = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []
            guard queryItems.count == 2,
                  Set(queryItems.map(\.name)).count == queryItems.count else {
                return false
            }
            let values = Dictionary(
                uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) }
            )
            return values["playsinline"] == "1" && values["rel"] == "0"
        }
        guard host == "www.youtube.com" || host == "m.youtube.com" else {
            return false
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first else { return true }
        return ["results", "watch", "shorts", "live"].contains(first)
    }

    private static func isSafeYouTubeVideoID(_ value: String) -> Bool {
        value.utf8.count == 11
            && value.unicodeScalars.allSatisfy { scalar in
                (0x41...0x5A).contains(scalar.value)
                    || (0x61...0x7A).contains(scalar.value)
                    || (0x30...0x39).contains(scalar.value)
                    || scalar.value == 0x2D
                    || scalar.value == 0x5F
            }
    }
}
