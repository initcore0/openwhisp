import Foundation

/// Developer breadcrumbs for the meme generate path.
///
/// ## Why this exists — reading the wiring failed twice
///
/// Two rounds of the "four items render as two captions" report were diagnosed by
/// TRACING THE WIRING BY EYE, concluded correct, and shipped — and the owner then ran
/// a hash-verified binary with the exact repro prompt and still got two boxes. A
/// static read of the same code keeps saying the same thing; what was missing was
/// evidence from the RUNNING APP about which branch actually executed.
///
/// So the decision points can emit a line each. The rule this encodes: when a
/// user-visible outcome contradicts what the code appears to say, the next move is a
/// breadcrumb, not another read.
///
/// ## Two gates, and why the split is where it is
///
/// **Emission is compiled out of consumer builds.** `log` is a no-op unless the binary
/// was built with `INSTRUMENTATION=1` (`OPENWHISP_INSTRUMENTATION`), matching every
/// other developer-only surface in this app (`Instrumentation`, `LLMBenchRunner`,
/// `LLMLabView`). A release build therefore carries no `NSLog` on the generate path at
/// all — not a disabled one, an absent one. `OPENWHISP_MEME_TRACE=1` then arms it at
/// runtime, so even an instrumented build is quiet until asked.
///
/// **The LINE BUILDERS below are always compiled**, because they are pure functions
/// that `swift test` asserts on, and the core test target has no instrumentation
/// define. Gating them too would delete their coverage — and a trace that silently
/// stopped describing the code is worse than no trace, since the next debugging round
/// would trust it. Only the side effect is conditional; the formatting is not.
///
/// Lines go to `NSLog`, so they land in unified logging AND on stderr — the app is
/// launched by `open`, whose stderr is redirected to a file by the runtime harnesses
/// in `scripts/meme-runtime-proof.sh` and `scripts/meme-voice-command-proof.sh`. That
/// belt-and-braces matters because this app's NSLog output has historically not been
/// reliably visible to `log stream`.
public enum MemeTrace {

    /// Whether breadcrumbs are emitted.
    ///
    /// False in every consumer build regardless of the environment: without
    /// `OPENWHISP_INSTRUMENTATION` there is no code behind this to enable. In an
    /// instrumented build it still defaults off, and the harness (or a curious owner)
    /// turns it on with `OPENWHISP_MEME_TRACE=1`.
    ///
    /// Read once — an env var cannot change under a running process, and re-reading it
    /// per line would put a `getenv` in the middle of the render loop.
    public static let isEnabled: Bool = {
        #if OPENWHISP_INSTRUMENTATION
        let raw = ProcessInfo.processInfo.environment["OPENWHISP_MEME_TRACE"]
        return raw == "1" || raw == "true" || raw == "YES"
        #else
        return false
        #endif
    }()

    /// Emit one breadcrumb, prefixed so `grep '\[MemeGen\]'` finds the whole trace.
    ///
    /// The message is an `@autoclosure`, so in a consumer build the argument is never
    /// even evaluated — a caller passing `MemeTrace.seedLine(…)` pays nothing for the
    /// string it would have built.
    public static func log(_ message: @autoclosure () -> String) {
        #if OPENWHISP_INSTRUMENTATION
        guard isEnabled else { return }
        NSLog("[MemeGen] %@", message())
        #endif
    }

    /// The breadcrumb for a resolved seeding decision.
    ///
    /// Built as a pure function — and deliberately NOT compiled out — so `swift test`
    /// can assert the LINE ITSELF, not just the decision behind it.
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
