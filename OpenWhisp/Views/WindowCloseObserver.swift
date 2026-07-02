import SwiftUI
import AppKit

/// Invokes `onWillClose` when the HOSTING NSWindow is about to close, regardless
/// of how — a button that calls close() or the title-bar close button. Scoped to
/// that window only: an app-wide `willCloseNotification` publisher would also
/// fire for open/save panels, the onboarding window, and every other window,
/// which is how Settings once committed half-typed drafts on unrelated closes.
///
/// - `firesOnce: true` (Onboarding): fire a single time, deferred past the
///   in-flight close() so a callback that itself calls close() isn't re-entrant.
/// - `firesOnce: false` (Settings — a retained window that reopens): fire
///   synchronously on every close so pending edits land before any
///   app-termination path proceeds.
struct WindowCloseObserver: NSViewRepresentable {
    var firesOnce: Bool = true
    var onWillClose: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.firesOnce = firesOnce
        view.onWillClose = onWillClose
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.firesOnce = firesOnce
        nsView.onWillClose = onWillClose
    }

    final class ObserverView: NSView {
        var firesOnce = true
        var onWillClose: (() -> Void)?
        private var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observedWindow else { return }
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.willCloseNotification, object: observedWindow)
            }
            observedWindow = window
            if let window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowWillClose(_:)),
                    name: NSWindow.willCloseNotification, object: window)
            }
        }

        @objc private func windowWillClose(_ note: Notification) {
            if firesOnce {
                // Fire once, deferred past the in-flight close() so the callback
                // (which may call close() itself) isn't re-entrant.
                let callback = onWillClose
                onWillClose = nil
                DispatchQueue.main.async { callback?() }
            } else {
                onWillClose?()
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
