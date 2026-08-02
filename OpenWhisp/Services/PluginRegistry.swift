import Foundation

/// The compile-time list of in-repo plugins (spike).
///
/// In-repo plugins live under `plugins/<id>/`, are reviewed and maintained in this
/// repository, and are compiled INTO the app. This registry is the single place that
/// knows they exist — the host asks it for manifests and never hardcodes a plugin id
/// anywhere else.
///
/// Why a compile-time list and not a loader: the app holds Accessibility, microphone,
/// and clipboard rights, so running third-party native code in-process would inherit
/// all of them (`docs/ROADMAP.md` §6 rejects SwiftPM/dylib plugins outright for this
/// reason). Compiling reviewed plugins in keeps the spike honest about what it is —
/// a UI/architecture prototype for the plugin *surface*, not a third-party code
/// distribution mechanism. The manifest schema is forward-compatible with an
/// out-of-process loader (`PluginEntryKind.externalProcess`), which is the likelier
/// real answer.
///
/// Manifests live here as literals rather than being parsed from
/// `plugins/<id>/manifest.json` at runtime. The JSON files are checked in as the
/// authored source of truth and as the schema example for external plugins, but a
/// built-in plugin must not be able to go missing because a resource didn't get
/// copied into the bundle. `PluginRegistryTests` asserts the two agree.
public enum PluginRegistry {

    /// Every plugin compiled into this build.
    ///
    /// The meme generator is the spike's first and only plugin. Adding a second one
    /// means adding a manifest here and a window in the host's `open` switch — the
    /// two places a built-in plugin is wired.
    public static let builtInManifests: [PluginManifest] = [
        memeGenerator
    ]

    /// The Meme Generator plugin (`plugins/MemeGenerator/`).
    ///
    /// Voice-first: dictate a description of the meme you want, and it picks a
    /// template, writes the captions, and renders them locally.
    public static let memeGenerator = PluginManifest(
        id: "meme-generator",
        name: "Meme Generator",
        version: "0.1.0",
        summary: "Dictate a meme description — the AI picks a template and writes the captions.",
        symbol: "photo.badge.plus",
        entry: .builtIn,
        // Template images are downloaded from imgflip's public, key-less catalog.
        // Captions are rendered locally, so no text ever leaves the Mac.
        networkHosts: ["api.imgflip.com", "i.imgflip.com"]
    )
}
