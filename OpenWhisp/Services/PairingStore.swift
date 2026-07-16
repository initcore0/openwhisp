import Foundation

// App-target only (NOT in Package.swift's OpenWhispCore sources): it persists PSKs
// via the concrete `SecretStore` (Keychain) and reads UserDefaults. The pure index
// logic it wraps (`PairedPeerIndex`, `PairedPeer`) lives in core and is tested.

/// The Mac's on-device pairing state for P2P sync (MAK-51 WP6): the stable local
/// peer id, the list of paired iPhones (metadata), and each pairing's 32-byte PSK.
///
/// PSKs are stored in the **Keychain** via the injected `SecretStore` (keyed by the
/// peer UUID under a `sync-psk.<uuid>` account), so the raw key never sits in a
/// plaintext JSON file. The peer metadata index is a small JSON file next to the
/// other stores. Unpair = delete the Keychain PSK AND drop the index entry, so the
/// key is destroyed and the listener can no longer authenticate that peer.
///
/// `@MainActor` so it can be an `@Published`-friendly member of `AppState`; the
/// LAN listener reads a snapshot (`pskLookup()`) under the main actor before
/// handing the transport a plain closure.
@MainActor
final class PairingStore {

    private let secrets: SecretStore
    private(set) var index: PairedPeerIndex

    /// The Mac's stable peer id, minted once and persisted in UserDefaults. Shared
    /// in every QR payload and used as our TLS-PSK identity hint label.
    let localPeerID: UUID

    /// Keychain account prefix for a peer's PSK. The account is `pskAccountPrefix +
    /// uuidString`, distinct per peer so unpairing one never touches another.
    private static let pskAccountPrefix = "sync-psk."
    private static let localPeerIDDefaultsKey = "syncLocalPeerID"

    init(secrets: SecretStore) {
        self.secrets = secrets
        self.localPeerID = Self.loadOrMintLocalPeerID()
        self.index = Self.loadIndex()
    }

    // MARK: - Local identity

    private static func loadOrMintLocalPeerID() -> UUID {
        if let s = UserDefaults.standard.string(forKey: localPeerIDDefaultsKey),
           let id = UUID(uuidString: s) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: localPeerIDDefaultsKey)
        return id
    }

    // MARK: - Paired peers

    var pairedPeers: [PairedPeer] { index.peers }
    /// CONFIRMED peers only — a minted-but-unscanned pairing must not count, or
    /// abandoning the pairing sheet would leave the LAN listener running forever.
    var hasPairedPeers: Bool { !index.isEmpty }

    /// A pairing minted for the open sheet but not yet proven by a handshake.
    /// Held in MEMORY ONLY: nothing touches the Keychain or the index until the
    /// phone actually connects and proves the PSK (`confirmPairing`), so an
    /// abandoned QR leaves no ghost peer, no lingering live key, and no
    /// permanently-running listener. Discarded by `discardPendingPairing()`.
    private(set) var pendingPairing: (peer: PairedPeer, pskBase64: String)?

    /// The PSK bytes for a paired peer, or nil if none/malformed. Read from Keychain.
    func psk(for peerID: UUID) -> Data? {
        guard let b64 = secrets.read(key: Self.pskAccountPrefix + peerID.uuidString),
              let data = Data(base64Encoded: b64),
              data.count == LANPairingPayload.pskByteCount else { return nil }
        return data
    }

    /// A snapshot map of peerID → PSK bytes for every paired peer — plus the
    /// pending (sheet-open) pairing, so the scanning phone's very first connection
    /// authenticates — for the transport to verify incoming TLS handshakes and
    /// hello proofs without calling back onto the actor.
    func pskLookup() -> [UUID: Data] {
        var out: [UUID: Data] = [:]
        for peer in index.peers {
            if let psk = psk(for: peer.id) { out[peer.id] = psk }
        }
        if let pending = pendingPairing,
           let pskData = Data(base64Encoded: pending.pskBase64),
           pskData.count == LANPairingPayload.pskByteCount {
            out[pending.peer.id] = pskData
        }
        return out
    }

    // MARK: - Mint a pairing (Mac shows the QR)

    /// Mint a fresh pairing for a NEW phone: allocate a peer id, generate a 32-byte
    /// PSK, persist both (Keychain PSK + index metadata), and return the QR payload
    /// the settings pane renders. The phone completes pairing by scanning it and
    /// connecting with the PSK.
    ///
    /// `displayName` is this MAC's name (shown on the phone). NOTHING persists
    /// here: the pairing is staged in memory and only becomes a real peer
    /// (Keychain PSK + index entry) when the phone proves the PSK
    /// (`confirmPairing`). Minting again (sheet re-opened) replaces the stage —
    /// the previous unscanned QR's PSK dies with it.
    @discardableResult
    func mintPairing(
        macDisplayName: String,
        serviceInstanceName: String,
        rng: RandomBytesGenerating = SystemRandomBytes()
    ) -> LANPairingPayload {
        let peerID = UUID()
        let psk = LANPairingMint.newPSK(using: rng)
        pendingPairing = (
            peer: PairedPeer(
                id: peerID,
                displayName: "iPhone (pairing…)",
                createdAt: Date(),
                localPeerID: localPeerID),
            pskBase64: psk)

        return LANPairingPayload(
            peerID: peerID,
            displayName: macDisplayName,
            psk: psk,
            serviceInstanceName: serviceInstanceName)
    }

    /// Discard a staged pairing that was never proven (sheet closed / abandoned).
    /// Nothing was persisted, so this is purely dropping the in-memory PSK.
    func discardPendingPairing() {
        pendingPairing = nil
    }

    /// The listener proved a peer's identity (PSK-authenticated hello + HMAC
    /// proof). If it's the staged pairing, PERSIST it now — Keychain PSK + index
    /// entry with the phone's real name; if it's an already-paired peer, refresh
    /// its display name. No-op for an unknown peer (unpaired mid-flight).
    func confirmPairing(peerID: UUID, phoneDisplayName: String) {
        if let pending = pendingPairing, pending.peer.id == peerID {
            secrets.save(pending.pskBase64, key: Self.pskAccountPrefix + peerID.uuidString)
            var peer = pending.peer
            peer.displayName = phoneDisplayName.isEmpty ? peer.displayName : phoneDisplayName
            var idx = index
            idx.upsert(peer)
            commit(idx)
            pendingPairing = nil
            return
        }
        guard var peer = index.peer(id: peerID) else { return }
        peer.displayName = phoneDisplayName.isEmpty ? peer.displayName : phoneDisplayName
        var idx = index
        idx.upsert(peer)
        commit(idx)
    }

    // MARK: - Unpair (destroy the key)

    /// Unpair a device: destroy its PSK in the Keychain and drop the index entry.
    /// After this the listener can no longer authenticate that peer.
    func unpair(peerID: UUID) {
        secrets.save("", key: Self.pskAccountPrefix + peerID.uuidString) // empty = delete
        var idx = index
        idx.remove(id: peerID)
        commit(idx)
    }

    // MARK: - Persistence

    private func commit(_ newIndex: PairedPeerIndex) {
        index = newIndex
        Self.saveIndex(newIndex)
    }

    private static var indexURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("paired-peers.json")
    }

    private static func loadIndex() -> PairedPeerIndex {
        JSONStore.load(from: indexURL, default: PairedPeerIndex(), label: "PairingStore")
    }

    private static func saveIndex(_ index: PairedPeerIndex) {
        JSONStore.save(index, to: indexURL, label: "PairingStore")
    }
}
