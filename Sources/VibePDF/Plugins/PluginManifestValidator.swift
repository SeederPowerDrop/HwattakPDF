// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Strict decoder for untrusted plug-in manifests.
///
/// `JSONDecoder` intentionally ignores unknown keys. A versioned security
/// boundary should not: a misspelled permission or action field must fail
/// closed instead of appearing to install successfully.
struct PluginManifestValidator {
    private static let rootKeys: Set<String> = [
        "schemaVersion",
        "identifier",
        "displayName",
        "version",
        "author",
        "description",
        "minimumHostVersion",
        "capabilities",
        "actions"
    ]
    private static let actionKeys: Set<String> = [
        "id", "title", "description", "output", "template"
    ]
    private static let allowedTokens = [
        "{{selection}}",
        "{{selection.urlEncoded}}",
        "{{document.name}}",
        "{{document.name.urlEncoded}}",
        "{{page.number}}",
        "{{document.pageCount}}",
        "{{page.text}}",
        "{{page.text.urlEncoded}}"
    ]
    private static let legacyCapabilities: Set<PluginCapability> = [
        .documentMetadata, .selectedText, .clipboardWrite, .externalURL
    ]

    let hostVersion: String

    init(hostVersion: String = PluginHost.currentVersion) {
        self.hostVersion = hostVersion
    }

    func decodeAndValidate(_ data: Data) throws -> PluginManifest {
        guard !data.isEmpty, data.count <= HwattakPluginLimits.maximumManifestBytes else {
            throw PluginSystemError.invalidManifest("manifest.json size is outside the allowed range")
        }

        // Foundation accepts duplicate object keys and silently keeps one of
        // their values. That ambiguity is unsafe at an installation boundary:
        // a reviewer and the runtime could otherwise reason about different
        // values. Parse the small manifest once up front and fail closed.
        try StrictJSONDuplicateKeyValidator.validate(data)

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PluginSystemError.invalidManifest("manifest.json is not valid JSON")
        }
        guard let root = json as? [String: Any] else {
            throw PluginSystemError.invalidManifest("the manifest root must be an object")
        }
        try rejectUnknownKeys(in: root, allowed: Self.rootKeys, context: "manifest")
        guard let rawActions = root["actions"] as? [Any] else {
            throw PluginSystemError.invalidManifest("actions must be an array")
        }
        for (index, value) in rawActions.enumerated() {
            guard let action = value as? [String: Any] else {
                throw PluginSystemError.invalidManifest("action \(index + 1) must be an object")
            }
            try rejectUnknownKeys(
                in: action,
                allowed: Self.actionKeys,
                context: "action \(index + 1)"
            )
        }

        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PluginSystemError.invalidManifest("required fields or field types are invalid")
        }
        try validate(manifest)
        return manifest
    }

    func validate(_ manifest: PluginManifest) throws {
        guard HwattakPluginLimits.supportedManifestSchemaVersions.contains(
            manifest.schemaVersion
        ) else {
            throw PluginSystemError.invalidManifest(
                "unsupported schemaVersion \(manifest.schemaVersion)"
            )
        }
        try validateIdentifier(manifest.identifier, field: "identifier", requiresDot: true)
        guard
            !manifest.identifier.hasPrefix("com.vibepdf."),
            !manifest.identifier.hasPrefix("com.hwattakpdf.")
        else {
            throw PluginSystemError.invalidManifest(
                "the com.vibepdf and com.hwattakpdf namespaces are reserved"
            )
        }
        try validatePlainText(manifest.displayName, field: "displayName", maximumBytes: 160)
        try validatePlainText(manifest.author, field: "author", maximumBytes: 160)
        try validatePlainText(
            manifest.description,
            field: "description",
            maximumBytes: 4_096,
            allowsLineBreaks: true
        )

        guard PluginSemanticVersion(manifest.version) != nil else {
            throw PluginSystemError.invalidManifest("version must use major.minor.patch")
        }
        if let minimumHostVersion = manifest.minimumHostVersion {
            guard
                let required = PluginSemanticVersion(minimumHostVersion),
                let current = PluginSemanticVersion(hostVersion)
            else {
                throw PluginSystemError.invalidManifest(
                    "minimumHostVersion must use major.minor.patch"
                )
            }
            guard current >= required else {
                throw PluginSystemError.incompatibleHost(
                    required: minimumHostVersion,
                    current: hostVersion
                )
            }
        }

        guard
            !manifest.actions.isEmpty,
            manifest.actions.count <= HwattakPluginLimits.maximumActionsPerPlugin
        else {
            throw PluginSystemError.invalidManifest(
                "actions must contain 1...\(HwattakPluginLimits.maximumActionsPerPlugin) items"
            )
        }
        guard Set(manifest.capabilities).count == manifest.capabilities.count else {
            throw PluginSystemError.invalidManifest("capabilities contains duplicates")
        }
        if manifest.schemaVersion == HwattakPluginLimits.legacyManifestSchemaVersion {
            let unsupported = Set(manifest.capabilities).subtracting(Self.legacyCapabilities)
            guard unsupported.isEmpty else {
                throw PluginSystemError.invalidManifest(
                    "schemaVersion 1 does not support capability: "
                        + unsupported.map(\.rawValue).sorted().joined(separator: ", ")
                )
            }
        }

        var actionIDs: Set<String> = []
        var requiredCapabilities: Set<PluginCapability> = []
        for action in manifest.actions {
            try validateAction(action, schemaVersion: manifest.schemaVersion)
            guard actionIDs.insert(action.id).inserted else {
                throw PluginSystemError.invalidManifest("duplicate action id: \(action.id)")
            }
            requiredCapabilities.formUnion(action.requiredCapabilities)
        }
        let declaredCapabilities = Set(manifest.capabilities)
        guard declaredCapabilities == requiredCapabilities else {
            let missing = requiredCapabilities.subtracting(declaredCapabilities)
                .map(\.rawValue)
                .sorted()
                .joined(separator: ", ")
            let unused = declaredCapabilities.subtracting(requiredCapabilities)
                .map(\.rawValue)
                .sorted()
                .joined(separator: ", ")
            let detail = [
                missing.isEmpty ? nil : "missing: \(missing)",
                unused.isEmpty ? nil : "unused: \(unused)"
            ]
            .compactMap { $0 }
            .joined(separator: "; ")
            throw PluginSystemError.invalidManifest("capability mismatch (\(detail))")
        }
    }

    private func validateAction(
        _ action: PluginActionManifest,
        schemaVersion: Int
    ) throws {
        try validateIdentifier(action.id, field: "action.id", requiresDot: false)
        try validatePlainText(action.title, field: "action.title", maximumBytes: 240)
        if let description = action.description {
            try validatePlainText(
                description,
                field: "action.description",
                maximumBytes: 1_024,
                allowsLineBreaks: true
            )
        }
        guard
            !action.template.isEmpty,
            action.template.utf8.count <= HwattakPluginLimits.maximumTemplateUTF8Bytes,
            !action.template.unicodeScalars.contains(where: Self.isForbiddenTemplateScalar)
        else {
            throw PluginSystemError.invalidManifest("action.template is empty or too large")
        }

        var remainder = action.template
        Self.allowedTokens.forEach {
            remainder = remainder.replacingOccurrences(of: $0, with: "")
        }
        guard !remainder.contains("{{"), !remainder.contains("}}") else {
            throw PluginSystemError.invalidManifest("action.template contains an unknown token")
        }

        if schemaVersion == HwattakPluginLimits.legacyManifestSchemaVersion {
            guard
                action.output == .showText
                    || action.output == .copyText
                    || action.output == .openURL
            else {
                throw PluginSystemError.invalidManifest(
                    "schemaVersion 1 does not support \(action.output.rawValue)"
                )
            }
            guard
                !action.template.contains("{{page.text}}"),
                !action.template.contains("{{page.text.urlEncoded}}")
            else {
                throw PluginSystemError.invalidManifest(
                    "schemaVersion 1 does not support current-page text tokens"
                )
            }
        }

        if action.output == .openURL {
            guard action.template.lowercased().hasPrefix("https://") else {
                throw PluginSystemError.invalidManifest("openURL templates must start with https://")
            }
            guard
                !action.template.contains("{{selection}}"),
                !action.template.contains("{{document.name}}"),
                !action.template.contains("{{page.text}}"),
                !action.template.contains("{{page.text.urlEncoded}}")
            else {
                throw PluginSystemError.invalidManifest(
                    "URL text must use a .urlEncoded token; current-page text is panel-only"
                )
            }
        }

        switch action.output {
        case .showText, .copyText, .openURL:
            guard
                !action.template.contains("{{page.text}}"),
                !action.template.contains("{{page.text.urlEncoded}}")
            else {
                throw PluginSystemError.invalidManifest(
                    "current-page text tokens are supported only by translatePanel"
                )
            }
            break
        case .translatePanel:
            guard action.template == "{{selection}}" || action.template == "{{page.text}}" else {
                throw PluginSystemError.invalidManifest(
                    "translatePanel template must be exactly {{selection}} or {{page.text}}"
                )
            }
        case .youtubePanel, .browserPanel:
            guard action.template.lowercased().hasPrefix("https://") else {
                throw PluginSystemError.invalidManifest(
                    "web panel templates must start with https://"
                )
            }
            guard !Self.allowedTokens.contains(where: { action.template.contains($0) }) else {
                throw PluginSystemError.invalidManifest(
                    "browser and YouTube panels cannot send PDF data in their initial URL"
                )
            }
            guard
                let url = URL(string: action.template),
                url.scheme?.lowercased() == "https",
                AIEndpointPolicy.isValidExternalWebURL(url)
            else {
                throw PluginSystemError.invalidManifest(
                    "web panel template must be a public HTTPS URL"
                )
            }
            if action.output == .youtubePanel {
                guard PluginWebURLPolicy.allows(url, scope: .youtube) else {
                    throw PluginSystemError.invalidManifest(
                        "youtubePanel must use an allowed YouTube HTTPS destination"
                    )
                }
            } else {
                guard PluginWebURLPolicy.allows(url, scope: .publicWeb) else {
                    throw PluginSystemError.invalidManifest(
                        "browserPanel must use an allowed public HTTPS destination"
                    )
                }
            }
        }
    }

    private func validateIdentifier(
        _ value: String,
        field: String,
        requiresDot: Bool
    ) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard
            (1...128).contains(value.utf8.count),
            value == value.lowercased(),
            value.unicodeScalars.allSatisfy(allowed.contains),
            value.first?.isLetter == true,
            value.last != ".",
            value.last != "-",
            !value.contains(".."),
            (!requiresDot || value.contains("."))
        else {
            throw PluginSystemError.invalidManifest("\(field) is not a safe lowercase identifier")
        }
    }

    private func validatePlainText(
        _ value: String,
        field: String,
        maximumBytes: Int,
        allowsLineBreaks: Bool = false
    ) throws {
        let forbidden = value.unicodeScalars.contains { scalar in
            if Self.isForbiddenFormatControl(scalar) { return true }
            if allowsLineBreaks, scalar == "\n" || scalar == "\t" { return false }
            return CharacterSet.controlCharacters.contains(scalar)
        }
        guard
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.utf8.count <= maximumBytes,
            !forbidden
        else {
            throw PluginSystemError.invalidManifest("\(field) is empty, too large, or contains control characters")
        }
    }

    private static func isForbiddenFormatControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0
            || (0x202A...0x202E).contains(scalar.value)
            || (0x2066...0x2069).contains(scalar.value)
            || scalar.value == 0x200E
            || scalar.value == 0x200F
    }

    private static func isForbiddenTemplateScalar(_ scalar: Unicode.Scalar) -> Bool {
        if isForbiddenFormatControl(scalar) { return true }
        if scalar == "\n" || scalar == "\t" { return false }
        return CharacterSet.controlCharacters.contains(scalar)
    }

    private func rejectUnknownKeys(
        in object: [String: Any],
        allowed: Set<String>,
        context: String
    ) throws {
        let unknown = Set(object.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw PluginSystemError.invalidManifest(
                "unknown \(context) field: \(unknown.joined(separator: ", "))"
            )
        }
    }
}

/// A deliberately small RFC 8259 structural scanner used only to reject
/// duplicate object members before Foundation normalizes the JSON object.
/// String keys are decoded with `JSONDecoder`, so escaped and literal spellings
/// of the same key (for example `"name"` and `"na\u006de"`) also collide.
private struct StrictJSONDuplicateKeyValidator {
    private let bytes: [UInt8]
    private var index = 0

    static func validate(_ data: Data) throws {
        // Plug-in manifests are specified as UTF-8. Reject legacy encodings and
        // a BOM instead of allowing different parsers to interpret them.
        guard String(data: data, encoding: .utf8) != nil,
              !data.starts(with: [0xEF, 0xBB, 0xBF]) else {
            throw PluginSystemError.invalidManifest("manifest.json must be UTF-8 without a byte-order mark")
        }

        var scanner = Self(bytes: Array(data))
        try scanner.parseValue(depth: 0)
        scanner.skipWhitespace()
        guard scanner.index == scanner.bytes.count else {
            throw PluginSystemError.invalidManifest("manifest.json contains trailing data")
        }
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= 64 else {
            throw PluginSystemError.invalidManifest("manifest.json nesting is too deep")
        }
        skipWhitespace()
        guard let byte = currentByte else { throw invalidJSON() }
        switch byte {
        case UInt8(ascii: "{"):
            try parseObject(depth: depth)
        case UInt8(ascii: "["):
            try parseArray(depth: depth)
        case UInt8(ascii: "\""):
            _ = try parseString()
        case UInt8(ascii: "t"):
            try consumeLiteral("true")
        case UInt8(ascii: "f"):
            try consumeLiteral("false")
        case UInt8(ascii: "n"):
            try consumeLiteral("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            try parseNumber()
        default:
            throw invalidJSON()
        }
    }

    private mutating func parseObject(depth: Int) throws {
        try consume(UInt8(ascii: "{"))
        skipWhitespace()
        if consumeIfPresent(UInt8(ascii: "}")) { return }

        var keys: Set<String> = []
        while true {
            skipWhitespace()
            guard currentByte == UInt8(ascii: "\"") else { throw invalidJSON() }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw PluginSystemError.invalidManifest("manifest.json contains a duplicate object key: \(key)")
            }
            skipWhitespace()
            try consume(UInt8(ascii: ":"))
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "}")) { return }
            try consume(UInt8(ascii: ","))
        }
    }

    private mutating func parseArray(depth: Int) throws {
        try consume(UInt8(ascii: "["))
        skipWhitespace()
        if consumeIfPresent(UInt8(ascii: "]")) { return }

        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "]")) { return }
            try consume(UInt8(ascii: ","))
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        try consume(UInt8(ascii: "\""))
        while let byte = currentByte {
            if byte == UInt8(ascii: "\"") {
                index += 1
                let encoded = Data(bytes[start..<index])
                do {
                    return try JSONDecoder().decode(String.self, from: encoded)
                } catch {
                    throw invalidJSON()
                }
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard currentByte != nil else { throw invalidJSON() }
            }
            index += 1
        }
        throw invalidJSON()
    }

    private mutating func parseNumber() throws {
        let start = index
        while let byte = currentByte, Self.numberBytes.contains(byte) {
            index += 1
        }
        guard index > start else { throw invalidJSON() }
        let encoded = Data(bytes[start..<index])
        do {
            _ = try JSONDecoder().decode(Double.self, from: encoded)
        } catch {
            throw invalidJSON()
        }
    }

    private mutating func consumeLiteral(_ literal: StaticString) throws {
        let expected = Array(String(describing: literal).utf8)
        guard bytes[index...].starts(with: expected) else { throw invalidJSON() }
        index += expected.count
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard currentByte == expected else { throw invalidJSON() }
        index += 1
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard currentByte == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte, Self.whitespaceBytes.contains(byte) {
            index += 1
        }
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func invalidJSON() -> PluginSystemError {
        .invalidManifest("manifest.json is not valid JSON")
    }

    private static let whitespaceBytes: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
    private static let numberBytes = Set("-+0123456789.eE".utf8)
}
