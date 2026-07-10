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

    var onHotkeyDown: ((_ locked: Bool) -> Void)?
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
    /// Bare-tap detection for the refine key: a press only counts as a refine
    /// tap if it's released quickly with NO other input in between — otherwise
    /// it was a shortcut chord (⌃C, ⌃-click, …), not a refine request.
    private var refineTap = RefineTapRecognizer()
    var triggerMode: String = "controlSpace"
    /// How activation behaves: "hold" (press-to-talk) or "toggle" (hands-free
    /// lock). Setting it rebuilds the interaction machine so a live mode change
    /// starts clean (never mid-gesture). A double-tap still reaches lock from
    /// hold mode; see `ActivationInteraction`.
    var hotkeyMode: String = "hold" {
        didSet {
            guard hotkeyMode != oldValue else { return }
            activation = ActivationInteraction(mode: hotkeyMode == "toggle" ? .toggle : .hold)
            isPressed = false
        }
    }
    /// Selected refine key id (see RefineKey). "off" disables it.
    var refineKey: String = RefineKey.defaultKey.rawValue

    /// The pure interaction state machine (hold vs. toggle vs. double-tap → lock,
    /// Esc-cancel). The raw debounced `.down`/`.up` edges resolved below are fed
    /// through this, and its intents become the callbacks. Built for the current
    /// `hotkeyMode`; rebuilt whenever the mode changes.
    private var activation = ActivationInteraction(mode: .hold)

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
        let eventMask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged,
            // Only consumed as refine-tap disqualifiers (⌃-click, ⌃-scroll);
            // handleNSEvent returns before any key handling for these.
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]

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

    func resetActivation() {
        // Only a machine that still thinks a session is live needs resetting. An
        // idle machine may be holding the last-tap timestamp that makes the NEXT
        // press read as a double-tap — a session finalizing quickly between the
        // two taps must not erase it.
        guard activation.isActive else { return }
        activation.reset()
        isPressed = false
    }

    // MARK: - Edge dispatch

    /// Apply a resolved gesture, updating the debounced state and feeding the
    /// interaction machine, which decides the high-level intent (start / stop /
    /// lock-open) for the current hold-or-toggle mode. Single point so the
    /// CGEvent and NSEvent paths agree.
    private func apply(_ gesture: HotkeyGesture) {
        let now = ProcessInfo.processInfo.systemUptime
        switch gesture {
        case .down:
            isPressed = true
            dispatch(activation.triggerDown(now: now))
        case .up:
            isPressed = false
            dispatch(activation.triggerUp(now: now))
        case .none:
            break
        }
    }

    /// Turn an interaction intent into the outward callbacks. `.start` carries
    /// whether the session is locked (hands-free); `.none` (e.g. the release
    /// that locks a toggle session open, or the swallowed stop-tap release) fires
    /// nothing.
    private func dispatch(_ intent: ActivationInteraction.Intent) {
        switch intent {
        case .start(let locked):
            Task { @MainActor in self.onHotkeyDown?(locked) }
        case .stop:
            Task { @MainActor in self.onHotkeyUp?() }
        case .cancel:
            Task { @MainActor in self.onCancel?() }
        case .none:
            break
        }
    }

    /// Refine key edge dispatch, independent of the dictation trigger. The
    /// refine callback fires on the UP edge of a clean bare tap — firing on the
    /// down edge treated every shortcut that uses the key (⌃C, ⌃-click…) as a
    /// refine request, invisibly arming refine for the next dictation.
    private func applyRefine(_ gesture: HotkeyGesture) {
        switch gesture {
        case .down:
            isRefinePressed = true
            refineTap.keyDown()
        case .up:
            isRefinePressed = false
            if refineTap.keyUp() {
                Task { @MainActor in self.onRefineDown?() }
            }
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
        let key = RefineKey.from(id: refineKey)
        guard let target = key.keyCode, refineKey != "off" else { return }
        // A Control refine key can't coexist with the Control+Space trigger —
        // holding Control to start dictation would read as a refine tap. The
        // Settings UI warns about this combination; suppress it here too.
        guard !key.conflictsWithTrigger(triggerMode) else { return }
        guard keyCode == target else {
            // A DIFFERENT modifier changed while the refine key is held: the
            // hold is a chord (⌃⌘…), not a bare tap.
            if isRefinePressed { refineTap.otherInput() }
            return
        }
        applyRefine(HotkeyGesture.resolve(isActive: flagActive, wasPressed: isRefinePressed))
    }

    /// Whether the modifier FLAG corresponding to a given modifier keycode is set
    /// in `flags` — i.e. "is this key currently held". Uses the DEVICE-DEPENDENT
    /// bits (IOKit NX_DEVICER*KEYMASK, carried in the low word of both CGEventFlags
    /// and NSEvent.modifierFlags): the device-independent flags (.maskAlternate
    /// etc.) stay set while the LEFT sibling of the pair is held, which would make
    /// us miss the refine key's release edge.
    /// Union of all NX_DEVICE[LR]*KEYMASK modifier bits. HID-sourced events
    /// always carry these; synthesizers that assign public device-independent
    /// masks (CGEventSetFlags) wipe the whole low word. Excludes
    /// NX_DEVICE_ALPHASHIFT_STATELESS_MASK (0x0080), which isn't a modifier key.
    private static let anyDeviceModifierBits: UInt64 = 0x207F

    private static func modifierBits(forKeyCode keyCode: Int64) -> (device: UInt64, independent: UInt64)? {
        switch keyCode {
        case 0x3B: return (0x0001, CGEventFlags.maskControl.rawValue)   // Left Control (NX_DEVICELCTLKEYMASK)
        case 0x3A: return (0x0020, CGEventFlags.maskAlternate.rawValue) // Left Option (NX_DEVICELALTKEYMASK)
        case 0x37: return (0x0008, CGEventFlags.maskCommand.rawValue)   // Left Command (NX_DEVICELCMDKEYMASK)
        case 0x3D: return (0x0040, CGEventFlags.maskAlternate.rawValue) // Right Option (NX_DEVICERALTKEYMASK)
        case 0x36: return (0x0010, CGEventFlags.maskCommand.rawValue)   // Right Command (NX_DEVICERCMDKEYMASK)
        case 0x3E: return (0x2000, CGEventFlags.maskControl.rawValue)   // Right Control (NX_DEVICERCTLKEYMASK)
        case 0x3C: return (0x0004, CGEventFlags.maskShift.rawValue)     // Right Shift (NX_DEVICERSHIFTKEYMASK)
        default:   return nil
        }
    }
    private static func modifierFlagActive(forKeyCode keyCode: Int64, rawFlags: UInt64) -> Bool {
        guard let bits = modifierBits(forKeyCode: keyCode) else { return false }
        if rawFlags & bits.device != 0 { return true }
        // When ANY device bit is present the event is HID-sourced and the
        // device bit alone is authoritative — this preserves the release-edge
        // detection while the LEFT sibling of the pair is still held. Zero
        // device bits means a synthetic event (Hammerspoon, AppleScript,
        // remote desktop) — fall back to the device-independent flag.
        return rawFlags & anyDeviceModifierBits == 0 && rawFlags & bits.independent != 0
    }
    private static func modifierFlagActive(forKeyCode keyCode: Int64, cgFlags: CGEventFlags) -> Bool {
        modifierFlagActive(forKeyCode: keyCode, rawFlags: cgFlags.rawValue)
    }
    private static func modifierFlagActive(forKeyCode keyCode: Int64, nsFlags: NSEvent.ModifierFlags) -> Bool {
        // NSEvent.ModifierFlags shares CGEventFlags' raw layout for both the
        // device-independent masks and the device-dependent low word.
        modifierFlagActive(forKeyCode: keyCode, rawFlags: UInt64(nsFlags.rawValue))
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
        } else if type == .keyDown, isRefinePressed {
            // Typing while the refine key is held = a keyboard shortcut.
            refineTap.otherInput()
        }

        if type == .keyDown, keyCode == Self.escapeKeyCode {
            handleEscape()
        }
    }

    /// Esc cancels the active session. Clear the interaction machine (so a
    /// locked-open session doesn't stay "active" in the machine's eyes) and
    /// always deliver the cancel — AppState decides what to tear down (a locked
    /// dictation, an agent session being read, or an armed refine), and the
    /// machine may legitimately be idle for those non-hotkey sessions.
    private func handleEscape() {
        _ = activation.cancel()
        isPressed = false
        Task { @MainActor in self.onCancel?() }
    }

    private func handleNSEvent(_ event: NSEvent) {
        // Mouse/scroll while the refine key is held = ⌃-click / ⌃-scroll etc.
        // Handle and return BEFORE the key handlers (NSEvent.keyCode is only
        // valid for key events).
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            if isRefinePressed { refineTap.otherInput() }
            return
        default:
            break
        }

        if event.type == .keyDown, isRefinePressed {
            refineTap.otherInput()
        }

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
            handleEscape()
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
