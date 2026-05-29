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
            let size = NSSize(width: 386, height: 74)
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
            panel.hasShadow = false
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
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel else { return }
                panel.orderOut(nil)
                panel.contentViewController = nil
                self.panel = nil
            }
        }
    }
    
    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - panel.frame.width / 2
        let y = frame.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct OverlayView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        LuxuryWaveform(level: appState.audioLevel, isFinalizing: appState.isTranscribing)
            .frame(width: 322, height: 34)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.005, green: 0.005, blue: 0.006).opacity(0.98),
                                Color(red: 0.03, green: 0.028, blue: 0.024).opacity(0.97),
                                Color(red: 0.006, green: 0.006, blue: 0.008).opacity(0.99)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.black.opacity(0.72), radius: 22, x: 0, y: 14)
                    .shadow(color: Color(red: 0.88, green: 0.72, blue: 0.42).opacity(0.13), radius: 18, x: 0, y: 0)
            }
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
                .padding(1)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color(red: 0.95, green: 0.78, blue: 0.42).opacity(0.16),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .padding(4)
        }
        .overlay {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.075),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .blendMode(.screen)
                .padding(5)
        }
        .padding(2)
    }
}

struct LuxuryWaveform: View {
    let level: Float
    let isFinalizing: Bool
    
    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { proxy in
                let bars = 48
                let spacing: CGFloat = 4
                let width = max(2, (proxy.size.width - CGFloat(bars - 1) * spacing) / CGFloat(bars))
                let now = timeline.date.timeIntervalSinceReferenceDate
                let liveLevel = max(0.08, min(1.0, Double(level)))
                
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.055))
                        .frame(height: 1)
                        .blur(radius: 0.8)
                    
                    HStack(alignment: .center, spacing: spacing) {
                        ForEach(0..<bars, id: \.self) { index in
                            let centerDistance = abs(Double(index) - Double(bars - 1) / 2.0)
                            let centerBoost = 1.0 - min(1.0, centerDistance / (Double(bars) * 0.58))
                            let wave = (sin(now * 5.6 + Double(index) * 0.38) + 1.0) / 2.0
                            let ripple = (sin(now * 1.9 - Double(index) * 0.16) + 1.0) / 2.0
                            let finalizingPulse = isFinalizing ? 0.72 + 0.28 * sin(now * 6.0) : 1.0
                            let amplitude = (0.14 + liveLevel * 0.66) * (0.34 + centerBoost * 0.7) * (0.62 + wave * 0.38) * finalizingPulse
                            let height = max(4, proxy.size.height * CGFloat(amplitude + ripple * 0.045))
                            
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 1.0, green: 0.94, blue: 0.78),
                                            Color(red: 0.86, green: 0.66, blue: 0.34),
                                            Color(red: 0.78, green: 0.78, blue: 0.82)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: width, height: height)
                                .shadow(color: Color(red: 1.0, green: 0.82, blue: 0.46).opacity(0.22), radius: 3, x: 0, y: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
