import Foundation

/// Runtime breadcrumbs for the meme generate path (spike v9).
///
/// ## Why this exists — reading the wiring failed twice
///
/// v7 and v8 both diagnosed the "four items render as two captions" report by TRACING
/// THE WIRING BY EYE, concluded it was correct, and shipped. The owner then ran a
/// hash-verified v8 binary with the exact repro prompt and still got two boxes. A
/// static read of the same code will keep saying the same thing; what was missing was
/// evidence from the RUNNING APP about which branch actually executed.
///
/// So the decision points now emit a line each. The rule this encodes: when a
/// user-visible outcome contradicts what the code appears to say, the next move is a
/// breadcrumb, not another read.
///
/// Lines go to `NSLog`, so they land in unified logging AND on stderr — the app is
/// launched by `open`, whose stderr is redirected to a file by the runtime harness in
/// `scripts/meme-runtime-proof.sh`. That belt-and-braces matters because this app's
/// NSLog output has historically not been reliably visible to `log stream`.
public enum MemeTrace {

    /// Whether breadcrumbs are emitted. Off by default so a normal run is quiet;
    /// the harness (and a curious owner) turns it on with `OPENWHISP_MEME_TRACE=1`.
    ///
    /// Read once — an env var cannot change under a running process, and re-reading it
    /// per line would put a `getenv` in the middle of the render loop.
    public static let isEnabled: Bool = {
        let raw = ProcessInfo.processInfo.environment["OPENWHISP_MEME_TRACE"]
        return raw == "1" || raw == "true" || raw == "YES"
    }()

    /// Emit one breadcrumb, prefixed so `grep '\[MemeGen\]'` finds the whole trace.
    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[MemeGen] %@", message())
    }

    /// The breadcrumb for a resolved seeding decision.
    ///
    /// Built as a pure function so `swift test` can assert the LINE ITSELF, not just
    /// the decision behind it. A trace that silently stopped describing the code would
    /// be worse than no trace: the next debugging round would trust it.
    public static func seedLine(
        description: String, specCaptions: [String], slots: Int?,
        seed: MemeCaptionSeeding.Seed
    ) -> String {
        "resolve(prompt: \(quoted(description)), specCaptions: \(specCaptions.count), "
            + "slots: \(slots.map(String.init) ?? "nil")) -> \(seed.boxes.count) boxes, "
            + "captions: \(seed.captions.count), fromUser: \(seed.captionsCameFromUser), "
            + "refit: \(seed.refit.map { "\($0.from.count)->\($0.slots)" } ?? "none")"
    }

    /// The breadcrumb for the extraction step, before any LLM involvement.
    public static func extractionLine(_ extraction: MemeCaptionExtraction.Extraction?) -> String {
        guard let extraction else { return "extraction fired: 0 items (not list-shaped)" }
        return "extraction fired: \(extraction.captions.count) items, "
            + "theme: \(quoted(extraction.theme))"
    }

    /// The breadcrumb for the parsed LLM answer.
    public static func llmLine(captions: [String], wasLegacyShape: Bool, schema: Bool) -> String {
        "LLM path, schema=\(schema), captions=\(captions.count), legacyShape=\(wasLegacyShape)"
    }

    /// The breadcrumb for what actually reached the canvas.
    public static func seedingLine(boxes: Int, merged: Int) -> String {
        "seeding \(boxes) boxes (canvas now \(merged))"
    }

    /// Truncated + quoted, so a long dictation can't flood the log and an empty string
    /// is visibly empty rather than invisible.
    private static func quoted(_ text: String) -> String {
        let limit = 120
        let clipped = text.count > limit ? String(text.prefix(limit)) + "…" : text
        return "\"\(clipped)\""
    }
}
