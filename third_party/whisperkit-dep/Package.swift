// swift-tools-version:5.9
import PackageDescription

// Helper package whose ONLY purpose is to resolve + build WhisperKit so the
// app's raw-swiftc build (build.sh WHISPERKIT=1) can link it. The app itself is
// NOT a SwiftPM target (it's compiled by build.sh); this just produces the
// WhisperKit module + static libs under .build. See docs/WHISPERKIT_PILOT.md.
let package = Package(
    name: "WhisperKitDep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WhisperKitDep", type: .static, targets: ["WhisperKitDep"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "WhisperKitDep",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]
        )
    ]
)
