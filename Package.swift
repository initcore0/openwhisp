// swift-tools-version:5.9
import PackageDescription

// This package exists ONLY to unit-test VoiceNote's pure-logic types
// (formatting, vocabulary, voice-command parsing, profiles). The GUI app itself
// is still built/bundled by build.sh + package.sh (SwiftPM can't produce a
// signed .app). `VoiceNoteCore` includes just the Foundation-only Services files
// so they can be tested with `swift test` without pulling in AppKit/SwiftUI.
let package = Package(
    name: "VoiceNoteCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "VoiceNoteCore",
            path: "VoiceNote/Services",
            sources: [
                "SmartFormatter.swift",
                "Vocabulary.swift",
                "VoiceCommandParser.swift",
                "PostProcessor.swift",
                "AppProfile.swift",
                "TranscriptionHistory.swift"
            ]
        ),
        .testTarget(
            name: "VoiceNoteCoreTests",
            dependencies: ["VoiceNoteCore"],
            path: "Tests/VoiceNoteCoreTests"
        )
    ]
)
