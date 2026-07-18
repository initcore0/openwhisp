// swift-tools-version:6.0
import PackageDescription

// ─────────────────────────────────────────────────────────────────────────────
// DEV-ONLY manifest for the mac app target (MAK-65).
//
// WHY THIS EXISTS
// The release/CI build stays build.sh's raw `swiftc` glob (+ package.sh for the
// signed .app). SwiftPM can't produce a signed bundle, and the engine link-args
// (WhisperKit / FluidAudio / Sparkle) are resolved dynamically by the
// scripts/*-link-args.sh helpers, which a static manifest can't run.
//
// What this manifest adds is what build.sh can't: incremental compilation and
// full SourceKit-LSP / Xcode support over the WHOLE app module — AppState, the
// 41 app-only services, and every SwiftUI view — the exact files the root
// Package.swift's OpenWhispCore test target deliberately excludes.
//
// It compiles the app in the LEAN configuration (stub engines, no Sparkle): the
// same seam CI's `build mac app (lean)` job uses via `WHISPERKIT=0 PARAKEET=0`.
// Lean mode needs ZERO dynamic link-args — the whole app source glob builds as a
// single module against nothing but system frameworks, so there are no
// unsafeFlags carrying build-machine paths and no plugin.
//
// WHY A SEPARATE MANIFEST (not the root Package.swift)
// The root manifest ships OpenWhispCore + OpenWhispBridgeKit as LIBRARY PRODUCTS
// consumed remotely by the iOS companion (openwhisp-ios). `.unsafeFlags`
// ANYWHERE in a package makes that whole package non-consumable as a remote
// dependency — it would break the `ios-libraries` CI job and the iPhone app.
// Isolating the app target in its own dev-only package keeps the root manifest
// clean and untouched.
//
// LAYOUT
// SwiftPM forbids target paths that escape the package root, so the app's
// sources are symlinked into Sources/OpenWhispApp/ (AppMain.swift + Models/ +
// Services/ + Views/ point back at ../../../OpenWhisp/...). `swift build` here
// compiles the SAME files build.sh globs — one module, byte-for-byte the same
// sources. BuildInfo.swift is generated into this dir by scripts/dev-app.sh
// (gitignored); it is NOT written into ../OpenWhisp so build.sh's own glob never
// picks up a duplicate.
//
// NOT a release path. Do not wire this package into CI as the app builder; the
// byte-compatible release output stays with build.sh / package.sh.
// ─────────────────────────────────────────────────────────────────────────────
let package = Package(
    name: "OpenWhispApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenWhispApp",
            path: "Sources/OpenWhispApp",
            // The whole app is ONE module (build.sh compiles it as a single
            // swiftc glob). The three sync files (AgentBridgeHost / SyncBridgeHost
            // / LANBridgeServer) carry `#if canImport(OpenWhispCore)` guards that
            // no-op here exactly as they do under build.sh, since this module
            // doesn't depend on OpenWhispCore.
            swiftSettings: [
                // build.sh uses -parse-as-library (the @main entry lives in
                // AppMain.swift, not a top-level main.swift). Match it so the
                // dev build resolves the entry point the same way.
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
