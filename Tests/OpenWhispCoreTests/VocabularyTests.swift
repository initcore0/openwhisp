import XCTest
@testable import OpenWhispCore

final class VocabularyTests: XCTestCase {
    private func sub(_ from: String, _ to: String) -> Vocabulary.Substitution {
        Vocabulary.Substitution(from: from, to: to)
    }

    func testMultiwordPhrase() {
        let s = VocabularySubstitutor(substitutions: [sub("clod code", "Claude Code")])
        XCTAssertEqual(s.apply(to: "i use clod code daily"), "i use Claude Code daily")
    }

    func testCaseInsensitive() {
        let s = VocabularySubstitutor(substitutions: [sub("clod code", "Claude Code")])
        XCTAssertEqual(s.apply(to: "Clod Code rocks"), "Claude Code rocks")
    }

    func testWordBoundaryNoSubstring() {
        // "cat" must not match inside "category"/"catalog".
        let s = VocabularySubstitutor(substitutions: [sub("cat", "dog")])
        XCTAssertEqual(s.apply(to: "category catalog cat"), "category catalog dog")
    }

    func testPunctuationEdgedFromMatches() {
        // \b inverts at non-word edges, so "C++"/".net"/"@here"-style entries
        // would silently never fire; the lookaround boundaries must match them.
        let s = VocabularySubstitutor(substitutions: [sub("c++", "C++")])
        XCTAssertEqual(s.apply(to: "i like c++ a lot"), "i like C++ a lot")

        let dot = VocabularySubstitutor(substitutions: [sub(".net", ".NET")])
        XCTAssertEqual(dot.apply(to: "use .net here"), "use .NET here")

        let at = VocabularySubstitutor(substitutions: [sub("@here", "@channel")])
        XCTAssertEqual(at.apply(to: "ping @here now"), "ping @channel now")
    }

    func testPunctuationEdgedFromStillNotGluedToWordChars() {
        // The relaxed boundary must not rewrite a phrase glued to a word char.
        let s = VocabularySubstitutor(substitutions: [sub("c++", "C++")])
        XCTAssertEqual(s.apply(to: "typedef c++x thing"), "typedef c++x thing")
    }

    func testReplacementWithDollarIsLiteral() {
        // Replacement must not be interpreted as a regex template ($5 -> literal).
        let s = VocabularySubstitutor(substitutions: [sub("dollars", "$5")])
        XCTAssertEqual(s.apply(to: "five dollars please"), "five $5 please")
    }

    func testEmptyFromSkipped() {
        let s = VocabularySubstitutor(substitutions: [sub("   ", "x")])
        XCTAssertEqual(s.apply(to: "leave me alone"), "leave me alone")
    }

    func testWhisperPromptJoinsTerms() {
        let v = Vocabulary(terms: ["Claude", " Anthropic ", ""], substitutions: [])
        XCTAssertEqual(v.whisperPrompt, "Claude, Anthropic")
    }

    // MARK: - Priority (star) + usage-frequency model (MAK-41)

    func testNewFieldsDefaultToUnstarredZeroUsage() {
        let s = sub("a", "b")
        XCTAssertFalse(s.starred)
        XCTAssertEqual(s.usageCount, 0)
    }

    func testCodableRoundTripWithNewFields() throws {
        let original = Vocabulary(terms: ["x"], substitutions: [
            Vocabulary.Substitution(from: "clod", to: "Claude", starred: true, usageCount: 7)
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Vocabulary.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.substitutions[0].starred)
        XCTAssertEqual(decoded.substitutions[0].usageCount, 7)
    }

    func testBackwardCompatDecodeOfOldSubstitutionJSON() throws {
        // An OLD stored file: substitution objects have only id/from/to — no
        // `starred` or `usageCount`. Must still decode with the defaults.
        let json = """
        {"terms":["Claude"],"substitutions":[
          {"id":"00000000-0000-0000-0000-000000000001","from":"clod","to":"Claude"}
        ]}
        """
        let decoded = try JSONDecoder().decode(Vocabulary.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.substitutions.count, 1)
        let s = decoded.substitutions[0]
        XCTAssertEqual(s.from, "clod")
        XCTAssertEqual(s.to, "Claude")
        XCTAssertFalse(s.starred)
        XCTAssertEqual(s.usageCount, 0)
    }

    func testBackwardCompatDecodeWithoutIdSynthesizesOne() throws {
        // Defensive: a hand-edited file omitting `id` should not fail the load.
        let json = """
        {"terms":[],"substitutions":[{"from":"clod","to":"Claude"}]}
        """
        let decoded = try JSONDecoder().decode(Vocabulary.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.substitutions.count, 1)
        XCTAssertEqual(decoded.substitutions[0].to, "Claude")
    }

    func testSortByFrequencyStarredFirstThenUsage() {
        let a = Vocabulary.Substitution(from: "alpha", to: "A", starred: false, usageCount: 2)
        let b = Vocabulary.Substitution(from: "bravo", to: "B", starred: false, usageCount: 9)
        let c = Vocabulary.Substitution(from: "charlie", to: "C", starred: true, usageCount: 0)
        let v = Vocabulary(terms: [], substitutions: [a, b, c])
        let ordered = v.substitutionsByFrequency()
        // Starred floats to the top regardless of usage; then by descending usage.
        XCTAssertEqual(ordered.map(\.from), ["charlie", "bravo", "alpha"])
    }

    func testSortByFrequencyStableFromTiebreak() {
        let a = Vocabulary.Substitution(from: "zulu", to: "Z", usageCount: 3)
        let b = Vocabulary.Substitution(from: "alpha", to: "A", usageCount: 3)
        let v = Vocabulary(terms: [], substitutions: [a, b])
        // Equal usage, neither starred → alphabetical by `from`.
        XCTAssertEqual(v.substitutionsByFrequency().map(\.from), ["alpha", "zulu"])
    }

    func testIncrementUsageBumpsMatchingSubstitution() {
        let a = Vocabulary.Substitution(from: "clod", to: "Claude", usageCount: 0)
        let b = Vocabulary.Substitution(from: "kube", to: "kubectl", usageCount: 5)
        let v = Vocabulary(terms: [], substitutions: [a, b])
        let bumped = v.incrementingUsage(of: a.id)
        XCTAssertEqual(bumped.substitutions[0].usageCount, 1)
        XCTAssertEqual(bumped.substitutions[1].usageCount, 5) // untouched
        // Original unchanged (value semantics).
        XCTAssertEqual(v.substitutions[0].usageCount, 0)
    }

    func testIncrementUsageUnknownIdIsNoOp() {
        let a = Vocabulary.Substitution(from: "clod", to: "Claude", usageCount: 2)
        let v = Vocabulary(terms: [], substitutions: [a])
        let same = v.incrementingUsage(of: UUID())
        XCTAssertEqual(same, v)
    }

    // MARK: - Part A: usageCount bumps when a rule fires against a transcript

    func testFiredSubstitutionIDsReportsMatchingRules() {
        let a = sub("clod code", "Claude Code")
        let b = sub("kube", "kubectl")
        let c = sub("nomatch", "x")
        let s = VocabularySubstitutor(substitutions: [a, b, c])
        let fired = s.firedSubstitutionIDs(in: "i use clod code with kube daily")
        XCTAssertEqual(fired, [a.id, b.id])   // c never appears in the text
    }

    func testFiredSubstitutionIDsIsCaseInsensitiveAndWholePhrase() {
        let a = sub("cat", "dog")
        let s = VocabularySubstitutor(substitutions: [a])
        // Whole-word, case-insensitive: "category" must NOT count "cat" as fired.
        XCTAssertTrue(s.firedSubstitutionIDs(in: "my CAT sat").contains(a.id))
        XCTAssertFalse(s.firedSubstitutionIDs(in: "the category list").contains(a.id))
    }

    func testFiredSubstitutionIDsSkipsBlankFrom() {
        let blank = sub("   ", "x")
        let s = VocabularySubstitutor(substitutions: [blank])
        XCTAssertTrue(s.firedSubstitutionIDs(in: "anything at all").isEmpty)
    }

    func testFiredMatchesApplyExactly() {
        // A rule fires iff apply() rewrites — the two must never disagree.
        let a = sub("c++", "C++")           // punctuation-edged
        let b = sub("dollars", "$5")
        let s = VocabularySubstitutor(substitutions: [a, b])
        let text = "i like c++ and five dollars"
        let fired = s.firedSubstitutionIDs(in: text)
        let changed = s.apply(to: text) != text
        XCTAssertEqual(fired, [a.id, b.id])
        XCTAssertTrue(changed)
    }

    func testUsageBumpForFiredRulesCountsEachRuleOnce() {
        // The pipeline flow: figure out which rules fired, then bump each once even
        // if the rule matched multiple words in the same transcript.
        let a = Vocabulary.Substitution(from: "clod", to: "Claude", usageCount: 0)
        let b = Vocabulary.Substitution(from: "kube", to: "kubectl", usageCount: 3)
        let v = Vocabulary(terms: [], substitutions: [a, b])
        let transcript = "clod told clod to run kube"   // "clod" appears twice
        let fired = VocabularySubstitutor(substitutions: v.substitutions)
            .firedSubstitutionIDs(in: transcript)
        let bumped = v.incrementingUsage(of: fired)
        XCTAssertEqual(bumped.substitutions[0].usageCount, 1)   // clod: counted ONCE
        XCTAssertEqual(bumped.substitutions[1].usageCount, 4)   // kube: 3 -> 4
    }

    func testUsageBumpNoOpWhenNothingFires() {
        let a = Vocabulary.Substitution(from: "clod", to: "Claude", usageCount: 5)
        let v = Vocabulary(terms: [], substitutions: [a])
        let fired = VocabularySubstitutor(substitutions: v.substitutions)
            .firedSubstitutionIDs(in: "nothing to replace here")
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(v.incrementingUsage(of: fired), v)   // unchanged
    }

    // MARK: - Pre-translation substitution pass (MAK-95)

    private func cleaner(substitutions: [Vocabulary.Substitution], enabled: Bool = true) -> TranscriptCleaner {
        TranscriptCleaner(config: .init(
            language: "en",
            customVocabularyEnabled: enabled,
            substitutions: substitutions,
            smartFormattingEnabled: false,
            fillerRemovalEnabled: false,
            spokenPunctuationEnabled: false,
            normalizeNumbers: false,
            normalizeCurrency: false,
            spokenListsEnabled: false,
            basicMarkdownEnabled: false,
            fileTaggingEnabled: false))
    }

    /// THE translate-session bug: substitutions key on the SPOKEN language, so
    /// the pre-translation pass must rewrite the raw (e.g. Cyrillic) transcript
    /// — after translation the mishearing is gone and the rule can never fire.
    func testPreTranslationPassSubstitutesSourceLanguageMishearing() {
        let c = cleaner(substitutions: [
            .init(from: "пара кит", to: "parakeet"),
        ])
        XCTAssertEqual(
            c.substitutionsApplied(toRawTranscript: "мой любимый пара кит поёт"),
            "мой любимый parakeet поёт")
    }

    /// ONLY substitutions run pre-translation — formatting rules target the
    /// OUTPUT language and must not touch the source text.
    func testPreTranslationPassAppliesNothingButSubstitutions() {
        let c = cleaner(substitutions: [])
        XCTAssertEqual(
            c.substitutionsApplied(toRawTranscript: "ну эм пара кит"),
            "ну эм пара кит", "no rules → text passes through untouched")
    }

    func testPreTranslationPassRespectsVocabularyToggle() {
        let c = cleaner(
            substitutions: [.init(from: "пара кит", to: "parakeet")],
            enabled: false)
        XCTAssertEqual(
            c.substitutionsApplied(toRawTranscript: "пара кит"),
            "пара кит", "vocabulary off → substitutions must not run")
    }

    /// The pre-translation pass and `firedSubstitutionIDs` see the same
    /// normalized text — a rule that rewrote the transcript is always counted.
    func testPreTranslationPassAgreesWithFiredIDs() {
        let sub = Vocabulary.Substitution(from: "пара кит", to: "parakeet")
        let c = cleaner(substitutions: [sub])
        let raw = "  пара   кит  "   // messy whitespace — normalization shared
        XCTAssertEqual(c.substitutionsApplied(toRawTranscript: raw), "parakeet")
        XCTAssertEqual(c.firedSubstitutionIDs(inRawTranscript: raw), [sub.id])
    }
}
