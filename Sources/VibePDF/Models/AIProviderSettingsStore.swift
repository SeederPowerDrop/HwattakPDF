// SPDX-License-Identifier: MPL-2.0

import Foundation
import SwiftUI

protocol AIProviderConfigurationStoring {
    func loadSnapshot() -> AIProviderConfigurationSnapshot
    func saveSnapshot(_ snapshot: AIProviderConfigurationSnapshot) throws
}

enum AIProviderConfigurationStoreError: LocalizedError, Equatable {
    case encodingFailed

    var errorDescription: String? {
        "The AI provider settings could not be saved."
    }
}

struct UserDefaultsAIProviderConfigurationStore: AIProviderConfigurationStoring {
    static let defaultKey = "ai.providerConfiguration.v1"

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func loadSnapshot() -> AIProviderConfigurationSnapshot {
        guard
            let data = defaults.data(forKey: key),
            let snapshot = try? JSONDecoder().decode(
                AIProviderConfigurationSnapshot.self,
                from: data
            ),
            snapshot.version == AIProviderConfigurationSnapshot.currentVersion
        else {
            return .defaults
        }
        return Self.normalized(snapshot)
    }

    func saveSnapshot(_ snapshot: AIProviderConfigurationSnapshot) throws {
        let normalized = Self.normalized(snapshot)
        guard let data = try? JSONEncoder().encode(normalized) else {
            throw AIProviderConfigurationStoreError.encodingFailed
        }
        defaults.set(data, forKey: key)
    }

    private static func normalized(
        _ snapshot: AIProviderConfigurationSnapshot
    ) -> AIProviderConfigurationSnapshot {
        var seen = Set<AIProviderKind>()
        var configurations: [AIProviderConfiguration] = []

        for configuration in snapshot.configurations where seen.insert(configuration.kind).inserted {
            configurations.append(normalizedConfiguration(configuration))
        }

        for kind in AIProviderKind.allCases where !seen.contains(kind) {
            configurations.append(kind.defaultConfiguration)
        }

        return AIProviderConfigurationSnapshot(
            configurations: configurations,
            selectedProvider: snapshot.selectedProvider
        )
    }

    fileprivate static func normalizedConfiguration(
        _ configuration: AIProviderConfiguration
    ) -> AIProviderConfiguration {
        var value = configuration
        value.requestTimeout = min(
            max(value.requestTimeout, AIProviderConfiguration.allowedTimeoutRange.lowerBound),
            AIProviderConfiguration.allowedTimeoutRange.upperBound
        )
        value.maximumOutputTokens = min(
            max(
                value.maximumOutputTokens,
                AIProviderConfiguration.allowedMaximumOutputTokens.lowerBound
            ),
            AIProviderConfiguration.allowedMaximumOutputTokens.upperBound
        )
        if value.kind != .customOpenAICompatible {
            value.baseURL = value.kind.defaultConfiguration.baseURL
            value.allowsInsecureLocalhost = false
            value.requiresAPIKey = true
        } else if !AIEndpointPolicy.isValidProviderBaseURL(
            value.baseURL,
            allowsInsecureLocalhost: value.allowsInsecureLocalhost
        ) {
            // Never persist embedded URL credentials or query/fragment tokens.
            value.baseURL = AIProviderKind.customOpenAICompatible.defaultConfiguration.baseURL
            value.allowsInsecureLocalhost = false
        }
        if !value.capabilities.supportsWebSearch {
            value.isWebSearchEnabled = false
        }
        if value.capabilities.supportsRemoteMCP {
            value.remoteMCPServers = normalizedMCPServers(value.remoteMCPServers)
        } else {
            value.remoteMCPServers = []
        }
        return value
    }

    private static func normalizedMCPServers(
        _ servers: [AIRemoteMCPServer]
    ) -> [AIRemoteMCPServer] {
        var seenLabels = Set<String>()
        var seenURLs = Set<String>()
        var result: [AIRemoteMCPServer] = []

        for server in servers {
            let label = server.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let labelKey = label.lowercased()
            let urlKey = server.serverURL.absoluteString.lowercased()
            guard AIEndpointPolicy.isSafeIdentifier(label),
                  AIEndpointPolicy.isValidRemoteMCPURL(server.serverURL),
                  seenLabels.insert(labelKey).inserted,
                  seenURLs.insert(urlKey).inserted else {
                continue
            }

            var allowedTools: [String] = []
            var seenTools = Set<String>()
            for rawTool in server.allowedTools.prefix(128) {
                let tool = rawTool.trimmingCharacters(in: .whitespacesAndNewlines)
                guard AIEndpointPolicy.isSafeIdentifier(tool),
                      seenTools.insert(tool).inserted else { continue }
                allowedTools.append(tool)
            }

            var normalizedServer = server
            normalizedServer.label = label
            normalizedServer.allowedTools = allowedTools
            if let description = normalizedServer.serverDescription,
               description.count > 2_000 {
                normalizedServer.serverDescription = String(description.prefix(2_000))
            }
            result.append(normalizedServer)
        }
        return result
    }
}

@MainActor
final class AIProviderSettingsStore: ObservableObject {
    static let shared = AIProviderSettingsStore()

    @Published var configurations: [AIProviderConfiguration] {
        didSet {
            guard !isLoading else { return }
            persist()
            let oldScopes = Set(oldValue.map { AIAPIKeyScope(configuration: $0) })
            let newScopes = Set(configurations.map { AIAPIKeyScope(configuration: $0) })
            if oldScopes != newScopes {
                refreshAPIKeyAvailability()
            }
        }
    }

    @Published var selectedProvider: AIProviderKind {
        didSet {
            guard !isLoading else { return }
            persist()
        }
    }

    @Published private(set) var apiKeyAvailability: [UUID: Bool] = [:]
    @Published private(set) var lastErrorDescription: String?

    private let configurationStore: any AIProviderConfigurationStoring
    private let keyStore: any SecureAIAPIKeyStoring
    private var isLoading = false

    init(
        configurationStore: any AIProviderConfigurationStoring =
            UserDefaultsAIProviderConfigurationStore(),
        keyStore: any SecureAIAPIKeyStoring = KeychainSecureAIAPIKeyStore.shared
    ) {
        self.configurationStore = configurationStore
        self.keyStore = keyStore
        let snapshot = configurationStore.loadSnapshot()
        configurations = snapshot.configurations
        selectedProvider = snapshot.selectedProvider
        // Persist first-run preset UUIDs immediately. API keys are scoped to
        // those UUIDs, so regenerating unsaved defaults on the next launch
        // would make a valid Keychain item appear to be missing.
        var initialPersistenceError: Error?
        do {
            try configurationStore.saveSnapshot(snapshot)
        } catch {
            initialPersistenceError = error
        }
        refreshAPIKeyAvailability()
        if let initialPersistenceError {
            lastErrorDescription = initialPersistenceError.localizedDescription
        }
    }

    var selectedConfiguration: AIProviderConfiguration {
        configuration(for: selectedProvider)
    }

    func configuration(for provider: AIProviderKind) -> AIProviderConfiguration {
        configurations.first(where: { $0.kind == provider })
            ?? provider.defaultConfiguration
    }

    func updateConfiguration(_ configuration: AIProviderConfiguration) {
        var safeConfiguration = UserDefaultsAIProviderConfigurationStore
            .normalizedConfiguration(configuration)
        guard let index = configurations.firstIndex(where: { $0.kind == safeConfiguration.kind }) else {
            configurations.append(safeConfiguration)
            return
        }
        var credentialCleanupError: Error?
        if safeConfiguration.kind == .customOpenAICompatible,
           AIEndpointPolicy.normalizedEndpoint(configurations[index].baseURL)
                != AIEndpointPolicy.normalizedEndpoint(safeConfiguration.baseURL) {
            // A custom credential belongs to one explicit destination. Give a
            // changed endpoint a new identity so the prior server's Keychain
            // secret cannot be silently replayed to the new host/path.
            do {
                try keyStore.deleteAPIKey(
                    for: AIAPIKeyScope(configuration: configurations[index])
                )
            } catch {
                // The new UUID still makes the old item unreachable. Surface
                // cleanup failure so the user can inspect Keychain manually.
                credentialCleanupError = error
            }
            safeConfiguration.id = UUID()
        }
        configurations[index] = safeConfiguration
        if let credentialCleanupError {
            lastErrorDescription = credentialCleanupError.localizedDescription
        }
    }

    func resetConfiguration(for provider: AIProviderKind) {
        let current = configuration(for: provider)
        var replacement = provider.defaultConfiguration
        // Keep the identity so the provider's Keychain credential remains
        // associated with it when only non-secret settings are reset.
        replacement.id = current.id
        updateConfiguration(replacement)
    }

    func hasAPIKey(for provider: AIProviderKind) -> Bool {
        let configurationID = configuration(for: provider).id
        return apiKeyAvailability[configurationID] ?? false
    }

    func saveAPIKey(_ apiKey: String, for provider: AIProviderKind) throws {
        let configuration = configuration(for: provider)
        let configurationID = configuration.id
        let keyScope = AIAPIKeyScope(configuration: configuration)
        do {
            try configurationStore.saveSnapshot(
                AIProviderConfigurationSnapshot(
                    configurations: configurations,
                    selectedProvider: selectedProvider
                )
            )
            try keyStore.saveAPIKey(apiKey, for: keyScope)
            apiKeyAvailability[configurationID] = true
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func deleteAPIKey(for provider: AIProviderKind) throws {
        let configuration = configuration(for: provider)
        let configurationID = configuration.id
        let keyScope = AIAPIKeyScope(configuration: configuration)
        do {
            try keyStore.deleteAPIKey(for: keyScope)
            apiKeyAvailability[configurationID] = false
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func refreshAPIKeyAvailability() {
        var availability: [UUID: Bool] = [:]
        var firstError: Error?
        for configuration in configurations {
            do {
                availability[configuration.id] = try keyStore.containsAPIKey(
                    for: AIAPIKeyScope(configuration: configuration)
                )
            } catch {
                availability[configuration.id] = false
                if firstError == nil { firstError = error }
            }
        }
        apiKeyAvailability = availability
        lastErrorDescription = firstError?.localizedDescription
    }

    func reload() {
        isLoading = true
        let snapshot = configurationStore.loadSnapshot()
        configurations = snapshot.configurations
        selectedProvider = snapshot.selectedProvider
        isLoading = false
        refreshAPIKeyAvailability()
    }

    private func persist() {
        do {
            try configurationStore.saveSnapshot(
                AIProviderConfigurationSnapshot(
                    configurations: configurations,
                    selectedProvider: selectedProvider
                )
            )
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }
}
