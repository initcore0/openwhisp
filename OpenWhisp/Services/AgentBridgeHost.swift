import Foundation
// In the mac app's flat swiftc glob these types are in-module (no import); the
// sync loopback SwiftPM target compiles this file as its own module and imports
// the core. `canImport` is false in the glob (no such module) and true in SwiftPM.
#if canImport(OpenWhispCore)
import OpenWhispCore
#endif

// The Agent Bridge host seam, extracted from AgentBridgeServer.swift so BOTH the
// UNIX-socket server (app) and the LAN bridge server + its loopback harness drive
// the same contract. Foundation-only; app-target for the glob build, and included
// verbatim in the `openwhisp-sync-loopback` executable target (see Package.swift).

/// Callbacks the Agent Bridge server invokes **on the main thread** — the server
/// hops via its main-thread bridge before every call, so implementations may
/// touch main-only AppState state directly. AppState conforms.
protocol AgentBridgeHost: AnyObject {
    /// A read-only status snapshot.
    func bridgeStatus() -> BridgeWire.StatusResult
    /// Recent dictation history, newest first, capped to `limit`.
    func bridgeHistory(limit: Int) -> [BridgeWire.HistoryEntryDTO]
    /// The capability tokens this build actually implements (grows as dictate /
    /// refine are wired). Advertised in `bridge.hello`.
    func bridgeCapabilities() -> [String]
    /// The consent posture `clientName` would get right now (stored per-scope
    /// policies + this-run grants), WITHOUT prompting: a per-scope map plus a
    /// summary scalar (`.granted` only if every scope is already allowed,
    /// `.denied` only if every scope is denied, else `.pending`). Advertised in
    /// `bridge.hello`; per-scope resolution happens per call in
    /// `bridgeResolveConsent`.
    func bridgeConsentSnapshot(clientName: String) -> (summary: BridgeWire.ConsentState, scopes: [String: BridgeWire.ConsentState])
    /// Resolve consent for `clientName` for a SPECIFIC `scope` (presenting the
    /// consent window if that scope's stored policy requires it). `completion`
    /// fires on the main thread with allow/deny; the server blocks its connection
    /// thread until it does.
    func bridgeResolveConsent(clientName: String, scope: AgentScope, completion: @escaping (Bool) -> Void)
    /// Note a completed agent call on the client's record (for the settings pane).
    func bridgeDidCall(clientName: String, tool: String)
    /// Start an agent-initiated dictation. `completion` (main thread) delivers the
    /// result when the session finalizes or on timeout; the server blocks its
    /// connection thread until then.
    func bridgeStartDictation(
        clientName: String, prompt: String?, timeoutSeconds: Int, language: String?,
        context: BridgeWire.DictateContext?,
        completion: @escaping (Result<BridgeWire.DictateResult, BridgeWire.ErrorObject>) -> Void
    )
    /// Finalize the active agent dictation (agent said the user is done). No-op on
    /// a user session; returns whether an agent session was stopped.
    func bridgeStopAgentDictation() -> Bool
    /// Cancel the active agent dictation (no transcript). No-op on a user session.
    func bridgeCancelAgentDictation() -> Bool
    /// Refine `text` per `instruction` with the user's LLM. `completion` (main
    /// thread) delivers the refined text or an error (which carries the original
    /// text for a fail-open agent). The server blocks its connection thread.
    func bridgeRefine(
        clientName: String, text: String, instruction: String,
        completion: @escaping (Result<String, BridgeWire.ErrorObject>) -> Void
    )

    // MARK: P2P sync (MAK-51 WP0b seam; real impls WP6-mac).
    //
    // Default implementations below keep a host that doesn't sync compiling:
    // manifest reports an empty peer, pull returns an empty bundle, push refuses
    // (accepted:false) so nothing is silently dropped. AppState overrides all three
    // with the real store-backed handlers (AppState+Sync.swift); the `sync`
    // capability is only advertised by a build that implements them.

    /// A read-only manifest of this device's syncable sections (hashes, history
    /// head, per-section updatedAt) for the peer's `SyncEngine.plan`.
    func bridgeSyncManifest() -> BridgeWire.SyncManifestResult
    /// The requested sections + history delta since the cursor.
    func bridgeSyncPull(params: BridgeWire.SyncPullParams) -> BridgeWire.SyncBundleResult
    /// Merge the peer's offered bundle + history delta (boring v1 merge policy),
    /// returning what was accepted/merged.
    func bridgeSyncPush(params: BridgeWire.SyncBundleResult) -> BridgeWire.SyncPushResult
}

extension AgentBridgeHost {
    func bridgeSyncManifest() -> BridgeWire.SyncManifestResult {
        BridgeWire.SyncManifestResult(
            schemaVersion: ConfigBundle.currentSchemaVersion,
            vocabHash: "", profilesHash: "", modesHash: "", packsHash: "",
            historyHead: BridgeWire.SyncHistoryHead(count: 0, newestID: nil, newestDate: nil),
            updatedAt: [:]
        )
    }
    func bridgeSyncPull(params: BridgeWire.SyncPullParams) -> BridgeWire.SyncBundleResult {
        BridgeWire.SyncBundleResult(bundle: ConfigBundle(), historyEntries: [])
    }
    func bridgeSyncPush(params: BridgeWire.SyncBundleResult) -> BridgeWire.SyncPushResult {
        BridgeWire.SyncPushResult(accepted: false)
    }
}
