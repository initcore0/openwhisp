import Foundation
// Same-module in the mac app glob; a separate module (imports core) in the sync
// loopback SwiftPM target. See AgentBridgeHost.swift for the guard rationale.
#if canImport(OpenWhispCore)
import OpenWhispCore
#endif

// App-target file (NOT in OpenWhispCore's Package.swift sources), but deliberately
// Foundation-only and dependency-light so the loopback harness executable can link
// it too. It holds NO transport and NO AppKit — just the sync-verb logic over an
// abstract store seam, driving the tested `SyncMerge` funnel.

/// The live-store seam the sync verbs read/write. `AppState` conforms (mapping to
/// its `@Published` vocabulary/profiles/modes/history), and the loopback harness
/// supplies a file-backed conformer, so the EXACT same verb handlers exercise both.
///
/// All accessors are main-actor-free value snapshots + whole-list setters: the
/// caller (AppState on the main thread, the harness on its own queue) owns
/// threading. Packs are read-only content-hash identity (bundled resources on the
/// Mac), so there is no pack setter — only a hash for the manifest.
protocol SyncStore: AnyObject {
    var syncVocabulary: Vocabulary { get set }
    var syncProfiles: [AppProfile] { get set }
    var syncModes: [Mode] { get set }
    var syncHistory: [TranscriptionEntry] { get set }
    /// Content hash of the device's packs section for the manifest (identity only).
    /// The Mac's packs are bundled read-only resources, never merged in from a peer.
    func syncPacksHash() -> String
    /// The pack bundles this device would OFFER on a pull (its bundled config packs
    /// as ConfigBundles), so a peer can import them. Empty when none.
    func syncPackBundles() -> [ConfigBundle]
}

/// The real implementations of the three sync verbs (`sync.manifest` / `sync.pull`
/// / `sync.push`), factored out of any transport so they are shared by the app and
/// the loopback harness and are driven entirely by the tested pure `SyncMerge`.
///
/// A push is idempotent because `SyncMerge.merge` is: pushing the same payload
/// twice merges zero on the second apply. The store setters are only invoked when a
/// section actually changed, so a no-op push doesn't churn the on-disk files.
struct SyncVerbHandlers {

    let store: SyncStore

    // MARK: sync.manifest

    func manifest() -> BridgeWire.SyncManifestResult {
        let vocab = store.syncVocabulary
        let profiles = store.syncProfiles
        let modes = store.syncModes
        let history = store.syncHistory

        var updatedAt: [String: String] = [:]
        // Vocabulary's coarse LWW signal = newest substitution stamp (terms are
        // set-union and carry no stamp).
        if let v = SyncMerge.newestUpdatedAt(vocab.substitutions, updatedAt: { $0.updatedAt }) {
            updatedAt[BridgeWire.SyncSection.vocabulary.rawValue] = v
        }
        if let p = SyncMerge.newestUpdatedAt(profiles, updatedAt: { $0.updatedAt }) {
            updatedAt[BridgeWire.SyncSection.profiles.rawValue] = p
        }
        if let m = SyncMerge.newestUpdatedAt(modes, updatedAt: { $0.updatedAt }) {
            updatedAt[BridgeWire.SyncSection.modes.rawValue] = m
        }
        if let h = SyncMerge.historyHead(history).newestDate {
            updatedAt[BridgeWire.SyncSection.history.rawValue] = h
        }

        return BridgeWire.SyncManifestResult(
            schemaVersion: ConfigBundle.currentSchemaVersion,
            vocabHash: SyncMerge.contentHash(vocab),
            profilesHash: SyncMerge.contentHash(profiles),
            modesHash: SyncMerge.contentHash(modes),
            packsHash: store.syncPacksHash(),
            historyHead: SyncMerge.historyHead(history),
            updatedAt: updatedAt)
    }

    // MARK: sync.pull

    /// Assemble a ConfigBundle carrying ONLY the requested sections (absent/empty
    /// `want` → every section) plus the history delta since the cursor.
    func pull(_ params: BridgeWire.SyncPullParams) -> BridgeWire.SyncBundleResult {
        let want: Set<BridgeWire.SyncSection>
        if let w = params.want, !w.isEmpty {
            want = Set(w)
        } else {
            want = Set(BridgeWire.SyncSection.allCases)
        }

        var bundle = ConfigBundle(profiles: nil, modes: nil, vocabulary: nil)
        if want.contains(.vocabulary) { bundle.vocabulary = store.syncVocabulary }
        if want.contains(.profiles)   { bundle.profiles = store.syncProfiles }
        if want.contains(.modes)      { bundle.modes = store.syncModes }
        // Packs are offered as extra bundles the peer can import; the v1 wire's
        // SyncBundleResult carries a single ConfigBundle, so packs merge into the
        // pulled bundle's vocabulary/profiles/modes only if the peer asked for
        // packs. For v1 we fold nothing automatically (Mac packs are read-only and
        // the phone imports them through its own pack path); the section is present
        // in the manifest for identity, but pull returns the live config, not packs.

        let history: [TranscriptionEntry]
        if want.contains(.history) {
            history = SyncMerge.historyDelta(store.syncHistory, sinceCursor: params.sinceHistoryCursor)
        } else {
            history = []
        }

        return BridgeWire.SyncBundleResult(bundle: bundle, historyEntries: history)
    }

    // MARK: sync.push

    /// Merge a peer's offered bundle + history delta into the local stores with the
    /// boring v1 policy, writing back only the sections that actually changed.
    /// Refuses (accepted:false, no writes) a bundle whose schema is newer than this
    /// build understands — mirrors ConfigBundle's reject-from-the-future.
    func push(_ params: BridgeWire.SyncBundleResult) -> BridgeWire.SyncPushResult {
        guard params.bundle.schemaVersion <= ConfigBundle.currentSchemaVersion else {
            return BridgeWire.SyncPushResult(accepted: false)
        }

        let outcome = SyncMerge.merge(
            localVocabulary: store.syncVocabulary,
            localProfiles: store.syncProfiles,
            localModes: store.syncModes,
            localHistory: store.syncHistory,
            incomingBundle: params.bundle,
            incomingHistory: params.historyEntries)

        // Write back only changed sections so a no-op push doesn't churn stores.
        if outcome.counts.vocabulary > 0 { store.syncVocabulary = outcome.vocabulary }
        if outcome.counts.profiles > 0   { store.syncProfiles = outcome.profiles }
        if outcome.counts.modes > 0      { store.syncModes = outcome.modes }
        if outcome.counts.history > 0    { store.syncHistory = outcome.history }

        return BridgeWire.SyncPushResult(accepted: true, mergedCounts: outcome.counts)
    }
}
