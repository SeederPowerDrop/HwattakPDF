// SPDX-License-Identifier: MPL-2.0

import Foundation
import Security

/// The versioned, device-local representation of the user's default signature.
///
/// Only vector input is retained. A rendered bitmap or PDF page is never put in
/// the Keychain, so the saved secret stays small and can be redrawn cleanly at
/// another PDF scale.
struct SavedSignature: Codable, Equatable {
    static let currentVersion = 1
    static let maximumEncodedByteCount = 512 * 1_024
    static let maximumStrokeCount = 256
    static let maximumPointCount = 20_000
    static let maximumPointsPerStroke = 10_000
    static let minimumCanvasDimension: Double = 1
    static let maximumCanvasDimension: Double = 10_000
    static let maximumStrokeDuration: TimeInterval = 60 * 60

    let version: Int
    let strokes: [SignatureStroke]
    private let canvasWidth: Double
    private let canvasHeight: Double

    init(strokes: [SignatureStroke], canvasSize: CGSize) {
        version = Self.currentVersion
        self.strokes = Self.normalizedTimestamps(in: strokes)
        canvasWidth = Double(canvasSize.width)
        canvasHeight = Double(canvasSize.height)
    }

    private init(
        version: Int,
        strokes: [SignatureStroke],
        canvasWidth: Double,
        canvasHeight: Double
    ) {
        self.version = version
        self.strokes = strokes
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    var canvasSize: CGSize {
        CGSize(width: canvasWidth, height: canvasHeight)
    }

    func encodedData(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        try validate()
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedByteCount else {
            throw SecureSignatureStoreError.payloadTooLarge
        }
        return data
    }

    static func decode(
        _ data: Data,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> SavedSignature {
        guard data.count <= maximumEncodedByteCount else {
            throw SecureSignatureStoreError.payloadTooLarge
        }
        do {
            let signature = try decoder.decode(SavedSignature.self, from: data)
            try signature.validate()
            let normalized = SavedSignature(
                version: signature.version,
                strokes: normalizedTimestamps(in: signature.strokes),
                canvasWidth: signature.canvasWidth,
                canvasHeight: signature.canvasHeight
            )
            try normalized.validate()
            return normalized
        } catch let error as SecureSignatureStoreError {
            throw error
        } catch {
            throw SecureSignatureStoreError.invalidPayload
        }
    }

    private func validate() throws {
        guard version == Self.currentVersion else {
            throw SecureSignatureStoreError.unsupportedVersion(version)
        }
        guard
            canvasWidth.isFinite,
            canvasHeight.isFinite,
            canvasWidth >= Self.minimumCanvasDimension,
            canvasHeight >= Self.minimumCanvasDimension,
            canvasWidth <= Self.maximumCanvasDimension,
            canvasHeight <= Self.maximumCanvasDimension,
            !strokes.isEmpty,
            strokes.count <= Self.maximumStrokeCount
        else {
            throw SecureSignatureStoreError.invalidPayload
        }

        var pointCount = 0
        for stroke in strokes {
            guard
                !stroke.points.isEmpty,
                stroke.points.count <= Self.maximumPointsPerStroke
            else {
                throw SecureSignatureStoreError.invalidPayload
            }
            pointCount += stroke.points.count
            guard pointCount <= Self.maximumPointCount else {
                throw SecureSignatureStoreError.payloadTooLarge
            }
            var previousTimestamp: TimeInterval?
            let firstTimestamp = stroke.points[0].timestamp
            for point in stroke.points {
                guard
                    point.x.isFinite,
                    point.y.isFinite,
                    point.pressure.isFinite,
                    point.timestamp.isFinite,
                    point.x >= 0,
                    point.y >= 0,
                    Double(point.x) <= canvasWidth,
                    Double(point.y) <= canvasHeight,
                    point.pressure >= 0,
                    point.pressure <= 1,
                    abs(point.timestamp) <= 1_000_000_000_000,
                    point.timestamp - firstTimestamp <= Self.maximumStrokeDuration,
                    point.timestamp >= (previousTimestamp ?? point.timestamp)
                else {
                    throw SecureSignatureStoreError.invalidPayload
                }
                previousTimestamp = point.timestamp
            }
        }
    }

    /// Absolute NSEvent timestamps reveal system uptime and add no visual
    /// value. Preserve only each stroke's relative timing, which is sufficient
    /// for velocity-based rendering.
    private static func normalizedTimestamps(
        in strokes: [SignatureStroke]
    ) -> [SignatureStroke] {
        strokes.map { stroke in
            guard let origin = stroke.points.first?.timestamp else { return stroke }
            return SignatureStroke(
                id: stroke.id,
                points: stroke.points.map { point in
                    var normalized = point
                    normalized.timestamp -= origin
                    return normalized
                }
            )
        }
    }
}

protocol SecureSignatureStoring {
    func loadSignature() throws -> SavedSignature?
    func saveSignature(_ signature: SavedSignature) throws
    func deleteSignature() throws
    func retryLegacyCleanup() throws
}

enum SecureSignatureApplicationOutcome: Equatable {
    case applicationFailed
    case appliedAndSaved
    case appliedAndSavedButLegacyCleanupFailed
    case appliedButStorageFailed
}

/// Keeps PDF placement authoritative: persistence happens only after placement
/// succeeds, and a persistence error is reported without undoing that success.
enum SecureSignatureApplicationWorkflow {
    static func applyAndPersist(
        rawStrokes: [SignatureStroke],
        canvasSize: CGSize,
        store: any SecureSignatureStoring,
        applyToPDF: () -> Bool
    ) -> SecureSignatureApplicationOutcome {
        guard applyToPDF() else { return .applicationFailed }
        do {
            try store.saveSignature(
                SavedSignature(strokes: rawStrokes, canvasSize: canvasSize)
            )
            return .appliedAndSaved
        } catch let error as SecureSignatureStoreError {
            if case .legacyCleanupFailed = error {
                return .appliedAndSavedButLegacyCleanupFailed
            }
            return .appliedButStorageFailed
        } catch {
            return .appliedButStorageFailed
        }
    }
}

enum SecureSignatureStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case invalidPayload
    case unsupportedVersion(Int)
    case payloadTooLarge
    /// The new Data Protection item is authoritative and was saved, but an
    /// older file-based Keychain copy could not be removed.
    case legacyCleanupFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let systemMessage = SecCopyErrorMessageString(status, nil) as String?
            return systemMessage ?? "Keychain error \(status)"
        case .invalidPayload:
            return "The saved signature data is invalid."
        case let .unsupportedVersion(version):
            return "The saved signature version (\(version)) is not supported."
        case .payloadTooLarge:
            return "The saved signature data is too large."
        case let .legacyCleanupFailed(status):
            let systemMessage = SecCopyErrorMessageString(status, nil) as String?
            return systemMessage ?? "Legacy Keychain cleanup error \(status)"
        }
    }
}

struct KeychainCopyResult {
    let status: OSStatus
    let data: Data?
}

/// A narrow adapter keeps Security.framework state transitions deterministic
/// in unit tests without touching a developer's real Keychain.
protocol KeychainItemOperating {
    func copyMatching(_ query: [CFString: Any]) -> KeychainCopyResult
    func add(_ attributes: [CFString: Any]) -> OSStatus
    func update(
        _ query: [CFString: Any],
        attributes: [CFString: Any]
    ) -> OSStatus
    func delete(_ query: [CFString: Any]) -> OSStatus
}

struct SystemKeychainItemOperator: KeychainItemOperating {
    func copyMatching(_ query: [CFString: Any]) -> KeychainCopyResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return KeychainCopyResult(status: status, data: result as? Data)
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

/// Prefers the current macOS user's Data Protection Keychain with
/// `WhenUnlockedThisDeviceOnly` and synchronization disabled. Development
/// ad-hoc signatures lack a provisioned access group, so missing-entitlement
/// builds fall back to that user's non-synchronizing legacy login Keychain.
final class KeychainSecureSignatureStore: SecureSignatureStoring {
    static let shared = KeychainSecureSignatureStore()

    static let defaultService = "com.hwattakpdf.secure-signature"
    static let defaultAccount = "default-signature-v1"

    private let service: String
    private let account: String
    private let keychain: any KeychainItemOperating

    init(
        service: String = KeychainSecureSignatureStore.defaultService,
        account: String = KeychainSecureSignatureStore.defaultAccount,
        keychain: any KeychainItemOperating = SystemKeychainItemOperator()
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    func loadSignature() throws -> SavedSignature? {
        var query = baseQuery
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        let result = keychain.copyMatching(query)
        let status = result.status
        if status == errSecItemNotFound {
            return try loadLegacySignature()
        }
        if status == errSecMissingEntitlement {
            return try loadLegacySignature()
        }
        guard status == errSecSuccess else {
            throw SecureSignatureStoreError.keychain(status)
        }
        guard let data = result.data else {
            throw SecureSignatureStoreError.invalidPayload
        }
        return try SavedSignature.decode(data)
    }

    func saveSignature(_ signature: SavedSignature) throws {
        let data = try signature.encodedData()
        let attributes = addAttributes(data: data)

        let addStatus = keychain.add(attributes)
        switch addStatus {
        case errSecSuccess:
            try removeLegacyCopyAfterDataProtectionSave()
            return
        case errSecDuplicateItem:
            // Items created by this service always have ThisDeviceOnly access.
            // Updating only the secret is atomic and preserves that policy.
            let updateStatus = keychain.update(
                baseQuery,
                attributes: [kSecValueData: data]
            )
            if updateStatus == errSecMissingEntitlement {
                try saveLegacySignature(data)
                return
            }
            guard updateStatus == errSecSuccess else {
                throw SecureSignatureStoreError.keychain(updateStatus)
            }
            try removeLegacyCopyAfterDataProtectionSave()
        case errSecMissingEntitlement:
            try saveLegacySignature(data)
        default:
            throw SecureSignatureStoreError.keychain(addStatus)
        }
    }

    func deleteSignature() throws {
        // Remove the compatibility copy first. If this fails, leave the Data
        // Protection item intact and report the error; deleting the primary
        // item first could make the older signature reappear on the next load.
        try deleteLegacySignature()
        let status = keychain.delete(baseQuery)
        if status == errSecMissingEntitlement {
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureSignatureStoreError.keychain(status)
        }
    }

    func retryLegacyCleanup() throws {
        try removeLegacyCopyAfterDataProtectionSave()
    }

    /// Exposed internally so tests can verify the security attributes without
    /// reading from or writing to a developer's real Keychain.
    var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any
        ]
    }

    var legacyBaseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
    }

    func addAttributes(data: Data) -> [CFString: Any] {
        var attributes = baseQuery
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = "HwattakPDF Saved Signature"
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return attributes
    }

    func legacyAddAttributes(data: Data) -> [CFString: Any] {
        var attributes = legacyBaseQuery
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = "HwattakPDF Saved Signature"
        return attributes
    }

    private func loadLegacySignature() throws -> SavedSignature? {
        var query = legacyBaseQuery
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        let result = keychain.copyMatching(query)
        let status = result.status
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecureSignatureStoreError.keychain(status)
        }
        guard let data = result.data else {
            throw SecureSignatureStoreError.invalidPayload
        }
        return try SavedSignature.decode(data)
    }

    private func saveLegacySignature(_ data: Data) throws {
        let addStatus = keychain.add(legacyAddAttributes(data: data))
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = keychain.update(
                legacyBaseQuery,
                attributes: [kSecValueData: data]
            )
            guard updateStatus == errSecSuccess else {
                throw SecureSignatureStoreError.keychain(updateStatus)
            }
        default:
            throw SecureSignatureStoreError.keychain(addStatus)
        }
    }

    private func deleteLegacySignature() throws {
        let status = keychain.delete(legacyBaseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureSignatureStoreError.keychain(status)
        }
    }

    private func removeLegacyCopyAfterDataProtectionSave() throws {
        let status = keychain.delete(legacyBaseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureSignatureStoreError.legacyCleanupFailed(status)
        }
    }
}

/// Test-only and preview-friendly implementation. Tests inject this type so an
/// ad-hoc test run can never create or replace a real saved signature.
final class InMemorySecureSignatureStore: SecureSignatureStoring {
    var signature: SavedSignature?
    var loadError: Error?
    var saveError: Error?
    var deleteError: Error?
    var legacyCleanupError: Error?
    private(set) var legacyCleanupAttemptCount = 0

    init(signature: SavedSignature? = nil) {
        self.signature = signature
    }

    func loadSignature() throws -> SavedSignature? {
        if let loadError { throw loadError }
        return signature
    }

    func saveSignature(_ signature: SavedSignature) throws {
        if let saveError { throw saveError }
        self.signature = signature
    }

    func deleteSignature() throws {
        if let deleteError { throw deleteError }
        signature = nil
    }

    func retryLegacyCleanup() throws {
        legacyCleanupAttemptCount += 1
        if let legacyCleanupError { throw legacyCleanupError }
    }
}
