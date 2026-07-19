import Foundation
import Network
import CryptoKit
import os
// Same-module in the mac app glob; a separate module (imports core) in the sync
// loopback SwiftPM target. See AgentBridgeHost.swift for the guard rationale.
#if canImport(OpenWhispCore)
import OpenWhispCore
#endif

// App-target only (NOT in Package.swift's OpenWhispCore sources): it uses
// Network.framework (NWListener/Bonjour/TLS-PSK) and drives the SAME
// BridgeRouter/AgentBridgeHost pipeline the UNIX-socket AgentBridgeServer uses.
// The pure routing/validation + merge it depends on live in core (tested).

/// The **LAN** counterpart of `AgentBridgeServer` (MAK-51 WP6): an `NWListener`
/// that advertises `_openwhisp._tcp` over Bonjour and accepts TLS 1.3 PSK
/// connections from paired iPhones, then feeds each connection's NDJSON frames into
/// the EXISTING `BridgeRouter` → `AgentBridgeHost` pipeline — routing, consent,
/// rate-limit, and every verb handler reused verbatim.
///
/// The only substitution vs. the UNIX server is **authentication**: there is no
/// cross-device code-signing identity, so a peer is authenticated by "the TLS
/// handshake completed with a PSK we minted at pairing". Each paired device has one
/// PSK; the client presents its peer UUID as the TLS-PSK identity hint, and we
/// supply that peer's PSK to the handshake. A hint we don't recognize gets no PSK →
/// the handshake fails → the connection never yields a byte.
///
/// **Lifecycle:** default-off. It runs ONLY while at least one device is paired, or
/// while the pairing pane is open (`setPairingModeActive`). `refresh()` starts or
/// stops it to match that condition, so a user who never pairs pays zero cost and
/// nothing is exposed on the LAN.
@MainActor
final class LANBridgeServer {

    private weak var host: AgentBridgeHost?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenWhisp", category: "LANBridge")

    /// Resolves a peer UUID (the TLS identity hint) to its PSK. Provided by the
    /// PairingStore; captured as a snapshot closure so the transport queue never
    /// re-enters the main actor per handshake.
    private let pskProvider: () -> [UUID: Data]
    /// The Mac's display name for the Bonjour TXT record.
    private let deviceName: () -> String
    /// The Bonjour service INSTANCE name — the same string the QR carries as
    /// `serviceInstanceName`, so the phone can browse for this specific Mac.
    /// Advertising under the OS default machine name (the old behavior) broke
    /// that contract: the phone would never find the instance the QR named.
    private let instanceName: () -> String
    /// Called (main actor) when a peer completes a PSK-authenticated hello, with the
    /// peer UUID and the client name it announced — so the PairingStore can record
    /// the phone's display name.
    private let onPeerHandshake: (UUID, String) -> Void

    private var listener: NWListener?
    /// The port the listener actually bound (dynamic). Nil until started. Exposed for
    /// the loopback harness / tests.
    private(set) var boundPort: UInt16?

    /// True while the "Pair iPhone…" pane is open — the server runs even with no
    /// paired peers so the first phone can connect with a freshly-minted PSK.
    private var pairingModeActive = false

    /// The transport queue for all Network.framework callbacks.
    private let queue = DispatchQueue(label: "app.openwhisp.lanbridge")

    /// Live accepted connections, retained until each closes. Without this the
    /// per-connection `LANConnection` (built in `newConnectionHandler`) would
    /// deallocate the instant the handler returns, and its `[weak self]` receive
    /// callbacks would silently no-op — the handshake completes but no frame is
    /// ever read. Only ever touched on the transport `queue` (both
    /// newConnectionHandler and onClosed run there), hence `nonisolated(unsafe)`:
    /// the serial queue is the synchronization, not the main actor.
    private nonisolated(unsafe) var connections: [ObjectIdentifier: LANConnection] = [:]

    init(
        host: AgentBridgeHost,
        pskProvider: @escaping () -> [UUID: Data],
        deviceName: @escaping () -> String,
        instanceName: @escaping () -> String,
        onPeerHandshake: @escaping (UUID, String) -> Void
    ) {
        self.host = host
        self.pskProvider = pskProvider
        self.deviceName = deviceName
        self.instanceName = instanceName
        self.onPeerHandshake = onPeerHandshake
    }

    /// Hard cap on concurrently-accepted connections. Anything valid needs 1–2
    /// (one phone syncing); the cap exists so a LAN host opening TCP connections
    /// that stall mid-handshake can't accumulate unbounded half-open sessions.
    private nonisolated static let maxConcurrentConnections = 8

    // MARK: - Lifecycle

    var isRunning: Bool { listener != nil }

    /// Mark the pairing pane open/closed; (re)evaluates whether the server should run.
    func setPairingModeActive(_ active: Bool, hasPairedPeers: Bool) {
        pairingModeActive = active
        refresh(hasPairedPeers: hasPairedPeers)
    }

    /// Start the listener iff it should run (paired peers exist, or pairing mode is
    /// active) and it isn't already running; otherwise stop it. Idempotent.
    func refresh(hasPairedPeers: Bool) {
        let shouldRun = hasPairedPeers || pairingModeActive
        if shouldRun && listener == nil {
            start()
        } else if !shouldRun && listener != nil {
            stop()
        }
    }

    /// Start on an ephemeral port (port 0 → OS-assigned), or a FIXED port when
    /// `forcedPort` is set (the loopback harness pins one for the iOS test).
    func start(forcedPort: UInt16? = nil) {
        guard listener == nil else { return }
        do {
            // One PSK snapshot per listener lifetime, shared by the TLS layer
            // (handshake) and every connection (hello-proof verification) — both
            // must see the same set or a peer could pass one gate and fail the other.
            let pskSnapshot = pskProvider()
            let params = makeTLSParameters(psks: pskSnapshot)
            let listener: NWListener
            if let forcedPort, let port = NWEndpoint.Port(rawValue: forcedPort) {
                listener = try NWListener(using: params, on: port)
            } else {
                listener = try NWListener(using: params) // ephemeral
            }

            // Advertise over Bonjour under the INSTANCE NAME the QR carries
            // (`serviceInstanceName`) — the phone browses for exactly this name to
            // find the Mac it paired with, so leaving the name to the OS default
            // (the machine name) made the QR's promise dead on arrival. The TXT
            // record carries the display name + wire version for the browse UI.
            let txt = NWTXTRecord([
                LANBridgeService.txtKeyDeviceName: deviceName(),
                LANBridgeService.txtKeyWireVersion: BridgeWire.wireVersionLabel,
            ])
            listener.service = NWListener.Service(
                name: instanceName(), type: LANBridgeService.bonjourType, txtRecord: txt)

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        Task { @MainActor in self.boundPort = port }
                    }
                case .failed(let err):
                    self.log.error("LAN bridge listener failed: \(String(describing: err), privacy: .public)")
                    Task { @MainActor in self.stop() }
                default:
                    break
                }
            }
            // Build each accepted connection on the transport queue (nonisolated).
            // The host ref + callbacks are captured as plain values so no main-actor
            // hop is needed here; LANConnection does its own main-thread hops. The
            // session is RETAINED in `connections` (keyed by identity) until it
            // closes — otherwise it would deallocate the moment this handler returns
            // and its receive callbacks would never fire.
            let host = self.host
            let log = self.log
            let queue = self.queue
            let onHandshake = self.onPeerHandshake
            // `connections` is only ever touched on `queue` (newConnectionHandler
            // and onClosed both run there), so this box needs no extra lock.
            listener.newConnectionHandler = { [weak self] conn in
                // Pre-auth flood guard: refuse connections beyond the cap outright.
                guard let self, self.connections.count < Self.maxConcurrentConnections else {
                    log.notice("LAN bridge: connection cap reached; refusing")
                    conn.cancel()
                    return
                }
                let session = LANConnection(
                    connection: conn, queue: queue, host: host, log: log,
                    psks: pskSnapshot,
                    onPeerHandshake: { peerID, clientName in
                        Task { @MainActor in onHandshake(peerID, clientName) }
                    },
                    onClosed: { [weak self] closed in
                        // Runs on `queue`. Drop our retain so the session deallocates.
                        self?.connections.removeValue(forKey: ObjectIdentifier(closed))
                    })
                self.connections[ObjectIdentifier(session)] = session
                session.start()
            }
            listener.start(queue: queue)
            self.listener = listener
            log.info("LAN bridge listening (Bonjour \(LANBridgeService.bonjourType, privacy: .public))")
        } catch {
            log.error("LAN bridge failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
        // Drop every live accepted connection too — unpairing the last device must
        // TEAR DOWN its in-flight session, not just stop accepting new ones (the
        // deliverable: unpair = PSK destruction + drop connections). Mutating
        // `connections` on the transport queue keeps it single-threaded.
        queue.async { [weak self] in
            guard let self else { return }
            for (_, conn) in self.connections { conn.forceClose() }
            self.connections.removeAll()
        }
        log.info("LAN bridge stopped")
    }

    // MARK: - TLS-PSK parameters

    /// Mutual TLS-PSK with a pre-shared key per paired peer. We ADD every paired
    /// peer's PSK (each labeled with that peer's UUID as the TLS identity) via
    /// `sec_protocol_options_add_pre_shared_key`; TLS negotiates whichever PSK the
    /// connecting client offers. A client that offers a PSK/identity we never added
    /// cannot complete the handshake, so no unpaired device yields a byte. WHICH
    /// paired peer connected is NOT taken from the TLS layer — the metadata API
    /// enumerates the locally-configured PSKs, not the negotiated one — but from
    /// the `bridge.hello` peerID + HMAC proof (see `LANPeerProof`), verified
    /// against the same PSK snapshot.
    ///
    /// **TLS version (cross-repo BINDING contract):** we request the range TLS
    /// 1.2…1.3 and pin the PSK ciphersuite `TLS_PSK_WITH_AES_128_GCM_SHA256`. The
    /// intent is TLS 1.3, but Network.framework's NWListener does not accept an
    /// external TLS-1.3 PSK on the SDK the CI runners ship (the handshake fails with
    /// errSSLPeerHandshakeFail); it negotiates cleanly down to TLS 1.2 with the PSK
    /// AEAD suite, which preserves the security posture that matters here — a
    /// 32-byte pre-shared key, AEAD encryption, NO certificate/CA, and nothing
    /// readable on the wire before the handshake. The iOS `SyncKit` client MUST use
    /// the SAME version range + ciphersuite (and add its (psk, peerID-identity)
    /// pair) or the handshake won't complete.
    ///
    /// The PSK set is snapshotted at listener-start; a device paired while the
    /// listener is up gets picked up on the next `refresh()` restart (pairing-mode
    /// keeps the listener running and the store restarts it), so a fresh pairing's
    /// first connect always finds its PSK.
    private func makeTLSParameters(psks: [UUID: Data]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        // Pin the PSK AEAD ciphersuite so the PSK's associated hash (SHA-256) is
        // defined and both sides agree — without a matching suite the handshake
        // fails. This suite is the TLS-1.2 external-PSK path NWListener accepts.
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)

        // Add one PSK per paired peer, identity = the peer UUID string. Both sides
        // must add the SAME (key, identity) pair; the phone adds its own peer id +
        // PSK from the QR, so the identities match and TLS derives a shared key.
        for (peerID, pskBytes) in psks {
            let keyDD = pskBytes.withUnsafeBytes { DispatchData(bytes: $0) }
            let identityData = Data(peerID.uuidString.utf8)
            let identityDD = identityData.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(
                sec, keyDD as __DispatchData, identityDD as __DispatchData)
        }

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        return params
    }

}

/// One accepted LAN connection: reads NDJSON frames, routes them through the shared
/// `BridgeRouter`, and executes intents against the `AgentBridgeHost` on the main
/// thread — the same contract the UNIX server honors, RESTRICTED to the sync verbs
/// (see `execute`). The peer's identity is the `bridge.hello` peerID claim verified
/// by an HMAC proof under that peer's PSK (`LANPeerProof`) — TLS proves the client
/// held SOME registered PSK; the proof pins WHICH one, so consent can never
/// cross-bind between two paired devices.
private final class LANConnection {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var host: AgentBridgeHost?
    private let log: Logger
    /// The listener's PSK snapshot (peerID → key), for hello-proof verification.
    private let psks: [UUID: Data]
    private let onPeerHandshake: (UUID, String) -> Void
    /// Called (on `queue`) exactly once when this connection closes, so the server
    /// can drop its retain. Guarded by `closedFired` so a failed+cancelled sequence
    /// doesn't call it twice.
    private let onClosed: (LANConnection) -> Void
    private var closedFired = false

    private var buffer = Data()
    private var handshaken = false
    /// The paired peer's UUID, PROVEN by the hello HMAC proof (`LANPeerProof`).
    /// nil until then. This — NOT the client-claimed display name — keys consent.
    private var peerID: UUID?
    /// A stable, human-readable client name derived from the peer, used for consent
    /// records + the settings pane. Set at handshake.
    private var clientName: String = "iPhone"

    init(
        connection: NWConnection, queue: DispatchQueue,
        host: AgentBridgeHost?, log: Logger,
        psks: [UUID: Data],
        onPeerHandshake: @escaping (UUID, String) -> Void,
        onClosed: @escaping (LANConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.host = host
        self.log = log
        self.psks = psks
        self.onPeerHandshake = onPeerHandshake
        self.onClosed = onClosed
    }

    /// A connection that hasn't completed `bridge.hello` within this window is
    /// dropped — stalled/half-open TLS handshakes must not linger retained.
    private static let handshakeTimeout: TimeInterval = 15

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // The TLS handshake completed with a valid PSK (an invalid one
                // never reaches .ready) — but WHICH peer holds it is only proven
                // by the upcoming hello's HMAC proof. Start reading frames.
                self.receive()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Handshake timeout: a connection that stalls before completing hello
        // (mid-TLS or silent post-TLS) is torn down instead of lingering.
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
            guard let self, !self.handshaken else { return }
            self.log.notice("LAN bridge: handshake timeout; closing")
            self.close()
        }
    }

    /// Cancel the connection and notify the server once (so it drops its retain).
    private func close() {
        connection.cancel()
        guard !closedFired else { return }
        closedFired = true
        onClosed(self)
    }

    /// Server-initiated teardown (listener stopped / device unpaired). Cancels the
    /// connection WITHOUT re-notifying the server — the caller (`stop()`) is already
    /// clearing the `connections` map, so a re-entrant `onClosed` would mutate it
    /// mid-iteration. Must be called on the transport queue.
    func forceClose() {
        closedFired = true // suppress the onClosed callback from the cancel path
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            // Cap a single partial frame so a hostile peer can't force unbounded buffering.
            if self.buffer.count > BridgeWire.maxFrameBytes {
                self.log.notice("LAN bridge: frame exceeded cap; closing")
                self.close()
                return
            }
            self.receive()
        }
    }

    private func drainFrames() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if lineData.isEmpty { continue }

            switch BridgeRouter.route(line: lineData, hasHandshaken: handshaken) {
            case .close(let reason):
                log.notice("LAN bridge: closing — \(reason, privacy: .public)")
                close()
                return
            case .error(let id, let err):
                sendError(id: id, error: err)
            case .intent(let intent):
                if !execute(intent) { close(); return }
            }
        }
    }

    // MARK: - Intent execution (shared contract with AgentBridgeServer)

    /// Execute a routed intent, blocking this transport queue until the main-thread
    /// host answers (semaphore bridge, exactly like the UNIX server). Returns false
    /// to close the connection.
    private func execute(_ intent: BridgeRouter.Intent) -> Bool {
        switch intent {
        case .hello(let id, let params):
            // Identity FIRST: the hello must carry a peerID claim + the HMAC proof
            // computed under that peer's PSK (LANPeerProof). TLS proved the client
            // holds SOME PSK from the snapshot; the proof pins WHICH peer it is,
            // so a second paired device can never inherit another's consent. Any
            // missing/unknown/unverifiable claim closes the connection.
            guard let claimed = params.peerID.flatMap(UUID.init(uuidString:)),
                  let psk = psks[claimed],
                  let proof = params.peerProof,
                  LANPeerProof.verify(proofBase64: proof, psk: psk, peerID: claimed) else {
                log.notice("LAN bridge: hello identity proof failed; closing")
                sendError(id: id, error: .domain(
                    .consentDenied,
                    message: "peer identity proof missing or invalid — re-pair this device"))
                return false
            }
            do {
                let negotiated = try BridgeWire.negotiatedProtocolVersion(clientProtocolVersion: params.protocolVersion)
                peerID = claimed
                clientName = LANBridgeService.clientName(forPeerID: claimed)
                // Bind the peer's display name to its pairing record now that the
                // claim is proven (this is what confirms a pending pairing).
                onPeerHandshake(claimed, params.clientName)
                let (caps, appVersion, consent) = onMain { [clientName] in
                    (self.host?.bridgeCapabilities() ?? [],
                     self.host?.bridgeStatus().appVersion ?? "",
                     self.host?.bridgeConsentSnapshot(clientName: clientName)
                        ?? (summary: .pending, scopes: [:]))
                }
                let result = BridgeWire.HelloResult(
                    protocolVersion: negotiated, appVersion: appVersion,
                    capabilities: caps, clientId: claimed.uuidString,
                    consent: consent.summary, consentScopes: consent.scopes)
                send(id: id, result: result)
                handshaken = true
                return true
            } catch {
                sendError(id: id, error: .domain(
                    .unsupportedVersion,
                    message: "client protocol \(params.protocolVersion) is newer than this app supports (\(BridgeWire.protocolVersion)); update OpenWhisp"))
                return false
            }

        case .status(let id):
            let result = onMain { self.host?.bridgeStatus() }
            if let result { send(id: id, result: result) }
            else { sendError(id: id, error: .domain(.internalError, message: "status unavailable")) }
            return true

        case .syncManifest(let id):
            guard consentGranted(BridgeWire.Method.syncManifest.requiredScope!, id: id) else { return true }
            let result = onMain { self.host?.bridgeSyncManifest() }
            if let result {
                onMain { self.host?.bridgeDidCall(clientName: self.clientName, tool: AgentScope.sync.rawValue) }
                send(id: id, result: result)
            } else { sendError(id: id, error: .domain(.internalError, message: "sync manifest unavailable")) }
            return true

        case .syncPull(let id, let params):
            guard consentGranted(BridgeWire.Method.syncPull.requiredScope!, id: id) else { return true }
            let result = onMain { self.host?.bridgeSyncPull(params: params) }
            if let result {
                onMain { self.host?.bridgeDidCall(clientName: self.clientName, tool: AgentScope.sync.rawValue) }
                send(id: id, result: result)
            } else { sendError(id: id, error: .domain(.internalError, message: "sync pull unavailable")) }
            return true

        case .syncPush(let id, let params):
            guard consentGranted(BridgeWire.Method.syncPush.requiredScope!, id: id) else { return true }
            let result = onMain { self.host?.bridgeSyncPush(params: params) }
            if let result {
                onMain { self.host?.bridgeDidCall(clientName: self.clientName, tool: AgentScope.sync.rawValue) }
                send(id: id, result: result)
            } else { sendError(id: id, error: .domain(.internalError, message: "sync push unavailable")) }
            return true

        // The LAN link is the SYNC transport, full stop. The pairing UX promises
        // "sync vocabulary, profiles, modes, and history"; letting the same TLS
        // session drive dictation (the mic), refine (the LLM), or the redacted
        // history DTO would turn a sync pairing into remote agent control — and
        // dictateStop/Cancel had no consent gate at all. Agents get those verbs
        // on the UNIX socket, where the code-signing identity authenticates.
        // These also can't block the shared transport queue for tens of seconds
        // the way a LAN bridge.dictate would.
        case .historyList(let id, _), .dictate(let id, _), .refine(let id, _),
             .transcribeFile(let id, _),
             .dictateStop(let id), .dictateCancel(let id):
            sendError(id: id, error: BridgeWire.ErrorObject(
                code: BridgeWire.ErrorObject.methodNotFound,
                message: "this verb isn't available over the LAN sync link — only sync.* and bridge.status are"))
            return true
        }
    }

    // MARK: - Consent + main-thread bridge

    private func consentGranted(_ scope: AgentScope, id: BridgeWire.RPCID?) -> Bool {
        let granted = blockOnHost(noHost: false) { [clientName] host, done in
            host.bridgeResolveConsent(clientName: clientName, scope: scope, completion: done)
        }
        if !granted {
            sendError(id: id, error: .domain(.consentDenied,
                message: "the user declined this device's \(scope.rawValue) access"))
        }
        return granted
    }

    /// Block this transport queue until a host completion fires on the main thread.
    /// Never called from the main thread (the transport queue is separate), so the
    /// wait can't self-deadlock.
    private func blockOnHost<T>(
        noHost: T, _ start: @escaping (AgentBridgeHost, @escaping (T) -> Void) -> Void
    ) -> T {
        let sem = DispatchSemaphore(value: 0)
        var out = noHost
        DispatchQueue.main.async {
            guard let host = self.host else { sem.signal(); return }
            start(host) { result in out = result; sem.signal() }
        }
        sem.wait()
        return out
    }

    private func onMain<T>(_ body: @escaping () -> T) -> T {
        var result: T!
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { result = body(); sem.signal() }
        sem.wait()
        return result
    }

    // MARK: - Writing responses

    private func send<R: Codable & Sendable>(id: BridgeWire.RPCID?, result: R) {
        writeJSON(BridgeWire.Response(id: id, result: result))
    }

    private func sendError(id: BridgeWire.RPCID?, error: BridgeWire.ErrorObject) {
        writeJSON(BridgeWire.Response<BridgeWire.NoParams>(id: id, error: error))
    }

    private func writeJSON<T: Encodable>(_ value: T) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
