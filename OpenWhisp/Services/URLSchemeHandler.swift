import Foundation
import AppKit
import os

// App-target only (NOT in Package.swift's OpenWhispCore sources): it touches
// AppState + AppKit. The pure parsing/validation it depends on lives in
// URLScheme (tested). This file is the thin executor that turns validated
// `URLScheme.Command`s into the app's EXISTING actions — it deliberately owns no
// command routing of its own, mirroring how AgentBridgeServer executes the intents
// BridgeRouter produces.

/// Executes the commands a parsed `openwhisp://` URL yields, on the main actor,
/// against the running app. Reuses the same AppState actions the hotkey, menu bar,
/// and agent bridge already drive — it never opens a shell, runs a file, or
/// interprets a parameter as code (the allow-list in ``URLScheme`` is the boundary;
/// this just dispatches what got past it).
@MainActor
enum URLSchemeHandler {

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenWhisp", category: "URLScheme")

    /// Handle a batch of `openwhisp://` URLs (AppKit may deliver several at once).
    static func handle(urls: [URL], appState: AppState) {
        for url in urls { handle(url: url, appState: appState) }
    }

    /// Parse one URL and execute its commands all-or-nothing. A rejection runs
    /// nothing and is logged (never echoed back — no oracle to a hostile caller).
    static func handle(url: URL, appState: AppState) {
        switch URLScheme.parse(url) {
        case .rejected(let reason):
            log.notice("openwhisp:// URL rejected: \(String(describing: reason), privacy: .public)")
        case .commands(let commands):
            for command in commands { execute(command, appState: appState) }
        }
    }

    private static func execute(_ command: URLScheme.Command, appState: AppState) {
        switch command {
        case .record:
            // Toggle: the launcher press behaves like the hotkey — start a
            // dictation, or stop one already running.
            if appState.isRecording { appState.stopDictation() }
            else { appState.startDictation() }

        case .refine(let instruction, let text):
            // Reuse the exact agent-bridge refine primitive. Text defaults to the
            // last result. The refined text is placed on the clipboard (the URL
            // caller has no stdout to receive it, unlike the CLI).
            let payload = text ?? appState.lastTranscription ?? ""
            guard !payload.isEmpty else {
                log.notice("openwhisp://refine: no text and no last result — nothing to refine")
                return
            }
            appState.bridgeRefine(clientName: "openwhisp-url", text: payload, instruction: instruction) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let refined):
                        appState.textOutput.setClipboard(refined)
                        appState.lastTranscription = refined
                    case .failure(let error):
                        Self.log.notice("openwhisp://refine failed: \(error.message, privacy: .public)")
                    }
                }
            }

        case .scratchpad:
            // Open/focus the floating Scratchpad. Once it's key, the next dictation
            // lands in it (MAK-49). A launcher can chain `?scratchpad&record`.
            appState.openScratchpad()

        case .pasteLast:
            guard let last = appState.lastTranscription, !last.isEmpty else {
                log.notice("openwhisp://paste-last-result: no last result to paste")
                return
            }
            appState.textOutput.insert(last, mode: .paste, restoreClipboard: true)

        case .switchMode(let key), .activateMode(let key):
            // Recognized and validated, but not yet wired to a runtime action:
            // OpenWhisp's "modes" today are per-app profiles keyed by bundle ID and
            // applied automatically at dictation start — there is no named-mode
            // registry to switch by key yet. Parsing/validation ship now (the
            // security boundary and grammar are the hard part); the runtime hook
            // lands when the named-mode registry does. Logged honestly rather than
            // silently doing nothing that reads as success.
            log.notice("openwhisp:// \(command.verb.rawValue, privacy: .public) key=\(key, privacy: .public): recognized but not yet wired (named-mode registry pending)")
        }
    }
}
