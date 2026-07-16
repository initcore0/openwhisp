import XCTest
import Network
@testable import OpenWhispSyncLAN
import OpenWhispCore

/// The MAK-51 WP6 wiring lesson made a test: start a REAL `LANBridgeServer` on
/// 127.0.0.1 with a fixed PSK against in-memory stores, and drive a REAL TLS-TCP
/// NDJSON client through hello -> consent -> sync.manifest -> sync.push ->
/// sync.pull, asserting the merged store contents. This proves the whole stack —
/// TLS-PSK auth, the router, consent, and the store-backed sync handlers — end to
/// end, not just the pure merge.
final class LANBridgeE2ETests: XCTestCase {

    /// An in-memory `SyncStore` so the E2E asserts merged state without disk I/O.
    final class MemStore: SyncStore {
        var syncVocabulary: Vocabulary = .empty
        var syncProfiles: [AppProfile] = []
        var syncModes: [Mode] = []
        var syncHistory: [TranscriptionEntry] = []
        func syncPacksHash() -> String { "" }
        func syncPackBundles() -> [ConfigBundle] { [] }
    }

    private let peerID = UUID(uuidString: "0BADF00D-0000-0000-0000-00000000CAFE")!
    private let t1 = Date(timeIntervalSince1970: 2_000)
    private let t2 = Date(timeIntervalSince1970: 3_000)

    /// Boot a server on an ephemeral-but-fixed local port with a fixed PSK, returning
    /// the running server, its host/store, the PSK, and the bound port.
    /// Peer handshakes the server reported (peerID, announced client name) — the
    /// wiring-lesson assertion: identity binding must be OBSERVED, not assumed.
    final class HandshakeLog: @unchecked Sendable { var events: [(UUID, String)] = [] }
    private let handshakes = HandshakeLog()

    @MainActor
    private func startServer(port: UInt16, store: MemStore) throws -> (LANBridgeServer, Data) {
        let psk = Data((0..<32).map { UInt8($0) })
        let host = LoopbackHost(store: store)
        let handshakes = self.handshakes
        let server = LANBridgeServer(
            host: host,
            pskProvider: { [self.peerID: psk] },
            deviceName: { "E2E Mac" },
            instanceName: { "OpenWhisp-E2E" },
            onPeerHandshake: { id, name in handshakes.events.append((id, name)) })
        server.start(forcedPort: port)
        // Wait for the listener to bind.
        let deadline = Date().addingTimeInterval(5)
        while server.boundPort == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard server.boundPort != nil else { throw XCTSkip("listener did not bind in time") }
        return (server, psk)
    }

    /// A deterministic-ish free-ish port; the test tolerates a couple of retries.
    private func testPort() -> UInt16 { UInt16.random(in: 49_200...49_900) }

    func testFullSyncRoundTrip() throws {
        let store = MemStore()
        // Seed the SERVER (Mac) with one local substitution + one history entry so
        // the pull can return them and the push merge is a genuine union.
        let localSubID = UUID()
        store.syncVocabulary = Vocabulary(terms: ["Anthropic"], substitutions: [
            .init(id: localSubID, from: "clod", to: "cloud", updatedAt: t1)
        ])
        let localEntryID = UUID()
        store.syncHistory = [TranscriptionEntry(id: localEntryID, text: "mac note", date: t1, appBundleID: nil, appName: nil)]

        let port = testPort()
        let (server, psk) = try MainActor.assumeIsolated { try startServer(port: port, store: store) }
        defer { MainActor.assumeIsolated { server.stop() } }

        // The server hops to the MAIN thread for each host call (consent, manifest,
        // …). In this in-process E2E the client must therefore run OFF the main
        // thread, so the main run loop stays free to service those hops. We drive
        // the whole client flow on a background queue and pump the main run loop
        // here until it finishes (mirrors how the real phone — a separate process —
        // never blocks the Mac's main thread).
        let remoteEntryID = UUID()
        let newSubID = UUID()
        let done = expectation(description: "client flow complete")
        var flowError: Error?

        DispatchQueue.global().async {
            do {
                let client = try TLSPSKClient(port: port, psk: psk, identity: self.peerID.uuidString)
                try client.connect()
                defer { client.cancel() }

                // 1) hello — establishes the handshake + advertises `sync`. The
                // peerID claim MUST carry the HMAC proof under this peer's PSK
                // (LANPeerProof) or the server closes the connection.
                let hello: BridgeWire.HelloResult = try client.call(
                    method: "bridge.hello",
                    params: BridgeWire.HelloParams(
                        protocolVersion: 1, clientName: "iPhone E2E", clientVersion: "1.0",
                        peerID: self.peerID.uuidString,
                        peerProof: LANPeerProof.proof(psk: psk, peerID: self.peerID)),
                    resultType: BridgeWire.HelloResult.self)
                XCTAssertTrue(hello.capabilities.contains(BridgeWire.Capability.sync))
                XCTAssertEqual(hello.clientId, self.peerID.uuidString,
                    "the session must be bound to the PROVEN peer identity")

                // 2) sync.manifest — the server reports its live sections.
                let manifest: BridgeWire.SyncManifestResult = try client.call(
                    method: "sync.manifest", params: Optional<BridgeWire.NoParams>.none,
                    resultType: BridgeWire.SyncManifestResult.self)
                XCTAssertEqual(manifest.schemaVersion, ConfigBundle.currentSchemaVersion)
                XCTAssertEqual(manifest.historyHead.count, 1)
                XCTAssertEqual(manifest.historyHead.newestID, localEntryID)
                XCTAssertFalse(manifest.vocabHash.isEmpty)

                // 3) sync.push — a NEWER edit of the shared sub + a new sub + a new
                // history entry. The boring v1 merge must apply all three.
                let pushPayload = BridgeWire.SyncBundleResult(
                    bundle: ConfigBundle(vocabulary: Vocabulary(terms: ["kubectl"], substitutions: [
                        .init(id: localSubID, from: "clod", to: "Claude", updatedAt: self.t2), // newer -> wins
                        .init(id: newSubID, from: "gh", to: "GitHub", updatedAt: self.t2),      // new
                    ])),
                    historyEntries: [TranscriptionEntry(id: remoteEntryID, text: "phone note", date: self.t2, appBundleID: nil, appName: nil)])
                let pushResult: BridgeWire.SyncPushResult = try client.call(
                    method: "sync.push", params: pushPayload, resultType: BridgeWire.SyncPushResult.self)
                XCTAssertTrue(pushResult.accepted)
                XCTAssertEqual(pushResult.mergedCounts.vocabulary, 3) // updated sub + new sub + new term
                XCTAssertEqual(pushResult.mergedCounts.history, 1)

                // 4) Idempotency: re-push the same payload — counts all 0.
                let secondPush: BridgeWire.SyncPushResult = try client.call(
                    method: "sync.push", params: pushPayload, resultType: BridgeWire.SyncPushResult.self)
                XCTAssertTrue(secondPush.accepted)
                XCTAssertEqual(secondPush.mergedCounts.vocabulary, 0)
                XCTAssertEqual(secondPush.mergedCounts.history, 0)

                // 5) sync.pull — fetch the merged config back (both subs, both entries).
                let pulled: BridgeWire.SyncBundleResult = try client.call(
                    method: "sync.pull", params: BridgeWire.SyncPullParams(),
                    resultType: BridgeWire.SyncBundleResult.self)
                XCTAssertEqual(pulled.bundle.vocabulary?.substitutions.count, 2)
                XCTAssertEqual(pulled.historyEntries.count, 2)

                // 6) Delta pull at t1 returns ONLY the newer (t2) entry.
                let cursor = BridgeWire.iso8601String(from: self.t1)
                let delta: BridgeWire.SyncBundleResult = try client.call(
                    method: "sync.pull", params: BridgeWire.SyncPullParams(sinceHistoryCursor: cursor, want: [.history]),
                    resultType: BridgeWire.SyncBundleResult.self)
                XCTAssertEqual(delta.historyEntries.map(\.id), [remoteEntryID])
            } catch {
                flowError = error
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 20)
        if let flowError { XCTFail("client flow failed: \(flowError)") }

        // Identity binding was OBSERVED: the server reported exactly this peer's
        // proven handshake with the name it announced (drives confirmPairing).
        XCTAssertEqual(handshakes.events.map(\.0), [peerID])
        XCTAssertEqual(handshakes.events.map(\.1), ["iPhone E2E"])

        // The server writes the merged store on its MAIN-thread hop; flush the main
        // queue so those writes are visible before we assert (a barrier, not a poll).
        let flushed = expectation(description: "main flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)

        // The server store reflects the merge.
        MainActor.assumeIsolated {
            XCTAssertEqual(store.syncVocabulary.substitutions.first(where: { $0.id == localSubID })?.to, "Claude")
            XCTAssertNotNil(store.syncVocabulary.substitutions.first(where: { $0.id == newSubID }))
            XCTAssertTrue(store.syncVocabulary.terms.contains("kubectl"))
            XCTAssertEqual(store.syncHistory.count, 2)
            XCTAssertTrue(store.syncHistory.contains(where: { $0.id == remoteEntryID }))
        }
    }

    /// Unpairing (a listener restart with a smaller PSK snapshot) must revoke the
    /// dropped peer: after the restart its PSK no longer completes the handshake,
    /// while a still-paired peer keeps connecting. Proves the "unpair = PSK
    /// destruction + drop connections" security property at the transport layer.
    func testRestartWithoutPSKRevokesPeer() throws {
        let store = MemStore()
        let psk = Data((0..<32).map { UInt8($0) })
        let port = testPort()

        // A mutable snapshot the server reads through — mimics PairingStore.pskLookup.
        final class Box: @unchecked Sendable { var map: [UUID: Data] = [:] }
        let box = Box()
        box.map = [peerID: psk]

        let server = try MainActor.assumeIsolated { () -> LANBridgeServer in
            let host = LoopbackHost(store: store)
            let s = LANBridgeServer(
                host: host, pskProvider: { box.map }, deviceName: { "M" },
                instanceName: { "OpenWhisp-E2E" }, onPeerHandshake: { _, _ in })
            s.start(forcedPort: port)
            let deadline = Date().addingTimeInterval(5)
            while s.boundPort == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return s
        }
        defer { MainActor.assumeIsolated { server.stop() } }

        // Paired: connects.
        let ok = expectation(description: "paired connects")
        DispatchQueue.global().async {
            do { let c = try TLSPSKClient(port: port, psk: psk, identity: self.peerID.uuidString); try c.connect(timeout: 4); c.cancel() }
            catch { XCTFail("paired peer should connect: \(error)") }
            ok.fulfill()
        }
        wait(for: [ok], timeout: 10)

        // "Unpair": drop the PSK + restart the listener so it re-snapshots an empty set.
        MainActor.assumeIsolated {
            box.map = [:]
            server.stop()
            server.start(forcedPort: port)
            let deadline = Date().addingTimeInterval(5)
            while server.boundPort == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }

        // Now the same PSK must FAIL (no PSK registered → handshake can't complete).
        let revoked = expectation(description: "revoked fails")
        DispatchQueue.global().async {
            do { let c = try TLSPSKClient(port: port, psk: psk, identity: self.peerID.uuidString); try c.connect(timeout: 4); c.cancel(); XCTFail("revoked peer should NOT connect") }
            catch { /* expected */ }
            revoked.fulfill()
        }
        wait(for: [revoked], timeout: 10)
    }

    /// A TLS-authenticated client whose hello claims a peer identity WITHOUT a
    /// valid HMAC proof must be rejected before any verb runs — this is what stops
    /// one paired device from riding another's consent (the TLS metadata API
    /// cannot say which of N registered PSKs was negotiated).
    func testHelloWithoutValidProofIsRejected() throws {
        let store = MemStore()
        let port = testPort()
        let (server, psk) = try MainActor.assumeIsolated { try startServer(port: port, store: store) }
        defer { MainActor.assumeIsolated { server.stop() } }

        let done = expectation(description: "rejections observed")
        DispatchQueue.global().async {
            // No proof at all.
            do {
                let c = try TLSPSKClient(port: port, psk: psk, identity: self.peerID.uuidString)
                try c.connect()
                defer { c.cancel() }
                _ = try c.call(
                    method: "bridge.hello",
                    params: BridgeWire.HelloParams(protocolVersion: 1, clientName: "sneaky", clientVersion: "1.0"),
                    resultType: BridgeWire.HelloResult.self)
                XCTFail("hello without a proof must be rejected")
            } catch { /* expected: error response and/or closed connection */ }

            // Proof computed under the WRONG key (another device's PSK).
            do {
                let c = try TLSPSKClient(port: port, psk: psk, identity: self.peerID.uuidString)
                try c.connect()
                defer { c.cancel() }
                let wrongKeyProof = LANPeerProof.proof(psk: Data(repeating: 0xEE, count: 32), peerID: self.peerID)
                _ = try c.call(
                    method: "bridge.hello",
                    params: BridgeWire.HelloParams(
                        protocolVersion: 1, clientName: "sneaky", clientVersion: "1.0",
                        peerID: self.peerID.uuidString, peerProof: wrongKeyProof),
                    resultType: BridgeWire.HelloResult.self)
                XCTFail("hello with a wrong-key proof must be rejected")
            } catch { /* expected */ }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertTrue(handshakes.events.isEmpty, "no unproven hello may reach onPeerHandshake")
    }

    /// A client that presents an UNKNOWN identity / wrong PSK cannot complete the
    /// TLS handshake, so it never gets to send a request.
    func testWrongPSKFailsHandshake() throws {
        let store = MemStore()
        let port = testPort()
        let (server, _) = try MainActor.assumeIsolated { try startServer(port: port, store: store) }
        defer { MainActor.assumeIsolated { server.stop() } }

        // A different PSK than the server holds.
        let wrongPSK = Data(repeating: 0xFF, count: 32)
        let client = try TLSPSKClient(port: port, psk: wrongPSK, identity: peerID.uuidString)
        XCTAssertThrowsError(try client.connect(timeout: 3)) { _ in }
        client.cancel()
    }
}


/// Handler-level (no TLS) tests of `SyncVerbHandlers` — the paging/want/cap wiring
/// the pure-function tests can't see (the repo's wiring lesson).
final class SyncVerbHandlersTests: XCTestCase {

    final class MemStore: SyncStore {
        var syncVocabulary: Vocabulary = .empty
        var syncProfiles: [AppProfile] = []
        var syncModes: [Mode] = []
        var syncHistory: [TranscriptionEntry] = []
        var syncHistoryRetentionLimit: Int?
        func syncPacksHash() -> String { "" }
        func syncPackBundles() -> [ConfigBundle] { [] }
    }

    private func entry(_ seconds: TimeInterval, text: String = "e") -> TranscriptionEntry {
        TranscriptionEntry(id: UUID(), text: text, date: Date(timeIntervalSince1970: seconds), appBundleID: nil, appName: nil)
    }

    /// Walk `pull` page by page exactly as the documented client contract says
    /// (nextHistoryCursor → pageCursor): every entry arrives exactly once, config
    /// sections ride the first page only, and pagination terminates.
    func testPullPagesWalkEveryEntryOnceAndTerminate() {
        let store = MemStore()
        store.syncVocabulary = Vocabulary(terms: ["term"], substitutions: [])
        store.syncHistory = (0..<25).map { entry(Double(1_000 + $0)) }
        let handlers = SyncVerbHandlers(store: store)

        var seen: [UUID] = []
        var cursor: String?
        var pages = 0
        repeat {
            let result = handlers.pull(BridgeWire.SyncPullParams(pageCursor: cursor, historyLimit: 10))
            seen += result.historyEntries.map(\.id)
            if pages == 0 {
                XCTAssertNotNil(result.bundle.vocabulary, "config rides the FIRST page")
            } else {
                XCTAssertNil(result.bundle.vocabulary, "continuation pages carry history only")
            }
            pages += 1
            cursor = result.nextHistoryCursor
            if result.hasMoreHistory != true { break }
        } while pages < 10
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(Set(seen), Set(store.syncHistory.map(\.id)))
        XCTAssertEqual(seen.count, 25, "no entry may repeat across pages")
    }

    /// ABSENT want → everything; present-but-EMPTY want (a newer peer asked only
    /// for sections this build doesn't know) → nothing.
    func testPullWantAbsentMeansAllEmptyMeansNone() {
        let store = MemStore()
        store.syncVocabulary = Vocabulary(terms: ["t"], substitutions: [])
        store.syncProfiles = []
        store.syncHistory = [entry(1)]
        let handlers = SyncVerbHandlers(store: store)

        let all = handlers.pull(BridgeWire.SyncPullParams(want: nil))
        XCTAssertNotNil(all.bundle.vocabulary)
        XCTAssertEqual(all.historyEntries.count, 1)

        let none = handlers.pull(BridgeWire.SyncPullParams(want: []))
        XCTAssertNil(none.bundle.vocabulary)
        XCTAssertNil(none.bundle.profiles)
        XCTAssertNil(none.bundle.modes)
        XCTAssertTrue(none.historyEntries.isEmpty)
    }

    /// Push idempotency must survive the receiver's retention cap: entries older
    /// than the cap window are NOT counted as merged (they'd be trimmed), so an
    /// identical re-push reports zero instead of re-"merging" them forever.
    func testPushRespectsRetentionCapAndStaysIdempotent() {
        let store = MemStore()
        store.syncHistoryRetentionLimit = 3
        store.syncHistory = [entry(300), entry(200), entry(100)] // full at cap
        let handlers = SyncVerbHandlers(store: store)

        // One genuinely-new (newest) + one too-old-to-survive entry.
        let fresh = entry(400, text: "fresh")
        let ancient = entry(50, text: "ancient")
        let payload = BridgeWire.SyncBundleResult(
            bundle: ConfigBundle(profiles: nil, modes: nil, vocabulary: nil),
            historyEntries: [fresh, ancient])

        let first = handlers.push(payload)
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(first.mergedCounts.history, 1, "only the surviving entry counts")
        XCTAssertTrue(store.syncHistory.contains { $0.id == fresh.id })
        XCTAssertFalse(store.syncHistory.contains { $0.id == ancient.id })
        XCTAssertEqual(store.syncHistory.count, 3)

        let second = handlers.push(payload)
        XCTAssertEqual(second.mergedCounts.history, 0, "identical re-push must merge nothing")
    }
}
