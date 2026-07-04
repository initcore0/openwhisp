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

        // Permission prompts: on FIRST run, let the onboarding wizard drive them
        // (it has guided microphone/accessibility steps). Firing the raw OS prompts
        // here at the same time is redundant and jarring on a brand-new Mac. On
        // subsequent launches, prompt eagerly as before (and the permission-banner
        // recheck handles any later revocation).
        if appState.didCompleteOnboarding {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            requestNotifications()
        }

        // Provision the model for the SELECTED engine only (WhisperKit by default) —
        // not an unconditional whisper.cpp download. The model download needs no
        // permissions, so it's fine to start before onboarding.
        appState.ensureSelectedEngineModel()

        // Agent Bridge (M8): start the local control-plane socket if enabled.
        appState.startAgentBridgeIfEnabled()

        // First-run onboarding
        showOnboardingIfNeeded()
        print("[OpenWhisp] Ready")
    }

    /// Re-check permissions whenever the app becomes active. This is what makes
    /// the missing-permission banner AUTO-CLEAR: the user grants the permission
    /// in System Settings, clicks back into OpenWhisp, and the live recheck
    /// removes the banner. It also catches revocations (e.g. after a reinstall,
    /// macOS silently drops the Accessibility grant) without re-running onboarding.
    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.refreshPermissionBanners()
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

        // Missing-permission affordance. OpenWhisp is a menu-bar app, so an
        // accessory-app activation may never fire while the user only uses the
        // status item — re-check here too, and surface a one-click deep link.
        appState.refreshPermissionBanners()
        for permission in appState.missingPermissionBanners {
            let item = NSMenuItem(
                title: "⚠️ \(permission.bannerTitle) — Open System Settings",
                action: #selector(openPermissionSettings),
                keyEquivalent: ""
            )
            item.representedObject = permission.rawValue
            menu.addItem(item)
        }

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
        // Settings; the menu holds what you flip between dictations.
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

        let languageItem = NSMenuItem(title: "Language: \(appState.languageDisplayName)", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        // Translate is its own switch now (split from the old "English —
        // translate to English" language overload). Whisper engines only.
        if appState.transcriptionEngine != "appleSpeech" {
            let translateItem = NSMenuItem(
                title: "Translate to English",
                action: #selector(toggleTranslateToEnglish),
                keyEquivalent: ""
            )
            translateItem.state = appState.translateToEnglish ? .on : .off
            menu.addItem(translateItem)
        }

        // AI refinement: ONE self-describing row that shows the live state
        // (on/off + which engine) and opens a small submenu. Model selection is
        // deliberately NOT here — it's a configure-once choice that lives in
        // Settings, reachable via "AI Settings…" below.
        let aiItem = NSMenuItem(title: aiMenuTitle, action: nil, keyEquivalent: "")
        aiItem.submenu = makeAIMenu()
        menu.addItem(aiItem)

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

    @objc private func openPermissionSettings(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let permission = PermissionBannerPolicy.Permission(rawValue: raw) else { return }
        appState.openSettings(for: permission)
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
    @objc private func toggleTranslateToEnglish() {
        appState.translateToEnglish.toggle()
    }
    @objc private func toggleAICleanup() {
        appState.openAIEnhancementEnabled.toggle()
    }
    @objc private func selectAIProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        appState.llmProvider = id
    }
    #if OPENWHISP_INSTRUMENTATION
    @objc private func toggleDebugOverlay() {
        appState.debugOverlayEnabled.toggle()
    }
    #endif
    @objc private func terminate()      { NSApp.terminate(nil) }

    // AI providers framed by OUTCOME / privacy posture rather than engine jargon,
    // so the choice is meaningful to non-technical users (and sells the privacy
    // story). The id values are unchanged (bundled/openai/local).
    private var aiProviderOptions: [(id: String, title: String)] {
        [
            ("bundled", "On-device (private)"),
            ("openai",  "OpenAI (leaves your Mac)"),
            ("local",   "Custom server (advanced)")
        ]
    }

    /// Short label for the active provider, used in the top-level AI row.
    private var aiProviderLabel: String {
        switch appState.llmProvider {
        case "bundled": return "On-device"
        case "local":   return "Custom server"
        default:        return "OpenAI"
        }
    }

    /// Self-describing top-level row: tells the user, at a glance, whether their
    /// next dictation gets cleaned up and by which engine.
    private var aiMenuTitle: String {
        guard let appState else { return "Refine with AI" }
        return appState.openAIEnhancementEnabled
            ? "Refine with AI: On — \(aiProviderLabel)"
            : "Refine with AI: Off"
    }

    /// The AI submenu: a single on/off toggle, the engine radio group framed by
    /// outcome, and a deep link to Settings for model/key/server config.
    private func makeAIMenu() -> NSMenu {
        let aiMenu = NSMenu()
        guard let appState else { return aiMenu }

        let toggle = NSMenuItem(title: "Refine my dictation", action: #selector(toggleAICleanup), keyEquivalent: "")
        toggle.state = appState.openAIEnhancementEnabled ? .on : .off
        aiMenu.addItem(toggle)

        aiMenu.addItem(.separator())
        for provider in aiProviderOptions {
            let item = NSMenuItem(title: provider.title, action: #selector(selectAIProvider), keyEquivalent: "")
            item.representedObject = provider.id
            item.state = appState.llmProvider == provider.id ? .on : .off
            // Engine choice is meaningless while refinement is off; show it but
            // disable it so the relationship (and the "off" state) is unambiguous.
            item.isEnabled = appState.openAIEnhancementEnabled
            aiMenu.addItem(item)
        }

        aiMenu.addItem(.separator())
        let aiSettings = NSMenuItem(title: "AI Settings…", action: #selector(openSettings), keyEquivalent: "")
        aiMenu.addItem(aiSettings)

        #if OPENWHISP_INSTRUMENTATION
        aiMenu.addItem(.separator())
        let debugOverlay = NSMenuItem(title: "Debug overlay (dev)", action: #selector(toggleDebugOverlay), keyEquivalent: "")
        debugOverlay.state = appState.debugOverlayEnabled ? .on : .off
        aiMenu.addItem(debugOverlay)
        #endif

        return aiMenu
    }

    private var languageOptions: [(code: String, title: String)] {
        [
            ("auto", "Auto Detect"),
            ("en", "English"),
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
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "OpenWhisp Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 540)
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
