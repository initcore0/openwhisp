import XCTest
@testable import OpenWhispCore

final class VoiceActionRegistryTests: XCTestCase {

    private func action(_ id: String, _ phrases: [String], prompt: String = "p") -> VoiceAction {
        VoiceAction(id: id, displayName: id, triggerPhrases: phrases, prompt: prompt)
    }

    // MARK: Built-ins

    func testBuiltinsContainTelegram() {
        let tg = VoiceActionRegistry.builtins.action(id: VoiceAction.telegramPostID)
        XCTAssertNotNil(tg)
        XCTAssertEqual(tg?.prompt, VoiceAction.defaultTelegramPostPrompt)
        XCTAssertTrue(tg?.triggerPhrases.contains("make a telegram post") ?? false)
        XCTAssertTrue(tg?.triggerPhrases.contains("сделай пост для телеграм") ?? false)
    }

    func testAllPhrasesCarryOwningID() {
        let reg = VoiceActionRegistry([action("a", ["x", "y"]), action("b", ["z"])])
        let pairs = reg.allPhrases
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(Set(pairs.filter { $0.id == "a" }.map(\.phrase)), ["x", "y"])
        XCTAssertEqual(pairs.first { $0.phrase == "z" }?.id, "b")
    }

    // MARK: Merge / override

    func testMergeAppendsNewAction() {
        let merged = VoiceActionRegistry([action("a", ["x"])]).merging([action("b", ["y"])])
        XCTAssertEqual(merged.actions.map(\.id), ["a", "b"])
    }

    func testMergeOverridesExistingByIDInPlace() {
        let base = VoiceActionRegistry([action("a", ["x"]), action("b", ["y"])])
        let merged = base.merging([action("a", ["x2"], prompt: "new")])
        // Order preserved, "a" replaced.
        XCTAssertEqual(merged.actions.map(\.id), ["a", "b"])
        XCTAssertEqual(merged.action(id: "a")?.prompt, "new")
        XCTAssertEqual(merged.action(id: "a")?.triggerPhrases, ["x2"])
        XCTAssertEqual(merged.action(id: "b")?.prompt, "p")
    }

    func testOverrideTelegramPromptViaMerge() {
        var custom = VoiceAction.telegramPost
        custom.prompt = "punchier"
        let reg = VoiceActionRegistry.builtins.merging([custom])
        XCTAssertEqual(reg.action(id: VoiceAction.telegramPostID)?.prompt, "punchier")
        // Still only one telegram action (override, not append).
        XCTAssertEqual(reg.actions.filter { $0.id == VoiceAction.telegramPostID }.count, 1)
    }

    func testMergeIsImmutableOnReceiver() {
        let base = VoiceActionRegistry([action("a", ["x"])])
        _ = base.merging([action("b", ["y"])])
        XCTAssertEqual(base.actions.map(\.id), ["a"], "merging must not mutate the receiver")
    }

    // MARK: Codable round-trip (so packs can carry actions later)

    func testCodableRoundTrip() throws {
        let original = action("tweet", ["make a tweet", "tweet this"], prompt: "Make a tweet")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VoiceAction.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

/// The longest-phrase-first matching the parser relies on, plus registry-driven
/// matching (a custom action's phrase triggers and returns its id).
final class VoiceCommandParserRegistryTests: XCTestCase {
    func testCustomActionTriggersByID() {
        let reg = VoiceActionRegistry([
            VoiceAction(id: "tweet", displayName: "Tweet",
                        triggerPhrases: ["make a tweet", "tweet this"], prompt: "p")
        ])
        let parser = VoiceCommandParser(wakeWord: "", actions: reg)
        let r = parser.parse("we shipped a huge update today. make a tweet")
        XCTAssertEqual(r?.actionID, "tweet")
        XCTAssertEqual(r?.content, "we shipped a huge update today.")
    }

    func testUnknownActionFallsThroughToGeneric() {
        // With an empty registry, a telegram phrase is no longer a named action;
        // it should not match the action branch (and isn't a generic imperative).
        let parser = VoiceCommandParser(wakeWord: "", actions: VoiceActionRegistry([]))
        XCTAssertNil(parser.parse("we shipped it. make a telegram post"))
    }

    func testLongerPhraseWinsOverSubstring() {
        // Two actions whose phrases are substrings; the longer, more specific
        // phrase must win so the right action id is returned.
        let reg = VoiceActionRegistry([
            VoiceAction(id: "short", displayName: "s", triggerPhrases: ["post"], prompt: "p"),
            VoiceAction(id: "long", displayName: "l", triggerPhrases: ["telegram post"], prompt: "p")
        ])
        let parser = VoiceCommandParser(wakeWord: "", actions: reg)
        XCTAssertEqual(parser.parse("the build is green. telegram post")?.actionID, "long")
    }
}
