import Cocoa
import CoreServices

// MARK: - Hotkey Monitor

/// Uses CGEventTap to capture ALL keyboard events including special keys like Fn.
class HotkeyMonitor {
    
    weak var appState: AppState?
    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    
    // Fn key code
    static let fnKeyCode: UInt16 = 0x37
    
    private var runLoopSource: Unmanaged<CFRunLoopSource>?
    private var isRunning = false
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    func start() {
        guard !isRunning else { return }
        
        // Listen for keyDown (type 8) and keyUp (type 9)
        let mask: CGEventMask = CGEventMask(Int64(1) << 8 | Int64(1) << 9)
        
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: Unmanaged.passRetained(self).toOpaque()
        ) else {
            print("[HotkeyMonitor] Failed to create event tap — check Accessibility permissions")
            return
        }
        
        // Create run loop source from CFMachPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
        runLoopSource = Unmanaged<CFRunLoopSource>.passRetained(source)
        
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        
        CGEvent.tapEnable(tap: port, enable: true)
        isRunning = true
        print("[HotkeyMonitor] Started (listening for Fn key)")
    }
    
    func stop() {
        guard isRunning else { return }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source.takeUnretainedValue(), .commonModes)
            source.release()
            runLoopSource = nil
        }
        
        isRunning = false
        print("[HotkeyMonitor] Stopped")
    }
    
    private func handleEvent(type: CGEventType, event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        
        if keyCode == Self.fnKeyCode {
            switch type {
            case .keyDown:
                print("[HotkeyMonitor] Fn key DOWN")
                Task { @MainActor in
                    self.onHotkeyDown?()
                }
            case .keyUp:
                print("[HotkeyMonitor] Fn key UP")
                Task { @MainActor in
                    self.onHotkeyUp?()
                }
            default:
                break
            }
        }
    }
    
    // C-compatible callback for the event tap
    @objc private static let tapCallback: CGEventTapCallBack = { (proxy, type, event, refcon) in
        guard let refcon else { return Unmanaged<CGEvent>.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleEvent(type: type, event: event)
        return Unmanaged<CGEvent>.passUnretained(event)
    }
}
