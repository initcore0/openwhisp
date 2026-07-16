import Foundation
import CryptoKit

/// The out-of-band **pairing payload** the Mac renders as a QR (openwhisp menu →
/// "Pair iPhone…") for the phone's camera to scan (ARCHITECTURE §6.5). It carries
/// everything the phone needs to open a TLS-PSK LAN connection back to this Mac:
/// the Mac's peer id, a display name, the freshly-minted 32-byte pre-shared key
/// (base64), and the Bonjour service instance name to look for.
///
/// Foundation-only + `Codable`, so it lives in `OpenWhispCore`: the exact JSON
/// shape is a BINDING cross-repo contract (the iOS `PairingService` decodes it),
/// and its encode/decode + PSK minting are unit-tested with `swift test`. Nothing
/// here touches Security/Network — key GENERATION uses a CSPRNG seam so the pure
/// logic is testable, and the app supplies the real system RNG.
public struct LANPairingPayload: Codable, Equatable, Sendable {
    /// Payload format version, so the phone can reject a Mac from the future. Bump
    /// only on a breaking change to these fields.
    public var version: Int
    /// The MAC's stable peer id (a UUID). Becomes the TLS-PSK identity HINT the
    /// phone presents on connect, which the Mac maps back to this pairing's PSK +
    /// its `AgentClientRecord`.
    public var peerID: UUID
    /// Human-friendly name of the Mac ("Max's MacBook Pro"), shown in the phone's
    /// paired-devices list. Display only.
    public var displayName: String
    /// The 32-byte pre-shared key, base64-encoded. Minted fresh at pairing; the
    /// phone stores it in its Keychain and uses it for TLS 1.3 PSK. Destroyed on
    /// unpair on both ends.
    public var psk: String
    /// The Bonjour service INSTANCE name the Mac advertises (`_openwhisp._tcp`),
    /// so the phone can find this specific Mac on the LAN. Display/discovery only —
    /// authentication is the PSK, never the name.
    public var serviceInstanceName: String

    /// The current payload format version.
    public static let currentVersion = 1

    /// The 32-byte PSK length the whole protocol assumes.
    public static let pskByteCount = 32

    public init(
        version: Int = LANPairingPayload.currentVersion,
        peerID: UUID,
        displayName: String,
        psk: String,
        serviceInstanceName: String
    ) {
        self.version = version
        self.peerID = peerID
        self.displayName = displayName
        self.psk = psk
        self.serviceInstanceName = serviceInstanceName
    }

    // Tolerant decode: unknown future fields are ignored; `version` is required so
    // a garbage QR fails fast rather than half-decoding.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.peerID = try c.decode(UUID.self, forKey: .peerID)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.psk = try c.decode(String.self, forKey: .psk)
        self.serviceInstanceName = try c.decode(String.self, forKey: .serviceInstanceName)
    }

    private enum CodingKeys: String, CodingKey {
        case version, peerID, displayName, psk, serviceInstanceName
    }

    // MARK: - Encode / decode for the QR

    /// Compact JSON (no pretty-print, stable key order) suitable for a QR code —
    /// smaller is denser and scans faster. The iOS side decodes this exact bytes.
    public func qrData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public enum DecodeError: Error, Equatable {
        case malformed(String)
        case unsupportedVersion(found: Int, supported: Int)
    }

    /// Decode a scanned QR payload, rejecting a version from the future.
    public static func decode(from data: Data) throws -> LANPairingPayload {
        let payload: LANPairingPayload
        do {
            payload = try JSONDecoder().decode(LANPairingPayload.self, from: data)
        } catch {
            throw DecodeError.malformed(error.localizedDescription)
        }
        guard payload.version <= currentVersion else {
            throw DecodeError.unsupportedVersion(found: payload.version, supported: currentVersion)
        }
        return payload
    }

    /// The decoded 32-byte PSK, or nil if the base64 is malformed / wrong length.
    /// The transport must refuse a payload whose PSK isn't exactly 32 bytes.
    public var pskBytes: Data? {
        guard let data = Data(base64Encoded: psk), data.count == Self.pskByteCount else { return nil }
        return data
    }
}

/// A CSPRNG seam so PSK minting is testable in `swift test` (inject a deterministic
/// generator) while the app supplies the real system RNG. The default uses Swift's
/// `SystemRandomNumberGenerator`, which is a CSPRNG on Apple platforms.
public protocol RandomBytesGenerating {
    /// Fill and return `count` cryptographically-random bytes.
    func randomBytes(count: Int) -> Data
}

/// The production generator: Swift's `SystemRandomNumberGenerator` (CSPRNG on
/// Apple platforms), so no Security-framework dependency leaks into core.
public struct SystemRandomBytes: RandomBytesGenerating {
    public init() {}
    public func randomBytes(count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        var data = Data(count: count)
        for i in 0..<count {
            data[i] = UInt8.random(in: .min ... .max, using: &rng)
        }
        return data
    }
}

/// Mints pairing material + builds the payload. Pure over its RNG seam.
public enum LANPairingMint {

    /// A freshly-minted 32-byte PSK, base64-encoded.
    public static func newPSK(using rng: RandomBytesGenerating = SystemRandomBytes()) -> String {
        rng.randomBytes(count: LANPairingPayload.pskByteCount).base64EncodedString()
    }

    /// Build a full pairing payload for this Mac. `peerID` is the Mac's stable id;
    /// `serviceInstanceName` is the Bonjour instance the listener advertises.
    public static func makePayload(
        peerID: UUID,
        displayName: String,
        serviceInstanceName: String,
        using rng: RandomBytesGenerating = SystemRandomBytes()
    ) -> LANPairingPayload {
        LANPairingPayload(
            peerID: peerID,
            displayName: displayName,
            psk: newPSK(using: rng),
            serviceInstanceName: serviceInstanceName
        )
    }
}

/// A paired iPhone as the MAC remembers it. The PSK is NOT stored in this record
/// (it lives in the Keychain, keyed by `id`); this is the display/index metadata
/// persisted alongside. Foundation-only + `Codable` so the list logic is tested in
/// `swift test`; the concrete `PairingStore` (Keychain + JSON index) is app-side.
public struct PairedPeer: Codable, Equatable, Identifiable, Sendable {
    /// The phone's stable id — the TLS-PSK identity HINT it presents on connect,
    /// which the Mac maps back to this record + its Keychain PSK.
    public var id: UUID
    /// The phone's display name ("Max's iPhone"), shown in the paired-devices list.
    public var displayName: String
    /// When this pairing was minted. For the settings list + audit.
    public var createdAt: Date
    /// The MAC's own peer id that was shared in the QR for THIS pairing (so a
    /// re-paired Mac that rotated its id can still be reasoned about). Display only.
    public var localPeerID: UUID

    public init(id: UUID, displayName: String, createdAt: Date, localPeerID: UUID) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.localPeerID = localPeerID
    }
}

/// The pure, on-device index of paired peers (the metadata half — PSKs live in the
/// Keychain). Value-semantic and Foundation-only so upsert/remove/lookup are unit-
/// tested; the app wraps it with Keychain PSK storage + JSON persistence.
public struct PairedPeerIndex: Codable, Equatable {
    public var peers: [PairedPeer]

    public init(peers: [PairedPeer] = []) {
        self.peers = peers
    }

    public func peer(id: UUID) -> PairedPeer? {
        peers.first { $0.id == id }
    }

    /// Insert or replace a peer (keyed by id).
    public mutating func upsert(_ peer: PairedPeer) {
        if let i = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[i] = peer
        } else {
            peers.append(peer)
        }
    }

    public mutating func remove(id: UUID) {
        peers.removeAll { $0.id == id }
    }

    public var isEmpty: Bool { peers.isEmpty }
}

/// Bonjour + wire constants for the LAN bridge, defined ONCE for both repos.
public enum LANBridgeService {
    /// The Bonjour service type — the SAME token the iOS side browses for and the
    /// mac app declares in `NSBonjourServices` (ARCHITECTURE D10).
    public static let bonjourType = "_openwhisp._tcp"
    /// TXT-record key: the Mac's human display name.
    public static let txtKeyDeviceName = "dn"
    /// TXT-record key: the human-readable wire version label (BridgeWire.wireVersionLabel).
    public static let txtKeyWireVersion = "wv"
    /// TXT-record key: the Mac's LOCAL peer id (UUID string) — lets a browsing
    /// phone match a discovered instance to a stored pairing without connecting
    /// (the QR carries the same value as `localPeerID`).
    public static let txtKeyPeerID = "pid"

    /// The consent-record client name derived from a paired peer id — defined ONCE
    /// so the LAN server (recording consent) and unpair (revoking it) can never
    /// drift on the naming and leave an orphaned grant behind.
    public static func clientName(forPeerID id: UUID) -> String {
        "iPhone (\(id.uuidString.prefix(8)))"
    }
}

/// Application-layer peer-identity proof for the LAN link (cross-repo BINDING
/// contract, both repos run this exact derivation).
///
/// **Why TLS alone isn't enough:** the listener registers one PSK per paired
/// peer, and a completed handshake proves the client held *some* registered PSK —
/// but Network.framework's metadata API (`sec_protocol_metadata_access_pre_shared_keys`)
/// enumerates the PSKs the LOCAL side configured, not the one that was negotiated,
/// so with two or more paired devices the server cannot tell WHICH peer connected.
/// Binding consent to a guessed identity would let device B inherit device A's
/// standing grants.
///
/// So the client proves its identity in `bridge.hello`: it sends its `peerID`
/// plus `peerProof = base64(HMAC-SHA256(key: psk, msg: "openwhisp-peer-binding:" + peerID))`.
/// Only the holder of that peer's PSK can compute it; another paired device can
/// neither compute it (different PSK) nor capture it (it travels only inside a
/// TLS session keyed to the claimed peer's PSK). The server verifies against the
/// PSK it stored at pairing and closes the connection on any mismatch.
public enum LANPeerProof {
    /// The HMAC'd message for a peer id. Version-prefixed so a future scheme can
    /// coexist without ambiguity.
    private static func message(forPeerID id: UUID) -> Data {
        Data("openwhisp-peer-binding:\(id.uuidString)".utf8)
    }

    /// Compute the proof the CLIENT sends in `bridge.hello.peerProof` (base64).
    public static func proof(psk: Data, peerID: UUID) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: message(forPeerID: peerID), using: SymmetricKey(data: psk))
        return Data(mac).base64EncodedString()
    }

    /// Constant-time server-side verification of a claimed identity.
    public static func verify(proofBase64: String, psk: Data, peerID: UUID) -> Bool {
        guard let provided = Data(base64Encoded: proofBase64) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            provided, authenticating: message(forPeerID: peerID),
            using: SymmetricKey(data: psk))
    }
}
