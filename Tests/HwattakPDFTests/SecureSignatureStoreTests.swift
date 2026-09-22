// SPDX-License-Identifier: MPL-2.0

import Security
import XCTest
@testable import HwattakPDF

final class SecureSignatureStoreTests: XCTestCase {
    func testVersionedSignatureRoundTripsVectorInputAndCanvasSize() throws {
        let signature = makeSignature()

        let decoded = try SavedSignature.decode(signature.encodedData())

        XCTAssertEqual(decoded, signature)
        XCTAssertEqual(decoded.version, SavedSignature.currentVersion)
        XCTAssertEqual(decoded.canvasSize, CGSize(width: 740, height: 300))
    }

    func testUnsupportedVersionIsRejected() throws {
        let validData = try makeSignature().encodedData()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        object["version"] = 999
        let unsupportedData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try SavedSignature.decode(unsupportedData)) { error in
            XCTAssertEqual(error as? SecureSignatureStoreError, .unsupportedVersion(999))
        }
    }

    func testInvalidOrOversizedPayloadIsRejectedBeforeUse() throws {
        XCTAssertThrowsError(try SavedSignature.decode(Data("not-json".utf8))) { error in
            XCTAssertEqual(error as? SecureSignatureStoreError, .invalidPayload)
        }

        let oversized = Data(
            repeating: 0,
            count: SavedSignature.maximumEncodedByteCount + 1
        )
        XCTAssertThrowsError(try SavedSignature.decode(oversized)) { error in
            XCTAssertEqual(error as? SecureSignatureStoreError, .payloadTooLarge)
        }
    }

    func testSavedTimestampsAreRelativeToEachStrokeAndPreserveTimingDeltas() throws {
        let signature = SavedSignature(
            strokes: [
                SignatureStroke(points: [
                    SignaturePoint(x: 10, y: 20, pressure: 0.4, timestamp: 12_345.5),
                    SignaturePoint(x: 80, y: 70, pressure: 0.7, timestamp: 12_345.75)
                ]),
                SignatureStroke(points: [
                    SignaturePoint(x: 15, y: 22, pressure: 0.5, timestamp: 98_000),
                    SignaturePoint(x: 30, y: 40, pressure: 0.6, timestamp: 98_000.5)
                ])
            ],
            canvasSize: CGSize(width: 740, height: 300)
        )

        XCTAssertEqual(signature.strokes[0].points[0].timestamp, 0)
        XCTAssertEqual(signature.strokes[0].points[1].timestamp, 0.25)
        XCTAssertEqual(signature.strokes[1].points[0].timestamp, 0)
        XCTAssertEqual(signature.strokes[1].points[1].timestamp, 0.5)

        let decoded = try SavedSignature.decode(signature.encodedData())
        XCTAssertEqual(decoded, signature)
    }

    func testLegacyAbsoluteTimestampsAreNormalizedWhenLoaded() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: makeSignature().encodedData()) as? [String: Any]
        )
        var strokes = try XCTUnwrap(object["strokes"] as? [[String: Any]])
        var points = try XCTUnwrap(strokes[0]["points"] as? [[String: Any]])
        points[0]["timestamp"] = 42_000.0
        points[1]["timestamp"] = 42_000.1
        strokes[0]["points"] = points
        object["strokes"] = strokes

        let decoded = try SavedSignature.decode(
            JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.strokes[0].points[0].timestamp, 0)
        XCTAssertEqual(decoded.strokes[0].points[1].timestamp, 0.1, accuracy: 0.000_001)
    }

    func testInvalidCanvasCoordinatesAndStrokeComplexityAreRejected() {
        let tooSmallCanvas = SavedSignature(
            strokes: [SignatureStroke(points: [
                SignaturePoint(x: 0.1, y: 0.1, pressure: 0.5, timestamp: 1)
            ])],
            canvasSize: CGSize(width: 0.5, height: 100)
        )
        XCTAssertThrowsError(try tooSmallCanvas.encodedData()) { error in
            XCTAssertEqual(error as? SecureSignatureStoreError, .invalidPayload)
        }

        let outsideCanvas = SavedSignature(
            strokes: [SignatureStroke(points: [
                SignaturePoint(x: -1, y: 10, pressure: 0.5, timestamp: 1)
            ])],
            canvasSize: CGSize(width: 100, height: 100)
        )
        XCTAssertThrowsError(try outsideCanvas.encodedData()) { error in
            XCTAssertEqual(error as? SecureSignatureStoreError, .invalidPayload)
        }

        let points = (0...SavedSignature.maximumPointsPerStroke).map { index in
            SignaturePoint(
                x: CGFloat(index % 100),
                y: CGFloat(index % 100),
                pressure: 0.5,
                timestamp: Double(index) / 240
            )
        }
        let excessiveStroke = SavedSignature(
            strokes: [SignatureStroke(points: points)],
            canvasSize: CGSize(width: 100, height: 100)
        )
        XCTAssertThrowsError(try excessiveStroke.encodedData()) { error in
            XCTAssertEqual(error as? SecureSignatureStoreError, .invalidPayload)
        }

        let maximumSizedStroke = Array(points.prefix(SavedSignature.maximumPointsPerStroke))
        let excessiveTotal = SavedSignature(
            strokes: [
                SignatureStroke(points: maximumSizedStroke),
                SignatureStroke(points: maximumSizedStroke),
                SignatureStroke(points: [
                    SignaturePoint(x: 1, y: 1, pressure: 0.5, timestamp: 0)
                ])
            ],
            canvasSize: CGSize(width: 100, height: 100)
        )
        XCTAssertThrowsError(try excessiveTotal.encodedData()) { error in
            XCTAssertEqual(error as? SecureSignatureStoreError, .payloadTooLarge)
        }
    }

    func testNonMonotonicOrExcessiveStrokeTimingIsRejected() {
        let nonMonotonic = SavedSignature(
            strokes: [SignatureStroke(points: [
                SignaturePoint(x: 10, y: 10, pressure: 0.5, timestamp: 100),
                SignaturePoint(x: 20, y: 20, pressure: 0.5, timestamp: 99)
            ])],
            canvasSize: CGSize(width: 100, height: 100)
        )
        XCTAssertThrowsError(try nonMonotonic.encodedData())

        let excessiveDuration = SavedSignature(
            strokes: [SignatureStroke(points: [
                SignaturePoint(x: 10, y: 10, pressure: 0.5, timestamp: 100),
                SignaturePoint(
                    x: 20,
                    y: 20,
                    pressure: 0.5,
                    timestamp: 100 + SavedSignature.maximumStrokeDuration + 1
                )
            ])],
            canvasSize: CGSize(width: 100, height: 100)
        )
        XCTAssertThrowsError(try excessiveDuration.encodedData())
    }

    func testKeychainQueryIsUserScopedDeviceOnlyAndNonSynchronizable() throws {
        let store = KeychainSecureSignatureStore(service: "test.service", account: "test.account")
        let query = store.baseQuery

        XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService] as? String, "test.service")
        XCTAssertEqual(query[kSecAttrAccount] as? String, "test.account")
        XCTAssertTrue(cfBoolean(query[kSecUseDataProtectionKeychain]))
        XCTAssertFalse(cfBoolean(query[kSecAttrSynchronizable]))

        let attributes = store.addAttributes(data: Data([1, 2, 3]))
        XCTAssertEqual(
            attributes[kSecAttrAccessible] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )

        // Ad-hoc builds do not have a provisioning-profile access group. The
        // compatibility path remains in this user's login Keychain, never
        // synchronizes, and does not claim unsupported accessibility flags.
        let legacy = store.legacyAddAttributes(data: Data([1, 2, 3]))
        XCTAssertNil(legacy[kSecUseDataProtectionKeychain])
        XCTAssertNil(legacy[kSecAttrAccessible])
        XCTAssertFalse(cfBoolean(legacy[kSecAttrSynchronizable]))
    }

    func testSuccessfulDataProtectionAddDeletesLegacyCopy() throws {
        let operatorSpy = RecordingKeychainItemOperator(
            addStatuses: [errSecSuccess],
            deleteStatuses: [errSecItemNotFound]
        )
        let store = KeychainSecureSignatureStore(
            service: "test.service",
            account: "test.account",
            keychain: operatorSpy
        )

        try store.saveSignature(makeSignature())

        XCTAssertEqual(operatorSpy.addQueries.count, 1)
        XCTAssertEqual(operatorSpy.deleteQueries.count, 1)
        XCTAssertTrue(cfBoolean(operatorSpy.addQueries[0][kSecUseDataProtectionKeychain]))
        XCTAssertNil(operatorSpy.deleteQueries[0][kSecUseDataProtectionKeychain])
    }

    func testSuccessfulDataProtectionUpdateDeletesLegacyCopy() throws {
        let operatorSpy = RecordingKeychainItemOperator(
            addStatuses: [errSecDuplicateItem],
            updateStatuses: [errSecSuccess],
            deleteStatuses: [errSecSuccess]
        )
        let store = KeychainSecureSignatureStore(keychain: operatorSpy)

        try store.saveSignature(makeSignature())

        XCTAssertEqual(operatorSpy.updateCalls.count, 1)
        XCTAssertEqual(operatorSpy.deleteQueries.count, 1)
    }

    func testCleanupFailureIsExplicitAndCanBeRetriedWithoutSavingAgain() throws {
        let operatorSpy = RecordingKeychainItemOperator(
            addStatuses: [errSecSuccess],
            deleteStatuses: [errSecAuthFailed, errSecSuccess]
        )
        let store = KeychainSecureSignatureStore(keychain: operatorSpy)

        XCTAssertThrowsError(try store.saveSignature(makeSignature())) { error in
            XCTAssertEqual(
                error as? SecureSignatureStoreError,
                .legacyCleanupFailed(errSecAuthFailed)
            )
        }
        XCTAssertEqual(operatorSpy.addQueries.count, 1)
        XCTAssertEqual(operatorSpy.deleteQueries.count, 1)

        try store.retryLegacyCleanup()

        XCTAssertEqual(operatorSpy.addQueries.count, 1, "Retry must not write or reapply the signature")
        XCTAssertEqual(operatorSpy.deleteQueries.count, 2)
    }

    func testMissingDataProtectionEntitlementFallsBackWithoutCleanup() throws {
        let operatorSpy = RecordingKeychainItemOperator(
            addStatuses: [errSecMissingEntitlement, errSecSuccess]
        )
        let store = KeychainSecureSignatureStore(keychain: operatorSpy)

        try store.saveSignature(makeSignature())

        XCTAssertEqual(operatorSpy.addQueries.count, 2)
        XCTAssertTrue(cfBoolean(operatorSpy.addQueries[0][kSecUseDataProtectionKeychain]))
        XCTAssertNil(operatorSpy.addQueries[1][kSecUseDataProtectionKeychain])
        XCTAssertTrue(operatorSpy.deleteQueries.isEmpty)
    }

    func testDeleteRemovesLegacyBeforePrimarySoFailureCannotResurrectOldSignature() throws {
        let failedCleanup = RecordingKeychainItemOperator(
            deleteStatuses: [errSecAuthFailed]
        )
        let failedStore = KeychainSecureSignatureStore(keychain: failedCleanup)

        XCTAssertThrowsError(try failedStore.deleteSignature()) { error in
            XCTAssertEqual(
                error as? SecureSignatureStoreError,
                .keychain(errSecAuthFailed)
            )
        }
        XCTAssertEqual(failedCleanup.deleteQueries.count, 1)
        XCTAssertNil(
            failedCleanup.deleteQueries[0][kSecUseDataProtectionKeychain],
            "The primary item must remain when compatibility cleanup fails"
        )

        let successful = RecordingKeychainItemOperator(
            deleteStatuses: [errSecSuccess, errSecSuccess]
        )
        let successfulStore = KeychainSecureSignatureStore(keychain: successful)

        try successfulStore.deleteSignature()

        XCTAssertEqual(successful.deleteQueries.count, 2)
        XCTAssertNil(successful.deleteQueries[0][kSecUseDataProtectionKeychain])
        XCTAssertTrue(cfBoolean(successful.deleteQueries[1][kSecUseDataProtectionKeychain]))
    }

    func testWorkflowReportsPersistedSignatureWithCleanupFailureSeparately() {
        let operatorSpy = RecordingKeychainItemOperator(
            addStatuses: [errSecSuccess],
            deleteStatuses: [errSecAuthFailed, errSecSuccess]
        )
        let store = KeychainSecureSignatureStore(keychain: operatorSpy)
        let signature = makeSignature()

        let outcome = SecureSignatureApplicationWorkflow.applyAndPersist(
            rawStrokes: signature.strokes,
            canvasSize: signature.canvasSize,
            store: store,
            applyToPDF: { true }
        )

        XCTAssertEqual(outcome, .appliedAndSavedButLegacyCleanupFailed)
        XCTAssertNoThrow(try store.retryLegacyCleanup())
        XCTAssertEqual(operatorSpy.addQueries.count, 1)
        XCTAssertEqual(operatorSpy.deleteQueries.count, 2)
    }

    func testInMemoryStoreSupportsLoadReplacementAndDeletionWithoutKeychainAccess() throws {
        let first = makeSignature()
        let store = InMemorySecureSignatureStore()

        XCTAssertNil(try store.loadSignature())
        try store.saveSignature(first)
        XCTAssertEqual(try store.loadSignature(), first)

        let replacement = SavedSignature(
            strokes: [
                SignatureStroke(points: [
                    SignaturePoint(x: 3, y: 4, pressure: 0.4, timestamp: 1),
                    SignaturePoint(x: 9, y: 12, pressure: 0.6, timestamp: 2)
                ])
            ],
            canvasSize: CGSize(width: 500, height: 200)
        )
        try store.saveSignature(replacement)
        XCTAssertEqual(try store.loadSignature(), replacement)

        try store.deleteSignature()
        XCTAssertNil(try store.loadSignature())
    }

    func testStorageFailureDoesNotTurnSuccessfulPDFApplicationIntoFailure() {
        enum ExpectedFailure: Error { case unavailable }
        let signature = makeSignature()
        let store = InMemorySecureSignatureStore()
        store.saveError = ExpectedFailure.unavailable
        var didApplyToPDF = false

        let outcome = SecureSignatureApplicationWorkflow.applyAndPersist(
            rawStrokes: signature.strokes,
            canvasSize: signature.canvasSize,
            store: store,
            applyToPDF: {
                didApplyToPDF = true
                return true
            }
        )

        XCTAssertTrue(didApplyToPDF)
        XCTAssertEqual(outcome, .appliedButStorageFailed)
        XCTAssertNil(store.signature)
    }

    func testFailedPDFApplicationDoesNotReplaceSavedSignature() {
        let original = makeSignature()
        let store = InMemorySecureSignatureStore(signature: original)

        let outcome = SecureSignatureApplicationWorkflow.applyAndPersist(
            rawStrokes: original.strokes,
            canvasSize: original.canvasSize,
            store: store,
            applyToPDF: { false }
        )

        XCTAssertEqual(outcome, .applicationFailed)
        XCTAssertEqual(store.signature, original)
    }

    func testLoadedSignatureScalesToTheCurrentCanvas() {
        let point = SignaturePoint(x: 100, y: 50, pressure: 0.5, timestamp: 1)
        let stroke = SignatureStroke(points: [point])

        let scaled = SignatureSheet.scaledStrokes(
            [stroke],
            from: CGSize(width: 200, height: 100),
            to: CGSize(width: 600, height: 200)
        )

        XCTAssertEqual(scaled[0].id, stroke.id)
        XCTAssertEqual(scaled[0].points[0].x, 300)
        XCTAssertEqual(scaled[0].points[0].y, 100)
        XCTAssertEqual(scaled[0].points[0].pressure, point.pressure)
        XCTAssertEqual(scaled[0].points[0].timestamp, point.timestamp)
    }

    func testScalingRejectsNonFiniteOrOutOfBoundsGeometry() {
        let stroke = SignatureStroke(points: [
            SignaturePoint(x: 1, y: 1, pressure: 0.5, timestamp: 0)
        ])
        XCTAssertTrue(
            SignatureSheet.scaledStrokes(
                [stroke],
                from: CGSize(width: CGFloat.leastNonzeroMagnitude, height: 100),
                to: CGSize(width: 800, height: 300)
            ).isEmpty
        )

        let outside = SignatureStroke(points: [
            SignaturePoint(x: 101, y: 1, pressure: 0.5, timestamp: 0)
        ])
        XCTAssertTrue(
            SignatureSheet.scaledStrokes(
                [outside],
                from: CGSize(width: 100, height: 100),
                to: CGSize(width: 800, height: 300)
            ).isEmpty
        )
    }

    func testUnreadablePayloadErrorsRemainDeletableButKeychainErrorsDoNot() {
        XCTAssertTrue(SignatureSheet.isUnreadableStorageError(
            SecureSignatureStoreError.invalidPayload
        ))
        XCTAssertTrue(SignatureSheet.isUnreadableStorageError(
            SecureSignatureStoreError.unsupportedVersion(99)
        ))
        XCTAssertTrue(SignatureSheet.isUnreadableStorageError(
            SecureSignatureStoreError.payloadTooLarge
        ))
        XCTAssertFalse(SignatureSheet.isUnreadableStorageError(
            SecureSignatureStoreError.keychain(errSecInteractionNotAllowed)
        ))
    }

    @MainActor
    func testCanvasRemovalDropsSensitiveStrokeBuffer() {
        let canvas = SignatureCanvasNSView()
        canvas.replaceStrokes(with: makeSignature().strokes)
        XCTAssertFalse(canvas.strokes.isEmpty)

        canvas.prepareForRemoval()

        XCTAssertTrue(canvas.strokes.isEmpty)
        XCTAssertFalse(canvas.isTrackpadCaptureActive)
    }

    private func makeSignature() -> SavedSignature {
        SavedSignature(
            strokes: [
                SignatureStroke(points: [
                    SignaturePoint(x: 10, y: 20, pressure: 0.4, timestamp: 100),
                    SignaturePoint(x: 80, y: 70, pressure: 0.7, timestamp: 100.1)
                ])
            ],
            canvasSize: CGSize(width: 740, height: 300)
        )
    }

    private func cfBoolean(_ value: Any?) -> Bool {
        guard let value else {
            XCTFail("Missing CFBoolean value")
            return false
        }
        guard let boolean = value as? Bool else {
            XCTFail("Value is not a Boolean")
            return false
        }
        return boolean
    }
}

private final class RecordingKeychainItemOperator: KeychainItemOperating {
    struct UpdateCall {
        let query: [CFString: Any]
        let attributes: [CFString: Any]
    }

    var copyResults: [KeychainCopyResult]
    var addStatuses: [OSStatus]
    var updateStatuses: [OSStatus]
    var deleteStatuses: [OSStatus]

    private(set) var copyQueries: [[CFString: Any]] = []
    private(set) var addQueries: [[CFString: Any]] = []
    private(set) var updateCalls: [UpdateCall] = []
    private(set) var deleteQueries: [[CFString: Any]] = []

    init(
        copyResults: [KeychainCopyResult] = [],
        addStatuses: [OSStatus] = [],
        updateStatuses: [OSStatus] = [],
        deleteStatuses: [OSStatus] = []
    ) {
        self.copyResults = copyResults
        self.addStatuses = addStatuses
        self.updateStatuses = updateStatuses
        self.deleteStatuses = deleteStatuses
    }

    func copyMatching(_ query: [CFString: Any]) -> KeychainCopyResult {
        copyQueries.append(query)
        guard !copyResults.isEmpty else {
            return KeychainCopyResult(status: errSecParam, data: nil)
        }
        return copyResults.removeFirst()
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        addQueries.append(attributes)
        return addStatuses.isEmpty ? errSecParam : addStatuses.removeFirst()
    }

    func update(
        _ query: [CFString: Any],
        attributes: [CFString: Any]
    ) -> OSStatus {
        updateCalls.append(UpdateCall(query: query, attributes: attributes))
        return updateStatuses.isEmpty ? errSecParam : updateStatuses.removeFirst()
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        deleteQueries.append(query)
        return deleteStatuses.isEmpty ? errSecParam : deleteStatuses.removeFirst()
    }
}
