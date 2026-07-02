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
}
