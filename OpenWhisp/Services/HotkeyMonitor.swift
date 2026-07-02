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
    var onRefineDown: (() -> Void)?
    var onRefineUp: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPermissionStateChanged: ((Bool) -> Void)?

    // Fn key code (kVK_Function)
    static let fnKeyCode: UInt16 = 0x3F
    private static let spaceKeyCode: Int64 = 0x31
    private static let escapeKeyCode: Int64 = 0x35

    private var runLoopSource: Unmanaged<CFRunLoopSource>?
    private var eventTap: CFMachPort?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRunning = false
    private var isPressed = false
    /// Debounced held-state for the refine key, tracked independently of the
    /// dictation trigger.
    private var isRefinePressed = false
    var triggerMode: String = "controlSpace"
    /// Selected refine key id (see RefineKey). "off" disables it.
    var refineKey: String = "rightOption"

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

    /// Refine chord edge dispatch (Fn+Ctrl held together). Independent of the
    /// dictation trigger so the two never interfere.
    private func applyRefine(_ gesture: HotkeyGesture) {
        switch gesture {
        case .down:
            isRefinePressed = true
            Task { @MainActor in self.onRefineDown?() }
        case .up:
            isRefinePressed = false
            Task { @MainActor in self.onRefineUp?() }
        case .none:
            break
        }
    }

    /// The refine key is a SINGLE modifier key, detected by its keycode in a
    /// flagsChanged event. A modifier keyDown/keyUp both arrive as flagsChanged
    /// carrying that key's keycode; we infer down vs. up from whether the key's
    /// own modifier flag is now set. This is stable under the event tap (unlike a
    /// Fn-based chord, whose flags oscillate while held).
    private func handleRefineKey(keyCode: Int64, flagActive: Bool) {
        guard let target = RefineKey.from(id: refineKey).keyCode, refineKey != "off" else { return }
        guard keyCode == target else { return }
        applyRefine(HotkeyGesture.resolve(isActive: flagActive, wasPressed: isRefinePressed))
    }

    /// Whether the modifier FLAG corresponding to a given modifier keycode is set
    /// in `flags` — i.e. "is this key currently held". Uses the DEVICE-DEPENDENT
    /// bits (IOKit NX_DEVICER*KEYMASK, carried in the low word of both CGEventFlags
    /// and NSEvent.modifierFlags): the device-independent flags (.maskAlternate
    /// etc.) stay set while the LEFT sibling of the pair is held, which would make
    /// us miss the refine key's release edge.
    private static func rightModifierDeviceBit(forKeyCode keyCode: Int64) -> UInt64? {
        switch keyCode {
        case 0x3D: return 0x0040   // NX_DEVICERALTKEYMASK   (Right Option)
        case 0x36: return 0x0010   // NX_DEVICERCMDKEYMASK   (Right Command)
        case 0x3E: return 0x2000   // NX_DEVICERCTLKEYMASK   (Right Control)
        case 0x3C: return 0x0004   // NX_DEVICERSHIFTKEYMASK (Right Shift)
        default:   return nil
        }
    }
    private static func modifierFlagActive(forKeyCode keyCode: Int64, cgFlags: CGEventFlags) -> Bool {
        guard let bit = rightModifierDeviceBit(forKeyCode: keyCode) else { return false }
        return cgFlags.rawValue & bit != 0
    }
    private static func modifierFlagActive(forKeyCode keyCode: Int64, nsFlags: NSEvent.ModifierFlags) -> Bool {
        guard let bit = rightModifierDeviceBit(forKeyCode: keyCode) else { return false }
        return UInt64(nsFlags.rawValue) & bit != 0
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

        // Refine key (a single selectable modifier) — track by its keycode.
        if type == .flagsChanged {
            handleRefineKey(
                keyCode: keyCode,
                flagActive: Self.modifierFlagActive(forKeyCode: keyCode, cgFlags: event.flags)
            )
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

        if event.type == .flagsChanged {
            handleRefineKey(
                keyCode: Int64(event.keyCode),
                flagActive: Self.modifierFlagActive(forKeyCode: Int64(event.keyCode), nsFlags: event.modifierFlags)
            )
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
        // Real keyDown/keyUp for the Fn keycode (some external keyboards emit
        // these). The built-in Fn key arrives as flagsChanged and MUST fall
        // through to the flags branch below.
        if event.keyCode == Self.fnKeyCode,
           event.type == .keyDown || event.type == .keyUp {
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
        if keyCode == Self.fnKeyCode,
           type == .keyDown || type == .keyUp {
            apply(fnKeyGesture(isKeyDown: type == .keyDown))
            return
        }
        guard type == .flagsChanged else { return }
        apply(HotkeyGesture.resolve(
            isActive: event.flags.contains(.maskSecondaryFn),
            wasPressed: isPressed
        ))
    }

    /// The dedicated Fn key (kVK_Function, 0x3F) delivered as a real keyDown/keyUp:
    /// keyDown is active, keyUp is inactive.
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
