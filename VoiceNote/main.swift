import Cocoa
import SwiftUI
import AVFoundation
import UserNotifications
import Foundation

// MARK: - Application Delegate

@MainActor
class VoiceNoteApp: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var appState: AppState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[VoiceNote] Application launching...")

        // Hide from dock — agent app
        NSApp.setActivationPolicy(.accessory)
        print("[VoiceNote] ActivationPolicy set to .accessory")

        // Initialize state
        appState = AppState.shared
        print("[VoiceNote] AppState initialized")

        // Build status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        print("[VoiceNote] StatusItem created: \(statusItem != nil ? "YES" : "NO")")
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceNote")
            button.toolTip = "VoiceNote"
            button.target = self
            button.action = #selector(showMenu)
            print("[VoiceNote] Button configured, image: \(button.image != nil ? "YES" : "NO")")
        } else {
            print("[VoiceNote] WARNING: statusItem.button is nil!")
        }

        // Request microphone permission
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // Request notification permission (safely — requires .app bundle)
        requestNotifications()

        // Ensure model exists
        appState.ensureModelExists()
        print("[VoiceNote] Ready")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
    }

    private func requestNotifications() {
        // UNUserNotificationCenter.current() crashes with NSInternalInconsistencyException
        // when the app is not run from a proper .app bundle.
        let path = Bundle.main.bundlePath
        print("[VoiceNote] bundlePath: \(path)")
        guard path.contains(".app") else {
            print("[VoiceNote] Warning: not running from .app bundle, skipping notification setup")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[VoiceNote] Notification error: \(error.localizedDescription)")
            } else {
                print("[VoiceNote] Notifications: \(granted ? "granted" : "denied")")
            }
        }
    }

    // MARK: - Menu

    @objc private func showMenu() {
        guard let appState, let btn = statusItem.button else { return }

        let menu = NSMenu()

        // Status
        let statusItem = NSMenuItem(title: "● \(appState.statusMessage)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        let modelStatusTitle = appState.isModelDownloading
            ? "Model: \(appState.modelDownloadStatus)"
            : "Model: \(appState.modelDownloadStatus)"
        let modelStatus = NSMenuItem(title: modelStatusTitle, action: nil, keyEquivalent: "")
        modelStatus.isEnabled = false
        menu.addItem(modelStatus)

        let whisperStatus = NSMenuItem(title: "Whisper Server: \(appState.whisperWorkerStatus)", action: nil, keyEquivalent: "")
        whisperStatus.isEnabled = false
        menu.addItem(whisperStatus)
        menu.addItem(.separator())

        // Last transcription
        if let last = appState.lastTranscription, !last.isEmpty {
            let display = String(last.prefix(40)) + (last.count > 40 ? "..." : "")
            let copyItem = NSMenuItem(title: "📋 \"\(display)\"", action: #selector(copyLast), keyEquivalent: "c")
            menu.addItem(copyItem)
            menu.addItem(.separator())
        }

        // Recording actions
        if appState.isRecording {
            let stop = NSMenuItem(title: "Stop Dictation", action: #selector(stopDictation), keyEquivalent: "")
            menu.addItem(stop)
            let cancel = NSMenuItem(title: "Cancel Dictation", action: #selector(cancelDictation), keyEquivalent: "")
            menu.addItem(cancel)
        } else {
            let start = NSMenuItem(title: "Start Dictation", action: #selector(startDictation), keyEquivalent: "")
            menu.addItem(start)
        }

        menu.addItem(.separator())

        let engineMenu = NSMenu()
        let whisper = NSMenuItem(title: "Whisper Local", action: #selector(useWhisperEngine), keyEquivalent: "")
        whisper.state = appState.transcriptionEngine == "whisper" ? .on : .off
        engineMenu.addItem(whisper)

        let apple = NSMenuItem(title: "Apple Speech Streaming", action: #selector(useAppleSpeechEngine), keyEquivalent: "")
        apple.state = appState.transcriptionEngine == "appleSpeech" ? .on : .off
        engineMenu.addItem(apple)

        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        let languageMenu = NSMenu()
        for option in languageOptions {
            let item = NSMenuItem(
                title: option.title,
                action: #selector(selectLanguage),
                keyEquivalent: ""
            )
            item.representedObject = option.code
            item.state = appState.language == option.code ? .on : .off
            languageMenu.addItem(item)
        }
        languageMenu.addItem(.separator())
        let hint = NSMenuItem(title: "Choose English to translate to English with Whisper", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        languageMenu.addItem(hint)

        let languageItem = NSMenuItem(title: "Language: \(appState.languageDisplayName)", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        // Settings
        let settings = NSMenuItem(title: "⚙ Settings", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settings)

        menu.addItem(.separator())

        // Quit
        let quit = NSMenuItem(title: "Quit", action: #selector(terminate), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: btn.frame.maxY),
                   in: btn)
    }

    @objc private func copyLast() {
        guard let text = appState.lastTranscription, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func startDictation() { appState.startDictation() }
    @objc private func stopDictation()  { appState.stopDictation() }
    @objc private func cancelDictation() { appState.cancelDictation() }
    @objc private func startStreaming() { appState.startStreaming() }
    @objc private func stopStreaming()  { appState.stopStreaming() }
    @objc private func startRecording() { appState.startRecording() }
    @objc private func stopRecording()  { appState.stopRecording() }
    @objc private func useWhisperEngine() { appState.transcriptionEngine = "whisper" }
    @objc private func useAppleSpeechEngine() { appState.transcriptionEngine = "appleSpeech" }
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        appState.language = code
    }
    @objc private func terminate()      { NSApp.terminate(nil) }

    private var languageOptions: [(code: String, title: String)] {
        [
            ("auto", "Auto Detect"),
            ("en", "English - Whisper translate to English"),
            ("ru", "Russian"),
            ("es", "Spanish"),
            ("fr", "French"),
            ("de", "German")
        ]
    }

    @objc private func openSettings() {
        guard let appState else { return }

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(appState: appState)
        let host = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "VoiceNote Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 460)
        window.contentViewController = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}

// MARK: - Main Entry

@main
class AppDelegateBootstrap {
    static func main() {
        let app = NSApplication.shared
        let delegate = VoiceNoteApp()
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
