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
}
