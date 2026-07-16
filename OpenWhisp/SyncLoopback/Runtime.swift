import Foundation
#if canImport(OpenWhispCore)
import OpenWhispCore
#endif

// The runtime for the standalone LANBridgeServer boot (MAK-51 WP6 loopback
// harness), factored so it lives in the SAME module as the LAN transport (it uses
// the internal LANBridgeServer / SyncStore / SyncVerbHandlers / AgentBridgeHost).
// `main.swift` is a thin `runSyncLoopback()` caller; the E2E test @testable-imports
// this module and starts a LANBridgeServer directly against temp stores.
//
// Environment (all required unless noted) — see scripts/sync-loopback-server.sh:
//   OPENWHISP_SYNC_PSK          base64 of the 32-byte pre-shared key (both sides)
//   OPENWHISP_SYNC_PORT         TCP port to bind on 127.0.0.1
//   OPENWHISP_SYNC_PEER_ID      UUID the client presents as the TLS identity hint
//   OPENWHISP_SYNC_FIXTURE_DIR  dir with vocabulary/profiles/modes/history .json;
//                               merged pushes are written BACK here to assert on.

// MARK: - File-backed sync store

/// A `SyncStore` reading/writing the four JSON files in the fixture dir. Whole-list
/// setters persist immediately, so a `sync.push` merge is observable on disk.
final class FileSyncStore: SyncStore {
    private let dir: URL
    private let ioQueue = DispatchQueue(label: "sync.loopback.store")

    init(directory: URL) {
        self.dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private func loadJSON<T: Decodable>(_ name: String, default def: T) -> T {
        guard let data = try? Data(contentsOf: url(name)),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return def }
        return value
    }

    private func saveJSON<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    var syncVocabulary: Vocabulary {
        get { ioQueue.sync { loadJSON("vocabulary.json", default: .empty) } }
        set { ioQueue.sync { saveJSON(newValue, "vocabulary.json") } }
    }
    var syncProfiles: [AppProfile] {
        get { ioQueue.sync { loadJSON("profiles.json", default: []) } }
        set { ioQueue.sync { saveJSON(newValue, "profiles.json") } }
    }
    var syncModes: [Mode] {
        get { ioQueue.sync { loadJSON("modes.json", default: []) } }
        set { ioQueue.sync { saveJSON(newValue, "modes.json") } }
    }
    var syncHistory: [TranscriptionEntry] {
        get { ioQueue.sync { loadJSON("history.json", default: []) } }
        set {
            ioQueue.sync {
                let sorted = newValue.sorted { $0.date > $1.date }
                saveJSON(Array(sorted.prefix(TranscriptionHistoryStore.maxEntries)), "history.json")
            }
        }
    }
    func syncPacksHash() -> String { "" } // no bundled packs in the harness
    func syncPackBundles() -> [ConfigBundle] { [] }
}

// MARK: - Minimal AgentBridgeHost

/// The harness host: real sync verbs (via `SyncVerbHandlers`), and a trivial
/// consent policy — the paired peer is pre-consented for `sync` (pairing IS the
/// out-of-band consent), everything else denied. Dictate/refine aren't exercised.
final class LoopbackHost: AgentBridgeHost {
    let handlers: SyncVerbHandlers
    init(store: SyncStore) { self.handlers = SyncVerbHandlers(store: store) }

    func bridgeStatus() -> BridgeWire.StatusResult {
        BridgeWire.StatusResult(
            appVersion: "loopback", engine: "none", model: "none", sessionActive: false,
            llmConfigured: false, llmProvider: "none", sendsTextToCloud: false, historyEnabled: true)
    }
    func bridgeHistory(limit: Int) -> [BridgeWire.HistoryEntryDTO] { [] }
    func bridgeCapabilities() -> [String] {
        [BridgeWire.Capability.sync, BridgeWire.Capability.history]
    }
    func bridgeConsentSnapshot(clientName: String) -> (summary: BridgeWire.ConsentState, scopes: [String: BridgeWire.ConsentState]) {
        (.pending, [AgentScope.sync.rawValue: .granted])
    }
    func bridgeResolveConsent(clientName: String, scope: AgentScope, completion: @escaping (Bool) -> Void) {
        completion(scope == .sync) // sync pre-consented; others denied in the harness
    }
    func bridgeDidCall(clientName: String, tool: String) {}
    func bridgeStartDictation(clientName: String, prompt: String?, timeoutSeconds: Int, language: String?, completion: @escaping (Result<BridgeWire.DictateResult, BridgeWire.ErrorObject>) -> Void) {
        completion(.failure(.domain(.internalError, message: "dictate not supported in loopback")))
    }
    func bridgeStopAgentDictation() -> Bool { false }
    func bridgeCancelAgentDictation() -> Bool { false }
    func bridgeRefine(clientName: String, text: String, instruction: String, completion: @escaping (Result<String, BridgeWire.ErrorObject>) -> Void) {
        completion(.failure(.domain(.llmUnavailable, message: "refine not supported in loopback", originalText: text)))
    }

    // Real sync verbs.
    func bridgeSyncManifest() -> BridgeWire.SyncManifestResult { handlers.manifest() }
    func bridgeSyncPull(params: BridgeWire.SyncPullParams) -> BridgeWire.SyncBundleResult { handlers.pull(params) }
    func bridgeSyncPush(params: BridgeWire.SyncBundleResult) -> BridgeWire.SyncPushResult { handlers.push(params) }
}

// MARK: - Boot

/// The executable entry point (called from `main.swift`). Reads the environment,
/// boots a real `LANBridgeServer` on 127.0.0.1 with a pinned PSK + port + file
/// store, prints "READY <port>" once listening, and runs the main run loop forever.
public func runSyncLoopback() {
    DispatchQueue.main.async { bootLoopback() }
    RunLoop.main.run()
}

// A module-scoped strong ref so the server outlives boot.
@MainActor private var loopbackServer: LANBridgeServer?

@MainActor
private func bootLoopback() {
    let env = ProcessInfo.processInfo.environment

    guard let pskB64 = env["OPENWHISP_SYNC_PSK"],
          let pskBytes = Data(base64Encoded: pskB64),
          pskBytes.count == LANPairingPayload.pskByteCount else {
        FileHandle.standardError.write(Data("FATAL: OPENWHISP_SYNC_PSK must be base64 of 32 bytes\n".utf8))
        exit(64)
    }
    guard let portStr = env["OPENWHISP_SYNC_PORT"], let port = UInt16(portStr) else {
        FileHandle.standardError.write(Data("FATAL: OPENWHISP_SYNC_PORT must be a port number\n".utf8))
        exit(64)
    }
    let peerID = env["OPENWHISP_SYNC_PEER_ID"].flatMap(UUID.init(uuidString:))
        ?? UUID(uuidString: "0BADF00D-0000-0000-0000-00000000CAFE")!
    let fixtureDir = URL(fileURLWithPath: env["OPENWHISP_SYNC_FIXTURE_DIR"] ?? NSTemporaryDirectory())

    let store = FileSyncStore(directory: fixtureDir)
    let host = LoopbackHost(store: store)

    let server = LANBridgeServer(
        host: host,
        pskProvider: { [peerID: pskBytes] },
        deviceName: { "OpenWhisp Loopback" },
        instanceName: { "OpenWhisp-Loopback" },
        onPeerHandshake: { id, name in
            // Visible in the harness log so the iOS integration test can assert
            // the identity binding fired (peer proof verified).
            FileHandle.standardError.write(Data("sync-loopback: peer \(id) hello as \"\(name)\"\n".utf8))
        })
    loopbackServer = server
    server.start(forcedPort: port)

    func announceWhenReady(attempt: Int) {
        if server.boundPort != nil {
            print("READY \(server.boundPort ?? port)")
            fflush(stdout)
        } else if attempt < 100 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                announceWhenReady(attempt: attempt + 1)
            }
        } else {
            FileHandle.standardError.write(Data("FATAL: listener never became ready\n".utf8))
            exit(70)
        }
    }
    announceWhenReady(attempt: 0)
}
