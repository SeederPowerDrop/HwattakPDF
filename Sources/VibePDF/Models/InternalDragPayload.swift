// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Opaque text carried by in-process drags.
///
/// A system text UTI is intentionally used by the views because it is
/// delivered reliably by AppKit. The launch nonce and payload kind prevent a
/// canceled drag's stale SwiftUI state from turning unrelated text into an
/// internal move when the provider contents are validated at drop time.
enum InternalDragPayload {
    private static let version = "v1"
    private static let launchNonce = UUID().uuidString.lowercased()
    private static let namespace = "hwattak-internal-drag"

    static func encodedValue(for id: UUID, kind: String) -> String {
        [namespace, version, launchNonce, kind, id.uuidString.lowercased()]
            .joined(separator: ":")
    }

    static func decode(_ value: String, expectedKind: String) -> UUID? {
        let expectedPrefix = [namespace, version, launchNonce, expectedKind]
            .joined(separator: ":") + ":"
        guard value.hasPrefix(expectedPrefix) else { return nil }
        let idValue = String(value.dropFirst(expectedPrefix.count))
        return UUID(uuidString: idValue)
    }

}
