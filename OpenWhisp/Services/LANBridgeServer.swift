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
        onPeerHandshake: @escaping (UUID, String) -> Void
    ) {
        self.host = host
        self.pskProvider = pskProvider
        self.deviceName = deviceName
        self.onPeerHandshake = onPeerHandshake
    }

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
            let params = makeTLSParameters()
            let listener: NWListener
            if let forcedPort, let port = NWEndpoint.Port(rawValue: forcedPort) {
                listener = try NWListener(using: params, on: port)
            } else {
                listener = try NWListener(using: params) // ephemeral
            }

            // Advertise over Bonjour with a TXT record (device name + wire version +
            // peer id). The service instance name is left to the OS unless a peer id
            // is meaningful; the TXT carries the identity the phone matches on.
            let txt = NWTXTRecord([
                LANBridgeService.txtKeyDeviceName: deviceName(),
                LANBridgeService.txtKeyWireVersion: BridgeWire.wireVersionLabel,
            ])
            listener.service = NWListener.Service(
                type: LANBridgeService.bonjourType, txtRecord: txt)

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
                let session = LANConnection(
                    connection: conn, queue: queue, host: host, log: log,
                    onPeerHandshake: { peerID, clientName in
                        Task { @MainActor in onHandshake(peerID, clientName) }
                    },
                    onClosed: { closed in
                        // Runs on `queue`. Drop our retain so the session deallocates.
                        self?.connections.removeValue(forKey: ObjectIdentifier(closed))
                    })
                self?.connections[ObjectIdentifier(session)] = session
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
    /// cannot complete the handshake, so no unpaired device yields a byte. The
    /// connection recovers WHICH peer authenticated post-handshake from the
    /// negotiated PSK identity, binding consent to the paired device.
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
    private func makeTLSParameters() -> NWParameters {
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
        for (peerID, pskBytes) in pskProvider() {
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

/// Convert a `DispatchData` (the negotiated TLS-PSK identity) into `Foundation.Data`.
private func dispatchDataToData(_ dd: DispatchData) -> Data {
    var out = Data(count: dd.count)
    out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        _ = dd.copyBytes(to: raw)
    }
    return out
}

/// One accepted LAN connection: reads NDJSON frames, routes them through the shared
/// `BridgeRouter`, and executes intents against the `AgentBridgeHost` on the main
/// thread — the same contract the UNIX server honors. The peer's identity comes
/// from the TLS handshake (recorded when the metadata verifies), so `clientName` is
/// bound to the paired peer, not to anything the client claims in `bridge.hello`.
private final class LANConnection {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var host: AgentBridgeHost?
    private let log: Logger
    private let onPeerHandshake: (UUID, String) -> Void
    /// Called (on `queue`) exactly once when this connection closes, so the server
    /// can drop its retain. Guarded by `closedFired` so a failed+cancelled sequence
    /// doesn't call it twice.
    private let onClosed: (LANConnection) -> Void
    private var closedFired = false

    private var buffer = Data()
    private var handshaken = false
    /// The paired peer's UUID, learned from the TLS identity once the handshake
    /// completes. nil until then. This — NOT the client-claimed name — keys consent.
    private var peerID: UUID?
    /// A stable, human-readable client name derived from the peer, used for consent
    /// records + the settings pane. Set at handshake.
    private var clientName: String = "iPhone"

    init(
        connection: NWConnection, queue: DispatchQueue,
        host: AgentBridgeHost?, log: Logger,
        onPeerHandshake: @escaping (UUID, String) -> Void,
        onClosed: @escaping (LANConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.host = host
        self.log = log
        self.onPeerHandshake = onPeerHandshake
        self.onClosed = onClosed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // The TLS handshake has completed with a valid PSK (an invalid one
                // never reaches .ready). Recover the peer identity from the
                // negotiated PSK identity so consent is bound to the paired device.
                self.capturePeerIdentity()
                self.receive()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
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

    /// Read the peer UUID from the completed TLS handshake's PSK identity. The
    /// identity we returned in the selection block is the peer UUID string, so a
    /// ready connection always has a recoverable identity; we fall back to a generic
    /// name if the metadata is somehow unavailable (the connection still can't have
    /// reached .ready without a valid PSK).
    private func capturePeerIdentity() {
        guard peerID == nil else { return }
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return }
        let secMeta = metadata.securityProtocolMetadata
        // Iterate the negotiated PSKs; the identity we added is the peer UUID string.
        var recovered: UUID?
        sec_protocol_metadata_access_pre_shared_keys(secMeta) { _, identityDD in
            let idData = dispatchDataToData(identityDD as DispatchData)
            if let idString = String(data: idData, encoding: .utf8),
               let id = UUID(uuidString: idString) {
                recovered = id
            }
        }
        if let id = recovered {
            peerID = id
            clientName = "iPhone (\(id.uuidString.prefix(8)))"
        }
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
            do {
                let negotiated = try BridgeWire.negotiatedProtocolVersion(clientProtocolVersion: params.protocolVersion)
                // Bind the peer's display name to its pairing record now that we
                // know the client name it announced.
                if let peerID {
                    onPeerHandshake(peerID, params.clientName)
                }
                let (caps, appVersion, consent) = onMain { [clientName] in
                    (self.host?.bridgeCapabilities() ?? [],
                     self.host?.bridgeStatus().appVersion ?? "",
                     self.host?.bridgeConsentSnapshot(clientName: clientName)
                        ?? (summary: .pending, scopes: [:]))
                }
                let result = BridgeWire.HelloResult(
                    protocolVersion: negotiated, appVersion: appVersion,
                    capabilities: caps, clientId: (peerID ?? UUID()).uuidString,
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
            guard consentGranted(.sync, id: id) else { return true }
            let result = onMain { self.host?.bridgeSyncManifest() }
            if let result {
                onMain { self.host?.bridgeDidCall(clientName: self.clientName, tool: AgentScope.sync.rawValue) }
                send(id: id, result: result)
            } else { sendError(id: id, error: .domain(.internalError, message: "sync manifest unavailable")) }
            return true

        case .syncPull(let id, let params):
            guard consentGranted(.sync, id: id) else { return true }
            let result = onMain { self.host?.bridgeSyncPull(params: params) }
            if let result {
                onMain { self.host?.bridgeDidCall(clientName: self.clientName, tool: AgentScope.sync.rawValue) }
                send(id: id, result: result)
            } else { sendError(id: id, error: .domain(.internalError, message: "sync pull unavailable")) }
            return true

        case .syncPush(let id, let params):
            guard consentGranted(.sync, id: id) else { return true }
            let result = onMain { self.host?.bridgeSyncPush(params: params) }
            if let result {
                onMain { self.host?.bridgeDidCall(clientName: self.clientName, tool: AgentScope.sync.rawValue) }
                send(id: id, result: result)
            } else { sendError(id: id, error: .domain(.internalError, message: "sync push unavailable")) }
            return true

        // Dictate/refine/history over the LAN reuse the same host + consent path.
        case .historyList(let id, let params):
            guard consentGranted(.history, id: id) else { return true }
            let limit = BridgeRouter.resolvedHistoryLimit(params.limit)
            let entries = onMain { self.host?.bridgeHistory(limit: limit) ?? [] }
            onMain { self.host?.bridgeDidCall(clientName: self.clientName, tool: AgentScope.history.rawValue) }
            send(id: id, result: BridgeWire.HistoryListResult(entries: entries))
            return true

        case .dictate(let id, let params):
            guard consentGranted(.dictate, id: id) else { return true }
            let timeout = BridgeRouter.resolvedTimeoutSeconds(params.timeoutSeconds)
            let result: Result<BridgeWire.DictateResult, BridgeWire.ErrorObject> =
                blockOnHost(noHost: .failure(.domain(.internalError, message: "no host"))) { [clientName] host, done in
                    host.bridgeStartDictation(
                        clientName: clientName, prompt: params.prompt,
                        timeoutSeconds: timeout, language: params.language, completion: done)
                }
            switch result {
            case .success(let r):
                onMain { self.host?.bridgeDidCall(clientName: self.clientName, tool: AgentScope.dictate.rawValue) }
                send(id: id, result: r)
            case .failure(let err):
                sendError(id: id, error: err)
            }
            return true

        case .dictateStop(let id):
            let stopped = onMain { self.host?.bridgeStopAgentDictation() ?? false }
            send(id: id, result: BridgeWire.DictateStopResult(stopped: stopped))
            return true

        case .dictateCancel(let id):
            let cancelled = onMain { self.host?.bridgeCancelAgentDictation() ?? false }
            send(id: id, result: BridgeWire.DictateCancelResult(cancelled: cancelled))
            return true

        case .refine(let id, let params):
            guard consentGranted(.refine, id: id) else { return true }
            let result: Result<String, BridgeWire.ErrorObject> =
                blockOnHost(noHost: .failure(.domain(.internalError, message: "no host"))) { [clientName] host, done in
                    host.bridgeRefine(clientName: clientName, text: params.text, instruction: params.instruction, completion: done)
                }
            switch result {
            case .success(let text):
                onMain { self.host?.bridgeDidCall(clientName: self.clientName, tool: AgentScope.refine.rawValue) }
                send(id: id, result: BridgeWire.RefineResult(text: text))
            case .failure(let err):
                sendError(id: id, error: err)
            }
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
