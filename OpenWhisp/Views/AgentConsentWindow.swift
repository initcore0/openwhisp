import AppKit
import SwiftUI

/// Presents the agent-consent window and returns the user's choice.
///
/// A menu-bar `.accessory` app has no `NSAlert` in this codebase and its overlay
/// panel can never be key, so consent uses a real `NSWindow` (the onboarding
/// pattern). One prompt is VISIBLE at a time; concurrent requests queue (bounded)
/// and present in arrival order — per-scope consent means one well-behaved agent
/// can legitimately need several prompts back-to-back, and auto-denying the
/// second used to surface as "the user declined" for a prompt that never
/// appeared. Each presentation auto-dismisses (refuse this call, no standing
/// deny) after 60s or if the user closes the window.
@MainActor
final class AgentConsentWindowController: NSObject, NSWindowDelegate {
    static let shared = AgentConsentWindowController()

    enum Choice {
        case always              // persist an "always allow"
        case whileRunning        // grant for this launch only (not persisted)
        case askEveryTime        // allow this call; keep prompting
        case deny                // persist a standing deny (fail fast next time)
        case dismiss             // refuse this call only (window closed / timed out / queue overflow)
        case grantedWhileQueued  // policy became allow while queued — no prompt shown, persist nothing
        case deniedWhileQueued   // policy became deny while queued — no prompt shown, persist nothing
    }

    private struct Request {
        let clientName: String
        let scope: AgentScope
        /// The caller's CURRENT decision for this (client, scope) — re-checked at
        /// presentation time, because the user may have answered an identical
        /// prompt while this request sat queued.
        let revalidate: () -> AgentConsentDecision
        let completion: (Choice) -> Void
    }

    /// Waiting requests beyond the visible one. Bounded so a hostile client
    /// can't stack prompts faster than the user resolves them.
    private var queue: [Request] = []
    private static let maxQueued = 3

    private var window: NSWindow?
    private var pending: ((Choice) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    /// Bumped per presentation; fences the timeout task (and any other stale
    /// callback) to the presentation it was armed for, so a late dismiss can
    /// never resolve the NEXT prompt.
    private var presentationGeneration = 0

    func present(
        clientName: String, scope: AgentScope,
        revalidate: @escaping () -> AgentConsentDecision,
        completion: @escaping (Choice) -> Void
    ) {
        let request = Request(clientName: clientName, scope: scope,
                              revalidate: revalidate, completion: completion)
        guard window == nil else {
            // A prompt is up — queue this one instead of spuriously "declining".
            if queue.count < Self.maxQueued {
                queue.append(request)
            } else {
                completion(.dismiss)
            }
            return
        }
        show(request)
    }

    private func show(_ request: Request) {
        // A decision may have landed while this request sat queued (the user just
        // answered an identical prompt for the same client+scope). Only a
        // still-undecided scope presents — a duplicate prompt would invite the
        // user to contradict, and thereby overwrite, the choice they made
        // seconds earlier.
        switch request.revalidate() {
        case .allow:
            request.completion(.grantedWhileQueued)
            showNextQueued()
            return
        case .deny:
            request.completion(.deniedWhileQueued)
            showNextQueued()
            return
        case .prompt:
            break
        }

        pending = request.completion
        presentationGeneration += 1
        let generation = presentationGeneration

        let view = AgentConsentView(clientName: request.clientName, scope: request.scope) { [weak self] choice in
            self?.resolve(choice, generation: generation)
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
            // Cancellation makes Task.sleep throw EARLY (and try? swallows it);
            // without these fences a cancelled timeout from prompt N could wake
            // immediately and dismiss prompt N+1 the moment it appears.
            guard !Task.isCancelled else { return }
            self?.resolve(.dismiss, generation: generation)
        }
    }

    private func resolve(_ choice: Choice, generation: Int) {
        guard generation == presentationGeneration, pending != nil else { return }
        timeoutTask?.cancel(); timeoutTask = nil
        let callback = pending
        pending = nil // nil BEFORE close() so windowWillClose doesn't double-resolve
        window?.delegate = nil
        window?.close()
        window = nil
        callback?(choice)
        showNextQueued()
    }

    /// Present the next queued request, if any (its own 60s window starts at
    /// presentation, not at enqueue). Recursion depth is bounded by maxQueued.
    private func showNextQueued() {
        if !queue.isEmpty {
            show(queue.removeFirst())
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Titlebar close with no button pressed → refuse this call.
        if pending != nil { resolve(.dismiss, generation: presentationGeneration) }
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
                Image(systemName: scope.icon)
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    // Names the SPECIFIC capability being requested — consent is
                    // per-scope, so granting "dictate" must not read as granting
                    // history or refine too.
                    Text("\(displayName) wants to \(scope.title)")
                        .font(.headline)
                    Text("\(scope.detail) Everything stays on this Mac. You can grant each capability separately.")
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
                    // Deny is per-scope — promising to "block this client" here
                    // would be false (other capabilities still prompt separately).
                    label("Deny", "Block \(scope.noun.lowercased()) for this client")
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

    private func label(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(subtitle).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
