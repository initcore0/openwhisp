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

    func present(clientName: String, completion: @escaping (Choice) -> Void) {
        // One consent prompt at a time.
        guard window == nil else { completion(.dismiss); return }
        pending = completion

        let view = AgentConsentView(clientName: clientName) { [weak self] choice in
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
    let onChoice: (AgentConsentWindowController.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(displayName) wants to use OpenWhisp")
                        .font(.headline)
                    Text("It can ask you to dictate, rewrite text with your on-device AI, and read your recent dictation history. Everything stays on this Mac.")
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
        let cleaned = clientName
            .replacingOccurrences(of: "\n", with: " ")
            .filter { !$0.unicodeScalars.contains(where: { $0.properties.isBidiControl || ($0.value < 0x20) }) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = cleaned.count > 60 ? String(cleaned.prefix(60)) + "…" : cleaned
        return capped.isEmpty ? "An agent" : capped
    }

    private func label(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(subtitle).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
