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
            // per-update window resizing (which would flicker).
            let size = NSSize(width: 440, height: 180)
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

    private var transcriptText: String {
        appState.streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showTranscript: Bool { !transcriptText.isEmpty }

    private var phaseCaption: String? {
        appState.isTranscribing ? appState.statusMessage : nil
    }

    /// While arming, tell the user capture isn't live yet so they don't speak into
    /// the startup gap (which would lose the first word). Shown as a small pill
    /// label since there's no transcript yet.
    private var armingCaption: String? {
        phase == .arming ? "Starting — wait to speak" : nil
    }

    var body: some View {
        VStack(spacing: 10) {
            waveformPill

            if let armingCaption {
                Text(armingCaption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(accent.opacity(0.95))
                    .transition(.opacity)
            }

            if appState.refineArmed {
                Text("Refine — speak your instruction")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(red: 0.66, green: 0.55, blue: 0.98))
                    .transition(.opacity)
            }

            if appState.clipboardFallbackActive {
                Text("Couldn't insert — copied, press ⌘V")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(red: 0.98, green: 0.74, blue: 0.30))
                    .transition(.opacity)
            }

            if showTranscript {
                transcriptPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.18), value: showTranscript)
        .animation(.easeInOut(duration: 0.18), value: phase)
        .animation(.easeInOut(duration: 0.18), value: appState.refineArmed)
        .animation(.easeInOut(duration: 0.18), value: appState.clipboardFallbackActive)
    }

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
                    // Hairline edge.
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                }
        }
        .animation(.easeInOut(duration: 0.18), value: phase)
        .animation(.easeOut(duration: 0.08), value: appState.audioLevel)
    }

    // MARK: Transcript

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption = phaseCaption {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accent.opacity(0.9))
                    .textCase(.uppercase)
            }
            Text(transcriptText)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
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
