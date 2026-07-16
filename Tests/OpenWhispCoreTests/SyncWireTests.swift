import XCTest
@testable import OpenWhispCore

/// Wire round-trip + shape tests for the P2P sync verbs (MAK-51 WP0b, wire v1.2):
/// `sync.manifest` / `sync.pull` / `sync.push`. Encoding/decoding is the contract
/// the iOS SyncKit + the mac LANBridgeServer (WP6-mac) both build on, so it is
/// pinned here with `swift test`.
final class SyncWireTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Method + capability names are stable on the wire

    func testSyncMethodRawValues() {
        XCTAssertEqual(BridgeWire.Method.syncManifest.rawValue, "sync.manifest")
        XCTAssertEqual(BridgeWire.Method.syncPull.rawValue, "sync.pull")
        XCTAssertEqual(BridgeWire.Method.syncPush.rawValue, "sync.push")
    }

    func testSyncCapabilityToken() {
        XCTAssertEqual(BridgeWire.Capability.sync, "sync")
    }

    func testWireVersionLabelIsAdditiveOnly() {
        // The additive milestone bumped to 1.2 for sync, but the on-the-wire major
        // stays 1 so no existing client is treated as "from the future".
        XCTAssertEqual(BridgeWire.wireVersionLabel, "1.2")
        XCTAssertEqual(BridgeWire.protocolVersion, 1)
    }

    // MARK: sync.manifest

    func testManifestRoundTrips() throws {
        let head = BridgeWire.SyncHistoryHead(
            count: 3, newestID: UUID(), newestDate: BridgeWire.iso8601String(from: Date())
        )
        let manifest = BridgeWire.SyncManifestResult(
            schemaVersion: ConfigBundle.currentSchemaVersion,
            vocabHash: "abc", profilesHash: "def", modesHash: "ghi", packsHash: "jkl",
            historyHead: head,
            updatedAt: [
                BridgeWire.SyncSection.vocabulary.rawValue: BridgeWire.iso8601String(from: Date()),
                BridgeWire.SyncSection.modes.rawValue: BridgeWire.iso8601String(from: Date()),
            ]
        )
        XCTAssertEqual(try roundTrip(manifest), manifest)
    }

    func testManifestEmptyHistoryHeadRoundTrips() throws {
        let head = BridgeWire.SyncHistoryHead(count: 0, newestID: nil, newestDate: nil)
        let manifest = BridgeWire.SyncManifestResult(
            schemaVersion: 3, vocabHash: "", profilesHash: "", modesHash: "", packsHash: "",
            historyHead: head, updatedAt: [:]
        )
        let back = try roundTrip(manifest)
        XCTAssertNil(back.historyHead.newestID)
        XCTAssertNil(back.historyHead.newestDate)
        XCTAssertEqual(back.historyHead.count, 0)
    }

    // MARK: sync.pull params

    func testPullParamsRoundTrip() throws {
        let params = BridgeWire.SyncPullParams(
            sinceHistoryCursor: BridgeWire.iso8601String(from: Date()),
            want: [.vocabulary, .history, .modes]
        )
        XCTAssertEqual(try roundTrip(params), params)
    }

    func testPullParamsDropsUnknownSectionToken() throws {
        // A newer peer asks for a section this build doesn't know: it is dropped,
        // not fatal — the request still routes.
        let json = #"{"want":["vocabulary","teleportation","history"]}"#
        let params = try JSONDecoder().decode(BridgeWire.SyncPullParams.self, from: Data(json.utf8))
        XCTAssertEqual(params.want, [.vocabulary, .history])
        XCTAssertNil(params.sinceHistoryCursor)
    }

    func testPullParamsAbsentFieldsDecode() throws {
        let params = try JSONDecoder().decode(BridgeWire.SyncPullParams.self, from: Data("{}".utf8))
        XCTAssertNil(params.want)
        XCTAssertNil(params.sinceHistoryCursor)
    }

    // MARK: sync.pull / sync.push bundle payload

    func testBundleResultRoundTripsWithHistory() throws {
        let now = Date()
        let vocab = Vocabulary(
            terms: ["OpenWhisp"],
            substitutions: [Vocabulary.Substitution(from: "clod", to: "Claude", updatedAt: now)]
        )
        let bundle = ConfigBundle(
            profiles: [AppProfile(appBundleID: "com.apple.mail", displayName: "Mail", updatedAt: now)],
            modes: [Mode(key: "email", name: "Email", updatedAt: now)],
            vocabulary: vocab
        )
        let entries = [
            TranscriptionEntry(text: "hello", date: now, appBundleID: "a", appName: "A",
                               rawText: "helo", audioFileName: "retained-x.wav")
        ]
        let payload = BridgeWire.SyncBundleResult(bundle: bundle, historyEntries: entries)
        let back = try roundTrip(payload)
        XCTAssertEqual(back, payload)
        // Fidelity: rawText + audio metadata survive (this is device-to-device, not
        // the redacted human-facing history.list DTO).
        XCTAssertEqual(back.historyEntries.first?.rawText, "helo")
        XCTAssertEqual(back.historyEntries.first?.audioFileName, "retained-x.wav")
    }

    func testBundleResultEmptyHistoryDefaults() throws {
        let payload = BridgeWire.SyncBundleResult(bundle: ConfigBundle())
        XCTAssertTrue(payload.historyEntries.isEmpty)
        XCTAssertEqual(try roundTrip(payload), payload)
    }

    // MARK: sync.push result

    func testPushResultRoundTrip() throws {
        let result = BridgeWire.SyncPushResult(
            accepted: true,
            mergedCounts: BridgeWire.SyncMergedCounts(vocabulary: 2, profiles: 1, modes: 0, history: 5, packs: 1)
        )
        XCTAssertEqual(try roundTrip(result), result)
    }

    func testPushResultRefusalDefaults() throws {
        let result = BridgeWire.SyncPushResult(accepted: false)
        let back = try roundTrip(result)
        XCTAssertFalse(back.accepted)
        XCTAssertEqual(back.mergedCounts, BridgeWire.SyncMergedCounts())
    }

    // MARK: The stamped types cross the wire carrying updatedAt (v3)

    func testSubstitutionUpdatedAtSurvivesWire() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sub = Vocabulary.Substitution(from: "a", to: "b", updatedAt: stamp)
        let back = try roundTrip(sub)
        XCTAssertEqual(back.updatedAt.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.001)
    }
}
