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

    func testMigratesEveryLegacyPolicyToAllScopes() throws {
        // A v1 record had one `policy` for everything. Decoding must apply it to
        // every scope so an existing grant stays byte-identical (no regression, no
        // accidental widening) — for EVERY policy value, not just always/denied.
        for policy in [AgentConsentPolicy.always, .denied, .askEveryTime, .whileRunning] {
            let legacyJSON = """
            { "clientName": "claude-code", "policy": "\(policy.rawValue)", "firstSeen": 1, "signingID": "TEAMID" }
            """.data(using: .utf8)!
            let r = try JSONDecoder().decode(AgentClientRecord.self, from: legacyJSON)
            for scope in AgentScope.allCases {
                XCTAssertEqual(r.policy(for: scope), policy, "\(scope) should inherit legacy \(policy)")
            }
            XCTAssertEqual(r.signingID, "TEAMID")
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

    func testLegacyWhileRunningDemotesAfterMigration() throws {
        // The load() pipeline is decode THEN demoteRunScopedGrants. A legacy
        // whileRunning record fans out to all scopes on decode; the demote pass
        // must then downgrade every one of them — otherwise an expired one-run
        // grant from a pre-update session becomes a standing tri-scope allow.
        let legacyStoreJSON = """
        { "records": [ { "clientName": "a", "policy": "whileRunning", "firstSeen": 1 } ] }
        """.data(using: .utf8)!
        var store = try JSONDecoder().decode(AgentClientStore.self, from: legacyStoreJSON)
        store.demoteRunScopedGrants()
        for scope in AgentScope.allCases {
            XCTAssertEqual(store.record(for: "a")?.policy(for: scope), .askEveryTime)
        }
    }

    // MARK: Version skew (newer builds' scopes/policies)

    func testUnknownScopeKeyIsPreservedNotDropped() throws {
        // Forward-compat: a scope key this build doesn't know is carried in
        // unknownScopeEntries and survives a re-save round trip, so switching
        // versions never erases a decision made on a newer build.
        let futureJSON = """
        {
          "clientName": "z",
          "scopePolicies": { "dictate": "always", "telepathy": "denied" },
          "firstSeen": 1
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(AgentClientRecord.self, from: futureJSON)
        XCTAssertEqual(r.policy(for: .dictate), .always)
        XCTAssertEqual(r.scopePolicies.count, 1)
        XCTAssertEqual(r.unknownScopeEntries, ["telepathy": "denied"])

        let reencoded = String(data: try JSONEncoder().encode(r), encoding: .utf8) ?? ""
        XCTAssertTrue(reencoded.contains("\"telepathy\""), "unknown scope must survive a save")
        XCTAssertEqual(try JSONDecoder().decode(AgentClientRecord.self,
                                                from: JSONEncoder().encode(r)), r)
    }

    func testUnknownPolicyValueIsQuarantinedPerEntryNotPerStore() throws {
        // A policy value from a newer build must NOT throw — a throw would
        // quarantine the whole store, wiping every client's standing denies over
        // one version-skewed entry. The entry is carried raw instead.
        let futureJSON = """
        {
          "records": [
            { "clientName": "a", "scopePolicies": { "dictate": "askOncePerDay" }, "firstSeen": 1 },
            { "clientName": "b", "scopePolicies": { "history": "denied" }, "firstSeen": 2 }
          ]
        }
        """.data(using: .utf8)!
        let store = try JSONDecoder().decode(AgentClientStore.self, from: futureJSON)
        XCTAssertNil(store.record(for: "a")?.policy(for: .dictate), "uninterpretable entry → no standing grant (prompt)")
        XCTAssertEqual(store.record(for: "a")?.unknownScopeEntries, ["dictate": "askOncePerDay"])
        XCTAssertEqual(store.record(for: "b")?.policy(for: .history), .denied,
                       "the OTHER client's standing deny must survive")
    }

    // MARK: v1 rollback bridge

    func testHomogeneousRecordDualWritesLegacyPolicyKey() throws {
        // A record still expressible in the v1 shape (one policy, all scopes)
        // also writes the legacy `policy` key so a downgraded build can decode
        // it instead of quarantining the store.
        let uniform = AgentClientRecord(clientName: "a", allScopes: .denied, firstSeen: now)
        let uniformJSON = String(data: try JSONEncoder().encode(uniform), encoding: .utf8) ?? ""
        XCTAssertTrue(uniformJSON.contains("\"policy\":\"denied\""), "got: \(uniformJSON)")

        // A heterogeneous record must NOT write it — v1 would apply one scope's
        // policy to every capability (widening or narrowing the user's choices).
        let mixed = AgentClientRecord(
            clientName: "b", scopePolicies: [.dictate: .always, .history: .denied], firstSeen: now
        )
        let mixedJSON = String(data: try JSONEncoder().encode(mixed), encoding: .utf8) ?? ""
        XCTAssertFalse(mixedJSON.contains("\"policy\""), "got: \(mixedJSON)")
    }

    // MARK: Scope ↔ capability token pinning

    func testScopeRawValuesMatchBridgeCapabilityTokens() {
        // AgentScope raw values are load-bearing three ways: persisted JSON keys,
        // consent error messages, and (by convention) the wire capability tokens.
        // Pin them so a future scope can't silently diverge from its capability.
        XCTAssertEqual(AgentScope.dictate.rawValue, BridgeWire.Capability.dictate)
        XCTAssertEqual(AgentScope.history.rawValue, BridgeWire.Capability.history)
        XCTAssertEqual(AgentScope.refine.rawValue, BridgeWire.Capability.refine)
    }
}
