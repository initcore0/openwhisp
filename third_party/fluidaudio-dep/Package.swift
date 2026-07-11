// swift-tools-version:5.10
import PackageDescription

// Helper package whose ONLY purpose is to resolve + build FluidAudio (the
// Parakeet/CoreML ASR SDK) so the app's raw-swiftc build (build.sh PARAKEET=1)
// can link it. The app itself is NOT a SwiftPM target (it's compiled by
// build.sh); this just produces the FluidAudio module + static libs under
// .build. Mirrors third_party/whisperkit-dep. See docs/PARAKEET_SPIKE.md.
let package = Package(
    name: "FluidAudioDep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FluidAudioDep", type: .static, targets: ["FluidAudioDep"])
    ],
    dependencies: [
        // Pinned exact: FluidAudio is pre-1.0 and its streaming API surface has
        // churned across minors (0.14 → 0.15). Bump deliberately, re-testing the
        // StreamingAsrManager surface each time.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .target(
            name: "FluidAudioDep",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
