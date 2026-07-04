import XCTest
@testable import OpenWhispCore

final class AgentClientStoreTests: XCTestCase {

    // MARK: Policy → decision

    func testAlwaysAllows() {
        XCTAssertEqual(AgentConsentPolicy.always.decision(grantedThisRun: false), .allow)
        XCTAssertEqual(AgentConsentPolicy.always.decision(grantedThisRun: true), .allow)
    }

    func testDeniedDenies() {
        XCTAssertEqual(AgentConsentPolicy.denied.decision(grantedThisRun: false), .deny)
        XCTAssertEqual(AgentConsentPolicy.denied.decision(grantedThisRun: true), .deny)
    }

    func testAskEveryTimePrompts() {
        XCTAssertEqual(AgentConsentPolicy.askEveryTime.decision(grantedThisRun: true), .prompt)
        XCTAssertEqual(AgentConsentPolicy.askEveryTime.decision(grantedThisRun: false), .prompt)
    }

    func testWhileRunningGrantsOnlyAfterThisRunGrant() {
        XCTAssertEqual(AgentConsentPolicy.whileRunning.decision(grantedThisRun: true), .allow)
        XCTAssertEqual(AgentConsentPolicy.whileRunning.decision(grantedThisRun: false), .prompt)
    }

    // MARK: Store upsert / lookup / remove

    func testUpsertInsertsThenReplaces() {
        var store = AgentClientStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.upsert(AgentClientRecord(clientName: "claude-code", policy: .askEveryTime, firstSeen: now))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.record(for: "claude-code")?.policy, .askEveryTime)

        // Same name replaces, doesn't duplicate.
        store.upsert(AgentClientRecord(clientName: "claude-code", policy: .always, firstSeen: now))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.record(for: "claude-code")?.policy, .always)
    }

    func testDistinctClientsCoexist() {
        var store = AgentClientStore()
        let now = Date()
        store.upsert(AgentClientRecord(clientName: "claude-code", policy: .always, firstSeen: now))
        store.upsert(AgentClientRecord(clientName: "cursor", policy: .denied, firstSeen: now))
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.record(for: "cursor")?.policy, .denied)
    }

    func testRemove() {
        var store = AgentClientStore()
        let now = Date()
        store.upsert(AgentClientRecord(clientName: "claude-code", policy: .always, firstSeen: now))
        store.remove(clientName: "claude-code")
        XCTAssertNil(store.record(for: "claude-code"))
    }

    func testUnknownClientHasNoRecord() {
        let store = AgentClientStore()
        XCTAssertNil(store.record(for: "nobody"))
    }

    // MARK: Codable round-trip (the on-disk shape)

    func testStoreRoundTrips() throws {
        var store = AgentClientStore()
        store.upsert(AgentClientRecord(
            clientName: "claude-code", policy: .whileRunning,
            firstSeen: Date(timeIntervalSince1970: 1),
            lastCall: Date(timeIntervalSince1970: 2), lastTool: "dictate", signingID: "TEAMID123"
        ))
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(AgentClientStore.self, from: data)
        XCTAssertEqual(decoded, store)
    }
}
