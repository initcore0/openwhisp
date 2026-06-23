import Cocoa
import CoreServices

// MARK: - Hotkey Monitor

/// macOS `HotkeyControlling`: uses CGEventTap to capture ALL keyboard events
/// including special keys like Fn, with an NSEvent fallback.
///
/// The Apple-only CGEventTap / NSEvent / CFRunLoop machinery is isolated here;
/// AppState depends on the `HotkeyControlling` protocol and receives gestures via
/// callbacks (no AppKit types cross the boundary). The pure press/release edge
/// detection lives in `HotkeyGesture` (OpenWhispCore).
final class HotkeyMonitor: HotkeyControlling {

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPermissionStateChanged: ((Bool) -> Void)?

    // Fn key code
    static let fnKeyCode: UInt16 = 0x37
    private static let spaceKeyCode: Int64 = 0x31
    private static let escapeKeyCode: Int64 = 0x35

    private var runLoopSource: Unmanaged<CFRunLoopSource>?
    private var eventTap: CFMachPort?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRunning = false
    private var isPressed = false
    var triggerMode: String = "controlSpace"

    init() {}

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

    // MARK: - Edge dispatch

    /// Apply a resolved gesture, updating the debounced state and firing the
    /// matching callback. Single point so CGEvent and NSEvent paths agree.
    private func apply(_ gesture: HotkeyGesture) {
        switch gesture {
        case .down:
            isPressed = true
            Task { @MainActor in self.onHotkeyDown?() }
        case .up:
            isPressed = false
            Task { @MainActor in self.onHotkeyUp?() }
        case .none:
            break
        }
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

        if type == .keyDown, keyCode == Self.escapeKeyCode {
            Task { @MainActor in self.onCancel?() }
        }
    }

    private func handleNSEvent(_ event: NSEvent) {
        if triggerMode == "fn" {
            handleFnEvent(event)
        } else {
            handleControlSpaceEvent(event)
        }

        if event.type == .keyDown, Int64(event.keyCode) == Self.escapeKeyCode {
            Task { @MainActor in self.onCancel?() }
        }
    }

    // MARK: - Control+Space

    private func handleControlSpaceEvent(_ event: NSEvent) {
        guard Int64(event.keyCode) == Self.spaceKeyCode else { return }
        let hasControl = event.modifierFlags.contains(.control)
        apply(controlSpaceGesture(isKeyDown: event.type == .keyDown, hasControl: hasControl))
    }

    private func handleControlSpace(type: CGEventType, keyCode: Int64, event: CGEvent) {
        guard keyCode == Self.spaceKeyCode else { return }
        let hasControl = event.flags.contains(.maskControl)
        apply(controlSpaceGesture(isKeyDown: type == .keyDown, hasControl: hasControl))
    }

    /// Control+Space is asymmetric: pressing needs Control held; releasing the
    /// space key ends regardless of Control. A keyDown without Control is a no-op.
    private func controlSpaceGesture(isKeyDown: Bool, hasControl: Bool) -> HotkeyGesture {
        let isActive: Bool
        if isKeyDown {
            isActive = hasControl ? true : isPressed   // keyDown w/o control: no change
        } else {
            isActive = false                            // any space keyUp releases
        }
        return HotkeyGesture.resolve(isActive: isActive, wasPressed: isPressed)
    }

    // MARK: - Fn

    private func handleFnEvent(_ event: NSEvent) {
        if event.keyCode == Self.fnKeyCode {
            apply(fnKeyGesture(isKeyDown: event.type == .keyDown))
            return
        }
        guard event.type == .flagsChanged else { return }
        apply(HotkeyGesture.resolve(
            isActive: event.modifierFlags.contains(.function),
            wasPressed: isPressed
        ))
    }

    private func handleFn(type: CGEventType, keyCode: Int64, event: CGEvent) {
        if keyCode == Self.fnKeyCode {
            apply(fnKeyGesture(isKeyDown: type == .keyDown))
            return
        }
        guard type == .flagsChanged else { return }
        apply(HotkeyGesture.resolve(
            isActive: event.flags.contains(.maskSecondaryFn),
            wasPressed: isPressed
        ))
    }

    /// The dedicated Fn key (0x37): keyDown is active, keyUp is inactive.
    private func fnKeyGesture(isKeyDown: Bool) -> HotkeyGesture {
        HotkeyGesture.resolve(isActive: isKeyDown, wasPressed: isPressed)
    }

    // C-compatible callback for the event tap
    @objc private static let tapCallback: CGEventTapCallBack = { (proxy, type, event, refcon) in
        guard let refcon else { return Unmanaged<CGEvent>.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleEvent(type: type, event: event)
        return Unmanaged<CGEvent>.passUnretained(event)
    }
}
