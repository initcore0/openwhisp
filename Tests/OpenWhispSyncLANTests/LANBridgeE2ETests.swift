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
    @MainActor
    private func startServer(port: UInt16, store: MemStore) throws -> (LANBridgeServer, Data) {
        let psk = Data((0..<32).map { UInt8($0) })
        let host = LoopbackHost(store: store)
        let server = LANBridgeServer(
            host: host,
            pskProvider: { [self.peerID: psk] },
            deviceName: { "E2E Mac" },
            onPeerHandshake: { _, _ in })
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

                // 1) hello — establishes the handshake + advertises `sync`.
                let hello: BridgeWire.HelloResult = try client.call(
                    method: "bridge.hello",
                    params: BridgeWire.HelloParams(protocolVersion: 1, clientName: "iPhone E2E", clientVersion: "1.0"),
                    resultType: BridgeWire.HelloResult.self)
                XCTAssertTrue(hello.capabilities.contains(BridgeWire.Capability.sync))

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
                host: host, pskProvider: { box.map }, deviceName: { "M" }, onPeerHandshake: { _, _ in })
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
