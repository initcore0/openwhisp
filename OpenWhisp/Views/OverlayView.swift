import SwiftUI
import Cocoa

@MainActor
final class OverlayWindowController {
    private var panel: NSPanel?
    private let appState: AppState

    /// Bumped on every show/hide. A fade-out completion only tears the panel down
    /// if its generation is still current — so a `show()` that arrives during a
    /// `hide()` fade-out cancels the teardown instead of being clobbered by it
    /// (the rapid-toggle "overlay stuck visible" bug).
    private var generation = 0

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        if panel == nil {
            let view = OverlayView(appState: appState)
            let host = NSHostingController(rootView: view)
            // Fixed, generous panel; content self-sizes within it and is
            // bottom-anchored so an empty transcript shows just the pill. No
            // per-update window resizing (which would flicker). Instrumented
            // builds get extra height for the debug HUD.
            #if OPENWHISP_INSTRUMENTATION
            let size = NSSize(width: 440, height: 340)
            #else
            // Tall enough for pill + the agent-question hero card (up to 5 lines) +
            // transcript box + the refine instruction row; unused space is
            // transparent, so ordinary user sessions just show the pill near the top.
            let size = NSSize(width: 440, height: 300)
            #endif
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            host.view.frame = NSRect(origin: .zero, size: size)
            panel.contentViewController = host
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.alphaValue = 0   // a fresh panel fades in from 0
            self.panel = panel
        }

        generation += 1
        positionPanel()
        // Re-targets any in-flight fade-out animation toward fully-shown. A reused
        // panel mid-fade animates from its current alpha; a fresh one from 0.
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel?.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        generation += 1
        let hideGeneration = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel else { return }
                // A show()/hide() happened after this fade started — don't tear
                // down the panel the newer call is now using/animating.
                guard hideGeneration == self.generation else { return }
                panel.orderOut(nil)
                panel.contentViewController = nil
                self.panel = nil
            }
        }
    }

    /// Bottom-center placement (like the leading dictation apps), so the pill
    /// doesn't cover what the user is looking at and the transcript grows
    /// downward into empty space.
    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 140
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Real glass material

/// Thin wrapper over NSVisualEffectView so the pill is true desktop-sampling
/// glass rather than a flat fill. Clipped to a shape by the caller.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

// MARK: - Overlay

struct OverlayView: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    #if OPENWHISP_INSTRUMENTATION
    @State private var debugSnapshot: AppState.DebugHUDSnapshot?
    /// Polls process stats ~2×/sec while the overlay is up. Sampling is cheap
    /// (Mach task_info + one `ps`), and only runs in instrumented builds.
    private let debugTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    #endif

    /// Visual styling per overlay phase. The phase *decision* is the pure
    /// `OverlayPhase` (tested in OpenWhispCore); this only maps it to colors.
    /// Refine mode tints everything magenta so the two stages are visually distinct
    /// (the overlay stays up and just changes color between dictation and refine).
    private var accent: Color {
        if appState.refineArmed {
            return Color(red: 0.93, green: 0.42, blue: 0.86)                 // magenta: refining
        }
        switch phase {
        case .arming:     return Color(red: 0.98, green: 0.74, blue: 0.30)   // amber: not capturing yet
        case .listening:  return Color(red: 0.80, green: 0.82, blue: 0.88)   // cool white
        case .speaking:   return Color(red: 0.35, green: 0.78, blue: 0.98)   // calm cyan-blue
        case .finalizing: return Color(red: 0.66, green: 0.55, blue: 0.98)   // violet (polishing)
        case .error:      return Color(red: 0.95, green: 0.45, blue: 0.45)   // red
        }
    }

    private var phase: OverlayPhase {
        OverlayPhase.resolve(
            hasError: appState.error != nil,
            isCapturing: appState.isRecording,
            isTranscribing: appState.isTranscribing,
            isArming: appState.isArming,
            audioLevel: appState.audioLevel
        )
    }

    /// Amber "your turn" tint for an agent-initiated session. Distinct from the
    /// cyan capture accent and the magenta refine accent so an agent handing the
    /// mic to the human is unmistakable at a glance.
    private static let agentWaitAccent = Color(red: 0.98, green: 0.74, blue: 0.30)

    /// True while an agent is actively waiting on the human to speak — an
    /// agent-attributed session (`agentDictatePrompt` set) that is still live
    /// (listening or speaking, not yet finalizing/errored). The pill breathes an
    /// amber halo in this state to pull attention; refine sessions keep their own
    /// magenta identity and are excluded.
    private var agentWaitingActive: Bool {
        guard appState.agentDictatePrompt != nil, !appState.refineArmed else { return false }
        // While the question is being read, capture hasn't begun — but this is
        // still very much a "your turn is coming" moment, so keep the amber skin.
        if appState.agentDictateReadingQuestion { return true }
        switch phase {
        case .arming, .listening, .speaking: return true
        case .finalizing, .error:            return false
        }
    }

    private var transcriptText: String {
        appState.streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showTranscript: Bool { !transcriptText.isEmpty || refineContentText != nil }

    // MARK: Refine presentation

    /// Refine's accent (matches `accent` while armed) — the instruction row and
    /// cues render in this so refine reads as a distinct stage, not more dictation.
    private static let refineAccent = Color(red: 0.93, green: 0.42, blue: 0.86)

    /// The frozen dictated content while refining. During instruction capture
    /// it's the snapshot taken at the refine tap; during the rewrite the stream
    /// holds exactly the content being rewritten.
    private var refineContentText: String? {
        guard appState.refineArmed else { return nil }
        let content = (appState.refineContentSnapshot ?? appState.streamingText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    /// True while the refine LLM is rewriting (instruction already captured).
    private var refineIsApplying: Bool { appState.refineArmed && appState.isTranscribing }

    /// The instruction to display: the finalized one while rewriting, else the
    /// live tail of the transcript beyond the frozen snapshot — the same split
    /// the LLM receives (InstructionChain.instructionSuffix).
    private var refineInstructionText: String {
        if let final = appState.refineActiveInstruction {
            return final
        }
        guard let content = appState.refineContentSnapshot else { return "" }
        return InstructionChain.instructionSuffix(fullFinal: appState.streamingText, content: content)
    }

    private var phaseCaption: String? {
        appState.isTranscribing ? appState.statusMessage : nil
    }

    /// MAK-35 (overlay): the raw pre-cleanup words the most-recent dictation can be
    /// reverted to, or nil to hide the control. The *decision* is the pure
    /// `OverlayRevert` (tested in OpenWhispCore); this just reads AppState's flags.
    /// Shown only in a settled, post-dictation overlay when AI cleanup actually changed
    /// the words this session — so the user can restore their exact words in one tap
    /// without opening Settings › Privacy.
    private var revertTarget: String? {
        OverlayRevert.target(
            mostRecentRevertTarget: appState.history.first?.revertTarget,
            isRecording: appState.isRecording,
            isTranscribing: appState.isTranscribing,
            isArming: appState.isArming,
            refineArmed: appState.refineArmed
        )
    }

    /// While the agent's question is being read aloud, the mic is intentionally
    /// held (so the app's own speech isn't captured) — tell the human to wait so
    /// they don't answer into a dead mic and lose their first words. Takes
    /// precedence over the generic arming cue.
    private var readingQuestionCaption: String? {
        appState.agentDictateReadingQuestion ? "Reading question — please wait" : nil
    }

    /// While arming, tell the user capture isn't live yet so they don't speak into
    /// the startup gap (which would lose the first word). Shown as a small pill
    /// label since there's no transcript yet.
    private var armingCaption: String? {
        // Suppressed while the question is being read — that state has its own cue.
        guard !appState.agentDictateReadingQuestion else { return nil }
        return phase == .arming ? "Starting — wait to speak" : nil
    }

    /// Hands-free lock accent — a warm green, distinct from the cyan "speaking"
    /// and amber "agent waiting" so a locked-open session reads at a glance as a
    /// deliberate, sustained state.
    private static let lockAccent = Color(red: 0.40, green: 0.82, blue: 0.55)

    /// True while a user's hands-free (toggle/double-tap) session is locked open
    /// and genuinely capturing — the moment the affordance should tell the user
    /// the mic is held for them. Suppressed while arming/finalizing (those have
    /// their own cues), while refining, and for agent sessions (amber owns those).
    private var lockAffordanceActive: Bool {
        guard appState.dictationLocked, !appState.refineArmed,
              appState.agentDictatePrompt == nil else { return false }
        switch phase {
        case .listening, .speaking: return true
        case .arming, .finalizing, .error: return false
        }
    }

    /// The lock caption: tells the user the session is held open and how to end
    /// it. Rendered under the pill, in the green lock accent.
    private var lockCaption: String? {
        lockAffordanceActive ? "Hands-free — tap key or Esc to stop" : nil
    }

    /// During finalization (recording stopped, transcribing), show a status caption
    /// so paste-at-end mode isn't a silent overlay — and surface a cold WhisperKit
    /// model load as "Loading model…" so the wait doesn't look like a hang. Suppressed
    /// when a transcript panel is already showing the same status.
    private var finalizingCaption: String? {
        guard !showTranscript else { return nil }
        return FinalizingCaption.resolve(
            isTranscribing: appState.isTranscribing,
            statusMessage: appState.statusMessage,
            workerStatus: appState.whisperWorkerStatus,
            usesWhisperKit: appState.transcriptionEngine == "whisperKit"
        )
    }

    /// MAK-25: the rotating first-run discoverability hint to show right now, or nil.
    /// Which hint (and whether the feature is still on) is `AppState.currentOverlayHint`
    /// (pure `HintRotation`); WHETHER it may show given the live overlay state is the
    /// pure `OverlayHintGate`. A hint is a calm, ambient tip — it yields to every other
    /// overlay cue and never appears during agent/refine/lock/finalize.
    private var overlayHint: TipsCatalog.Hint? {
        guard let hint = appState.currentOverlayHint else { return nil }
        let show = OverlayHintGate.shouldShow(
            phase: phase,
            isTranscribing: appState.isTranscribing,
            agentActive: appState.agentDictatePrompt != nil || appState.agentDictateReadingQuestion,
            refineArmed: appState.refineArmed,
            dictationLocked: appState.dictationLocked,
            showTranscript: showTranscript,
            clipboardFallbackActive: appState.clipboardFallbackActive,
            revertActive: revertTarget != nil
        )
        return show ? hint : nil
    }

    /// The dismissible hint row: a small tip line with an × to dismiss it forever.
    @ViewBuilder private func hintRow(_ hint: TipsCatalog.Hint) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(hint.text)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                appState.dismissOverlayHint(hint.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Dismiss this tip")
        }
        .foregroundColor(Color(red: 0.72, green: 0.75, blue: 0.82).opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.white.opacity(0.06))
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            waveformPill

            // Agent Bridge: an agent-initiated session is always attributed. The
            // question is the CONTENT the human has to answer, so it's the hero —
            // a small "who asks" eyebrow over the full, readable question. Falls
            // back to a one-line label when the agent gave no prompt. nil for
            // ordinary user sessions.
            if appState.agentDictatePrompt != nil {
                agentQuestionPanel
                    .transition(.opacity)
            }

            if let readingQuestionCaption {
                Text(readingQuestionCaption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Self.agentWaitAccent.opacity(0.95))
                    .transition(.opacity)
            }

            if let armingCaption {
                Text(armingCaption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(accent.opacity(0.95))
                    .transition(.opacity)
            }

            if let lockCaption {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(lockCaption)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundColor(Self.lockAccent.opacity(0.95))
                .transition(.opacity)
            }

            if let finalizingCaption {
                Text(finalizingCaption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(accent.opacity(0.95))
                    .transition(.opacity)
            }

            // With content on screen the instruction row inside the panel carries
            // the refine cue; this standalone caption only covers the no-panel case.
            if appState.refineArmed && !showTranscript {
                Text("Refine — speak your instruction")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Self.refineAccent)
                    .transition(.opacity)
            }

            if appState.clipboardFallbackActive {
                Text("Couldn't insert — copied, press ⌘V")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(red: 0.98, green: 0.74, blue: 0.30))
                    .transition(.opacity)
            }

            // MAK-35: post-dictation "revert to original" — one tap restores the raw
            // pre-AI-cleanup words. Shown only when cleanup changed them this session
            // (revertTarget != nil) and never mid-session. Coexists with the clipboard-
            // fallback cue: when the original insert fell back to ⌘V, revert is still a
            // useful "give me my raw words on the clipboard instead" action.
            if revertTarget != nil {
                revertButton
                    .transition(.opacity)
            }

            if showTranscript {
                transcriptPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // MAK-25: rotating first-run discoverability hint. Calm/ambient — the
            // gate (OverlayHintGate) already ensures it's nil unless we're in a quiet
            // listening/speaking user session with nothing else on screen, so it never
            // competes with a caption, transcript, agent question, or revert control.
            if let overlayHint {
                hintRow(overlayHint)
                    .transition(.opacity)
            }

            #if OPENWHISP_INSTRUMENTATION
            if appState.debugOverlayEnabled {
                debugHUD
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.18), value: showTranscript)
        .animation(.easeInOut(duration: 0.18), value: phase)
        .animation(.easeInOut(duration: 0.18), value: appState.refineArmed)
        .animation(.easeInOut(duration: 0.18), value: appState.dictationLocked)
        .animation(.easeInOut(duration: 0.18), value: appState.clipboardFallbackActive)
        .animation(.easeInOut(duration: 0.18), value: revertTarget != nil)
        .animation(.easeInOut(duration: 0.18), value: appState.isTranscribing)
        .animation(.easeInOut(duration: 0.18), value: appState.agentDictateReadingQuestion)
        .animation(.easeInOut(duration: 0.18), value: overlayHint?.id)
        #if OPENWHISP_INSTRUMENTATION
        .onAppear { if appState.debugOverlayEnabled { debugSnapshot = appState.debugHUDSnapshot() } }
        .onReceive(debugTimer) { _ in if appState.debugOverlayEnabled { debugSnapshot = appState.debugHUDSnapshot() } }
        #endif
    }

    #if OPENWHISP_INSTRUMENTATION
    // MARK: Debug HUD (dev builds only)

    /// A square diagnostic panel rendered above/below the waveform showing the
    /// active model, app + llama-server memory/CPU, engine/session state, and the
    /// last session's timings. Monospaced, dim, deliberately utilitarian.
    @ViewBuilder private var debugHUD: some View {
        if let s = debugSnapshot {
            VStack(alignment: .leading, spacing: 3) {
                Text("DEBUG")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                debugRow("eng", s.engineLine)
                debugRow("st ", s.stateLine)
                debugRow("llm", s.llmLine)
                debugRow("mem", s.appMemCPU)
                debugRow("   ", s.llamaMemCPU)
                debugRow("t  ", s.timingLine)
            }
            .padding(8)
            .frame(width: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .transition(.opacity)
        }
    }

    private func debugRow(_ tag: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(tag)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif

    // MARK: Pill

    /// The selected indicator style, rendered inside the pill. Styles are added per
    /// phase; anything not yet implemented falls back to the waveform.
    @ViewBuilder private var indicatorContent: some View {
        switch appState.voiceIndicatorStyle {
        case .bars:
            SpectralBars(
                level: appState.audioLevel,
                accent: accent,
                isFinalizing: appState.isTranscribing,
                reduceMotion: reduceMotion
            )
        default:   // .waveform (and .orb until phase 4)
            QuietWaveform(
                level: appState.audioLevel,
                accent: accent,
                isFinalizing: appState.isTranscribing,
                reduceMotion: reduceMotion
            )
        }
    }

    private var waveformPill: some View {
        indicatorContent
        .frame(width: 220, height: 26)
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background {
            // The accent glow is a shadow cast by a CAPSULE (the pill's own shape),
            // not by the rectangular container — otherwise the bloom is a rectangle
            // around the bounding box (the old halo bug). A dedicated capsule behind
            // the blur carries both the ambient drop shadow and the energy glow so
            // both are pill-shaped.
            Capsule(style: .continuous)
                .fill(reduceTransparency ? Color(red: 0.07, green: 0.07, blue: 0.08) : Color.black.opacity(0.001))
                .shadow(color: Color.black.opacity(0.32), radius: 18, x: 0, y: 8)
                .shadow(
                    color: accent.opacity(reduceMotion ? 0.18 : Double(min(0.55, max(0.0, appState.audioLevel))) * 0.6),
                    radius: 14 + CGFloat(min(1.0, max(0.0, appState.audioLevel))) * 10,
                    x: 0, y: 0
                )
                .overlay {
                    if reduceTransparency {
                        Capsule(style: .continuous).fill(Color(red: 0.07, green: 0.07, blue: 0.08))
                    } else {
                        VisualEffectView().clipShape(Capsule(style: .continuous))
                    }
                }
                .overlay {
                    // Same liquid-glass pill as ordinary dictation — the ONLY agent
                    // detail is the edge: the hairline warms to amber (and the
                    // breathing halo below pulses). No opaque fill; the body stays
                    // the shared glass so agent mode reads as the same overlay.
                    Capsule(style: .continuous)
                        .stroke(
                            agentWaitingActive ? Self.agentWaitAccent.opacity(0.9) : Color.white.opacity(0.10),
                            lineWidth: agentWaitingActive ? 1.2 : 0.8
                        )
                }
        }
        // A breathing amber halo layered UNDER the pill, cast by a matching capsule
        // so the bloom is pill-shaped (same trick as the energy glow). It animates on
        // its own clock via TimelineView, so it keeps pulsing while the human is
        // silent — which is exactly when the agent is waiting on them to start.
        .background { agentWaitGlow }
        .animation(.easeInOut(duration: 0.25), value: agentWaitingActive)
        .animation(.easeInOut(duration: 0.18), value: phase)
        .animation(.easeOut(duration: 0.08), value: appState.audioLevel)
    }

    /// The pulsing "agent is waiting for you" halo. Rendered only for agent-waiting
    /// sessions; a soft amber capsule shadow whose opacity + radius breathe on a
    /// ~1.8s sine (repeatForever via TimelineView's animation clock). Reduce Motion
    /// swaps the breathing for a steady, slightly stronger halo so the signal
    /// survives without motion.
    @ViewBuilder private var agentWaitGlow: some View {
        if agentWaitingActive {
            if reduceMotion {
                Capsule(style: .continuous)
                    .fill(Color.clear)
                    .shadow(color: Self.agentWaitAccent.opacity(0.55), radius: 22, x: 0, y: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    // 0…1 breathing on a ~1.8s period (2π / 1.8 ≈ 3.49 rad/s).
                    let breath = sin(now * 3.49) * 0.5 + 0.5
                    Capsule(style: .continuous)
                        .fill(Color.clear)
                        .shadow(
                            color: Self.agentWaitAccent.opacity(0.30 + breath * 0.45),
                            radius: 14 + breath * 16,
                            x: 0, y: 0
                        )
                }
            }
        }
    }

    // MARK: Agent question (hero)

    /// The agent's question, promoted to the primary content: a small amber
    /// "CLIENT asks" eyebrow over the full, readable question in its own tinted
    /// card. When the agent supplied no prompt, it degrades to a single quiet
    /// attribution line. The card only wears the amber "your turn" skin while the
    /// agent is actively waiting; once capture finalizes it cools to neutral.
    @ViewBuilder private var agentQuestionPanel: some View {
        if let question = appState.agentDictateQuestion {
            VStack(alignment: .leading, spacing: 5) {
                // Who's asking — quiet, uppercase, small (same treatment as the
                // transcript's phase caption). Amber only while waiting.
                Text("\(appState.agentDictateClientLabel ?? "An agent") asks")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundColor(agentWaitingActive ? Self.agentWaitAccent.opacity(0.9) : .white.opacity(0.55))

                // The question — same font family as the live transcript, just a
                // touch larger and readable in full (up to 5 lines). No heavy card,
                // no centered hero: it reads like the transcript, amber-edged.
                Text(question)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(width: 360, alignment: .leading)
            // Same glass panel as the live transcript (cornerRadius 16, HUD glass,
            // hairline, drop shadow) — agent mode is the SAME dictation overlay,
            // not a different component. The ONLY difference is the edge: amber
            // while waiting, the normal white hairline otherwise.
            .background {
                ZStack {
                    if reduceTransparency {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(red: 0.06, green: 0.06, blue: 0.07))
                    } else {
                        VisualEffectView()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            agentWaitingActive ? Self.agentWaitAccent.opacity(0.9) : Color.white.opacity(0.08),
                            lineWidth: agentWaitingActive ? 1.2 : 0.8
                        )
                }
                .shadow(color: Color.black.opacity(0.30), radius: 16, x: 0, y: 8)
            }
        } else {
            // No question supplied — a plain attribution line ("X asked you to
            // dictate"), warmed to amber while waiting.
            Text(appState.agentDictatePrompt ?? "")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(agentWaitingActive ? Self.agentWaitAccent : .white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
    }

    // MARK: Revert control

    /// The overlay "revert to original" affordance (MAK-35): a compact glass pill with
    /// the same undo glyph the History list uses, wired to `AppState.revertLastDictation`
    /// (which swaps the just-inserted text back to the raw words in place when it can,
    /// and always leaves them on the clipboard). Non-activating panel, so tapping it
    /// doesn't steal focus from the app the text is going back into. Styled to match the
    /// pill/transcript glass, not to shout — reverting is a quiet correction.
    private var revertButton: some View {
        Button {
            appState.revertLastDictation()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                Text("Revert to original")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                ZStack {
                    if reduceTransparency {
                        Capsule(style: .continuous).fill(Color(red: 0.09, green: 0.09, blue: 0.10))
                    } else {
                        VisualEffectView().clipShape(Capsule(style: .continuous))
                    }
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                }
                .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 6)
            }
        }
        .buttonStyle(.plain)
        .help("Restore the exact words you dictated, before AI cleanup")
        .accessibilityLabel("Revert to original — restore the words you dictated before AI cleanup")
    }

    // MARK: Transcript

    // Live transcript sizing. A FIXED three-line height keeps the panel from
    // relayouting on every streaming partial — the root cause of the shimmer. The
    // newest words stay visible via a bottom-anchored scroll (not head truncation,
    // which re-wraps every partial and jitters).
    private static let transcriptLineHeight: CGFloat = 18   // ~13pt rounded line box
    private static let transcriptVisibleLines: CGFloat = 3
    private var transcriptBoxHeight: CGFloat {
        Self.transcriptLineHeight * Self.transcriptVisibleLines
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption = phaseCaption {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accent.opacity(0.9))
                    .textCase(.uppercase)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // While refining, the dictated content freezes and dims — the
                    // instruction being spoken renders in its own row below
                    // instead of streaming into this text as more dictation.
                    Text(refineContentText ?? transcriptText)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(appState.refineArmed ? 0.5 : 0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        // Static anchor — never .id(transcriptText), which would
                        // recreate the Text (and flash) on every partial.
                        .id("transcriptTail")
                }
                .frame(height: transcriptBoxHeight, alignment: .bottom)
                .scrollDisabled(true)
                // No top-fade mask: a gradient mask dimmed the top of the first
                // line even when the transcript was short (it sits at the bottom of
                // the fixed box, but the mask faded the whole top band). The
                // fixed-height bottom-anchored scroll already keeps the newest text
                // visible; overflow clips cleanly at the top with no dimming.
                .clipped()
                .onChange(of: transcriptText) { _ in
                    // Keep the newest line pinned to the bottom, without animating
                    // (animating the scroll on every partial is itself jittery).
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo("transcriptTail", anchor: .bottom) }
                }
            }
            // Belt-and-braces: no ancestor implicit animation may animate the
            // rapidly-changing transcript content.
            .transaction { $0.animation = nil }

            if appState.refineArmed {
                Divider().overlay(Self.refineAccent.opacity(0.35))
                refineInstructionRow
                    .transaction { $0.animation = nil }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 360, alignment: .leading)
        .background {
            ZStack {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(red: 0.06, green: 0.06, blue: 0.07))
                } else {
                    VisualEffectView()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
            }
            .shadow(color: Color.black.opacity(0.30), radius: 16, x: 0, y: 8)
        }
    }

    /// The refine instruction as its own visually distinct row: wand icon +
    /// magenta text under the dimmed, frozen content — so refining never reads
    /// as "the dictation just kept going".
    private var refineInstructionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Self.refineAccent)

            if refineIsApplying {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                Text(refineInstructionText.isEmpty
                     ? "Rewriting…"
                     : "“\(refineInstructionText)” — rewriting…")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(Self.refineAccent)
            } else if refineInstructionText.isEmpty {
                Text("Speak your instruction — “make it formal”, “shorten it”…")
                    .font(.system(size: 12, weight: .medium, design: .rounded).italic())
                    .foregroundColor(Self.refineAccent.opacity(0.75))
            } else {
                Text("“\(refineInstructionText)”")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(Self.refineAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(2)
        .accessibilityLabel("Refine instruction: \(refineInstructionText.isEmpty ? "listening" : refineInstructionText)")
    }
}

// MARK: - Quiet Glass waveform

/// A single continuous symmetric waveform drawn in a Canvas. Tracks the live
/// mic level through attack/peak-decay smoothing, fakes spatial frequency
/// variation with summed sines ("fbm"), and maps color to the session state.
/// Honors Reduce Motion by rendering a static level-driven envelope.
struct QuietWaveform: View {
    let level: Float
    let accent: Color
    let isFinalizing: Bool
    let reduceMotion: Bool

    // Smoothed level, updated outside the draw pass (via onChange) so we never
    // mutate @State during view evaluation. Attack fast, release slow.
    @State private var displayLevel: Double = 0.08

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height / 2

                // Idle breathing so "listening" looks alive (skipped for reduce-motion).
                let breath = reduceMotion ? 0.0 : (sin(now * 1.6) * 0.5 + 0.5) * 0.05
                let baseline = max(displayLevel, 0.06 + breath)

                let steps = 56
                var top = Path()
                var bottom = Path()

                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    let x = t * size.width

                    // Center-weighted envelope so energy concentrates mid-pill.
                    let centerEnv = pow(sin(t * .pi), 0.85)

                    // fbm-ish spatial variation; loudness raises both amplitude
                    // and wiggle frequency, which sells "accuracy".
                    let motion: Double
                    if reduceMotion {
                        motion = 1.0
                    } else {
                        let freq = 5.0 + baseline * 7.0
                        let o1 = sin(t * freq + now * 4.0)
                        let o2 = sin(t * freq * 2.1 - now * 2.3) * 0.5
                        let o3 = sin(t * freq * 0.5 + now * 1.3) * 0.3
                        motion = 0.55 + ((o1 + o2 + o3) / 1.8 * 0.5 + 0.5) * 0.45
                    }

                    let finalizingPulse = (isFinalizing && !reduceMotion)
                        ? 0.72 + 0.28 * sin(now * 6.0)
                        : 1.0

                    let amp = baseline * centerEnv * motion * finalizingPulse
                    let half = max(0.5, amp * (size.height / 2))

                    let yTop = midY - half
                    let yBottom = midY + half
                    if i == 0 {
                        top.move(to: CGPoint(x: x, y: yTop))
                        bottom.move(to: CGPoint(x: x, y: yBottom))
                    } else {
                        top.addLine(to: CGPoint(x: x, y: yTop))
                        bottom.addLine(to: CGPoint(x: x, y: yBottom))
                    }
                }

                let gradient = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [accent.opacity(0.95), accent.opacity(0.6)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: 0)
                )
                let style = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                context.stroke(top, with: gradient, style: style)
                context.stroke(bottom, with: gradient, style: style)
            }
        }
        .onChange(of: level) { _, newValue in
            let target = max(0.06, min(1.0, Double(newValue)))
            // Attack fast (snap up), release slow (decay down) — meter feel.
            let factor = target > displayLevel ? 0.5 : 0.18
            withAnimation(.linear(duration: 0.05)) {
                displayLevel = displayLevel + (target - displayLevel) * factor
            }
        }
    }
}

// MARK: - Spectral bars

/// Reactive frequency-style bars (SwiftUI Canvas). Driven by the perceptual mic
/// level: a fixed set of bars, each with a stable center-weighted envelope and its
/// own time-varying motion, so the row "dances" with loudness. (A true FFT spectrum
/// is a possible later upgrade for engines that expose raw audio; this level-driven
/// version works identically on every backend, including WhisperKit.) Honors Reduce
/// Motion with a static level-driven envelope.
struct SpectralBars: View {
    let level: Float
    let accent: Color
    let isFinalizing: Bool
    let reduceMotion: Bool

    @State private var displayLevel: Double = 0.06

    private let barCount = 21

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let baseline = max(displayLevel, 0.05)
                let slot = size.width / CGFloat(barCount)
                let gap = slot * 0.42
                let barW = slot - gap
                let midY = size.height / 2

                let finalizingPulse = (isFinalizing && !reduceMotion)
                    ? 0.78 + 0.22 * sin(now * 6.0)
                    : 1.0

                for i in 0..<barCount {
                    let t = (Double(i) + 0.5) / Double(barCount)
                    // Center bars taller than edges (a natural spectrum-ish shape).
                    let centerEnv = pow(sin(t * .pi), 0.55)
                    // Each bar wiggles on its own phase so the row looks alive.
                    let motion: Double
                    if reduceMotion {
                        motion = 1.0
                    } else {
                        let phase = Double(i) * 0.7
                        motion = 0.45 + (sin(now * 6.0 + phase) * 0.5 + 0.5) * 0.85
                    }
                    let mag = baseline * centerEnv * motion * finalizingPulse
                    let h = max(2.0, mag * Double(size.height))
                    let x = CGFloat(i) * slot + gap / 2
                    let rect = CGRect(x: x, y: midY - CGFloat(h) / 2, width: barW, height: CGFloat(h))
                    let shape = Path(roundedRect: rect, cornerRadius: barW / 2)

                    let shading = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [accent.opacity(0.95), accent.opacity(0.55)]),
                        startPoint: CGPoint(x: 0, y: rect.minY),
                        endPoint: CGPoint(x: 0, y: rect.maxY)
                    )
                    context.fill(shape, with: shading)
                }
            }
        }
        .onChange(of: level) { _, newValue in
            let target = max(0.05, min(1.0, Double(newValue)))
            let factor = target > displayLevel ? 0.5 : 0.16   // attack fast, release slow
            withAnimation(.linear(duration: 0.05)) {
                displayLevel = displayLevel + (target - displayLevel) * factor
            }
        }
    }
}
