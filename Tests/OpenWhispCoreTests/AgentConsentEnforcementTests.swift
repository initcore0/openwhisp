import XCTest
@testable import OpenWhispCore

/// The consent CONTRACT test (MAK-81): every bridge verb is refused unless its
/// OWN scope is granted, and a grant for one scope never rides to another.
///
/// The enforcement itself lives in `AgentBridgeServer.execute` (app-target,
/// UNIX-socket) and `LANBridgeServer` — neither compiles under `swift test`.
/// Both now derive the scope they check from the single source of truth,
/// `BridgeWire.Method.requiredScope`, and refuse via the SAME pure decision path
/// (`AgentClientRecord.policy(for:)` → `AgentConsentPolicy.decision`) this suite
/// exercises directly. So pinning (a) the verb→scope map and (b) the per-scope
/// refusal here fails the build if a verb is rewired to the wrong scope or a
/// grant is allowed to leak across scopes — the regression the ticket guards.
final class AgentConsentEnforcementTests: XCTestCase {

    // MARK: (a) Each guarded verb requires exactly its own scope

    func testGuardedVerbsMapToTheirOwnScope() {
        XCTAssertEqual(BridgeWire.Method.dictate.requiredScope, .dictate)
        XCTAssertEqual(BridgeWire.Method.historyList.requiredScope, .history)
        XCTAssertEqual(BridgeWire.Method.refine.requiredScope, .refine)
        XCTAssertEqual(BridgeWire.Method.syncManifest.requiredScope, .sync)
        XCTAssertEqual(BridgeWire.Method.syncPull.requiredScope, .sync)
        XCTAssertEqual(BridgeWire.Method.syncPush.requiredScope, .sync)
    }

    func testUnguardedVerbsRequireNoScope() {
        // hello only advertises posture; status is read-only health; stop/cancel
        // merely END a session the same client already started under a dictate
        // grant — gating them would strand a caller unable to stop its own mic.
        for method in [BridgeWire.Method.hello, .status, .dictateStop, .dictateCancel, .transcribeFile] {
            XCTAssertNil(method.requiredScope, "\(method.rawValue) must be unguarded")
        }
    }

    func testEveryMethodHasADecidedScopePosture() {
        // Exhaustive: adding a Method forces a requiredScope decision (the switch
        // has no `default`). This asserts the set stays fully classified.
        let guarded = BridgeWire.Method.allCases.filter { $0.requiredScope != nil }
        XCTAssertEqual(Set(guarded.map(\.rawValue)),
                       ["dictate", "history.list", "refine", "sync.manifest", "sync.pull", "sync.push"])
    }

    // MARK: (b) A verb is refused unless ITS scope is granted (the refusal path)

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Mirrors `AppState.consentDecision(record:clientName:scope:)`: no record or
    /// no policy for the scope → prompt; else the policy's decision. (No this-run
    /// grant here — a fresh call with only stored policy.)
    private func decision(_ record: AgentClientRecord?, _ scope: AgentScope) -> AgentConsentDecision {
        guard let policy = record?.policy(for: scope) else { return .prompt }
        return policy.decision(grantedThisRun: false)
    }

    func testVerbRefusedWhenItsScopeUngranted() {
        // A client granted ONLY dictate. Every other verb's scope is undecided →
        // the server would prompt (never silently allow); an explicit deny → deny.
        let record = AgentClientRecord(
            clientName: "claude-code",
            scopePolicies: [.dictate: .always, .history: .denied],
            firstSeen: now
        )

        // Its granted scope proceeds without a prompt.
        XCTAssertEqual(decision(record, BridgeWire.Method.dictate.requiredScope!), .allow)

        // A different verb whose scope was explicitly denied is refused fast.
        XCTAssertEqual(decision(record, BridgeWire.Method.historyList.requiredScope!), .deny)

        // A verb whose scope was never decided is NOT auto-allowed by the dictate
        // grant — it prompts (the "don't ride history on a mic grant" invariant).
        XCTAssertEqual(decision(record, BridgeWire.Method.refine.requiredScope!), .prompt)
        XCTAssertEqual(decision(record, BridgeWire.Method.syncPull.requiredScope!), .prompt)
    }

    func testGrantDoesNotLeakAcrossScopes() {
        // Grant each scope in isolation; assert ONLY that verb's scope allows and
        // every other guarded verb still prompts.
        let guardedScopes: [AgentScope] = [.dictate, .history, .refine, .sync]
        for granted in guardedScopes {
            let record = AgentClientRecord(
                clientName: "c", scopePolicies: [granted: .always], firstSeen: now)
            for scope in guardedScopes {
                let expected: AgentConsentDecision = (scope == granted) ? .allow : .prompt
                XCTAssertEqual(decision(record, scope), expected,
                    "granting \(granted) must \(scope == granted ? "allow" : "NOT allow") \(scope)")
            }
        }
    }

    func testUnknownClientPromptsForEveryScope() {
        for scope in AgentScope.allCases {
            XCTAssertEqual(decision(nil, scope), .prompt,
                "a never-seen client has no standing grant on \(scope)")
        }
    }
}
