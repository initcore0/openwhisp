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
            let stop = NSMenuItem(title: "⏹ Stop Streaming", action: #selector(stopStreaming), keyEquivalent: "")
            menu.addItem(stop)
        } else {
            let start = NSMenuItem(title: "🎙 Start Streaming", action: #selector(startStreaming), keyEquivalent: "")
            menu.addItem(start)
            let oldStart = NSMenuItem(title: "🎙 Record (legacy)", action: #selector(startRecording), keyEquivalent: "")
            menu.addItem(oldStart)
        }

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

    @objc private func startStreaming() { appState.startStreaming() }
    @objc private func stopStreaming()  { appState.stopStreaming() }
    @objc private func startRecording() { appState.startRecording() }
    @objc private func stopRecording()  { appState.stopRecording() }
    @objc private func terminate()      { NSApp.terminate(nil) }

    @objc private func openSettings() {
        guard let appState else { return }

        let view = SettingsView(appState: appState)
        let host = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "VoiceNote Settings"
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
