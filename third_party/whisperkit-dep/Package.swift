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
        // Pinned to OUR fork of WhisperKit (argmaxinc renamed the repo to
        // `argmax-oss-swift`), at the v1.0.0 release + a single-file backport of
        // upstream PR #503 (inputDeviceID passthrough on AudioStreamTranscriber) so
        // streaming/live capture can target a selected input device. We fork rather
        // than pin the contributor's branch because that branch also carries ~60
        // files of divergent macOS-26 CoreML/ANE churn; our branch is v1.0.0 + ONLY
        // that patch. Pinned by exact commit (immutable) — bump to an upstream
        // release once #503 lands there, then drop the fork. macOS 26 model loading
        // is still handled app-side via `modelFolder` + a GPU audio encoder (see
        // docs/WHISPERKIT_PILOT.md).
        //
        // Fork branch: openwhisp/v1.0.0-input-device (initcore0/argmax-oss-swift).
        .package(
            url: "https://github.com/initcore0/argmax-oss-swift.git",
            revision: "7e5f648249fde3eeabab02250529f63f16476e91"
        )
    ],
    targets: [
        .target(
            name: "WhisperKitDep",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        )
    ]
)
