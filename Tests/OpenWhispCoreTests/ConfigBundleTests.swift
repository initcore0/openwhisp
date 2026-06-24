import XCTest
@testable import OpenWhispCore

final class ConfigBundleTests: XCTestCase {

    private func sampleProfiles() -> [AppProfile] {
        [
            AppProfile(appBundleID: "com.tinyspeck.slackmacgap", displayName: "Slack",
                       language: "en", outputMode: "liveChunks", aiCleanupEnabled: false),
            AppProfile(appBundleID: "com.apple.mail", displayName: "Mail", aiCleanupEnabled: true)
        ]
    }
    private func sampleVocab() -> Vocabulary {
        Vocabulary(terms: ["Claude", "OpenWhisp"],
                   substitutions: [Vocabulary.Substitution(from: "clod code", to: "Claude Code")])
    }

    // MARK: Round-trip

    func testFullRoundTrip() throws {
        let original = ConfigBundle(
            profiles: sampleProfiles(),
            vocabulary: sampleVocab(),
            actions: [VoiceAction(id: "tweet", displayName: "Tweet",
                                  triggerPhrases: ["make a tweet"], prompt: "Make a tweet")],
            prompts: .init(voiceCommandWakeWord: "computer")
        )
        let decoded = try ConfigBundle.decode(from: original.jsonData())
        XCTAssertEqual(decoded, original)
    }

    func testEmptyBundleRoundTrips() throws {
        let original = ConfigBundle()
        let decoded = try ConfigBundle.decode(from: original.jsonData())
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.profiles)
        XCTAssertNil(decoded.vocabulary)
        XCTAssertNil(decoded.prompts)
    }

    func testPartialBundleRoundTrips() throws {
        // A vocab-only "pack" — other sections absent, must stay nil (not empty).
        // Reuse the SAME vocab instance: Substitution ids are random per call, and
        // the round-trip must preserve them.
        let vocab = sampleVocab()
        let original = ConfigBundle(vocabulary: vocab)
        let decoded = try ConfigBundle.decode(from: original.jsonData())
        XCTAssertNil(decoded.profiles)
        XCTAssertNil(decoded.prompts)
        XCTAssertEqual(decoded.vocabulary, vocab)
    }

    func testSchemaVersionDefaultsToCurrent() {
        XCTAssertEqual(ConfigBundle().schemaVersion, ConfigBundle.currentSchemaVersion)
    }

    // MARK: Tolerant decode

    func testDecodesJSONMissingAllOptionalSections() throws {
        let json = Data(#"{"schemaVersion": 1}"#.utf8)
        let bundle = try ConfigBundle.decode(from: json)
        XCTAssertEqual(bundle.schemaVersion, 1)
        XCTAssertNil(bundle.profiles)
        XCTAssertNil(bundle.vocabulary)
    }

    func testDecodeIgnoresUnknownForwardCompatibleKeys() throws {
        // A field a future app added must not break an older importer.
        let json = Data(#"{"schemaVersion": 1, "futureFeature": {"x": 1}, "prompts": {"voiceCommandWakeWord": "computer"}}"#.utf8)
        let bundle = try ConfigBundle.decode(from: json)
        XCTAssertEqual(bundle.prompts?.voiceCommandWakeWord, "computer")
    }

    func testDecodesActions() throws {
        let json = Data(#"{"schemaVersion": 1, "actions": [{"id":"tweet","displayName":"Tweet","triggerPhrases":["make a tweet"],"prompt":"p"}]}"#.utf8)
        let bundle = try ConfigBundle.decode(from: json)
        XCTAssertEqual(bundle.actions?.count, 1)
        XCTAssertEqual(bundle.actions?.first?.id, "tweet")
    }

    // MARK: Version guard

    func testRejectsNewerSchemaVersion() {
        let json = Data(#"{"schemaVersion": 999}"#.utf8)
        XCTAssertThrowsError(try ConfigBundle.decode(from: json)) { error in
            XCTAssertEqual(error as? ConfigBundle.DecodeError,
                           .unsupportedVersion(found: 999, supported: ConfigBundle.currentSchemaVersion))
        }
    }

    func testAcceptsOlderSchemaVersion() throws {
        let json = Data(#"{"schemaVersion": 0, "prompts": {"voiceCommandWakeWord": "hey"}}"#.utf8)
        let bundle = try ConfigBundle.decode(from: json)
        XCTAssertEqual(bundle.prompts?.voiceCommandWakeWord, "hey")
    }

    // MARK: Malformed

    func testMalformedJSONThrowsMalformed() {
        let json = Data("not json at all".utf8)
        XCTAssertThrowsError(try ConfigBundle.decode(from: json)) { error in
            guard case ConfigBundle.DecodeError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    // MARK: Summary

    private func sampleActions(_ n: Int) -> [VoiceAction] {
        (0..<n).map { VoiceAction(id: "a\($0)", displayName: "a", triggerPhrases: ["p\($0)"], prompt: "x") }
    }

    func testSummaryListsNonEmptySections() {
        let bundle = ConfigBundle(
            profiles: sampleProfiles(),                              // 2 profiles
            vocabulary: sampleVocab(),                              // 2 terms, 1 sub
            actions: sampleActions(2),                              // 2 voice actions
            prompts: .init(voiceCommandWakeWord: "y")              // wake word
        )
        XCTAssertEqual(bundle.summary, "2 app profiles, 2 vocab terms, 1 substitution, 2 voice actions, wake word")
    }

    func testSummarySingularGrammar() {
        let bundle = ConfigBundle(
            profiles: [sampleProfiles()[0]],
            vocabulary: Vocabulary(terms: ["one"],
                                   substitutions: [Vocabulary.Substitution(from: "a", to: "b")]),
            actions: sampleActions(1),
            prompts: .init(voiceCommandWakeWord: nil)
        )
        XCTAssertEqual(bundle.summary, "1 app profile, 1 vocab term, 1 substitution, 1 voice action")
    }

    func testSummaryOmitsEmptyAndWhitespaceSections() {
        // Empty profiles list, empty vocab, empty actions, blank wake word -> "nothing".
        let bundle = ConfigBundle(
            profiles: [],
            vocabulary: .empty,
            actions: [],
            prompts: .init(voiceCommandWakeWord: "")
        )
        XCTAssertEqual(bundle.summary, "nothing")
    }

    func testSummaryOfEmptyBundle() {
        XCTAssertEqual(ConfigBundle().summary, "nothing")
    }
}
