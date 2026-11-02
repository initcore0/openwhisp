// swift-tools-version:6.0
// (6.0 is required for `.macOS(.v15)` — `.v15` is only available in
// PackageDescription 6.0+. The repo's toolchain floor is already Xcode 16 /
// Swift 6 tools, so this costs nothing; see CLAUDE.md.)
import PackageDescription

// Helper package whose ONLY purpose is to resolve + build WhisperKit so the
// app's raw-swiftc build (build.sh WHISPERKIT=1) can link it. The app itself is
// NOT a SwiftPM target (it's compiled by build.sh); this just produces the
// WhisperKit module + static libs under .build. See docs/WHISPERKIT_PILOT.md.
let package = Package(
    name: "WhisperKitDep",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WhisperKitDep", type: .static, targets: ["WhisperKitDep"])
    ],
    dependencies: [
        // Upstream WhisperKit (argmaxinc renamed the repo to `argmax-oss-swift`).
        // v1.1.1 ships upstream PR #503 (inputDeviceID passthrough on
        // AudioStreamTranscriber), which is what our former fork
        // (initcore0/argmax-oss-swift, v1.0.0 + that one patch) backported — so the
        // fork is retired. Pinned exact: bump deliberately and re-run
        // scripts/e2e-whisperkit.sh. macOS 26 model loading is still handled
        // app-side via `modelFolder` + a GPU audio encoder (see
        // docs/WHISPERKIT_PILOT.md).
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            exact: "1.1.1"
        )
    ],
    targets: [
        .target(
            name: "WhisperKitDep",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        )
    ]
)
