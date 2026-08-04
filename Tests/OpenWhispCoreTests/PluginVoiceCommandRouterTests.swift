import XCTest
@testable import OpenWhispCore

/// The v10 voice-command trigger layer: which spoken refine instructions get routed
/// to a plugin, and — just as important — which ones must NOT be.
///
/// The negatives carry most of the weight here. A false positive silently redirects a
/// dictation away from the user's editor into a plugin window, so "create a memo
/// about Q3" staying a normal refine is the property that keeps this feature safe.
final class PluginVoiceCommandRouterTests: XCTestCase {

    private func manifest(
        id: String, triggers: [String], name: String = "Test Plugin"
    ) -> PluginManifest {
        PluginManifest(
            id: id, name: name, version: "1.0.0", summary: "",
            symbol: "star", entry: .builtIn, voiceTriggers: triggers)
    }

    private var meme: PluginManifest {
        manifest(id: "meme-generator",
                 triggers: ["create a meme", "make a meme", "сделай мем"],
                 name: "Meme Generator")
    }

    // MARK: - Positive matches

    func testMatchesBarePrefixWithEmptyRemainder() {
        let match = PluginVoiceCommandRouter.match(
            instruction: "create a meme", enabledPlugins: [meme])
        XCTAssertEqual(match?.pluginID, "meme-generator")
        XCTAssertEqual(match?.trigger, "create a meme")
        // Empty remainder is legitimate: the material comes from the refine CONTENT.
        XCTAssertEqual(match?.remainder, "")
    }

    /// CASE 1: selection is the material, the spoken words are just the trigger plus
    /// a pointer back at the selection.
    func testMatchesSelectionPhrasingAndKeepsRemainder() {
        let match = PluginVoiceCommandRouter.match(
            instruction: "Create a meme based on that", enabledPlugins: [meme])
        XCTAssertEqual(match?.pluginID, "meme-generator")
        XCTAssertEqual(match?.remainder, "based on that")
    }

    /// CASE 2: the owner's real prompt. The colon is a boundary, and the list after
    /// it must survive intact — the commas ARE the items.
    func testMatchesOwnersExpandingBrainPromptPreservingTheList() {
        let match = PluginVoiceCommandRouter.match(
            instruction: "create a meme expanding brain: typing, dictating, dictating memes, dictating memes by voice",
            enabledPlugins: [meme])
        XCTAssertEqual(match?.pluginID, "meme-generator")
        XCTAssertEqual(
            match?.remainder,
            "expanding brain: typing, dictating, dictating memes, dictating memes by voice")
    }

    /// The trigger may be followed immediately by a colon — that punctuation belongs
    /// to the trigger, not to the material.
    func testTriggerTrailingPunctuationIsNotPartOfTheRemainder() {
        let match = PluginVoiceCommandRouter.match(
            instruction: "Create a meme: typing, dictating", enabledPlugins: [meme])
        XCTAssertEqual(match?.remainder, "typing, dictating")
    }

    func testMatchIsCaseAndWhitespaceInsensitive() {
        let match = PluginVoiceCommandRouter.match(
            instruction: "  MAKE   A   MEME   about deadlines ", enabledPlugins: [meme])
        XCTAssertEqual(match?.trigger, "make a meme")
        XCTAssertEqual(match?.remainder, "about deadlines")
    }

    /// The remainder is sliced from the ORIGINAL text, so the user's capitalization
    /// survives into the rendered captions.
    func testRemainderPreservesOriginalCasing() {
        let match = PluginVoiceCommandRouter.match(
            instruction: "create a meme about Kubernetes and YAML", enabledPlugins: [meme])
        XCTAssertEqual(match?.remainder, "about Kubernetes and YAML")
    }

    /// Russian, because the owner dictates in it.
    func testMatchesRussianTrigger() {
        let match = PluginVoiceCommandRouter.match(
            instruction: "Сделай мем про дедлайны", enabledPlugins: [meme])
        XCTAssertEqual(match?.pluginID, "meme-generator")
        XCTAssertEqual(match?.remainder, "про дедлайны")
    }

    // MARK: - Negatives (a false positive costs the user their dictation)

    /// The near-miss the runtime probe also pins: "memo" is not "meme".
    func testDoesNotMatchCreateAMemo() {
        XCTAssertNil(PluginVoiceCommandRouter.match(
            instruction: "create a memo about the Q3 numbers", enabledPlugins: [meme]))
    }

    /// A word-boundary check, not a substring check.
    func testDoesNotMatchWhenTriggerRunsIntoAnotherWord() {
        XCTAssertNil(PluginVoiceCommandRouter.match(
            instruction: "create a memes", enabledPlugins: [meme]))
    }

    /// PREFIX only — a mention mid-sentence is an ordinary refine instruction.
    func testDoesNotMatchTriggerInTheMiddle() {
        XCTAssertNil(PluginVoiceCommandRouter.match(
            instruction: "rewrite this so it doesn't sound like a meme", enabledPlugins: [meme]))
        XCTAssertNil(PluginVoiceCommandRouter.match(
            instruction: "summarize this, then create a meme", enabledPlugins: [meme]))
    }

    func testDoesNotMatchUnrelatedInstruction() {
        XCTAssertNil(PluginVoiceCommandRouter.match(
            instruction: "make this more concise", enabledPlugins: [meme]))
    }

    func testEmptyInstructionDoesNotMatch() {
        XCTAssertNil(PluginVoiceCommandRouter.match(instruction: "", enabledPlugins: [meme]))
        XCTAssertNil(PluginVoiceCommandRouter.match(instruction: "   ", enabledPlugins: [meme]))
    }

    // MARK: - Enablement gating

    /// The gate: the caller passes only ENABLED plugins, so a disabled plugin cannot
    /// claim a dictation.
    func testDisabledPluginDoesNotMatchWhenAbsentFromEnabledList() {
        XCTAssertNil(PluginVoiceCommandRouter.match(
            instruction: "create a meme about deadlines", enabledPlugins: []))
    }

    /// …but the caller can still ask whether it WOULD have matched, which is what
    /// gates the "plugin is disabled" hint so it never fires on an unrelated refine.
    func testMatchIgnoringEnablementDrivesTheDisabledHint() {
        XCTAssertNotNil(PluginVoiceCommandRouter.matchIgnoringEnablement(
            instruction: "create a meme about deadlines", plugins: [meme]))
        XCTAssertNil(PluginVoiceCommandRouter.matchIgnoringEnablement(
            instruction: "make this more concise", plugins: [meme]))
    }

    /// A plugin with no declared triggers is simply not routable.
    func testPluginWithoutTriggersNeverMatches() {
        let silent = manifest(id: "quiet", triggers: [])
        XCTAssertNil(PluginVoiceCommandRouter.match(
            instruction: "create a meme", enabledPlugins: [silent]))
    }

    // MARK: - Precedence

    /// The more SPECIFIC phrase wins regardless of list order, or the plugin that
    /// declared it would be unreachable.
    func testLongestTriggerWinsRegardlessOfOrder() {
        let general = manifest(id: "general", triggers: ["create a meme"])
        let specific = manifest(id: "specific", triggers: ["create a meme poster"])
        let match = PluginVoiceCommandRouter.match(
            instruction: "create a meme poster about deadlines",
            enabledPlugins: [general, specific])
        XCTAssertEqual(match?.pluginID, "specific")
        XCTAssertEqual(match?.remainder, "about deadlines")
    }

    /// Equal-length triggers resolve by list order — the same first-wins rule
    /// `PluginDiscovery` uses, so the host has one precedence story.
    func testEqualLengthTriggersResolveByListOrder() {
        let first = manifest(id: "first", triggers: ["create a meme"])
        let second = manifest(id: "second", triggers: ["create a meme"])
        XCTAssertEqual(
            PluginVoiceCommandRouter.match(
                instruction: "create a meme now", enabledPlugins: [first, second])?.pluginID,
            "first")
    }

    // MARK: - Manifest trigger normalization

    /// An empty prefix matches EVERYTHING — it must never survive into the router, or
    /// a stray `""` in a JSON file would swallow every refine the user ever spoke.
    func testEmptyTriggersAreNormalizedAwayAndNeverMatchEverything() {
        let broken = manifest(id: "broken", triggers: ["", "   "])
        XCTAssertEqual(broken.normalizedVoiceTriggers, [])
        XCTAssertNil(PluginVoiceCommandRouter.match(
            instruction: "anything at all", enabledPlugins: [broken]))
        // Reported to the author, but never fatal — the plugin still lists and runs.
        XCTAssertEqual(broken.validate(), .emptyVoiceTriggers)
        XCTAssertTrue(broken.isValid)
    }

    func testTriggersAreLowercasedTrimmedAndDeduplicated() {
        let messy = manifest(id: "messy", triggers: ["  Create A Meme  ", "create a meme"])
        XCTAssertEqual(messy.normalizedVoiceTriggers, ["create a meme"])
    }

    /// Forward-compatible decode: a manifest written before `voiceTriggers` existed
    /// still decodes (and simply has no voice route).
    func testManifestWithoutVoiceTriggersStillDecodes() throws {
        let json = """
        {"id":"legacy","name":"Legacy","symbol":"star","entry":"builtIn"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(decoded.voiceTriggers, [])
        XCTAssertTrue(decoded.isValid)
    }

    func testManifestDecodesDeclaredVoiceTriggers() throws {
        let json = """
        {"id":"p","name":"P","symbol":"star","entry":"builtIn",
         "voiceTriggers":["Create A Meme","make a meme"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(decoded.normalizedVoiceTriggers, ["create a meme", "make a meme"])
    }

    // MARK: - Overlay acknowledgment

    /// The routed dictation produces NOTHING in the focused app, so the overlay has
    /// to say where the words went — and it must name the plugin.
    func testAcknowledgmentNamesThePlugin() {
        XCTAssertEqual(
            PluginVoiceCommandRouter.acknowledgment(pluginName: "Meme Generator"),
            "Meme Generator — creating…")
    }

    func testDisabledHintNamesThePlugin() {
        XCTAssertEqual(
            PluginVoiceCommandRouter.disabledHint(pluginName: "Meme Generator"),
            "Meme Generator plugin is disabled")
    }

    /// The acknowledgment reaches the overlay through `statusMessage`, which
    /// `FinalizingCaption` surfaces verbatim — so no new OverlayPhase case is needed.
    /// This pins that the two agree; a change to either side that broke the caption
    /// would otherwise only show up on screen.
    func testAcknowledgmentSurvivesAsTheOverlayFinalizeCaption() {
        let ack = PluginVoiceCommandRouter.acknowledgment(pluginName: "Meme Generator")
        XCTAssertEqual(
            FinalizingCaption.resolve(
                isTranscribing: true, statusMessage: ack,
                workerStatus: "", usesWhisperKit: false),
            "Meme Generator — creating…")
    }

    // MARK: - The shipping manifest

    /// The meme plugin actually declares the phrases the owner speaks.
    func testShippingMemeManifestRoutesBothOwnerFlows() {
        let plugins = PluginRegistry.builtInManifests
        XCTAssertEqual(
            PluginVoiceCommandRouter.match(
                instruction: "create a meme based on that", enabledPlugins: plugins)?.pluginID,
            PluginRegistry.memeGenerator.id)
        XCTAssertEqual(
            PluginVoiceCommandRouter.match(
                instruction: "Сделай мем про дедлайны", enabledPlugins: plugins)?.pluginID,
            PluginRegistry.memeGenerator.id)
        XCTAssertNil(PluginVoiceCommandRouter.match(
            instruction: "create a memo about the Q3 numbers", enabledPlugins: plugins))
    }
}
