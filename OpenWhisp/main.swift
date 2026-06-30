import Cocoa
import SwiftUI
import AVFoundation
import UserNotifications
import Foundation

// MARK: - Application Delegate

@MainActor
class OpenWhispApp: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var appState: AppState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[OpenWhisp] Application launching...")

        // Hide from dock — agent app
        NSApp.setActivationPolicy(.accessory)
        print("[OpenWhisp] ActivationPolicy set to .accessory")

        // Initialize state
        appState = AppState.shared
        print("[OpenWhisp] AppState initialized")

        // Build status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        print("[OpenWhisp] StatusItem created: \(statusItem != nil ? "YES" : "NO")")
        if let button = statusItem.button {
            button.image = Self.menuBarImage()
            button.toolTip = "OpenWhisp"
            button.target = self
            button.action = #selector(showMenu)
            print("[OpenWhisp] Button configured, image: \(button.image != nil ? "YES" : "NO")")
        } else {
            print("[OpenWhisp] WARNING: statusItem.button is nil!")
        }

        // Request microphone permission
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // Request notification permission (safely — requires .app bundle)
        requestNotifications()

        // Ensure model exists
        appState.ensureModelExists()

        // First-run onboarding
        showOnboardingIfNeeded()
        print("[OpenWhisp] Ready")
    }

    private func showOnboardingIfNeeded() {
        guard let appState, !appState.didCompleteOnboarding else { return }
        // Onboarding requires a real .app bundle for the permission prompts to
        // behave; skip the guided flow when running the bare binary.
        guard Bundle.main.bundlePath.contains(".app") else { return }
        presentOnboarding()
    }

    private func presentOnboarding() {
        guard let appState else { return }
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(appState: appState) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let host = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Welcome to OpenWhisp"
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    /// Menu-bar icon: the bundled waveform glyph (template, so macOS tints it for
    /// light/dark menu bars) that matches the app icon. Falls back to the SF
    /// `waveform` symbol if the bundled image isn't present.
    private static func menuBarImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "waveform", accessibilityDescription: "OpenWhisp")
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
        print("[OpenWhisp] bundlePath: \(path)")
        guard path.contains(".app") else {
            print("[OpenWhisp] Warning: not running from .app bundle, skipping notification setup")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[OpenWhisp] Notification error: \(error.localizedDescription)")
            } else {
                print("[OpenWhisp] Notifications: \(granted ? "granted" : "denied")")
            }
        }
    }

    // MARK: - Menu

    @objc private func showMenu() {
        guard let appState, let btn = statusItem.button else { return }

        let menu = NSMenu()

        // Status (single line). Health details only surface when not ready.
        let statusItem = NSMenuItem(title: "● \(appState.statusMessage)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        // Only show the model line while it's downloading / not yet installed.
        if appState.isModelDownloading || !appState.modelDownloadStatus.hasPrefix("Installed") {
            let modelStatus = NSMenuItem(title: "Model: \(appState.modelDownloadStatus)", action: nil, keyEquivalent: "")
            modelStatus.isEnabled = false
            menu.addItem(modelStatus)
        }
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

        // Quick mid-use toggles only. Engine, live-chunk plumbing, etc. live in
        // Settings → Advanced; the menu holds what you flip between dictations.
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

        // AI refinement: a clear on/off plus a provider/model submenu so users can
        // switch the AI backend — and experiment with built-in models — between
        // dictations without opening Settings.
        let aiCleanup = NSMenuItem(
            title: "Refine text with AI",
            action: #selector(toggleAICleanup),
            keyEquivalent: ""
        )
        aiCleanup.state = appState.openAIEnhancementEnabled ? .on : .off
        menu.addItem(aiCleanup)

        let aiMenu = NSMenu()

        // Provider chooser.
        for provider in aiProviderOptions {
            let item = NSMenuItem(title: provider.title, action: #selector(selectAIProvider), keyEquivalent: "")
            item.representedObject = provider.id
            item.state = appState.llmProvider == provider.id ? .on : .off
            aiMenu.addItem(item)
        }

        // Built-in model chooser (only relevant for the bundled provider). Shows
        // each swappable model with its size + a download/active marker so users
        // can compare models on the fly.
        let bundledModels = appState.bundledLLMModelsList()
        if !bundledModels.isEmpty {
            aiMenu.addItem(.separator())
            let header = NSMenuItem(title: "Built-in model", action: nil, keyEquivalent: "")
            header.isEnabled = false
            aiMenu.addItem(header)
            for model in bundledModels {
                let installed = appState.isBundledModelInstalled(model.id)
                let suffix = installed ? "" : "  ⤓ downloads on use"
                let item = NSMenuItem(
                    title: "  \(model.label) · \(model.size)\(suffix)",
                    action: #selector(selectBundledModel),
                    keyEquivalent: ""
                )
                item.representedObject = model.id
                // Check the active built-in model only while the bundled provider is on.
                item.state = (appState.llmProvider == "bundled" && appState.bundledLLMModel == model.id) ? .on : .off
                aiMenu.addItem(item)
            }
        }

        let aiMenuItem = NSMenuItem(title: "AI: \(aiProviderLabel)", action: nil, keyEquivalent: "")
        aiMenuItem.submenu = aiMenu
        menu.addItem(aiMenuItem)

        #if OPENWHISP_INSTRUMENTATION
        // Dev-only: toggle the debug HUD on the recording overlay.
        let debugOverlay = NSMenuItem(
            title: "Debug overlay (dev)",
            action: #selector(toggleDebugOverlay),
            keyEquivalent: ""
        )
        debugOverlay.state = appState.debugOverlayEnabled ? .on : .off
        menu.addItem(debugOverlay)
        #endif

        menu.addItem(.separator())

        // Settings
        let settings = NSMenuItem(title: "⚙ Settings", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settings)

        let setupGuide = NSMenuItem(title: "Setup Guide…", action: #selector(openSetupGuide), keyEquivalent: "")
        menu.addItem(setupGuide)

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
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        appState.language = code
    }
    @objc private func toggleAICleanup() {
        appState.openAIEnhancementEnabled.toggle()
    }
    @objc private func selectAIProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        appState.llmProvider = id
    }
    @objc private func selectBundledModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Picking a built-in model implies the built-in provider; switch to it so
        // the choice takes effect immediately (and downloads if needed).
        if appState.llmProvider != "bundled" { appState.llmProvider = "bundled" }
        appState.bundledLLMModel = id
    }
    #if OPENWHISP_INSTRUMENTATION
    @objc private func toggleDebugOverlay() {
        appState.debugOverlayEnabled.toggle()
    }
    #endif
    @objc private func terminate()      { NSApp.terminate(nil) }

    private var aiProviderOptions: [(id: String, title: String)] {
        [
            ("bundled", "Built-in (offline)"),
            ("openai", "OpenAI (cloud)"),
            ("local", "Local server")
        ]
    }

    /// Short label for the AI submenu title reflecting the active provider.
    private var aiProviderLabel: String {
        switch appState.llmProvider {
        case "bundled": return "Built-in"
        case "local":   return "Local server"
        default:        return "OpenAI"
        }
    }

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

    @objc private func openSetupGuide() {
        presentOnboarding()
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
        window.title = "OpenWhisp Settings"
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
        let delegate = OpenWhispApp()
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
