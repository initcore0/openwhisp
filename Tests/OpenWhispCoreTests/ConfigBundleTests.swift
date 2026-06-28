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
            vocabulary: sampleVocab()
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
    }

    func testPartialBundleRoundTrips() throws {
        // A vocab-only "pack" — other sections absent, must stay nil (not empty).
        // Reuse the SAME vocab instance: Substitution ids are random per call, and
        // the round-trip must preserve them.
        let vocab = sampleVocab()
        let original = ConfigBundle(vocabulary: vocab)
        let decoded = try ConfigBundle.decode(from: original.jsonData())
        XCTAssertNil(decoded.profiles)
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
        // A field a future app added — or a legacy section we removed (actions,
        // prompts) — must not break the importer; unknown keys are ignored.
        let json = Data(#"{"schemaVersion": 1, "futureFeature": {"x": 1}, "actions": [{"id":"tweet"}], "prompts": {"voiceCommandWakeWord": "computer"}, "vocabulary": {"terms": ["Claude"], "substitutions": []}}"#.utf8)
        let bundle = try ConfigBundle.decode(from: json)
        XCTAssertEqual(bundle.vocabulary?.terms, ["Claude"])
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
        let json = Data(#"{"schemaVersion": 0, "vocabulary": {"terms": ["hey"], "substitutions": []}}"#.utf8)
        let bundle = try ConfigBundle.decode(from: json)
        XCTAssertEqual(bundle.vocabulary?.terms, ["hey"])
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

    func testSummaryListsNonEmptySections() {
        let bundle = ConfigBundle(
            profiles: sampleProfiles(),                              // 2 profiles
            vocabulary: sampleVocab()                               // 2 terms, 1 sub
        )
        XCTAssertEqual(bundle.summary, "2 app profiles, 2 vocab terms, 1 substitution")
    }

    func testSummarySingularGrammar() {
        let bundle = ConfigBundle(
            profiles: [sampleProfiles()[0]],
            vocabulary: Vocabulary(terms: ["one"],
                                   substitutions: [Vocabulary.Substitution(from: "a", to: "b")])
        )
        XCTAssertEqual(bundle.summary, "1 app profile, 1 vocab term, 1 substitution")
    }

    func testSummaryOmitsEmptyAndWhitespaceSections() {
        let bundle = ConfigBundle(profiles: [], vocabulary: .empty)
        XCTAssertEqual(bundle.summary, "nothing")
    }

    func testSummaryOfEmptyBundle() {
        XCTAssertEqual(ConfigBundle().summary, "nothing")
    }
}
