// swift-tools-version:5.9
import PackageDescription

// This package exists ONLY to unit-test OpenWhisp's pure-logic types
// (formatting, vocabulary, voice-command parsing, profiles). The GUI app itself
// is still built/bundled by build.sh + package.sh (SwiftPM can't produce a
// signed .app). `OpenWhispCore` includes just the Foundation-only Services files
// so they can be tested with `swift test` without pulling in AppKit/SwiftUI.
let package = Package(
    name: "OpenWhispCore",
    platforms: [.macOS(.v13)],
    products: [
        // The agent-callable CLI + MCP stdio server. Built by `swift build
        // --product openwhisp` and bundled into the .app at Contents/Helpers by
        // package.sh; lives OUTSIDE OpenWhisp/ so build.sh's source glob (which
        // compiles the GUI app) never picks up its `main`.
        .executable(name: "openwhisp", targets: ["openwhisp"]),
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
                "DictationSession.swift",
                "SilenceAutoStop.swift",
                "AgentSetup.swift",
                "AgentClientStore.swift",
                "AgentRateLimiter.swift",
                "ConfigPack.swift",
                "ScriptPostProcessor.swift",
                "AgentCLIProvider.swift",
                "WhisperTask.swift",
                "InstructionChain.swift",
                "CleanupIntensity.swift",
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
                "WhisperResponseClassifier.swift",
                "FileTranscriptionQueue.swift",
                "SubtitleFormatter.swift",
                "WatchFolderPolicy.swift",
                "TipsCatalog.swift",
                "HintRotation.swift"
            ]
        ),
        .executableTarget(
            name: "openwhisp",
            dependencies: ["OpenWhispCore"],
            path: "Sources/OpenWhispCLI"
        ),
        .testTarget(
            name: "OpenWhispCoreTests",
            dependencies: ["OpenWhispCore"],
            path: "Tests/OpenWhispCoreTests"
        )
    ]
)
