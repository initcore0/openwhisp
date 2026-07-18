import XCTest
@testable import OpenWhispCore

/// MAK-75: deriving session-scoped bias terms from an agent's workspace context
/// (cwd basename, git branch, file names), capping, and merging with the user's
/// vocabulary WITHOUT persisting. Covers the pure derivation/merge logic; the
/// end-to-end request path (BridgeRouter -> dictate -> engine start) is exercised
/// in FeatureMatrixE2ETests.
final class AgentContextVocabularyTests: XCTestCase {

    // MARK: - Derivation

    func testDerivesProjectNameFromCwdPath() {
        let terms = AgentContextVocabulary.derivedTerms(
            cwd: "/Users/me/projects/mnaboka/OpenWhisp")
        // The distinctive (capitalized/identifier-shaped) path components survive;
        // plain-lowercase generic dirs ("me", "projects", "mnaboka") are dropped by
        // the shared harvester's scorer (a proper-noun/identifier signal is
        // required to earn a bias slot).
        XCTAssertTrue(terms.contains("OpenWhisp"), "expected project name, got \(terms)")
        XCTAssertFalse(terms.contains("me"), "'me' is too short/generic to bias")
        XCTAssertFalse(terms.contains("projects"), "plain lowercase word is not bias-worthy")
    }

    func testSplitsBranchIntoSpeakableTerms() {
        let terms = AgentContextVocabulary.derivedTerms(
            gitBranch: "maksymnaboka/mak-75-agent-context-vocabulary")
        // Kebab/slash compound identifiers survive as whole tokens (the harvester
        // keeps `-`/`.`/`_` joiners), so the branch is biasable.
        XCTAssertTrue(
            terms.contains("mak-75-agent-context-vocabulary"),
            "expected the kebab branch token, got \(terms)")
    }

    func testDerivesFileNameIdentifiers() {
        let terms = AgentContextVocabulary.derivedTerms(
            terms: ["AppState.swift", "RefineFlow", "handleWebhookRequest"])
        XCTAssertTrue(terms.contains("AppState.swift"))
        XCTAssertTrue(terms.contains("RefineFlow"))
        XCTAssertTrue(terms.contains("handleWebhookRequest"))
    }

    func testEmptyContextYieldsNoTerms() {
        XCTAssertTrue(AgentContextVocabulary.derivedTerms().isEmpty)
        XCTAssertTrue(AgentContextVocabulary.derivedTerms(cwd: "", gitBranch: "", terms: []).isEmpty)
    }

    func testExcludesTermsAlreadyInUserVocabulary() {
        let terms = AgentContextVocabulary.derivedTerms(
            cwd: "/Users/me/projects/OpenWhisp",
            existingTerms: ["OpenWhisp"])
        XCTAssertFalse(
            terms.contains(where: { $0.caseInsensitiveCompare("OpenWhisp") == .orderedSame }),
            "a term already in the user's vocabulary must not be re-derived; got \(terms)")
    }

    func testSecretGuardRejectsApiKeyShapedTokens() {
        // A branch/path carrying an API-key-shaped token must NOT become a bias
        // term (a whisper prompt can echo its tokens into the inserted transcript).
        let terms = AgentContextVocabulary.derivedTerms(
            gitBranch: "tmp/sk-Ab12Cd34Ef56Gh78Ij90Kl",
            terms: ["AKIA1234567890ABCDEF"])
        XCTAssertFalse(
            terms.contains(where: { $0.contains("sk-Ab12") || $0.hasPrefix("AKIA") }),
            "secret-shaped tokens must be rejected; got \(terms)")
    }

    // MARK: - Capping

    // Distinct short PascalCase identifiers (letter-only, under the harvester's
    // 16-char secret-guard threshold) so each one is a genuine bias term.
    private func manyIdentifiers(_ n: Int) -> [String] {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return (0..<n).map { i -> String in
            let a = letters[i / 26 % 26], b = letters[i % 26]
            return "Widget\(String(a).uppercased())\(b)"   // e.g. "WidgetAa"
        }
    }

    func testCapsDerivedTermCount() {
        let terms = AgentContextVocabulary.derivedTerms(terms: manyIdentifiers(100), limit: 5)
        XCTAssertEqual(terms.count, 5)
    }

    func testDefaultCapIsMaxDerivedTerms() {
        let terms = AgentContextVocabulary.derivedTerms(terms: manyIdentifiers(100))
        XCTAssertEqual(terms.count, AgentContextVocabulary.maxDerivedTerms)
    }

    func testZeroLimitYieldsNothing() {
        XCTAssertTrue(AgentContextVocabulary.derivedTerms(cwd: "/x/OpenWhisp", limit: 0).isEmpty)
    }

    // MARK: - Merge (session-scoped; never persists)

    func testMergeKeepsUserTermsFirstThenAgentTerms() {
        let merged = AgentContextVocabulary.merged(
            base: ["Claude", "Anthropic"], with: ["OpenWhisp", "kubectl"])
        XCTAssertEqual(merged, ["Claude", "Anthropic", "OpenWhisp", "kubectl"])
    }

    func testMergeDropsCaseInsensitiveDuplicates() {
        let merged = AgentContextVocabulary.merged(
            base: ["OpenWhisp"], with: ["openwhisp", "Parakeet"])
        XCTAssertEqual(merged, ["OpenWhisp", "Parakeet"], "duplicate agent term dropped")
    }

    func testMergeTrimsAndDropsBlanks() {
        let merged = AgentContextVocabulary.merged(
            base: ["  Claude  ", ""], with: ["  ", "OpenWhisp"])
        XCTAssertEqual(merged, ["Claude", "OpenWhisp"])
    }

    // MARK: - Correction-context block

    func testCorrectionBlockListsTermsAndIsReferenceOnly() {
        let block = AgentContextVocabulary.correctionContextBlock(
            terms: ["OpenWhisp", "mak-75"])
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("OpenWhisp"))
        XCTAssertTrue(block!.contains("mak-75"))
        XCTAssertTrue(block!.lowercased().contains("reference only"),
                      "the block must frame itself as reference-only")
    }

    func testCorrectionBlockNilForEmptyTerms() {
        XCTAssertNil(AgentContextVocabulary.correctionContextBlock(terms: []))
        XCTAssertNil(AgentContextVocabulary.correctionContextBlock(terms: ["", "  "]))
    }
}
