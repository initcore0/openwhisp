import XCTest
@testable import OpenWhispCore

final class AgentClientStoreTests: XCTestCase {

    // MARK: Policy → decision (unchanged by the per-scope split)

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

    // MARK: Per-scope record

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testScopePoliciesAreIndependent() {
        let r = AgentClientRecord(
            clientName: "claude-code",
            scopePolicies: [.dictate: .always, .history: .denied],
            firstSeen: now
        )
        XCTAssertEqual(r.policy(for: .dictate), .always)
        XCTAssertEqual(r.policy(for: .history), .denied)
        XCTAssertNil(r.policy(for: .refine), "an unset scope has no standing grant")
    }

    func testAllScopesConvenienceInit() {
        let r = AgentClientRecord(clientName: "cursor", allScopes: .always, firstSeen: now)
        for scope in AgentScope.allCases {
            XCTAssertEqual(r.policy(for: scope), .always)
        }
    }

    // MARK: Store upsert / lookup / remove

    func testUpsertInsertsThenReplaces() {
        var store = AgentClientStore()
        store.upsert(AgentClientRecord(clientName: "claude-code", allScopes: .askEveryTime, firstSeen: now))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.record(for: "claude-code")?.policy(for: .dictate), .askEveryTime)

        // Same name replaces, doesn't duplicate.
        store.upsert(AgentClientRecord(clientName: "claude-code", allScopes: .always, firstSeen: now))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.record(for: "claude-code")?.policy(for: .dictate), .always)
    }

    func testDistinctClientsCoexist() {
        var store = AgentClientStore()
        store.upsert(AgentClientRecord(clientName: "claude-code", allScopes: .always, firstSeen: now))
        store.upsert(AgentClientRecord(clientName: "cursor", allScopes: .denied, firstSeen: now))
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.record(for: "cursor")?.policy(for: .refine), .denied)
    }

    func testRemove() {
        var store = AgentClientStore()
        store.upsert(AgentClientRecord(clientName: "claude-code", allScopes: .always, firstSeen: now))
        store.remove(clientName: "claude-code")
        XCTAssertNil(store.record(for: "claude-code"))
    }

    func testUnknownClientHasNoRecord() {
        let store = AgentClientStore()
        XCTAssertNil(store.record(for: "nobody"))
    }

    func testDemoteRunScopedGrantsPerScope() {
        // A `.whileRunning` grant dies with the app run that made it; reloaded rows
        // demote to askEveryTime PER SCOPE so the pane never shows an expired grant
        // as standing consent. Other scopes/policies are untouched.
        var store = AgentClientStore()
        store.upsert(AgentClientRecord(
            clientName: "claude-code",
            scopePolicies: [.dictate: .whileRunning, .history: .always, .refine: .denied],
            firstSeen: now
        ))
        store.demoteRunScopedGrants()
        let r = store.record(for: "claude-code")
        XCTAssertEqual(r?.policy(for: .dictate), .askEveryTime, "whileRunning demotes")
        XCTAssertEqual(r?.policy(for: .history), .always, "other scopes untouched")
        XCTAssertEqual(r?.policy(for: .refine), .denied)
    }

    // MARK: Codable round-trip (the on-disk shape)

    func testStoreRoundTrips() throws {
        var store = AgentClientStore()
        store.upsert(AgentClientRecord(
            clientName: "claude-code",
            scopePolicies: [.dictate: .whileRunning, .history: .always],
            firstSeen: Date(timeIntervalSince1970: 1),
            lastCall: Date(timeIntervalSince1970: 2), lastTool: "dictate", signingID: "TEAMID123"
        ))
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(AgentClientStore.self, from: data)
        XCTAssertEqual(decoded, store)
    }

    func testScopePoliciesEncodeAsReadableObject() throws {
        // The map must serialize as a JSON OBJECT keyed by scope name, not Swift's
        // flat [k,v,k,v] array for non-String-keyed dictionaries.
        let r = AgentClientRecord(
            clientName: "x", scopePolicies: [.dictate: .always], firstSeen: now
        )
        let json = String(data: try JSONEncoder().encode(r), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"scopePolicies\""))
        XCTAssertTrue(json.contains("\"dictate\""), "keyed by scope raw value, got: \(json)")
        XCTAssertTrue(json.contains("\"always\""))
    }

    // MARK: Migration from the v1 single-`policy` shape

    func testMigratesLegacySinglePolicyToAllScopes() throws {
        // A v1 record had one `policy` for everything. Decoding must apply it to
        // every scope so an existing grant stays byte-identical (no regression, no
        // accidental widening).
        let legacyJSON = """
        {
          "clientName": "claude-code",
          "policy": "always",
          "firstSeen": 1,
          "signingID": "TEAMID"
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(AgentClientRecord.self, from: legacyJSON)
        for scope in AgentScope.allCases {
            XCTAssertEqual(r.policy(for: scope), .always, "\(scope) should inherit the legacy grant")
        }
        XCTAssertEqual(r.signingID, "TEAMID")
    }

    func testMigratesLegacyDeniedToAllScopes() throws {
        let legacyJSON = """
        { "clientName": "cursor", "policy": "denied", "firstSeen": 5 }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(AgentClientRecord.self, from: legacyJSON)
        for scope in AgentScope.allCases {
            XCTAssertEqual(r.policy(for: scope), .denied)
        }
    }

    func testLegacyStoreMigratesThroughFullDecode() throws {
        // A whole store written by v1 decodes into per-scope records.
        let legacyStoreJSON = """
        { "records": [ { "clientName": "a", "policy": "always", "firstSeen": 1 } ] }
        """.data(using: .utf8)!
        let store = try JSONDecoder().decode(AgentClientStore.self, from: legacyStoreJSON)
        XCTAssertEqual(store.record(for: "a")?.policy(for: .history), .always)
    }

    func testNewShapeIgnoresUnknownScopeKeys() throws {
        // Forward-compat: a scope key this build doesn't know is dropped, not fatal.
        let futureJSON = """
        {
          "clientName": "z",
          "scopePolicies": { "dictate": "always", "telepathy": "always" },
          "firstSeen": 1
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(AgentClientRecord.self, from: futureJSON)
        XCTAssertEqual(r.policy(for: .dictate), .always)
        XCTAssertEqual(r.scopePolicies.count, 1, "unknown 'telepathy' scope dropped")
    }
}
