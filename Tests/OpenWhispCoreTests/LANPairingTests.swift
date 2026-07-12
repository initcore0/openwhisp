import XCTest
@testable import OpenWhispCore

/// The pairing-payload cross-repo contract (MAK-51 WP6): the QR JSON the Mac mints
/// and the iOS `PairingService` decodes. Round-trip, version guard, PSK length,
/// and deterministic minting over the RNG seam.
final class LANPairingTests: XCTestCase {

    /// A deterministic RNG for reproducible PSK bytes in tests.
    private struct FixedBytes: RandomBytesGenerating {
        let byte: UInt8
        func randomBytes(count: Int) -> Data { Data(repeating: byte, count: count) }
    }

    func testPayloadRoundTrips() throws {
        let payload = LANPairingPayload(
            peerID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            displayName: "Max's MacBook Pro",
            psk: Data(repeating: 7, count: 32).base64EncodedString(),
            serviceInstanceName: "OpenWhisp-Max")
        let data = try payload.qrData()
        let decoded = try LANPairingPayload.decode(from: data)
        XCTAssertEqual(decoded, payload)
    }

    func testDecodeRejectsFutureVersion() {
        let json = """
        {"version":999,"peerID":"11111111-1111-1111-1111-111111111111",\
        "displayName":"X","psk":"AAAA","serviceInstanceName":"S"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try LANPairingPayload.decode(from: json)) { err in
            guard case LANPairingPayload.DecodeError.unsupportedVersion(let found, let supported) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(found, 999)
            XCTAssertEqual(supported, LANPairingPayload.currentVersion)
        }
    }

    func testDecodeRejectsMalformed() {
        XCTAssertThrowsError(try LANPairingPayload.decode(from: Data("not json".utf8))) { err in
            guard case LANPairingPayload.DecodeError.malformed = err else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func testDecodeToleratesUnknownFutureField() throws {
        // Additive forward-compat: an extra key from a newer Mac is ignored.
        let json = """
        {"version":1,"peerID":"11111111-1111-1111-1111-111111111111",\
        "displayName":"X","psk":"\(Data(repeating: 1, count: 32).base64EncodedString())",\
        "serviceInstanceName":"S","futureField":42}
        """.data(using: .utf8)!
        let decoded = try LANPairingPayload.decode(from: json)
        XCTAssertEqual(decoded.displayName, "X")
    }

    func testPSKBytesValidatesLength() {
        let good = LANPairingPayload(
            peerID: UUID(), displayName: "X",
            psk: Data(repeating: 9, count: 32).base64EncodedString(), serviceInstanceName: "S")
        XCTAssertEqual(good.pskBytes?.count, 32)

        let tooShort = LANPairingPayload(
            peerID: UUID(), displayName: "X",
            psk: Data(repeating: 9, count: 16).base64EncodedString(), serviceInstanceName: "S")
        XCTAssertNil(tooShort.pskBytes)

        let garbage = LANPairingPayload(
            peerID: UUID(), displayName: "X", psk: "not-base64!!", serviceInstanceName: "S")
        XCTAssertNil(garbage.pskBytes)
    }

    func testMintProducesCorrectLengthPSK() {
        let psk = LANPairingMint.newPSK(using: SystemRandomBytes())
        let bytes = Data(base64Encoded: psk)
        XCTAssertEqual(bytes?.count, LANPairingPayload.pskByteCount)
    }

    func testMintIsRandomAcrossCalls() {
        // Two real mints must differ (astronomically unlikely to collide).
        XCTAssertNotEqual(LANPairingMint.newPSK(), LANPairingMint.newPSK())
    }

    func testMakePayloadUsesInjectedRNG() {
        let peer = UUID()
        let payload = LANPairingMint.makePayload(
            peerID: peer, displayName: "Mac", serviceInstanceName: "OpenWhisp-Mac",
            using: FixedBytes(byte: 0xAB))
        XCTAssertEqual(payload.peerID, peer)
        XCTAssertEqual(payload.pskBytes, Data(repeating: 0xAB, count: 32))
    }

    func testBonjourConstantsMatchArchitecture() {
        XCTAssertEqual(LANBridgeService.bonjourType, "_openwhisp._tcp")
    }
}
