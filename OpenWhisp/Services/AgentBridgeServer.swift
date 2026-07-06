import Foundation
import Darwin
import Security
import os

// This file is app-target only (NOT in Package.swift's OpenWhispCore sources):
// it uses Darwin sockets + the Security framework and calls back into AppState.
// The pure routing/validation it depends on lives in BridgeRouter (tested).

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
}

/// Per-connection state carried across frames on one connection.
private struct ConnectionState {
    var handshaken = false
    var clientName = ""
}

/// The local control-plane server for the Agent Bridge: a UNIX-domain-socket
/// JSON-RPC 2.0 endpoint the `openwhisp` CLI and MCP adapter connect to.
///
/// Default-off: nothing is created until ``start()`` is called, and ``stop()``
/// tears the socket down completely — so a user who never enables the bridge
/// pays zero cost. Every connection is authenticated at accept() (same-user
/// euid + code-signature match) before a single request byte is read; a failing
/// check closes the connection silently.
///
/// **Runtime note:** the socket lifecycle and peer authentication are validated
/// against the real signed app (see docs/AGENT_BRIDGE_PLAN.md step 3 "manual
/// verification"); this type is compile-checked and its request routing is
/// unit-tested via `BridgeRouter`.
final class AgentBridgeServer {

    private weak var host: AgentBridgeHost?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenWhisp", category: "AgentBridge")

    /// When false (the default), a peer must satisfy our own code-signing
    /// requirement (same Team ID, or same designated requirement). The Settings
    /// "Allow unsigned / third-party clients" toggle sets this true.
    var allowUnsignedClients = false

    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var boundPath: String?

    /// Lightweight denial throttle: timestamps of recent auth rejections, so a
    /// burst can be logged (and, once the consent UI lands, surfaced).
    private var recentDenials: [Date] = []

    init(host: AgentBridgeHost) {
        self.host = host
    }

    // MARK: - Lifecycle

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    /// Idempotent. Creates the socket and starts accepting connections.
    func start() {
        stateLock.lock()
        if running { stateLock.unlock(); return }
        stateLock.unlock()

        let path = Self.resolveSocketPath()
        guard let fd = makeListeningSocket(at: path) else {
            log.error("Agent Bridge: failed to open socket at \(path, privacy: .public)")
            return
        }
        Self.writePointerFile(resolvedPath: path)

        stateLock.lock()
        listenFD = fd
        boundPath = path
        running = true
        stateLock.unlock()

        log.info("Agent Bridge listening at \(path, privacy: .public)")
        Thread.detachNewThread { [weak self] in self?.acceptLoop(listenFD: fd) }
    }

    /// Idempotent. Stops accepting, closes the socket, and unlinks it.
    func stop() {
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        running = false
        let fd = listenFD
        let path = boundPath
        listenFD = -1
        boundPath = nil
        stateLock.unlock()

        if fd >= 0 { close(fd) } // makes the blocked accept() return
        if let path { unlink(path) }
        Self.removePointerFile()
        log.info("Agent Bridge stopped")
    }

    // MARK: - Socket setup

    /// The socket path: `~/Library/Application Support/OpenWhisp/agent.sock`, or a
    /// `$TMPDIR/openwhisp-<uid>/bridge.sock` fallback for pathologically long home
    /// paths (sun_path is only 104 bytes). Returns nil only if even the fallback
    /// overflows.
    static func resolveSocketPath() -> String {
        let primary = BridgeWire.SocketLocation.defaultSocketPath()
        if primary.utf8.count < 104 { return primary }
        // Fallback: short tmp path keyed by uid.
        let tmp = (ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
        let dir = URL(fileURLWithPath: tmp).appendingPathComponent("openwhisp-\(geteuid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fallback = dir.appendingPathComponent("bridge.sock").path
        return fallback.utf8.count < 104 ? fallback : primary // best effort
    }

    /// A pointer file so a client can find the socket when the fallback path is in
    /// use. Always written next to where the socket would nominally live.
    private static func writePointerFile(resolvedPath: String) {
        let dir = BridgeWire.SocketLocation.appSupportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let pointer = dir.appendingPathComponent(BridgeWire.SocketLocation.pointerFileName)
        try? resolvedPath.data(using: .utf8)?.write(to: pointer, options: .atomic)
    }

    private static func removePointerFile() {
        try? FileManager.default.removeItem(
            at: BridgeWire.SocketLocation.appSupportDirectory()
                .appendingPathComponent(BridgeWire.SocketLocation.pointerFileName))
    }

    private func makeListeningSocket(at path: String) -> Int32? {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path) // 104
        guard path.utf8.count < capacity else { close(fd); return nil }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString { src in
                p.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                    strncpy(dst, src, capacity - 1)
                }
            }
        }

        unlink(path) // remove a stale socket from a previous run/crash

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ap -> Int32 in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len)
            }
        }
        guard bound == 0 else {
            log.error("Agent Bridge: bind failed (errno \(errno))")
            close(fd); return nil
        }
        guard chmod(path, 0o600) == 0 else { close(fd); unlink(path); return nil }
        guard listen(fd, 8) == 0 else { close(fd); unlink(path); return nil }
        return fd
    }

    // MARK: - Accept loop

    private func acceptLoop(listenFD: Int32) {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 {
                if !isRunning { break } // stop() closed the fd
                if errno == EINTR { continue }
                break
            }
            if !isRunning { close(conn); break }
            // A peer that vanishes mid-call (Ctrl-C'd CLI, MCP host timeout) must
            // surface as EPIPE on our write, not as a SIGPIPE that kills the app.
            _ = fcntl(conn, F_SETNOSIGPIPE, 1)
            Thread.detachNewThread { [weak self] in self?.handleConnection(conn) }
        }
    }

    // MARK: - Per-connection handling

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        guard authenticatePeer(fd) else {
            recordDenial()
            return // silent close — no oracle to a rejected peer
        }

        var state = ConnectionState()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)

        while isRunning {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break } // EOF or error → connection closed
            buffer.append(contentsOf: chunk[0..<n])

            while let nlIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<nlIndex])
                buffer.removeSubrange(buffer.startIndex...nlIndex)
                if lineData.isEmpty { continue }

                switch BridgeRouter.route(line: lineData, hasHandshaken: state.handshaken) {
                case .close(let reason):
                    log.notice("Agent Bridge: closing — \(reason, privacy: .public)")
                    return
                case .error(let id, let err):
                    sendError(fd, id: id, error: err)
                case .intent(let intent):
                    if !execute(intent, fd: fd, state: &state) { return }
                }
            }

            // After draining complete lines the buffer holds at most one PARTIAL
            // frame; only that residue is capped. (Checking before the drain
            // counted the newline and any pipelined next frame, so a maximum-size
            // frame the router itself accepts would kill the connection.)
            if buffer.count > BridgeWire.maxFrameBytes {
                log.notice("Agent Bridge: frame exceeded cap; closing")
                break
            }
        }
    }

    /// Execute a routed intent. Returns false to close the connection.
    private func execute(_ intent: BridgeRouter.Intent, fd: Int32, state: inout ConnectionState) -> Bool {
        switch intent {
        case .hello(let id, let params):
            do {
                let negotiated = try BridgeWire.negotiatedProtocolVersion(clientProtocolVersion: params.protocolVersion)
                // One main-thread hop for everything the handshake advertises.
                // The consent field reports the client's CURRENT posture (stored
                // policy / this-run grant); tool calls still resolve consent —
                // and may prompt — per call.
                let (caps, appVersion, consent) = onMain {
                    (self.host?.bridgeCapabilities() ?? [],
                     self.host?.bridgeStatus().appVersion ?? "",
                     self.host?.bridgeConsentSnapshot(clientName: params.clientName)
                        ?? (summary: .pending, scopes: [:]))
                }
                let result = BridgeWire.HelloResult(
                    protocolVersion: negotiated,
                    appVersion: appVersion,
                    capabilities: caps,
                    clientId: UUID().uuidString,
                    consent: consent.summary,
                    consentScopes: consent.scopes
                )
                send(fd, id: id, result: result)
                state.handshaken = true
                state.clientName = params.clientName
                return true
            } catch {
                sendError(fd, id: id, error: BridgeWire.ErrorObject.domain(
                    .unsupportedVersion,
                    message: "client protocol \(params.protocolVersion) is newer than this app supports (\(BridgeWire.protocolVersion)); update OpenWhisp"
                ))
                return false // can't proceed without a shared protocol
            }

        case .status(let id):
            let result = onMain { self.host?.bridgeStatus() }
            if let result { send(fd, id: id, result: result) }
            else { sendError(fd, id: id, error: .domain(.internalError, message: "status unavailable")) }
            return true

        case .historyList(let id, let params):
            let clientName = state.clientName // copy out of `inout` for the closures below
            guard consentGranted(clientName, scope: .history, fd: fd, id: id) else { return true }
            let limit = BridgeRouter.resolvedHistoryLimit(params.limit)
            let entries = onMain { self.host?.bridgeHistory(limit: limit) ?? [] }
            onMain { self.host?.bridgeDidCall(clientName: clientName, tool: AgentScope.history.rawValue) }
            send(fd, id: id, result: BridgeWire.HistoryListResult(entries: entries))
            return true

        case .dictate(let id, let params):
            let clientName = state.clientName
            guard consentGranted(clientName, scope: .dictate, fd: fd, id: id) else { return true }
            let timeout = BridgeRouter.resolvedTimeoutSeconds(params.timeoutSeconds)
            switch blockingDictate(clientName: clientName, prompt: params.prompt, timeout: timeout, language: params.language) {
            case .success(let result):
                onMain { self.host?.bridgeDidCall(clientName: clientName, tool: AgentScope.dictate.rawValue) }
                send(fd, id: id, result: result)
            case .failure(let err):
                sendError(fd, id: id, error: err)
            }
            return true

        case .dictateStop(let id):
            let stopped = onMain { self.host?.bridgeStopAgentDictation() ?? false }
            send(fd, id: id, result: BridgeWire.DictateStopResult(stopped: stopped))
            return true

        case .dictateCancel(let id):
            let cancelled = onMain { self.host?.bridgeCancelAgentDictation() ?? false }
            send(fd, id: id, result: BridgeWire.DictateCancelResult(cancelled: cancelled))
            return true

        case .refine(let id, let params):
            let clientName = state.clientName
            guard consentGranted(clientName, scope: .refine, fd: fd, id: id) else { return true }
            switch blockingRefine(clientName: clientName, text: params.text, instruction: params.instruction) {
            case .success(let text):
                onMain { self.host?.bridgeDidCall(clientName: clientName, tool: AgentScope.refine.rawValue) }
                send(fd, id: id, result: BridgeWire.RefineResult(text: text))
            case .failure(let err):
                sendError(fd, id: id, error: err)
            }
            return true
        }
    }

    /// Block this connection thread until a host completion fires on the main
    /// thread. The one semaphore bridge every blocking call shares. Never called
    /// on the main thread, so the wait can't self-deadlock; if the host is gone,
    /// `noHost` is returned immediately.
    private func blockOnHost<T>(
        noHost: T, _ start: @escaping (AgentBridgeHost, @escaping (T) -> Void) -> Void
    ) -> T {
        let sem = DispatchSemaphore(value: 0)
        var out = noHost
        DispatchQueue.main.async {
            guard let host = self.host else { sem.signal(); return }
            start(host) { result in
                out = result
                sem.signal()
            }
        }
        sem.wait()
        return out
    }

    /// Block this connection thread until a refine completes.
    private func blockingRefine(
        clientName: String, text: String, instruction: String
    ) -> Result<String, BridgeWire.ErrorObject> {
        blockOnHost(noHost: .failure(.domain(.internalError, message: "no host"))) { host, done in
            host.bridgeRefine(clientName: clientName, text: text, instruction: instruction, completion: done)
        }
    }

    /// Block this connection thread until an agent dictation finishes (or times
    /// out). The human always wins the mic — the host busy-rejects if a session
    /// is active.
    private func blockingDictate(
        clientName: String, prompt: String?, timeout: Int, language: String?
    ) -> Result<BridgeWire.DictateResult, BridgeWire.ErrorObject> {
        blockOnHost(noHost: .failure(.domain(.internalError, message: "no host"))) { host, done in
            host.bridgeStartDictation(
                clientName: clientName, prompt: prompt, timeoutSeconds: timeout, language: language,
                completion: done
            )
        }
    }

    // MARK: - Peer authentication

    private func authenticatePeer(_ fd: Int32) -> Bool {
        // Layer 1: same-user. Kernel-guaranteed; kills the cross-user case.
        var uid = uid_t(); var gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0 else {
            log.notice("Agent Bridge: getpeereid failed; denying")
            return false
        }
        guard uid == geteuid() else {
            log.notice("Agent Bridge: peer euid \(uid) != \(geteuid()); denying")
            return false
        }

        // Layer 2: code signature (unless the user opted into unsigned clients).
        if allowUnsignedClients { return true }
        guard PeerCodeSignature.verifyPeerMatchesSelf(fd: fd) else {
            log.notice("Agent Bridge: peer code-signature check failed; denying")
            return false
        }
        return true
    }

    private func recordDenial() {
        stateLock.lock()
        let now = Date()
        recentDenials.append(now)
        recentDenials.removeAll { now.timeIntervalSince($0) > 60 }
        let count = recentDenials.count
        stateLock.unlock()
        if count >= 3 {
            log.error("Agent Bridge: \(count) connection denials in the last minute")
            // The user-facing notification is wired with the consent UI (step 5).
        }
    }

    // MARK: - Consent

    /// Synchronously resolve consent for `clientName` on a specific `scope`,
    /// blocking this connection thread until the host answers (which may include
    /// the user interacting with the consent window — up to its 60s timeout). On
    /// denial, sends the consentDenied error so callers just
    /// `guard ... else { return true }`.
    private func consentGranted(_ clientName: String, scope: AgentScope, fd: Int32, id: BridgeWire.RPCID?) -> Bool {
        let granted = blockOnHost(noHost: false) { host, done in
            host.bridgeResolveConsent(clientName: clientName, scope: scope, completion: done)
        }
        if !granted {
            sendError(fd, id: id, error: .domain(.consentDenied, message: "the user declined this client's \(scope.rawValue) access"))
        }
        return granted
    }

    // MARK: - Main-thread hop

    /// Synchronously run `body` on the main thread and return its value. Called
    /// only from connection threads (never the main thread), so the wait can't
    /// self-deadlock.
    private func onMain<T>(_ body: @escaping () -> T) -> T {
        var result: T!
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            result = body()
            sem.signal()
        }
        sem.wait()
        return result
    }

    // MARK: - Writing responses

    private func send<R: Codable & Sendable>(_ fd: Int32, id: BridgeWire.RPCID?, result: R) {
        writeJSON(fd, BridgeWire.Response(id: id, result: result))
    }

    private func sendError(_ fd: Int32, id: BridgeWire.RPCID?, error: BridgeWire.ErrorObject) {
        writeJSON(fd, BridgeWire.Response<BridgeWire.NoParams>(id: id, error: error))
    }

    private func writeJSON<T: Encodable>(_ fd: Int32, _ value: T) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A) // NDJSON frame terminator
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(fd, base + offset, data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }
}

// MARK: - Peer code-signature verification

/// Verifies that a connected socket peer is signed like us — same Team ID for a
/// Developer-ID / notarized build, or the same leaf certificate for a self-signed
/// dev build (NOT the designated requirement, which is identifier-bound and would
/// reject the differently-identified bundled CLI). Uses the peer's **audit token**
/// (which names one specific process incarnation) rather than its PID, so there is
/// no PID-reuse / exec race (the class of bug behind CVE-2019-13013 and similar).
private enum PeerCodeSignature {

    // From <sys/un.h>; not always surfaced as Swift constants.
    private static let SOL_LOCAL_VALUE: Int32 = 0
    private static let LOCAL_PEERTOKEN_VALUE: Int32 = 0x006

    /// How this build admits a same-user peer once its signature is examined.
    private enum SelfIdentity {
        /// Developer-ID / notarized: any binary with our Team ID — regardless of
        /// its own identifier (the bundled CLI has a different one).
        case teamRequirement(SecRequirement)
        /// Self-signed dev cert: any binary signed with our exact leaf
        /// certificate, again identifier-independent. The app's *designated*
        /// requirement is identifier-bound and would REJECT the differently-
        /// identified CLI (app `com.openwhisp.app` vs CLI `openwhisp`), so we
        /// match the certificate directly instead.
        case leafCertificate(Data)
        /// Unsigned / ad-hoc: no signature to match — euid alone gates (dev only).
        case unsigned
    }

    static func verifyPeerMatchesSelf(fd: Int32) -> Bool {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutablePointer(to: &token) { tp -> Int32 in
            getsockopt(fd, SOL_LOCAL_VALUE, LOCAL_PEERTOKEN_VALUE, tp, &len)
        }
        guard rc == 0, len == socklen_t(MemoryLayout<audit_token_t>.size) else { return false }

        var tokenCopy = token
        let tokenData = Data(bytes: &tokenCopy, count: MemoryLayout<audit_token_t>.size) as CFData
        let attrs = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &guest) == errSecSuccess,
              let guest else { return false }

        switch currentSelfIdentity() {
        case .teamRequirement(let requirement):
            // The requirement (anchor apple generic + our Team ID) validates the
            // guest's signature chain as well as its team.
            return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
        case .leafCertificate(let ourLeaf):
            // Confirm the guest is validly signed, then that it's the SAME signer
            // (identical leaf certificate) as us — independent of its identifier.
            guard SecCodeCheckValidity(guest, [], nil) == errSecSuccess else { return false }
            return Self.leafCertificateData(ofCode: guest) == ourLeaf
        case .unsigned:
            // We're unsigned/ad-hoc (dev build). euid already matched — admit.
            return true
        }
    }

    private static let cacheLock = NSLock()
    private static var cachedIdentity: SelfIdentity?

    /// Our admission identity, cached once derived (the signature can't change for
    /// the process lifetime). A transient derivation failure is NOT cached — it
    /// falls back to `.unsigned` for that call only (mirroring the dev-build
    /// admit-on-unknown behavior) and re-derives next connection, so a hiccup
    /// can't permanently downgrade the gate.
    private static func currentSelfIdentity() -> SelfIdentity {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = cachedIdentity { return cached }
        if let derived = deriveSelfIdentity() {
            cachedIdentity = derived
            return derived
        }
        return .unsigned
    }

    /// Returns nil on a transient SecCode failure; `.unsigned` only when we are
    /// genuinely unsigned / ad-hoc.
    private static func deriveSelfIdentity() -> SelfIdentity? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(selfStatic, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }

        // Developer ID / notarized: match Team ID (admits any same-team binary).
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            var req: SecRequirement?
            let reqString = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
            if SecRequirementCreateWithString(reqString, [], &req) == errSecSuccess, let req {
                return .teamRequirement(req)
            }
            return nil // had a team but couldn't build the requirement — treat as transient
        }

        // Self-signed: match our exact leaf certificate.
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certs.first {
            return .leafCertificate(SecCertificateCopyData(leaf) as Data)
        }

        // No team, no certificate → genuinely unsigned / ad-hoc.
        return .unsigned
    }

    /// The leaf-certificate DER of a live guest SecCode (nil if unsigned/ad-hoc).
    private static func leafCertificateData(ofCode code: SecCode) -> Data? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }
}
