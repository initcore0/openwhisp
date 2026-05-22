import Cocoa

// MARK: - Hotkey Monitor

class HotkeyMonitor {
    
    weak var appState: AppState?
    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    
    private var eventMonitorDown: Any?
    private var eventMonitorUp: Any?
    
    init(appState: AppState) {
        self.appState = appState
    }
    
    func start() {
        stop()
        
        // Monitor key down events
        eventMonitorDown = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let appState = self.appState else { return }
            
            let keyCode = appState.hotkeyCode
            let modifier = appState.hotkeyModifier
            
            if event.keyCode == keyCode {
                let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifier.isEmpty || eventMods.isSuperset(of: modifier) {
                    self.onHotkeyDown?()
                }
            }
        }
        
        // Monitor key up events
        eventMonitorUp = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, let appState = self.appState else { return }
            
            let keyCode = appState.hotkeyCode
            
            if event.keyCode == keyCode {
                self.onHotkeyUp?()
            }
        }
    }
    
    func stop() {
        if let monitor = eventMonitorDown {
            NSEvent.removeMonitor(monitor)
            eventMonitorDown = nil
        }
        if let monitor = eventMonitorUp {
            NSEvent.removeMonitor(monitor)
            eventMonitorUp = nil
        }
    }
}
