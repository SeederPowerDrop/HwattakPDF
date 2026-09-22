// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

enum AIProviderKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case openAI
    case anthropic
    case gemini
    case deepSeek
    case qwen
    case customOpenAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Claude (Anthropic)"
        case .gemini: "Gemini (Google)"
        case .deepSeek: "DeepSeek"
        case .qwen: "Qwen (Alibaba Cloud)"
        case .customOpenAICompatible: "OpenAI-compatible"
        }
    }

    var defaultConfiguration: AIProviderConfiguration {
        switch self {
        case .openAI:
            AIProviderConfiguration(
                name: displayName,
                kind: self,
                model: "gpt-5.6",
                baseURL: URL(string: "https://api.openai.com/v1")!
            )
        case .anthropic:
            AIProviderConfiguration(
                name: displayName,
                kind: self,
                model: "claude-sonnet-5",
                baseURL: URL(string: "https://api.anthropic.com/v1")!
            )
        case .gemini:
            AIProviderConfiguration(
                name: displayName,
                kind: self,
                model: "gemini-3.6-flash",
                baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!
            )
        case .deepSeek:
            AIProviderConfiguration(
                name: displayName,
                kind: self,
                model: "deepseek-v4-flash",
                baseURL: URL(string: "https://api.deepseek.com")!
            )
        case .qwen:
            AIProviderConfiguration(
                name: displayName,
                kind: self,
                model: "qwen3.7-flash",
                baseURL: URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")!
            )
        case .customOpenAICompatible:
            AIProviderConfiguration(
                name: displayName,
                kind: self,
                model: "model-name",
                baseURL: URL(string: "https://api.example.com/v1")!,
                requiresAPIKey: false
            )
        }
    }
}

struct AIProviderCapabilities: Codable, Equatable {
    let supportsWebSearch: Bool
    let supportsRemoteMCP: Bool
    let returnsSourceCitations: Bool
    let supportsSystemPrompt: Bool

    static func capabilities(for kind: AIProviderKind) -> AIProviderCapabilities {
        switch kind {
        case .openAI:
            AIProviderCapabilities(
                supportsWebSearch: true,
                supportsRemoteMCP: true,
                returnsSourceCitations: true,
                supportsSystemPrompt: true
            )
        case .gemini:
            AIProviderCapabilities(
                // Google Search grounding requires rendering Google's Search
                // Suggestions attribution UI. Keep request generation gated
                // off until that required presentation is implemented.
                supportsWebSearch: false,
                supportsRemoteMCP: false,
                returnsSourceCitations: true,
                supportsSystemPrompt: true
            )
        case .anthropic, .deepSeek, .qwen, .customOpenAICompatible:
            AIProviderCapabilities(
                supportsWebSearch: false,
                supportsRemoteMCP: false,
                returnsSourceCitations: false,
                supportsSystemPrompt: true
            )
        }
    }
}

/// Central URL policy shared by settings persistence and request validation.
/// Keeping it outside the networking service prevents unsafe URL components
/// from ever being serialized to UserDefaults while still validating again at
/// the final network boundary.
enum AIEndpointPolicy {
    private static let loopbackHosts: Set<String> = [
        "localhost", "127.0.0.1", "::1", "[::1]"
    ]
    private static let nonPublicDomainSuffixes = [
        ".local", ".localhost", ".internal", ".lan", ".home", ".home.arpa"
    ]
    private static let nonPublicRootHosts: Set<String> = [
        "local", "internal", "lan", "home", "home.arpa"
    ]

    static func isValidProviderBaseURL(
        _ url: URL,
        allowsInsecureLocalhost: Bool
    ) -> Bool {
        guard let components = safeComponents(for: url),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host else {
            return false
        }
        let host = canonicalHost(rawHost)
        if scheme == "https" { return true }
        return scheme == "http"
            && allowsInsecureLocalhost
            && loopbackHosts.contains(host)
    }

    /// Remote MCP is resolved by an external provider, not by this app. V1
    /// therefore accepts only public-looking HTTPS hostnames and intentionally
    /// rejects localhost, reserved local DNS suffixes, and IP literals.
    static func isValidRemoteMCPURL(_ url: URL) -> Bool {
        guard let components = safeComponents(for: url),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host,
              isPublicLookingHost(rawHost) else {
            return false
        }
        return true
    }

    /// Citations are opened by the user's browser, so they may keep normal
    /// query/fragment components. Reject embedded credentials, local names,
    /// and IP literals to prevent model-controlled links from targeting this
    /// Mac or hiding a different destination behind userinfo.
    static func isValidExternalWebURL(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        scheme == "https" || scheme == "http",
        let rawHost = components.host,
        components.user == nil,
        components.password == nil,
        isPublicLookingHost(rawHost) else {
            return false
        }
        return true
    }

    static func normalizedEndpoint(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let path = components.path == "/"
            ? ""
            : components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathSuffix = path.isEmpty ? "" : "/\(path)"
        let portSuffix = components.port.map { ":\($0)" } ?? ""
        let host = components.host.map(canonicalHost) ?? ""
        return "\(components.scheme?.lowercased() ?? "")://\(host)\(portSuffix)\(pathSuffix)"
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.count) else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_-")
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func safeComponents(for url: URL) -> URLComponents? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        return components
    }

    private static func isIPAddressLiteral(_ host: String) -> Bool {
        let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if unbracketed.contains(":") { return true }
        // `inet_aton` deliberately recognizes the legacy numeric IPv4 forms
        // still accepted by macOS networking APIs (for example 127.1,
        // 2130706433, 017700000001, and 0x7f000001). A four-octet-only parser
        // would let those spellings bypass the local-target policy.
        var address = in_addr()
        return unbracketed.withCString { pointer in
            inet_aton(pointer, &address) != 0
        }
    }

    private static func canonicalHost(_ host: String) -> String {
        var value = host.lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }

    private static func isPublicLookingHost(_ rawHost: String) -> Bool {
        let host = canonicalHost(rawHost)
        return !host.isEmpty
            // Public DNS names contain at least one label separator. Reject
            // single-label names because macOS may resolve them through a
            // local search domain (for example `printer` or `internal`).
            && host.contains(".")
            && !loopbackHosts.contains(host)
            && !nonPublicRootHosts.contains(host)
            && !isIPAddressLiteral(host)
            && !nonPublicDomainSuffixes.contains(where: { host.hasSuffix($0) })
    }
}

struct AIRemoteMCPServer: Identifiable, Codable, Equatable {
    var id: UUID
    var label: String
    var serverURL: URL
    var serverDescription: String?
    var allowedTools: [String]

    init(
        id: UUID = UUID(),
        label: String,
        serverURL: URL,
        serverDescription: String? = nil,
        allowedTools: [String] = []
    ) {
        self.id = id
        self.label = label
        self.serverURL = serverURL
        self.serverDescription = serverDescription
        self.allowedTools = allowedTools
    }
}

struct AIProviderConfiguration: Identifiable, Codable, Equatable {
    static let allowedTimeoutRange: ClosedRange<TimeInterval> = 5 ... 600
    static let allowedMaximumOutputTokens: ClosedRange<Int> = 64 ... 128_000

    var id: UUID
    var name: String
    let kind: AIProviderKind
    var model: String
    var baseURL: URL
    var requestTimeout: TimeInterval
    var maximumOutputTokens: Int
    var isWebSearchEnabled: Bool
    var remoteMCPServers: [AIRemoteMCPServer]
    var allowsInsecureLocalhost: Bool
    var requiresAPIKey: Bool

    init(
        id: UUID = UUID(),
        name: String,
        kind: AIProviderKind,
        model: String,
        baseURL: URL,
        requestTimeout: TimeInterval = 120,
        maximumOutputTokens: Int = 4_096,
        isWebSearchEnabled: Bool = false,
        remoteMCPServers: [AIRemoteMCPServer] = [],
        allowsInsecureLocalhost: Bool = false,
        requiresAPIKey: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.model = model
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
        self.maximumOutputTokens = maximumOutputTokens
        self.isWebSearchEnabled = isWebSearchEnabled
        self.remoteMCPServers = remoteMCPServers
        self.allowsInsecureLocalhost = allowsInsecureLocalhost
        self.requiresAPIKey = requiresAPIKey
    }

    var capabilities: AIProviderCapabilities {
        AIProviderCapabilities.capabilities(for: kind)
    }
}

enum AIChatRole: String, Codable, Equatable {
    case user
    case assistant
}

struct AIChatTurn: Identifiable, Codable, Equatable {
    var id: UUID
    var role: AIChatRole
    var content: String

    init(id: UUID = UUID(), role: AIChatRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

struct AICompletionRequest: Equatable {
    static let maximumPromptCharacterCount = 100_000
    static let maximumContextCharacterCount = 500_000
    static let maximumConversationTurnCount = 100

    var prompt: String
    var systemPrompt: String?
    /// Text deliberately selected by the user for external processing. The
    /// networking layer never opens a PDF or discovers additional file data.
    var context: String?
    var conversation: [AIChatTurn]
    var allowsWebSearch: Bool
    var allowsMCPTools: Bool

    init(
        prompt: String,
        systemPrompt: String? = nil,
        context: String? = nil,
        conversation: [AIChatTurn] = [],
        allowsWebSearch: Bool = false,
        allowsMCPTools: Bool = false
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.context = context
        self.conversation = conversation
        self.allowsWebSearch = allowsWebSearch
        self.allowsMCPTools = allowsMCPTools
    }
}

struct AISourceCitation: Identifiable, Codable, Equatable {
    var id: String { "\(url.absoluteString)#\(startIndex ?? -1)-\(endIndex ?? -1)" }

    let title: String
    let url: URL
    let startIndex: Int?
    let endIndex: Int?

    init(title: String, url: URL, startIndex: Int? = nil, endIndex: Int? = nil) {
        self.title = title
        self.url = url
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}

struct AIUsage: Codable, Equatable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
}

struct AIMCPApprovalRequest: Identifiable, Codable, Equatable {
    var id: String { approvalRequestID }

    let approvalRequestID: String
    let name: String
    let arguments: String
    let serverLabel: String
    /// The exact user-configured public endpoint matched to `serverLabel`.
    /// This is never accepted from the provider response itself.
    let serverURL: URL?

    init(
        approvalRequestID: String,
        name: String,
        arguments: String,
        serverLabel: String,
        serverURL: URL? = nil
    ) {
        self.approvalRequestID = approvalRequestID
        self.name = name
        self.arguments = arguments
        self.serverLabel = serverLabel
        self.serverURL = serverURL
    }
}

struct AIMCPApprovalDecision: Codable, Equatable {
    let approvalRequestID: String
    let approved: Bool
}

struct AICompletionResponse: Equatable {
    let text: String
    let citations: [AISourceCitation]
    let provider: AIProviderKind
    let model: String?
    let finishReason: String?
    let usage: AIUsage?
    let responseID: String?
    let pendingMCPApprovals: [AIMCPApprovalRequest]

    init(
        text: String,
        citations: [AISourceCitation] = [],
        provider: AIProviderKind,
        model: String? = nil,
        finishReason: String? = nil,
        usage: AIUsage? = nil,
        responseID: String? = nil,
        pendingMCPApprovals: [AIMCPApprovalRequest] = []
    ) {
        self.text = text
        self.citations = citations
        self.provider = provider
        self.model = model
        self.finishReason = finishReason
        self.usage = usage
        self.responseID = responseID
        self.pendingMCPApprovals = pendingMCPApprovals
    }
}

struct AIProviderConfigurationSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var configurations: [AIProviderConfiguration]
    var selectedProvider: AIProviderKind

    init(
        version: Int = currentVersion,
        configurations: [AIProviderConfiguration],
        selectedProvider: AIProviderKind
    ) {
        self.version = version
        self.configurations = configurations
        self.selectedProvider = selectedProvider
    }

    static var defaults: AIProviderConfigurationSnapshot {
        AIProviderConfigurationSnapshot(
            configurations: AIProviderKind.allCases.map(\.defaultConfiguration),
            selectedProvider: .openAI
        )
    }
}
