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
                "CorrectionConfidence.swift",
                "CorrectionLearningPipeline.swift",
                "SecretTokenGuard.swift",
                "EditDiff.swift",
                "LanguageResolver.swift",
                "EngineCapabilities.swift",
                "TextTranslationPolicy.swift",
                "TranslationPreviewPolicy.swift",
                "EnginePurposeRouter.swift",
                "ParakeetCatalog.swift",
                "ParakeetLanguageGate.swift",
                "ParakeetLanguageHint.swift",
                "ParakeetVocabularyPrompt.swift",
                "ParakeetTailHallucination.swift",
                "AgentContextVocabulary.swift",
                "ParakeetDownloadState.swift",
                "AgentEouAutoStop.swift",
                "StreamingRoutePolicy.swift",
                "SpeechAnalyzerAvailability.swift",
                "SpeechAnalyzerContextualStrings.swift",
                "SettingsResetDefaults.swift",
                "ProfileResolver.swift",
                "Mode.swift",
                "ModeResolver.swift",
                "MetaInstructionStripper.swift",
                "FileTagTransform.swift",
                "PostProcessor.swift",
                "AppProfile.swift",
                "RefinePreset.swift",
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
                "CaptureConfigChangePolicy.swift",
                "OverlayPhase.swift",
                "EngineReadiness.swift",
                "LiveChunkPipeline.swift",
                "ConfigBundle.swift",
                "BridgeWire.swift",
                "BridgeRouter.swift",
                "SyncMerge.swift",
                "LANPairing.swift",
                "URLScheme.swift",
                "Scratchpad.swift",
                "ScratchpadText.swift",
                "ScratchpadPersistencePolicy.swift",
                "MarkdownPreviewRenderer.swift",
                "ScratchpadExport.swift",
                "ScratchpadTags.swift",
                "ScratchpadFilter.swift",
                "MeetingScratchpadExport.swift",
                "FileTranscriptScratchpadExport.swift",
                "ScratchpadAI.swift",
                "ScratchpadAISession.swift",
                "DictationSession.swift",
                "AgentSessionFinish.swift",
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
                "WhisperModelPaths.swift",
                "PermissionBannerPolicy.swift",
                "OnboardingHotkeyGate.swift",
                "OnboardingModelStatus.swift",
                "ModelStorage.swift",
                "SettingsMigration.swift",
                "RefineTap.swift",
                "ServerProcessIdentity.swift",
                "ServerLaunchRetry.swift",
                "ManagedServerSpec.swift",
                "LoopbackPortRanges.swift",
                "WhisperResponseClassifier.swift",
                "FileTranscriptionQueue.swift",
                "Meeting.swift",
                "MeetingSessionStore.swift",
                "MeetingSummarizer.swift",
                "SummaryModelResolver.swift",
                "SubtitleFormatter.swift",
                "WatchFolderPolicy.swift",
                "TranscribeFileRequest.swift",
                "Rules.swift",
                "RuleStore.swift",
                "TipsCatalog.swift",
                "HintRotation.swift",
                "MeetingRecording.swift",
                "MeetingMixer.swift",
                "MeetingTalkState.swift",
                "TranscriptInterleaver.swift",
                "MeetingOrphanScan.swift",
                "StreamOverlay.swift",
                "StreamIngest.swift",
                // Plugin system spike (spike/plugin-system) + the in-repo meme plugin's
                // pure rules. Sources live under plugins/MemeGenerator/ for the app-layer
                // UI; the testable logic sits here so `swift test` covers it.
                "PluginManifest.swift",
                "PluginDiscovery.swift",
                "PluginEnablement.swift",
                "PluginRegistry.swift",
                "MemeAI.swift",
                "MemeTemplateMatcher.swift",
                "MemeCaptionLayout.swift",
                "MemeTemplateProvider.swift",
                "MemeUserLibrary.swift",
                "MemeGenerationState.swift",
                "MemeCatalogCache.swift",
                "LLMWarmReadiness.swift"
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
        // The app-side LAN sync transport + host as a testable library (MAK-51
        // WP6). These are Foundation/Network-only app-glob files (NOT part of
        // OpenWhispCore); compiling them as their own module lets the E2E test
        // @testable-import a real LANBridgeServer and drive it over TLS-TCP, and
        // lets the loopback harness executable link them. The mac app still
        // compiles the SAME source files via build.sh's swiftc glob (the
        // `#if canImport(OpenWhispCore)` guard makes the core import a no-op there).
        // macOS-only (Network.framework + the mac transport).
        .target(
            name: "OpenWhispSyncLAN",
            dependencies: ["OpenWhispCore"],
            path: "OpenWhisp",
            sources: [
                "Services/AgentBridgeHost.swift",
                "Services/SyncBridgeHost.swift",
                "Services/LANBridgeServer.swift",
                "Services/StreamOverlayServer.swift",
                "Services/StreamAudioIngestServer.swift",
                "SyncLoopback/Runtime.swift",
            ]
        ),
        // Standalone boot of the REAL LANBridgeServer for cross-repo sync
        // integration (the openwhisp-ios test drives it over TLS-TCP). Thin `main`
        // over OpenWhispSyncLAN. See scripts/sync-loopback-server.sh.
        .executableTarget(
            name: "openwhisp-sync-loopback",
            dependencies: ["OpenWhispCore", "OpenWhispSyncLAN"],
            path: "OpenWhisp",
            sources: ["SyncLoopback/main.swift"]
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
        ),
        // The LAN sync E2E: starts a REAL LANBridgeServer on 127.0.0.1 with a
        // fixed PSK against temp stores and drives a real TLS-TCP NDJSON client
        // through hello -> consent -> manifest -> push -> pull (MAK-51 WP6).
        .testTarget(
            name: "OpenWhispSyncLANTests",
            dependencies: ["OpenWhispSyncLAN", "OpenWhispCore"],
            path: "Tests/OpenWhispSyncLANTests"
        )
    ],
    // Tools-version was bumped to 6.0 solely to declare `.iOS(.v18)` (a
    // PackageDescription 6.0 API). Pin the Swift language mode to 5 so the bump
    // introduces ZERO behavior change: no strict-concurrency regressions in the
    // existing sources or `swift test`. The mac app is built by build.sh's raw
    // swiftc glob and is unaffected by this file regardless.
    swiftLanguageModes: [.v5]
)
