// swift-tools-version:6.0
import PackageDescription

// This package exists ONLY to unit-test OpenWhisp's pure-logic types
// (formatting, vocabulary, voice-command parsing, profiles). The GUI app itself
// is still built/bundled by build.sh + package.sh (SwiftPM can't produce a
// signed .app). `OpenWhispCore` includes just the Foundation-only Services files
// so they can be tested with `swift test` without pulling in AppKit/SwiftUI.
let package = Package(
    name: "OpenWhispCore",
    platforms: [.macOS(.v13), .iOS(.v18)],
    products: [
        // The agent-callable CLI + MCP stdio server. Built by `swift build
        // --product openwhisp` and bundled into the .app at Contents/Helpers by
        // package.sh; lives OUTSIDE OpenWhisp/ so build.sh's source glob (which
        // compiles the GUI app) never picks up its `main`.
        .executable(name: "openwhisp", targets: ["openwhisp"]),
        // Library products so the iOS companion app (openwhisp-ios) can consume
        // the Foundation-only core and the Agent Bridge wire as SwiftPM
        // dependencies. The mac app still builds via build.sh's swiftc glob and
        // never imports these products — they exist for the iOS consumer + CI.
        .library(name: "OpenWhispCore", targets: ["OpenWhispCore"]),
        .library(name: "OpenWhispBridgeKit", targets: ["OpenWhispBridgeKit"]),
    ],
    targets: [
        .target(
            name: "OpenWhispCore",
            path: "OpenWhisp/Services",
            sources: [
                "SmartFormatter.swift",
                "JSONStore.swift",
                "Vocabulary.swift",
                "CorrectionLearner.swift",
                "CorrectionProposal.swift",
                "EditDiff.swift",
                "LanguageResolver.swift",
                "ParakeetCatalog.swift",
                "ParakeetLanguageGate.swift",
                "ParakeetLanguageHint.swift",
                "ParakeetDownloadState.swift",
                "AgentEouAutoStop.swift",
                "StreamingRoutePolicy.swift",
                "SettingsResetDefaults.swift",
                "ProfileResolver.swift",
                "Mode.swift",
                "ModeResolver.swift",
                "MetaInstructionStripper.swift",
                "FileTagTransform.swift",
                "PostProcessor.swift",
                "AppProfile.swift",
                "AppleScriptInsert.swift",
                "MouseTrigger.swift",
                "TranscriptionHistory.swift",
                "AudioRetentionPolicy.swift",
                "CrashRecoveryState.swift",
                "SecureFieldPolicy.swift",
                "ScreenContext.swift",
                "DownloadProgressFormatter.swift",
                "PrivacyStatus.swift",
                "UpdatePreferences.swift",
                "TranscriptCleaner.swift",
                "SecretStore.swift",
                "LaunchAtLoginService.swift",
                "TextOutput.swift",
                "OutputTarget.swift",
                "OutputTargetResolver.swift",
                "FileOutputFormatter.swift",
                "WebhookRequest.swift",
                "ShortcutInvocation.swift",
                "HotkeyControlling.swift",
                "ActivationInteraction.swift",
                "TranscriptionEngine.swift",
                "AudioCapture.swift",
                "FileAudioCapture.swift",
                "AudioInputRoutingPolicy.swift",
                "OverlayPhase.swift",
                "LiveChunkPipeline.swift",
                "ConfigBundle.swift",
                "BridgeWire.swift",
                "BridgeRouter.swift",
                "URLScheme.swift",
                "Scratchpad.swift",
                "DictationSession.swift",
                "SilenceAutoStop.swift",
                "QuietDictationMode.swift",
                "AgentSetup.swift",
                "AgentClientStore.swift",
                "AgentRateLimiter.swift",
                "ConfigPack.swift",
                "ScriptPostProcessor.swift",
                "AgentCLIProvider.swift",
                "WhisperTask.swift",
                "InstructionChain.swift",
                "CleanupIntensity.swift",
                "RefineOutputGuard.swift",
                "VoiceEditCommand.swift",
                "RefineFlow.swift",
                "RefineKey.swift",
                "DictationTrigger.swift",
                "AudioLevel.swift",
                "FinalizingCaption.swift",
                "AsyncTimeout.swift",
                "SerialTaskChain.swift",
                "DictationStats.swift",
                "InsightsSummary.swift",
                "Instrumentation.swift",
                "VoiceIndicatorStyle.swift",
                "WhisperKitBridge.swift",
                "WhisperKitModelCatalog.swift",
                "PermissionBannerPolicy.swift",
                "OnboardingHotkeyGate.swift",
                "ModelStorage.swift",
                "SettingsMigration.swift",
                "RefineTap.swift",
                "ServerProcessIdentity.swift",
                "ServerLaunchRetry.swift",
                "ManagedServerSpec.swift",
                "WhisperResponseClassifier.swift",
                "FileTranscriptionQueue.swift",
                "Meeting.swift",
                "MeetingSessionStore.swift",
                "MeetingSummarizer.swift",
                "SummaryModelResolver.swift",
                "SubtitleFormatter.swift",
                "WatchFolderPolicy.swift",
                "Rules.swift",
                "RuleStore.swift",
                "TipsCatalog.swift",
                "HintRotation.swift",
                "MeetingRecording.swift",
                "MeetingMixer.swift",
                "MeetingTalkState.swift",
                "TranscriptInterleaver.swift",
                "MeetingOrphanScan.swift"
            ]
        ),
        // The Agent Bridge client + MCP stdio adapter. A library (not folded into
        // the executable) so its pure logic — the typed MCP wire and the
        // persistent-connection cache/retry — is unit-testable with `swift test`;
        // the `openwhisp` executable is a thin `main` on top.
        .target(
            name: "OpenWhispBridgeKit",
            dependencies: ["OpenWhispCore"],
            path: "Sources/OpenWhispBridgeKit"
        ),
        .executableTarget(
            name: "openwhisp",
            dependencies: ["OpenWhispCore", "OpenWhispBridgeKit"],
            path: "Sources/OpenWhispCLI"
        ),
        .testTarget(
            name: "OpenWhispCoreTests",
            dependencies: ["OpenWhispCore"],
            path: "Tests/OpenWhispCoreTests"
        ),
        .testTarget(
            name: "OpenWhispBridgeKitTests",
            dependencies: ["OpenWhispBridgeKit", "OpenWhispCore"],
            path: "Tests/OpenWhispBridgeKitTests"
        )
    ],
    // Tools-version was bumped to 6.0 solely to declare `.iOS(.v18)` (a
    // PackageDescription 6.0 API). Pin the Swift language mode to 5 so the bump
    // introduces ZERO behavior change: no strict-concurrency regressions in the
    // existing sources or `swift test`. The mac app is built by build.sh's raw
    // swiftc glob and is unaffected by this file regardless.
    swiftLanguageModes: [.v5]
)
