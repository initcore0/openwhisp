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
    var tipsWindow: NSWindow?
    var appState: AppState!
    /// EXPERIMENTAL translation-preview panel (display-only). Retained for the
    /// app's lifetime; it shows/hides itself from AppState's published state.
    var translationPreview: TranslationPreviewController?

    /// Meeting-mode capture session (MAK-50), lazily created on Start Meeting.
    /// Held as `Any?` so this file compiles on the macOS 12 SDK path too; cast
    /// to `MeetingCaptureSession` at the `@available(macOS 13.0, *)` use sites.
    private var meetingSession: Any?
    private var meetingActive = false
    /// MAK-52: polls the capture session's per-leg live levels a few times a second
    /// to drive the "who's talking" indicator (pane row + menu-title glyph).
    private var meetingTalkTimer: Timer?

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

        // Stream overlay (live subtitles for OBS/Twitch): start the loopback
        // caption server if enabled.
        appState.streamOverlay.startIfEnabled()

        // EXPERIMENTAL live translation preview: translates the live partial
        // transcript while you speak and feeds it into the MAIN overlay's
        // transcript panel (source as one dimmed line, translation as the
        // body). Owned here (not by AppState — MAK-32 LOC ratchet); it
        // subscribes to AppState's published transcript/session flags and arms
        // only when its opt-in is on AND the text-translation path arms.
        translationPreview = TranslationPreviewController(appState: appState)

        // Sparkle auto-update (MAK-56): start the updater. Touching `.shared`
        // constructs the SPUStandardUpdaterController and begins the scheduled
        // check cycle (honoring the user's persisted auto-check preference). On a
        // SPARKLE=0 lean build this is a no-op stand-in. The updater only makes a
        // network call to fetch the appcast — see docs/AUTO_UPDATE.md.
        _ = UpdaterManager.shared

        // Meeting mode (MAK-50): salvage any recording orphaned by a crash/quit
        // mid-meeting — patch its placeholder WAV header and ingest it so the
        // meeting shows up in the pane instead of silently rotting on disk.
        if #available(macOS 13.0, *) {
            let orphans = MeetingCaptureSession.recoverOrphanedRecordings()
            for recording in orphans {
                appState.meetingCoordinator.ingest(recording)
            }
            if !orphans.isEmpty {
                appState.statusMessage = "Recovered \(orphans.count) interrupted meeting recording\(orphans.count == 1 ? "" : "s")"
            }
        }

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

    /// `openwhisp://` URL scheme entry point (Raycast / Alfred / `open` launcher
    /// control surface, MAK-37). AppKit routes `open openwhisp://…` here once the
    /// scheme is declared in Info.plist's CFBundleURLTypes. Parsing/validation +
    /// the verb allow-list live in the pure `URLScheme` core type; this just hands
    /// the URLs to the executor, which reuses existing AppState actions.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let appState else { return }
        URLSchemeHandler.handle(urls: urls, appState: appState)
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

    /// Build a menu row with an SF Symbol in the icon gutter.
    ///
    /// **Every actionable row gets one.** That's what macOS itself does today:
    /// Finder's File menu puts a monochrome symbol on essentially every item, on
    /// the OS we build against and ship to. A menu with symbols on a favored few
    /// doesn't read as restraint, it reads as broken — which is the complaint
    /// that started this.
    ///
    /// A previous pass cut symbols back to the pickers alone, reasoning from the
    /// HIG's "don't include them for every menu item" plus a report that macOS 27
    /// hides menu-item images by default behind `NSMenuItem.preferredImageVisibility`.
    /// That API doesn't exist in the 26.5 SDK, so the claim couldn't be checked —
    /// and it lost to what Apple's shipping menus actually do here and now. If a
    /// future OS does suppress menu images, this degrades to plain text, which is
    /// exactly where cutting them lands us anyway. There's no downside worth
    /// paying up front.
    ///
    /// `symbol` stays optional for rows where no glyph honestly fits — better
    /// nothing than a misleading one (the HIG's real point).
    ///
    /// What this permanently replaces is unambiguous either way: the emoji this
    /// menu used to inline into its titles (`📋`, `🔴`, `📝`, `⚠️`, `●`, `⚙`).
    /// Those are text, so they dodge the system's image controls entirely, render
    /// as color glyphs that ignore menu tinting and dark mode, sit off the icon
    /// gutter, and get read aloud by VoiceOver ("memo emoji Scratchpad").
    private func menuItem(
        _ title: String,
        symbol: String? = nil,
        action: Selector?,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    @objc private func showMenu() {
        guard let appState, let btn = statusItem.button else { return }

        let menu = NSMenu()

        // Status (single line). Health details only surface when not ready.
        // `nil` action = disabled, which is also what dims it — no bullet glyph
        // needed to signal "this is a label, not a command".
        let status = NSMenuItem(title: appState.statusMessage, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        // Missing-permission affordance. OpenWhisp is a menu-bar app, so an
        // accessory-app activation may never fire while the user only uses the
        // status item — re-check here too, and surface a one-click deep link.
        appState.refreshPermissionBanners()
        for permission in appState.missingPermissionBanners {
            let item = menuItem(
                "\(permission.bannerTitle) — Open System Settings",
                symbol: "exclamationmark.triangle",
                action: #selector(openPermissionSettings)
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
            menu.addItem(menuItem("Copy \"\(display)\"",
                                  symbol: "doc.on.doc",
                                  action: #selector(copyLast),
                                  keyEquivalent: "c"))
            menu.addItem(.separator())
        }

        // Recording actions
        if appState.isRecording {
            menu.addItem(menuItem("Stop Dictation", symbol: "stop.fill", action: #selector(stopDictation)))
            menu.addItem(menuItem("Cancel Dictation", symbol: "xmark.circle", action: #selector(cancelDictation)))
        } else {
            menu.addItem(menuItem("Start Dictation", symbol: "mic.fill", action: #selector(startDictation)))
        }

        // Meeting mode (MAK-50): record system audio + mic locally. A meeting and
        // a dictation share the mic, so the two are mutually exclusive — the item
        // is disabled while dictating, and starting a meeting refuses if dictation
        // becomes active. macOS 13+ only (ScreenCaptureKit audio capture).
        if #available(macOS 13.0, *) {
            if meetingActive {
                menu.addItem(menuItem("Stop Meeting", symbol: "stop.circle", action: #selector(stopMeeting)))
            } else {
                let startMeeting = menuItem("Start Meeting", symbol: "record.circle", action: #selector(startMeeting))
                if appState.isRecording {
                    startMeeting.action = nil   // disabled while dictating
                    startMeeting.toolTip = "Stop dictation before starting a meeting."
                }
                menu.addItem(startMeeting)
            }
        }

        // Floating Scratchpad (MAK-49): a target-free surface to dictate into.
        menu.addItem(menuItem("Scratchpad", symbol: "note.text", action: #selector(openScratchpad), keyEquivalent: "s"))

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

        let languageItem = menuItem("Language: \(appState.languageDisplayName)", symbol: "globe", action: nil)
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        // Translate is its own switch now (split from the old "English —
        // translate to English" language overload).
        //
        // The on-device text path covers EVERY engine now, so with the macOS 15
        // floor this is effectively always offered — `appState.translationOffered`,
        // the SAME predicate the Dictation pane reads, so the two surfaces can't
        // disagree (a past bug). The dim branch survives only for the
        // should-be-impossible case of no on-device translator: macOS menus dim
        // unavailable commands rather than hiding them, so the capability stays
        // discoverable instead of looking like a bug (#175 history).
        let canTranslate = appState.translationOffered
        let translateItem = menuItem(
            canTranslate ? "Translate to English" : "Translate to English (unavailable)",
            symbol: "character.bubble",
            action: canTranslate ? #selector(toggleTranslateToEnglish) : nil
        )
        translateItem.state = (canTranslate && appState.translateToEnglish) ? .on : .off
        if !canTranslate {
            translateItem.toolTip = "On-device text translation isn't available on this Mac."
        }
        menu.addItem(translateItem)

        // AI refinement: ONE self-describing row that shows the live state
        // (on/off + which engine) and opens a small submenu. Model selection is
        // deliberately NOT here — it's a configure-once choice that lives in
        // Settings, reachable via "AI Settings…" below.
        let aiItem = menuItem(aiMenuTitle, symbol: "sparkles", action: nil)
        aiItem.submenu = makeAIMenu()
        menu.addItem(aiItem)

        menu.addItem(.separator())

        // Settings
        menu.addItem(menuItem("Settings…", symbol: "gearshape", action: #selector(openSettings), keyEquivalent: ","))

        // Help: two rarely-used, configure-once destinations. They belong in the
        // menu (discoverability) but not at the top level competing with the
        // things you flip between dictations.
        let helpMenu = NSMenu()
        helpMenu.addItem(menuItem("Setup Guide…", symbol: "checklist", action: #selector(openSetupGuide)))
        // Discoverability (MAK-25): a cheat sheet of gestures, spoken commands, and
        // features — sourced from what actually ships (TipsCatalog).
        helpMenu.addItem(menuItem("Tips & Commands…", symbol: "lightbulb", action: #selector(openTips)))
        let helpItem = menuItem("Help", symbol: "questionmark.circle", action: nil)
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)

        menu.addItem(.separator())

        // Quit
        menu.addItem(menuItem("Quit OpenWhisp", symbol: "power", action: #selector(terminate), keyEquivalent: "q"))

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

    // MARK: Meeting mode (MAK-50)

    @available(macOS 13.0, *)
    @objc private func startMeeting() {
        // Mic exclusivity: refuse to start a meeting while dictating.
        guard !appState.isRecording else {
            appState.statusMessage = "Stop dictation before starting a meeting"
            return
        }
        guard !meetingActive else { return }
        // Claim exclusivity NOW, not on `.recording`: SCK startup takes seconds,
        // and during that window (a) a second Start Meeting click would replace
        // `meetingSession` and orphan the first capture — live, invisible, and
        // unstoppable (the identity guard below discards its `.recording`), and
        // (b) the dictation hotkey would pass the `meetingInProgress` gate and
        // tap the mic the meeting's mic leg already owns. Both flags are cleared
        // by `.finished`/`.failed` — including the failure a stop-during-startup
        // now surfaces (see MeetingCaptureSession.stop).
        meetingActive = true
        appState.meetingInProgress = true
        // Always a FRESH session: MeetingCaptureSession's state machine is one-shot
        // (idle → recording → finished/failed, `delivered` never resets), so reusing
        // a finished session would make `start()` a silent no-op — the second
        // meeting would never record.
        let session = MeetingCaptureSession()
        meetingSession = session
        session.onStateChanged = { [weak self, weak session] state in
            guard let self else { return }
            // Ignore late callbacks from a superseded session (e.g. a salvage
            // `.failed` arriving after the user already started a new meeting) so
            // they can't clear the NEW meeting's exclusivity flag.
            guard let session, (self.meetingSession as? MeetingCaptureSession) === session else { return }
            switch state {
            case .recording:
                self.meetingActive = true
                self.appState.meetingInProgress = true   // block dictation while recording
                self.appState.statusMessage = "Meeting recording…"
                self.startMeetingTalkTimer(session: session)
            case .finished:
                self.meetingActive = false
                self.appState.meetingInProgress = false
                self.stopMeetingTalkTimer()
            case .failed(let msg):
                self.meetingActive = false
                self.appState.meetingInProgress = false
                self.stopMeetingTalkTimer()
                // A start/preflight failure never delivers onFinished — clear the
                // optimistic live row so it doesn't linger.
                self.appState.meetingCoordinator.endRecording()
                self.appState.statusMessage = msg
            case .idle:
                break
            }
        }
        // Mint the id up front and open the live row in the Meetings pane under that
        // SAME id; thread it into capture so the finished MeetingRecording carries it
        // and `ingest` turns the live row into the real row.
        let id = UUID()
        let startedAt = Date()
        appState.meetingCoordinator.beginRecording(id: id, startedAt: startedAt)
        // Deliver the finished recording straight into the pipeline — a single,
        // direct ingest path (no NotificationCenter hop, no double-ingest).
        session.onFinished = { [weak self] recording in
            guard let self else { return }
            self.appState.meetingCoordinator.ingest(recording)   // clears the live row + kicks off transcription
            self.appState.statusMessage = "Meeting saved (\(Int(recording.duration))s)"
        }
        session.start(id: id, startedAt: startedAt)
    }

    @available(macOS 13.0, *)
    @objc private func stopMeeting() {
        guard let session = meetingSession as? MeetingCaptureSession else { return }
        // Stop → finalize → the onFinished wired at start ingests exactly once.
        session.stop()
        meetingActive = false
        stopMeetingTalkTimer()
    }

    // MARK: MAK-52 live talking indicator

    @available(macOS 13.0, *)
    private func startMeetingTalkTimer(session: MeetingCaptureSession) {
        stopMeetingTalkTimer()
        // 5 Hz is plenty for a coarse indicator and negligible cost; the resolver's
        // hysteresis (MeetingTalkState) keeps the label from flickering.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.appState.meetingCoordinator.updateTalkState(
                micLevel: session.micLevel, systemLevel: session.systemLevel
            )
            self.refreshMeetingMenuGlyph()
        }
        RunLoop.main.add(timer, forMode: .common)
        meetingTalkTimer = timer
    }

    private func stopMeetingTalkTimer() {
        meetingTalkTimer?.invalidate()
        meetingTalkTimer = nil
        refreshMeetingMenuGlyph()
    }

    /// Reflect the current talk state as a cheap status-item title glyph while a
    /// meeting records; cleared when idle.
    private func refreshMeetingMenuGlyph() {
        guard let button = statusItem?.button else { return }
        if meetingActive {
            button.title = appState.meetingCoordinator.talkState.glyph
        } else if button.title != "" {
            button.title = ""
        }
    }

    @objc private func openScratchpad() { appState.openScratchpad() }
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
        aiMenu.addItem(menuItem("AI Settings…", symbol: "gearshape", action: #selector(openSettings)))

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

    /// "Tips & Commands…" — a cheat-sheet window of the gestures, spoken commands,
    /// and features that actually ship (content is the pure `TipsCatalog`).
    @objc private func openTips() {
        if let tipsWindow {
            tipsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: TipsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Tips & Commands"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 420)
        window.contentViewController = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        tipsWindow = window
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
