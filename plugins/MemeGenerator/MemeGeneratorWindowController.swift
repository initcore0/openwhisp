import AppKit
import SwiftUI

/// The Meme Generator plugin's window.
///
/// Deliberately thin, like `ScratchpadWindowController`: it owns the window's
/// lifecycle, the LLM wiring, and the dictation seam. All state lives in
/// `MemeGeneratorModel`; all rules live in OpenWhispCore (`MemeAI`,
/// `MemeTemplateMatcher`, `MemeCaptionLayout`) where `swift test` covers them.
///
/// A normal titled `NSWindow` rather than a floating panel: this is a workspace you
/// look at, not an always-on-top scratch surface. It still needs to become KEY so
/// dictation can land in it — that is what makes `appendDictationIfKey` fire.
@MainActor
final class MemeGeneratorWindowController: NSWindowController, NSWindowDelegate,
    PluginDictationSink, PluginWindowLifecycle, PluginVoiceCommandSink {

    private let model = MemeGeneratorModel()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = PluginRegistry.memeGenerator.name
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OpenWhispMemeGeneratorWindow")
        window.center()

        self.init(window: window)

        window.contentViewController = NSHostingController(
            rootView: MemeGeneratorView(model: model))
        window.delegate = self
        wireAI()

        // v3: warm the LLM and open the template catalog the moment the window
        // exists, NOT on the first Generate. The owner's report — "first Generate
        // fails: network error and model loading" — was a request hitting a
        // llama-server that hadn't started yet; the request surfaced connection-
        // refused as a network error. Doing this work at open turns that failure
        // into a brief, honest "Preparing model…".
        model.windowDidOpen()
    }

    // MARK: - LLM seam

    /// Wire the plugin's Generate action to the app's configured LLM.
    ///
    /// The same bridge `ScratchpadWindowController.wireAI` uses: both closures are
    /// re-evaluated per call so a mid-session settings change lands, and the model
    /// never sees AppState. Reusing `summarizeResolved` means the plugin inherits its
    /// guarantees for free — busy-reject while dictating, bundled-engine bracketing,
    /// fail-closed on the agent-CLI provider, and exactly-once delivery.
    ///
    /// Note the plugin does NOT get its own model picker: it follows
    /// the Scratchpad's resolution (its override, else the cleanup settings). A real
    /// plugin config surface would put that on the plugin's own defaults keys.
    private func wireAI() {
        model.configureAI(
            call: { instruction, input, resolved, schema in
                try await withCheckedThrowingContinuation { cont in
                    Task { @MainActor in
                        // v7: when the model gives us a schema, ask the endpoint to
                        // CONSTRAIN the response to it. llama-server turns this into a
                        // GBNF grammar, so an off-schema reply becomes unrepresentable
                        // rather than merely rejected downstream.
                        let format = schema.map {
                            ResponseFormat.jsonSchema(name: "meme_response", schema: $0)
                        }
                        AppState.shared.summarizeResolved(
                            text: input, instruction: instruction, resolved: resolved,
                            responseFormat: format
                        ) { result in
                            switch result {
                            case .success(let out): cont.resume(returning: out)
                            case .failure(let err): cont.resume(throwing: err)
                            }
                        }
                    }
                }
            },
            resolveModel: { ScratchpadWindowController.resolvedAIModel() },
            // Start the bundled llama-server WITHOUT running a completion, passing
            // the plugin's RESOLVED provider: the global `warmLlamaServerIfPossible()`
            // only fires when Settings → Cleanup is itself set to the bundled
            // provider, so a plugin resolved to bundled would otherwise never warm.
            // Same MAK-53 split `ensureBundledLLMReady(provider:)` already makes.
            //
            // v4: the completion carries REAL readiness — `ensureRunning` polls
            // llama-server's `/health` and calls back only when it answers. v3
            // discarded that signal and had the plugin sleep a guessed 2.5s instead,
            // which is why the first generates still hit a socket nothing was
            // listening on.
            warm: { resolved, ready in
                AppState.shared.warmLlamaServerIfPossible(
                    provider: resolved.provider, completion: ready)
            })
    }

    // MARK: - Runtime proof hooks (INSTRUMENTATION=1 only)

    #if OPENWHISP_INSTRUMENTATION
    /// Drive the REAL generate path from a launch argument, and log what it produced.
    ///
    /// ## Why a hook rather than another read of the code
    ///
    /// Two rounds each fixed the "four items, two captions" report by tracing the
    /// wiring and declaring it correct. The owner then ran a hash-verified build and
    /// got two boxes anyway. At that point the code's appearance had been wrong twice,
    /// so the only evidence worth anything is what the running binary does — and
    /// driving Generate by hand through the UI is not something a build script can do.
    ///
    /// This runs `model.generate()` — the same method the Generate button calls, with
    /// no branch of its own — after seeding `description` exactly as the user's typing
    /// would. Everything downstream (extraction, shortlist, the LLM round-trip, the
    /// seeding) is the production path, and `MemeTrace` reports what each step decided.
    ///
    /// Compiled in only under `INSTRUMENTATION=1`, and gated on an env var even then,
    /// so no consumer build carries a launch-time path that drives the plugin.
    func runTraceProbeIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let prompt = env["OPENWHISP_MEME_PROBE_PROMPT"], !prompt.isEmpty else { return }

        MemeTrace.log("probe start, prompt=\"\(prompt)\"")
        model.description = prompt
        model.generate()

        reportCanvasAfter(seconds: Double(env["OPENWHISP_MEME_PROBE_SECONDS"] ?? "") ?? 90)
    }

    /// Report the canvas after the generate settles.
    ///
    /// The probe cannot know when the LLM answers, so it samples on a deadline and
    /// states what it found — a probe that reported nothing would look like a crash.
    /// Shared by the prompt probe and the voice-command probe so both prove the
    /// outcome the same way: N boxes, and the text in them.
    func reportCanvasAfter(seconds: Double) {
        Task { @MainActor [model] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            MemeTrace.log(
                "probe result: \(model.boxes.count) boxes on canvas, "
                + "texts=\(model.boxes.map(\.text))")
            MemeTrace.log("probe done")
        }
    }
    #endif  // OPENWHISP_INSTRUMENTATION

    // MARK: - PluginWindowLifecycle

    /// The window is being shown again after a close.
    ///
    /// `PluginHost` caches this controller forever, so without this hook the model's
    /// `windowDidOpen` ran exactly once — at `init` — while `windowWillClose` ran on
    /// every close. The two are a matched pair: close sets `isCancelled = true` so a
    /// late result can't write into a dead window, and only `windowDidOpen` clears it.
    /// Unbalanced, the FIRST close permanently poisoned every later download; the
    /// symptom the owner saw was a plugin that worked all day and then stopped, since
    /// closing the window at some point during that day is what armed it.
    func pluginWindowWillShow() {
        model.windowDidOpen()
    }

    // MARK: - PluginVoiceCommandSink

    /// Run a meme from a spoken refine command ("create a meme …").
    ///
    /// Unlike `appendDictationIfKey`, this arrives from a dictation the user spoke
    /// into ANOTHER app, so it must not append to whatever is sitting in the window
    /// from an earlier session — `startNewMeme()` clears first, then the material
    /// becomes the description and Generate runs. That is the same
    /// `description` + `generate()` pair the Generate button uses, so the voice route
    /// inherits the whole production path (extraction, shortlist, LLM, seeding) with
    /// no branch of its own.
    ///
    /// The meme plugin does not declare `clipboardAccess`, so `context.clipboard` is
    /// always nil here — the material is the whole input. That is deliberate: the
    /// plugin has an explicit ⌘V import for template IMAGES, and a caption source that
    /// silently pulled from the clipboard would be a surprise rather than a feature.
    func runVoiceCommand(_ context: PluginInvocationContext) {
        let material = context.material
        MemeTrace.log("runVoiceCommand material=\"\(material)\"")
        // The window was just opened/focused by the host; make sure the model is in
        // its open state (clears `isCancelled` if the window had been closed before).
        model.windowDidOpen()
        model.startNewMeme()
        model.description = material
        model.generate()
    }

    // MARK: - PluginDictationSink

    /// True while this window is frontmost — the signal that a completed dictation
    /// belongs here rather than in the focused app.
    var isKeyWindow: Bool { window?.isKeyWindow ?? false }

    /// Append a completed dictation to the meme description IF this window is key.
    ///
    /// Returns whether it handled the text so AppState skips its focused-app insert.
    /// Without this the words would be lost: the focused-app paste path deliberately
    /// declines while OpenWhisp itself is frontmost.
    @discardableResult
    func appendDictationIfKey(_ text: String) -> Bool {
        guard isKeyWindow, !text.isEmpty else { return false }
        model.appendDictation(text)
        return true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // A closed window must never be mutated by a late generate result.
        model.cancel()
    }
}
