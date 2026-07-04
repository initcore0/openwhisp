import AppKit
import SwiftUI

/// Presents the agent-consent window and returns the user's choice.
///
/// A menu-bar `.accessory` app has no `NSAlert` in this codebase and its overlay
/// panel can never be key, so consent uses a real `NSWindow` (the onboarding
/// pattern). One prompt at a time — a second concurrent request is denied for
/// this call. Auto-dismisses (refuse this call, no standing deny) after 60s or if
/// the user closes the window.
@MainActor
final class AgentConsentWindowController: NSObject, NSWindowDelegate {
    static let shared = AgentConsentWindowController()

    enum Choice {
        case always          // persist an "always allow"
        case whileRunning    // grant for this launch only (not persisted)
        case askEveryTime    // allow this call; keep prompting
        case deny            // persist a standing deny (fail fast next time)
        case dismiss         // refuse this call only (window closed / timed out)
    }

    private var window: NSWindow?
    private var pending: ((Choice) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    func present(clientName: String, scope: AgentScope, completion: @escaping (Choice) -> Void) {
        // One consent prompt at a time.
        guard window == nil else { completion(.dismiss); return }
        pending = completion

        let view = AgentConsentView(clientName: clientName, scope: scope) { [weak self] choice in
            self?.resolve(choice)
        }
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = "OpenWhisp — Agent Request"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            self?.resolve(.dismiss)
        }
    }

    private func resolve(_ choice: Choice) {
        timeoutTask?.cancel(); timeoutTask = nil
        let callback = pending
        pending = nil // nil BEFORE close() so windowWillClose doesn't double-resolve
        window?.delegate = nil
        window?.close()
        window = nil
        callback?(choice)
    }

    func windowWillClose(_ notification: Notification) {
        // Titlebar close with no button pressed → refuse this call.
        if pending != nil { resolve(.dismiss) }
    }
}

/// The consent card. Agent-controlled text (the client name) is displayed
/// verbatim but always framed as "X wants to…", never as OpenWhisp's own voice.
private struct AgentConsentView: View {
    let clientName: String
    let scope: AgentScope
    let onChoice: (AgentConsentWindowController.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: scopeIcon)
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    // Names the SPECIFIC capability being requested — consent is
                    // per-scope, so granting "dictate" must not read as granting
                    // history or refine too.
                    Text("\(displayName) wants to \(scope.title)")
                        .font(.headline)
                    Text("\(scopeDetail) Everything stays on this Mac. You can grant each capability separately.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 8) {
                Button { onChoice(.always) } label: {
                    label("Always allow", "Remember this choice")
                }
                .buttonStyle(.borderedProminent)

                Button { onChoice(.whileRunning) } label: {
                    label("Allow while OpenWhisp is running", "Until you quit the app")
                }
                Button { onChoice(.askEveryTime) } label: {
                    label("Allow once", "Ask again next time")
                }
                Button(role: .destructive) { onChoice(.deny) } label: {
                    label("Deny", "Block this client")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 420)
    }

    /// The client name, sanitized for display: single line, trimmed, capped.
    private var displayName: String {
        let capped = BridgeWire.sanitizedForDisplay(clientName, maxLength: 60)
        return capped.isEmpty ? "An agent" : capped
    }

    private var scopeIcon: String {
        switch scope {
        case .dictate: return "mic.badge.plus"
        case .history: return "clock.arrow.circlepath"
        case .refine:  return "wand.and.stars"
        }
    }

    /// A sentence describing what THIS scope entails (privacy-relevant specifics).
    private var scopeDetail: String {
        switch scope {
        case .dictate: return "It opens your voice overlay so you can speak an answer; the transcript goes back to the agent."
        case .history: return "It can read the text of your recent dictations and which apps they went to."
        case .refine:  return "It can send text to your configured AI model to rewrite it."
        }
    }

    private func label(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(subtitle).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
