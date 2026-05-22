import SwiftUI
import Cocoa

@MainActor
final class OverlayWindowController {
    private var panel: NSPanel?
    private let appState: AppState
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    func show() {
        if panel == nil {
            let view = OverlayView(appState: appState)
            let host = NSHostingController(rootView: view)
            let size = NSSize(width: 520, height: 170)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = host
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            self.panel = panel
        }
        
        positionPanel()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel?.animator().alphaValue = 1
        }
    }
    
    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
    
    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 90
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct OverlayView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: appState.isTranscribing ? "waveform.badge.magnifyingglass" : "mic.fill")
                    .foregroundStyle(appState.isTranscribing ? .orange : .red)
                    .font(.system(size: 18, weight: .semibold))
                
                Text(appState.isTranscribing ? "Finalizing..." : "Listening...")
                    .font(.headline)
                
                Spacer()
                
                Text(formattedElapsed)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            WaveformStrip(level: appState.audioLevel)
                .frame(height: 42)
            
            Text(displayText)
                .font(.body)
                .foregroundStyle(appState.streamingText.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.default, value: appState.streamingText)
            
            HStack {
                Text(appState.hotkeyHelpText)
                Spacer()
                Button {
                    appState.cancelDictation()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Cancel dictation")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .padding(1)
    }
    
    private var formattedElapsed: String {
        let total = max(0, Int(appState.recordingElapsed))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
    
    private var displayText: String {
        if !appState.streamingText.isEmpty {
            return appState.streamingText
        }
        return appState.outputMode == "liveChunks"
            ? "Stable chunks will appear here as they are transcribed."
            : "Release to transcribe and insert the final text."
    }
}

struct WaveformStrip: View {
    let level: Float
    
    var body: some View {
        GeometryReader { proxy in
            let bars = 36
            let width = proxy.size.width / CGFloat(bars)
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { index in
                    let phase = Double(index) * 0.48
                    let pulse = (sin(phase + Date().timeIntervalSinceReferenceDate * 5.0) + 1.0) / 2.0
                    let height = max(8, proxy.size.height * CGFloat(0.15 + Double(level) * (0.35 + pulse * 0.5)))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.35 + Double(level) * 0.55))
                        .frame(width: max(3, width - 3), height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
