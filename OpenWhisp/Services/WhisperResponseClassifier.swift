import Foundation

// MARK: - Whisper server response classifier

/// Pure, dependency-free classification of a `whisper-server` `/inference`
/// response into one of three outcomes: a real transcript, a **clean empty**
/// (the server ran fine but heard no speech), or a genuine **error**.
///
/// ## Why this exists (MAK-23)
///
/// The two whisper backends used to disagree about silence. The `whisper-cli`
/// path treats an empty transcript as a clean no-op (delivers `""` via
/// `onTranscriptionComplete`), but the warm `whisper-server` (HTTP) path raised
/// `WhisperWorkerError.emptyTranscript` on the same input — so dictating silence
/// produced an error toast on one backend and quiet nothing on the other,
/// depending purely on the Advanced → backend setting.
///
/// The chosen fix is the CLI's UX everywhere: "no speech detected" is a clean
/// empty on BOTH paths. The subtlety is distinguishing *that* from a genuine
/// failure — a network error, a non-200, or a body that doesn't parse — which
/// must still surface as an error. That distinction is pure logic over
/// `(statusCode, body)`, so it lives here and the server path routes through it,
/// making it the reliably-testable core (`WhisperResponseClassifier` in
/// `OpenWhispCore`).
///
/// Transport-level failures (URLSession error, no `HTTPURLResponse`) are handled
/// by the caller *before* this point — this classifier only speaks to the case
/// where the server actually answered with a status and a body.
enum WhisperResponseClassifier {

    /// The classification of a server response.
    enum Outcome: Equatable {
        /// A real, non-empty transcript. The associated value is the trimmed
        /// text (leading/trailing whitespace and newlines removed).
        case transcript(String)
        /// The server ran successfully (HTTP 200, parseable body) but produced
        /// no speech — an empty or whitespace-only transcript. This is a clean
        /// no-op, delivered as `onTranscriptionComplete(requestID, "")`, NOT an
        /// error. Mirrors the CLI path's "quietly nothing".
        case cleanEmpty
        /// A genuine failure: a non-200 status, or a 200 whose body could not be
        /// parsed as the expected JSON shape. `message` is a short, log-safe
        /// reason (never the raw transcript). Surfaced via `onTranscriptionError`.
        case error(message: String)
    }

    /// Classify a server `/inference` response given its HTTP `statusCode` and
    /// raw `body`.
    ///
    /// Decision order:
    /// 1. **Non-200** ⇒ `.error` — a real server failure. The message is the
    ///    body decoded as UTF-8 (or `"HTTP <status>"`), matching the prior
    ///    `serverError` behavior. Not treated as empty even if the body is blank.
    /// 2. **200 but the body isn't the expected `{ "text": ... }` JSON** ⇒
    ///    `.error` — malformed/unexpected payload is a failure, not silence. An
    ///    empty body (0 bytes) also lands here: a 200 with nothing to decode is
    ///    malformed, distinct from a 200 whose JSON `text` is empty.
    /// 3. **200, parseable, `text` empty or whitespace-only (or JSON `null`)** ⇒
    ///    `.cleanEmpty` — the server heard no speech. THIS is the MAK-23 fix.
    /// 4. **200, parseable, non-empty `text`** ⇒ `.transcript(trimmed)`.
    static func classify(statusCode: Int, body: Data) -> Outcome {
        // 1. Non-200 → genuine server error (unchanged from prior behavior).
        guard statusCode == 200 else {
            let message = String(data: body, encoding: .utf8)
                .flatMap { $0.isEmpty ? nil : $0 } ?? "HTTP \(statusCode)"
            return .error(message: message)
        }

        // 2. 200 but the body doesn't decode to the expected shape → malformed
        //    payload is a failure, not silence. (An empty 0-byte body fails to
        //    decode and lands here too.)
        struct InferenceResponse: Decodable {
            let text: String?
        }
        guard let decoded = try? JSONDecoder().decode(InferenceResponse.self, from: body) else {
            return .error(message: "Malformed whisper-server response (HTTP 200, \(body.count) bytes)")
        }

        // 3 & 4. A parseable 200: empty/whitespace-only (or null) text is the
        //        clean-empty "no speech" case; anything else is a transcript.
        let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? .cleanEmpty : .transcript(text)
    }

    /// Reduce a **CLI** (`whisper-cli`) run into the SAME `Outcome` the server
    /// path routes through (MAK-85). This is the CLI half of the silence
    /// contract: a clean exit whose trimmed stdout is empty is `.cleanEmpty` (the
    /// "no speech detected" no-op), a clean exit with text is a `.transcript`,
    /// and a non-zero exit is an `.error`.
    ///
    /// Sharing this reduction is what keeps the two backends from ever disagreeing
    /// about silence again: the original PR #83 bug (the server path errored on an
    /// empty transcript while the CLI path silently no-op'd) can't drift back,
    /// because BOTH paths now collapse silence to `.cleanEmpty` through one
    /// unit-tested function. It also trims identically to the server path.
    ///
    /// - Parameters:
    ///   - exitCode: the child's termination status (0 == success).
    ///   - stdout: the raw child stdout (untrimmed); this method does the trim.
    ///   - stderr: child stderr, folded into the error message ONLY (never the
    ///     success path).
    static func classifyCLI(exitCode: Int32, stdout: Data, stderr: String) -> Outcome {
        guard exitCode == 0 else {
            let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmedErr.isEmpty ? "" : ": \(trimmedErr)"
            return .error(message: "whisper exited with code \(exitCode)\(detail)")
        }
        let text = (String(data: stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .cleanEmpty : .transcript(text)
    }
}
