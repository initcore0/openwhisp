import Foundation

// The Mac side of P2P sync (MAK-51 WP6): AppState as the live `SyncStore` +
// the REAL sync verb handlers (overriding the no-op AgentBridgeHost defaults) +
// the pairing lifecycle the settings pane drives. The merge itself is the tested
// pure `SyncMerge` funnel (via `SyncVerbHandlers`); nothing here re-decides policy.

// MARK: - SyncStore (live stores)

extension AppState: SyncStore {
    var syncVocabulary: Vocabulary {
        get { vocabulary }
        set { vocabulary = newValue } // @Published didSet debounces the save
    }

    var syncProfiles: [AppProfile] {
        get { profiles }
        set { profiles = newValue } // @Published didSet persists via AppProfileStore
    }

    var syncModes: [Mode] {
        get { modes }
        set { modes = newValue } // @Published didSet persists via ModeStore
    }

    var syncHistory: [TranscriptionEntry] {
        // The `historyEnabled` privacy toggle governs sync exactly like it
        // governs recording and the bridge's history.list: when the user turned
        // history OFF, sync must neither ship residual local entries to a peer
        // nor write a peer's entries into this Mac's history.json.
        get { historyEnabled ? history : [] }
        set {
            guard historyEnabled else { return }
            // Restore the store's newest-first invariant + retention cap after a
            // merge appended entries in arbitrary date order, then persist.
            let sorted = newValue.sorted { $0.date > $1.date }
            history = Array(sorted.prefix(TranscriptionHistoryStore.maxEntries))
            TranscriptionHistoryStore.save(history)
        }
    }

    /// The store's retention cap, so a push merge only counts entries that will
    /// actually survive (see SyncStore.syncHistoryRetentionLimit).
    var syncHistoryRetentionLimit: Int? { TranscriptionHistoryStore.maxEntries }

    /// Content hash of the bundled config packs, so a peer's manifest can tell if
    /// its pack set differs. Packs are read-only bundled resources; identity only.
    func syncPacksHash() -> String {
        SyncMerge.contentHash(bundledConfigPacks())
    }

    /// The bundled packs projected as their ConfigBundles, offered on a pull.
    func syncPackBundles() -> [ConfigBundle] {
        bundledConfigPacks().map(\.bundle)
    }
}

// MARK: - Sync verb handlers (override AgentBridgeHost defaults with real stores)

extension AppState {
    /// Shared handler struct bound to `self` as the live store.
    private var syncHandlers: SyncVerbHandlers { SyncVerbHandlers(store: self) }

    func bridgeSyncManifest() -> BridgeWire.SyncManifestResult {
        syncHandlers.manifest()
    }

    func bridgeSyncPull(params: BridgeWire.SyncPullParams) -> BridgeWire.SyncBundleResult {
        syncHandlers.pull(params)
    }

    func bridgeSyncPush(params: BridgeWire.SyncBundleResult) -> BridgeWire.SyncPushResult {
        syncHandlers.push(params)
    }
}

// MARK: - Pairing lifecycle (driven by the settings pane)

extension AppState {

    /// A stable Bonjour service instance name for this Mac, shared in the QR so the
    /// phone can find this specific device. Derived from the host name; the PSK, not
    /// the name, is what authenticates.
    var syncServiceInstanceName: String {
        let base = Host.current().localizedName ?? "Mac"
        // Bonjour instance names are UTF-8 and <= 63 bytes; keep it simple + short.
        return "OpenWhisp-" + base.replacingOccurrences(of: " ", with: "-")
    }

    /// Enter pairing mode: STAGE a fresh pairing (new peer id + PSK, in memory
    /// only — it persists on the phone's first proven handshake), show its QR, and
    /// bring the LAN listener up so the scanning phone can connect with the new
    /// PSK. Called when the "Pair iPhone…" sheet opens.
    func beginPairing() {
        let payload = pairingStore.mintPairing(
            macDisplayName: Host.current().localizedName ?? "Mac",
            serviceInstanceName: syncServiceInstanceName)
        pendingPairingPayload = payload
        // Restart the listener so it picks up the just-staged PSK, and keep it
        // running while the pane is open even if this is the first pairing.
        lanBridgeServer.stop()
        lanBridgeServer.setPairingModeActive(true, hasPairedPeers: pairingStore.hasPairedPeers)
    }

    /// Leave pairing mode: drop the shown QR, DISCARD an unproven staged pairing
    /// (its PSK dies here — an abandoned QR must not stay scannable-later), and
    /// restart the listener so the discarded PSK leaves the live snapshot too.
    /// The restart resolves to "keep running" iff a confirmed device is paired.
    func endPairing() {
        pendingPairingPayload = nil
        pairingStore.discardPendingPairing()
        lanBridgeServer.stop()
        lanBridgeServer.setPairingModeActive(false, hasPairedPeers: pairingStore.hasPairedPeers)
    }

    /// Unpair a device: destroy its PSK, drop it from the list, and RESTART the
    /// listener so it re-snapshots the PSK set — otherwise the unpaired device's
    /// PSK would linger in the running listener's snapshot (it's captured at
    /// listener-start) and still authenticate until the next restart. `stop()`
    /// also tears down that device's in-flight connection. If no devices remain
    /// (and the pane is closed) the restart resolves to "stay stopped".
    func unpairDevice(_ peerID: UUID) {
        pairingStore.unpair(peerID: peerID)
        // Unpair = FULL revocation: also drop the device's consent record, or the
        // phone would linger in the Agent Bridge clients list with its standing
        // sync grant (a re-pair mints a new peer id, so the record is pure residue).
        revokeAgentClient(LANBridgeService.clientName(forPeerID: peerID))
        objectWillChange.send() // the pane reads pairingStore.pairedPeers directly
        lanBridgeServer.stop()
        lanBridgeServer.refresh(hasPairedPeers: pairingStore.hasPairedPeers)
    }

    /// The paired devices for the settings list.
    var syncPairedPeers: [PairedPeer] { pairingStore.pairedPeers }
}
