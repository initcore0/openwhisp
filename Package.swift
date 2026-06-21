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
    targets: [
        .target(
            name: "OpenWhispCore",
            path: "OpenWhisp/Services",
            sources: [
                "SmartFormatter.swift",
                "Vocabulary.swift",
                "VoiceCommandParser.swift",
                "MetaInstructionStripper.swift",
                "PostProcessor.swift",
                "AppProfile.swift",
                "TranscriptionHistory.swift"
            ]
        ),
        .testTarget(
            name: "OpenWhispCoreTests",
            dependencies: ["OpenWhispCore"],
            path: "Tests/OpenWhispCoreTests"
        )
    ]
)
