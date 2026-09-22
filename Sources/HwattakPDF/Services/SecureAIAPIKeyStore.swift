// SPDX-License-Identifier: MPL-2.0

import Foundation
import Security

private func containsAPIKeyHeaderControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
        scalar.value == 0 || scalar.value == 10 || scalar.value == 13
    }
}

protocol SecureAIAPIKeyStoring {
    func loadAPIKey(for scope: AIAPIKeyScope) throws -> String?
    func saveAPIKey(_ apiKey: String, for scope: AIAPIKeyScope) throws
    func deleteAPIKey(for scope: AIAPIKeyScope) throws
    func containsAPIKey(for scope: AIAPIKeyScope) throws -> Bool
}

struct AIAPIKeyScope: Hashable {
    let configurationID: UUID
    let provider: AIProviderKind

    init(configurationID: UUID, provider: AIProviderKind) {
        self.configurationID = configurationID
        self.provider = provider
    }

    init(configuration: AIProviderConfiguration) {
        self.init(configurationID: configuration.id, provider: configuration.kind)
    }
}

struct AIKeychainCopyResult {
    let status: OSStatus
    let data: Data?
}

protocol AIKeychainItemOperating {
    func copyMatching(_ query: [CFString: Any]) -> AIKeychainCopyResult
    func add(_ attributes: [CFString: Any]) -> OSStatus
    func update(
        _ query: [CFString: Any],
        attributes: [CFString: Any]
    ) -> OSStatus
    func delete(_ query: [CFString: Any]) -> OSStatus
}

struct SystemAIKeychainItemOperator: AIKeychainItemOperating {
    func copyMatching(_ query: [CFString: Any]) -> AIKeychainCopyResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return AIKeychainCopyResult(status: status, data: result as? Data)
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(
        _ query: [CFString: Any],
        attributes: [CFString: Any]
    ) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

enum SecureAIAPIKeyStoreError: LocalizedError, Equatable {
    case invalidAPIKey
    case keychain(OSStatus)
    case legacyCleanupFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "The API key is empty or invalid."
        case let .keychain(status):
            return (SecCopyErrorMessageString(status, nil) as String?)
                ?? "Keychain error \(status)"
        case let .legacyCleanupFailed(status):
            return (SecCopyErrorMessageString(status, nil) as String?)
                ?? "Legacy Keychain cleanup error \(status)"
        }
    }
}

/// Stores provider credentials in this macOS user's Keychain. Configuration
/// metadata is persisted separately and never contains an API key.
final class KeychainSecureAIAPIKeyStore: SecureAIAPIKeyStoring {
    static let shared = KeychainSecureAIAPIKeyStore()
    static let defaultService = "com.hwattakpdf.ai-api-keys"
    static let maximumAPIKeyByteCount = 64 * 1_024

    private let service: String
    private let keychain: any AIKeychainItemOperating

    init(
        service: String = KeychainSecureAIAPIKeyStore.defaultService,
        keychain: any AIKeychainItemOperating = SystemAIKeychainItemOperator()
    ) {
        self.service = service
        self.keychain = keychain
    }

    func loadAPIKey(for scope: AIAPIKeyScope) throws -> String? {
        var query = baseQuery(for: scope)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        let result = keychain.copyMatching(query)
        if result.status == errSecItemNotFound || result.status == errSecMissingEntitlement {
            return try loadLegacyAPIKey(for: scope)
        }
        guard result.status == errSecSuccess else {
            throw SecureAIAPIKeyStoreError.keychain(result.status)
        }
        return try decodedAPIKey(from: result.data)
    }

    func saveAPIKey(_ apiKey: String, for scope: AIAPIKeyScope) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalized.isEmpty,
            !containsAPIKeyHeaderControlCharacter(normalized),
            let data = normalized.data(using: .utf8),
            data.count <= Self.maximumAPIKeyByteCount
        else {
            throw SecureAIAPIKeyStoreError.invalidAPIKey
        }

        var attributes = baseQuery(for: scope)
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = "HwattakPDF AI Provider Credential"
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = keychain.add(attributes)
        switch addStatus {
        case errSecSuccess:
            try removeLegacyCopy(for: scope)
        case errSecDuplicateItem:
            let updateStatus = keychain.update(
                baseQuery(for: scope),
                attributes: [kSecValueData: data]
            )
            if updateStatus == errSecMissingEntitlement {
                try saveLegacyAPIKey(data, for: scope)
                return
            }
            guard updateStatus == errSecSuccess else {
                throw SecureAIAPIKeyStoreError.keychain(updateStatus)
            }
            try removeLegacyCopy(for: scope)
        case errSecMissingEntitlement:
            try saveLegacyAPIKey(data, for: scope)
        default:
            throw SecureAIAPIKeyStoreError.keychain(addStatus)
        }
    }

    func deleteAPIKey(for scope: AIAPIKeyScope) throws {
        let legacyStatus = keychain.delete(legacyBaseQuery(for: scope))
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw SecureAIAPIKeyStoreError.keychain(legacyStatus)
        }

        let status = keychain.delete(baseQuery(for: scope))
        if status == errSecMissingEntitlement { return }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureAIAPIKeyStoreError.keychain(status)
        }
    }

    func containsAPIKey(for scope: AIAPIKeyScope) throws -> Bool {
        // Existence checks deliberately omit kSecReturnData so settings UI
        // refreshes never copy provider secrets into process memory.
        let result = keychain.copyMatching(baseQuery(for: scope))
        switch result.status {
        case errSecSuccess:
            return true
        case errSecItemNotFound, errSecMissingEntitlement:
            let legacyResult = keychain.copyMatching(legacyBaseQuery(for: scope))
            if legacyResult.status == errSecSuccess { return true }
            if legacyResult.status == errSecItemNotFound { return false }
            throw SecureAIAPIKeyStoreError.keychain(legacyResult.status)
        default:
            throw SecureAIAPIKeyStoreError.keychain(result.status)
        }
    }

    /// Internal for deterministic security-policy tests.
    func baseQuery(for scope: AIAPIKeyScope) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: scope),
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any
        ]
    }

    /// Compatibility path for ad-hoc builds without a provisioned access
    /// group. It remains user-scoped and explicitly non-synchronizing.
    func legacyBaseQuery(for scope: AIAPIKeyScope) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: scope),
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
    }

    private func account(for scope: AIAPIKeyScope) -> String {
        "provider-\(scope.provider.rawValue.lowercased())-\(scope.configurationID.uuidString.lowercased())"
    }

    private func decodedAPIKey(from data: Data?) throws -> String {
        guard
            let data,
            data.count <= Self.maximumAPIKeyByteCount,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty,
            !containsAPIKeyHeaderControlCharacter(value)
        else {
            throw SecureAIAPIKeyStoreError.invalidAPIKey
        }
        return value
    }

    private func loadLegacyAPIKey(for scope: AIAPIKeyScope) throws -> String? {
        var query = legacyBaseQuery(for: scope)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        let result = keychain.copyMatching(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw SecureAIAPIKeyStoreError.keychain(result.status)
        }
        return try decodedAPIKey(from: result.data)
    }

    private func saveLegacyAPIKey(_ data: Data, for scope: AIAPIKeyScope) throws {
        var attributes = legacyBaseQuery(for: scope)
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = "HwattakPDF AI Provider Credential"

        let status = keychain.add(attributes)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = keychain.update(
                legacyBaseQuery(for: scope),
                attributes: [kSecValueData: data]
            )
            guard updateStatus == errSecSuccess else {
                throw SecureAIAPIKeyStoreError.keychain(updateStatus)
            }
        default:
            throw SecureAIAPIKeyStoreError.keychain(status)
        }
    }

    private func removeLegacyCopy(for scope: AIAPIKeyScope) throws {
        let status = keychain.delete(legacyBaseQuery(for: scope))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureAIAPIKeyStoreError.legacyCleanupFailed(status)
        }
    }
}

final class InMemorySecureAIAPIKeyStore: SecureAIAPIKeyStoring {
    var keys: [AIAPIKeyScope: String]
    var loadError: Error?
    var saveError: Error?
    var deleteError: Error?

    init(keys: [AIAPIKeyScope: String] = [:]) {
        self.keys = keys
    }

    func loadAPIKey(for scope: AIAPIKeyScope) throws -> String? {
        if let loadError { throw loadError }
        return keys[scope]
    }

    func saveAPIKey(_ apiKey: String, for scope: AIAPIKeyScope) throws {
        if let saveError { throw saveError }
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalized.isEmpty,
            !containsAPIKeyHeaderControlCharacter(normalized)
        else {
            throw SecureAIAPIKeyStoreError.invalidAPIKey
        }
        keys[scope] = normalized
    }

    func deleteAPIKey(for scope: AIAPIKeyScope) throws {
        if let deleteError { throw deleteError }
        keys.removeValue(forKey: scope)
    }

    func containsAPIKey(for scope: AIAPIKeyScope) throws -> Bool {
        keys[scope] != nil
    }
}
