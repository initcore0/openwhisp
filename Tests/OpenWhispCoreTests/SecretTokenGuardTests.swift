import XCTest
@testable import OpenWhispCore

/// The shared "does this token look like a credential" guard (MAK-86), extracted
/// from the screen-context harvester so the self-learning dictionary applies the
/// identical refusal before learning a term.
final class SecretTokenGuardTests: XCTestCase {

    // MARK: - Ordinary vocabulary is NOT a secret

    func testPlainWordsAreNotSecret() {
        XCTAssertFalse(SecretTokenGuard.looksLikeSecret("Parakeet"))
        XCTAssertFalse(SecretTokenGuard.looksLikeSecret("kubernetes"))
        XCTAssertFalse(SecretTokenGuard.looksLikeSecret("OpenWhisp"))
        XCTAssertFalse(SecretTokenGuard.looksLikeSecret("Anthropic"))
    }

    func testShortMixedTokenIsNotSecret() {
        // Under the 16-char length floor: version-ish identifiers stay learnable.
        XCTAssertFalse(SecretTokenGuard.looksLikeSecret("OAuth2"))
        XCTAssertFalse(SecretTokenGuard.looksLikeSecret("s3bucket"))
    }

    // MARK: - Credential shapes ARE secret

    func testLongMixedCaseDigitTokenIsSecret() {
        // 16+ chars, digits, both cases → base64/JWT-ish key material.
        XCTAssertTrue(SecretTokenGuard.looksLikeSecret("aB3kZ9qLmN2pQ7rS4tV"))
    }

    func testDigitHeavyLongTokenIsSecret() {
        // 16+ chars, >=25% digits → hash / numeric id.
        XCTAssertTrue(SecretTokenGuard.looksLikeSecret("user1029384756token"))
    }

    func testKnownPrefixesTripAtAnyLength() {
        XCTAssertTrue(SecretTokenGuard.looksLikeSecret("sk-abc123"))
        XCTAssertTrue(SecretTokenGuard.looksLikeSecret("ghp_shortish"))
        XCTAssertTrue(SecretTokenGuard.looksLikeSecret("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(SecretTokenGuard.looksLikeSecret("xoxb-11111"))
    }

    func testPemMarkerIsSecret() {
        XCTAssertTrue(SecretTokenGuard.looksLikeSecret("-----BEGIN"))
    }

    // MARK: - Phrase-level scan

    func testContainsSecretDetectsAnyToken() {
        XCTAssertTrue(SecretTokenGuard.containsSecret("my key is sk-abc123def"))
        XCTAssertFalse(SecretTokenGuard.containsSecret("open whisper is great"))
    }
}
