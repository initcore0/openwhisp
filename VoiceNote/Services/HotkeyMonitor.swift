import Cocoa
import CoreServices

// MARK: - Hotkey Monitor

/// Uses CGEventTap to capture ALL keyboard events including special keys like Fn.
class HotkeyMonitor {
    
    weak var appState: AppState?
    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    var onPermissionStateChanged: ((Bool) -> Void)?
    
    // Fn key code
    static let fnKeyCode: UInt16 = 0x37
    private static let spaceKeyCode: Int64 = 0x31
    
    private var runLoopSource: Unmanaged<CFRunLoopSource>?
    private var eventTap: CFMachPort?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRunning = false
    private var isPressed = false
    var triggerMode: String = "controlSpace"
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    func start() {
        guard !isRunning else { return }
        
        let mask: CGEventMask = CGEventMask(
            (Int64(1) << CGEventType.keyDown.rawValue) |
            (Int64(1) << CGEventType.keyUp.rawValue) |
            (Int64(1) << CGEventType.flagsChanged.rawValue)
        )
        
        let port = createEventTap(mask: mask, tap: .cghidEventTap)
            ?? createEventTap(mask: mask, tap: .cgSessionEventTap)
        
        if let port {
            eventTap = port
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
            runLoopSource = Unmanaged<CFRunLoopSource>.passRetained(source)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            onPermissionStateChanged?(true)
            print("[HotkeyMonitor] Started with CGEventTap")
        } else {
            print("[HotkeyMonitor] CGEventTap unavailable; using NSEvent fallback")
            onPermissionStateChanged?(false)
        }
        
        startNSEventFallback()
        isRunning = true
    }
    
    private func createEventTap(mask: CGEventMask, tap: CGEventTapLocation) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: tap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }
    
    private func startNSEventFallback() {
        let eventMask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleNSEvent(event)
        }
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }
    
    func stop() {
        guard isRunning else { return }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source.takeUnretainedValue(), .commonModes)
            source.release()
            runLoopSource = nil
        }
        eventTap = nil
        
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        
        isRunning = false
        print("[HotkeyMonitor] Stopped")
    }
    
    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        
        if triggerMode == "fn" {
            handleFn(type: type, keyCode: keyCode, event: event)
        } else {
            handleControlSpace(type: type, keyCode: keyCode, event: event)
        }
        
        if type == .keyDown, keyCode == 0x35 {
            Task { @MainActor in
                self.appState?.cancelDictation()
            }
        }
    }
    
    private func handleNSEvent(_ event: NSEvent) {
        if triggerMode == "fn" {
            handleFnEvent(event)
        } else {
            handleControlSpaceEvent(event)
        }
        
        if event.type == .keyDown, event.keyCode == 0x35 {
            Task { @MainActor in
                self.appState?.cancelDictation()
            }
        }
    }
    
    private func handleControlSpaceEvent(_ event: NSEvent) {
        let hasControl = event.modifierFlags.contains(.control)
        guard Int64(event.keyCode) == Self.spaceKeyCode else { return }
        
        if event.type == .keyDown, hasControl, !isPressed {
            isPressed = true
            print("[HotkeyMonitor] Control+Space DOWN (NSEvent)")
            Task { @MainActor in
                self.onHotkeyDown?()
            }
        } else if event.type == .keyUp, isPressed {
            isPressed = false
            print("[HotkeyMonitor] Control+Space UP (NSEvent)")
            Task { @MainActor in
                self.onHotkeyUp?()
            }
        }
    }
    
    private func handleFnEvent(_ event: NSEvent) {
        if event.keyCode == Self.fnKeyCode {
            if event.type == .keyDown, !isPressed {
                isPressed = true
                Task { @MainActor in
                    self.onHotkeyDown?()
                }
            } else if event.type == .keyUp, isPressed {
                isPressed = false
                Task { @MainActor in
                    self.onHotkeyUp?()
                }
            }
            return
        }
        
        guard event.type == .flagsChanged else { return }
        let hasFn = event.modifierFlags.contains(.function)
        if hasFn, !isPressed {
            isPressed = true
            Task { @MainActor in
                self.onHotkeyDown?()
            }
        } else if !hasFn, isPressed {
            isPressed = false
            Task { @MainActor in
                self.onHotkeyUp?()
            }
        }
    }
    
    private func handleControlSpace(type: CGEventType, keyCode: Int64, event: CGEvent) {
        let hasControl = event.flags.contains(.maskControl)
        guard keyCode == Self.spaceKeyCode else { return }
        
        if type == .keyDown, hasControl, !isPressed {
            isPressed = true
            print("[HotkeyMonitor] Control+Space DOWN")
            Task { @MainActor in
                self.onHotkeyDown?()
            }
        } else if type == .keyUp, isPressed {
            isPressed = false
            print("[HotkeyMonitor] Control+Space UP")
            Task { @MainActor in
                self.onHotkeyUp?()
            }
        }
    }
    
    private func handleFn(type: CGEventType, keyCode: Int64, event: CGEvent) {
        if keyCode == Self.fnKeyCode {
            if type == .keyDown, !isPressed {
                isPressed = true
                print("[HotkeyMonitor] Fn key DOWN")
                Task { @MainActor in
                    self.onHotkeyDown?()
                }
            } else if type == .keyUp, isPressed {
                isPressed = false
                print("[HotkeyMonitor] Fn key UP")
                Task { @MainActor in
                    self.onHotkeyUp?()
                }
            }
            return
        }
        
        guard type == .flagsChanged else { return }
        let hasFn = event.flags.contains(.maskSecondaryFn)
        if hasFn, !isPressed {
            isPressed = true
            print("[HotkeyMonitor] Fn flag DOWN")
            Task { @MainActor in
                self.onHotkeyDown?()
            }
        } else if !hasFn, isPressed {
            isPressed = false
            print("[HotkeyMonitor] Fn flag UP")
            Task { @MainActor in
                self.onHotkeyUp?()
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
