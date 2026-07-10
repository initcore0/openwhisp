import XCTest
@testable import OpenWhispCore

/// Unit tests for the pure rules-engine core (MAK-43): matcher semantics, the
/// session/app/hook gates, the planner's ordering + agent fail-safe, the Codable
/// round-trip, and the `RuleURLBuilder.build` interpolation.
final class RulesTests: XCTestCase {

    // MARK: - Matcher

    func testAlwaysMatchesAnything() {
        XCTAssertTrue(RuleMatcher.matches("anything", RuleTextMatch(kind: .always)))
        XCTAssertTrue(RuleMatcher.matches("", RuleTextMatch(kind: .always)))
    }

    func testExactIsCaseInsensitiveAndTrimmed() {
        let m = RuleTextMatch(kind: .exact, pattern: "Done")
        XCTAssertTrue(RuleMatcher.matches("  done  ", m))
        XCTAssertTrue(RuleMatcher.matches("DONE", m))
        XCTAssertFalse(RuleMatcher.matches("done now", m))
    }

    func testPrefixAnchorsAtStart() {
        let m = RuleTextMatch(kind: .prefix, pattern: "todo")
        XCTAssertTrue(RuleMatcher.matches("todo buy milk", m))
        XCTAssertTrue(RuleMatcher.matches("TODO ship it", m))
        XCTAssertFalse(RuleMatcher.matches("my todo list", m))
    }

    func testContainsMatchesAnywhere() {
        let m = RuleTextMatch(kind: .contains, pattern: "urgent")
        XCTAssertTrue(RuleMatcher.matches("this is URGENT please", m))
        XCTAssertFalse(RuleMatcher.matches("nothing here", m))
    }

    func testEmptyPatternNeverMatchesLiteralModes() {
        XCTAssertFalse(RuleMatcher.matches("x", RuleTextMatch(kind: .exact, pattern: "")))
        XCTAssertFalse(RuleMatcher.matches("x", RuleTextMatch(kind: .prefix, pattern: "")))
        XCTAssertFalse(RuleMatcher.matches("x", RuleTextMatch(kind: .contains, pattern: "")))
    }

    func testRegexMatchesAndIsCaseInsensitive() {
        let m = RuleTextMatch(kind: .regex, pattern: "^meeting.*notes$")
        XCTAssertTrue(RuleMatcher.matches("Meeting with the notes", m))
        XCTAssertFalse(RuleMatcher.matches("no match here", m))
    }

    func testInvalidRegexNeverMatchesAndDoesNotThrow() {
        // An unbalanced group is an invalid ICU pattern — must degrade to "no match".
        XCTAssertFalse(RuleMatcher.matches("anything", RuleTextMatch(kind: .regex, pattern: "(")))
        XCTAssertFalse(RuleMatcher.matches("anything", RuleTextMatch(kind: .regex, pattern: "")))
    }

    func testCatastrophicBacktrackingPatternIsAbandonedWithinBudget() {
        // `(a+)+b` over a run of 'a's with no 'b' is the classic exponential
        // backtracking bomb — unguarded, NSRegularExpression hangs for minutes on 60
        // chars (well under the input cap). The time-budget guard must abandon it
        // and report "no match" quickly instead of hanging.
        let bomb = String(repeating: "a", count: 60)
        let start = Date()
        let matched = RuleMatcher.matches(bomb, RuleTextMatch(kind: .regex, pattern: "(a+)+b"))
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(matched)
        XCTAssertLessThan(elapsed, RuleMatcher.regexTimeBudget + 1.0,
                          "pathological regex must be abandoned near the time budget, not hang")
    }

    func testRegexDeclinesOverlongInput() {
        let long = String(repeating: "a", count: RuleMatcher.regexInputCap + 1)
        // Even a trivially-true pattern is declined past the cap (backtracking guard).
        XCTAssertFalse(RuleMatcher.matches(long, RuleTextMatch(kind: .regex, pattern: "a")))
    }

    // MARK: - Session-mode gate

    func testSessionModeAdmits() {
        XCTAssertTrue(RuleSessionMode.dictation.admits(isAgentSession: false))
        XCTAssertFalse(RuleSessionMode.dictation.admits(isAgentSession: true))
        XCTAssertTrue(RuleSessionMode.agent.admits(isAgentSession: true))
        XCTAssertFalse(RuleSessionMode.agent.admits(isAgentSession: false))
        XCTAssertTrue(RuleSessionMode.any.admits(isAgentSession: true))
        XCTAssertTrue(RuleSessionMode.any.admits(isAgentSession: false))
    }

    // MARK: - App scope

    func testAppScopeAnyAdmitsEverything() {
        XCTAssertTrue(RuleAppScope.any.admits(appBundleID: "com.apple.Notes"))
        XCTAssertTrue(RuleAppScope.any.admits(appBundleID: nil))
        XCTAssertTrue(RuleAppScope(bundleID: "   ").admits(appBundleID: "x"))  // blank = any
    }

    func testAppScopeMatchesExactBundle() {
        let scope = RuleAppScope(bundleID: "com.apple.Notes")
        XCTAssertTrue(scope.admits(appBundleID: "com.apple.Notes"))
        XCTAssertFalse(scope.admits(appBundleID: "com.apple.Safari"))
        XCTAssertFalse(scope.admits(appBundleID: nil))
    }

    // MARK: - Planner

    private func rule(
        hook: RuleHook = .llmComplete,
        match: RuleTextMatch = .always,
        scope: RuleAppScope = .any,
        mode: RuleSessionMode = .dictation,
        enabled: Bool = true,
        name: String = "r",
        actions: [RuleAction] = [.insertSnippet(text: "x")]
    ) -> Rule {
        Rule(name: name, isEnabled: enabled, hook: hook, match: match,
             appScope: scope, sessionMode: mode, actions: actions)
    }

    func testPlannerEmitsMatchingActionsInOrder() {
        let a = rule(name: "a", actions: [.insertSnippet(text: "1"), .openURL(template: "u")])
        let set = RuleSet(rules: [a])
        let ctx = RuleContext(hook: .llmComplete, text: "hello", appBundleID: nil, isAgentSession: false)
        let plan = RulePlanner.plan(rules: set, context: ctx)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.map { $0.action }, [.insertSnippet(text: "1"), .openURL(template: "u")])
        XCTAssertEqual(plan[0].ruleName, "a")
    }

    func testPlannerSkipsDisabledWrongHookAndNonMatching() {
        let disabled = rule(enabled: false, name: "off")
        let wrongHook = rule(hook: .transcribeComplete, name: "wrongHook")
        let nonMatch = rule(match: RuleTextMatch(kind: .exact, pattern: "nope"), name: "noMatch")
        let good = rule(match: RuleTextMatch(kind: .contains, pattern: "ell"), name: "good")
        let set = RuleSet(rules: [disabled, wrongHook, nonMatch, good])
        let ctx = RuleContext(hook: .llmComplete, text: "hello", appBundleID: nil, isAgentSession: false)
        let plan = RulePlanner.plan(rules: set, context: ctx)
        XCTAssertEqual(plan.map(\.ruleName), ["good"])
    }

    func testPlannerAgentGateBlocksNonOptedInRule() {
        // Default dictation-only rule must NOT fire on an agent session.
        let dictationOnly = rule(mode: .dictation, name: "dict")
        let agentOptIn = rule(mode: .any, name: "any")
        let set = RuleSet(rules: [dictationOnly, agentOptIn])
        let ctx = RuleContext(hook: .llmComplete, text: "hi", appBundleID: nil, isAgentSession: true)
        let plan = RulePlanner.plan(rules: set, context: ctx)
        XCTAssertEqual(plan.map(\.ruleName), ["any"], "agent session must only run opted-in rules")
    }

    func testPlannerAppScopeFiltersByBundle() {
        let notesOnly = rule(scope: RuleAppScope(bundleID: "com.apple.Notes"), name: "notes")
        let anyApp = rule(scope: .any, name: "any")
        let set = RuleSet(rules: [notesOnly, anyApp])
        let inSafari = RuleContext(hook: .llmComplete, text: "t", appBundleID: "com.apple.Safari", isAgentSession: false)
        XCTAssertEqual(RulePlanner.plan(rules: set, context: inSafari).map(\.ruleName), ["any"])
        let inNotes = RuleContext(hook: .llmComplete, text: "t", appBundleID: "com.apple.Notes", isAgentSession: false)
        XCTAssertEqual(RulePlanner.plan(rules: set, context: inNotes).map(\.ruleName), ["notes", "any"])
    }

    func testPlannerEmptyRuleSetIsNoOp() {
        let ctx = RuleContext(hook: .llmComplete, text: "t", appBundleID: nil, isAgentSession: false)
        XCTAssertTrue(RulePlanner.plan(rules: .empty, context: ctx).isEmpty)
    }

    // MARK: - Codable round-trip (persistence contract)

    func testRuleSetCodableRoundTrip() throws {
        let set = RuleSet(rules: [
            rule(hook: .transcribeComplete,
                 match: RuleTextMatch(kind: .prefix, pattern: "todo"),
                 scope: RuleAppScope(bundleID: "com.apple.Notes"),
                 mode: .any,
                 actions: [
                    .insertSnippet(text: "hi"),
                    .openURL(template: "https://x/{{text}}"),
                    .runShell(scriptPath: "/bin/cat"),
                    .runShortcut(name: "Log"),
                    .postWebhook(config: WebhookConfig(url: "https://x/hook", headers: ["A": "b"])),
                    .appendFile(config: FileOutputConfig(path: "~/log.md", mode: .append)),
                 ])
        ])
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(RuleSet.self, from: data)
        XCTAssertEqual(decoded, set)
    }

    func testDecodingRejectsUnknownActionTag() {
        // An unknown action `type` must fail the decode (so RuleStore quarantines it)
        // rather than silently dropping the action.
        let json = #"{"rules":[{"id":"\#(UUID().uuidString)","name":"r","isEnabled":true,"hook":"llmComplete","match":{"kind":"always","pattern":""},"appScope":{},"sessionMode":"dictation","actions":[{"type":"launchMissiles"}]}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(RuleSet.self, from: Data(json.utf8)))
    }

    // MARK: - URL interpolation (runner helper, pure)

    func testBuildURLPercentEncodesTranscript() {
        let url = RuleURLBuilder.build(template: "https://x.test/q?s={{text}}", text: "a b&c=d")
        XCTAssertEqual(url?.absoluteString, "https://x.test/q?s=a%20b%26c%3Dd")
    }

    func testBuildURLWithoutTokenOpensAsIs() {
        let url = RuleURLBuilder.build(template: "https://x.test/open", text: "ignored")
        XCTAssertEqual(url?.absoluteString, "https://x.test/open")
    }

    func testBuildURLRejectsEmptyTemplate() {
        XCTAssertNil(RuleURLBuilder.build(template: "   ", text: "t"))
    }
}
