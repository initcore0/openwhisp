import Foundation

/// Pure, Foundation-only guard against learning credential-shaped strings.
///
/// Extracted from `ScreenContextHarvester.score` (MAK-34's screen-context bias
/// harvester), which already refused to echo API-key / session-token / hash
/// shapes into the whisper prompt. The self-learning dictionary (MAK-86) needs
/// the SAME refusal: a captured "correction" whose text looks like a secret must
/// never be folded into `vocabulary.json` (which is inserted into transcripts,
/// saved to history, and synced to the iOS companion). Shared here so both
/// call sites apply one, tested definition of "looks like a secret".
///
/// The check is deliberately blunt and FAIL-SAFE toward privacy: a false
/// positive costs one missed vocabulary term; a false negative could launder a
/// live credential into a synced JSON file. When in doubt, treat it as a secret.
enum SecretTokenGuard {

    /// True when `token` (a single whitespace-delimited word) has the shape of an
    /// API key / session token / hash rather than dictation-worthy vocabulary.
    ///
    /// The heuristic mirrors the original screen-context guard: a long token
    /// (16+ chars) that mixes digits with letters is suspicious, and is rejected
    /// when it either mixes upper AND lower case (base64/JWT-ish) or is
    /// digit-heavy (>=25% digits — hashes / numeric ids). A recognizable
    /// secret PREFIX (`sk-`, `ghp_`, `AKIA…`, PEM `-----BEGIN`) trips it at any
    /// length, since those are unambiguous credential markers.
    static func looksLikeSecret(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }

        // Unambiguous credential markers — trip at any length.
        if t.contains("-----BEGIN") { return true }
        let lower = t.lowercased()
        for prefix in secretPrefixes where lower.hasPrefix(prefix) {
            return true
        }

        let count = t.count
        guard count >= 16 else { return false }

        let hasDigit = t.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        guard hasDigit else { return false }

        let hasUpper = t.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }
        let hasLower = t.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        let digitCount = t.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let digitHeavy = Double(digitCount) / Double(count) >= 0.25

        return (hasUpper && hasLower) || digitHeavy
    }

    /// True when ANY whitespace-delimited token of `phrase` looks like a secret.
    /// Used by the multi-word correction path, where the captured text can span
    /// several tokens and any one of them being credential-shaped disqualifies
    /// the whole phrase from being learned.
    static func containsSecret(_ phrase: String) -> Bool {
        phrase.split(whereSeparator: { $0.isWhitespace })
            .contains { looksLikeSecret(String($0)) }
    }

    /// Well-known credential prefixes (lowercased). Not exhaustive — the
    /// length/shape rule catches the general case; these catch short-but-obvious
    /// markers the shape rule would miss.
    private static let secretPrefixes: [String] = [
        "sk-",      // OpenAI / Anthropic-style secret keys
        "sk_live_", "sk_test_",  // Stripe
        "ghp_", "gho_", "ghs_", "github_pat_",  // GitHub tokens
        "xoxb-", "xoxp-", "xapp-",  // Slack
        "akia",     // AWS access key id
        "aiza",     // Google API key
    ]
}
