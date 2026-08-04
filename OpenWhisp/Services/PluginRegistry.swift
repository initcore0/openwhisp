import Foundation

/// The compile-time list of in-repo plugins (docs/PLUGINS.md).
///
/// In-repo plugins live under `plugins/<id>/`, are reviewed and maintained in this
/// repository, and are compiled INTO the app. This registry is the single place that
/// knows they exist — the host asks it for manifests and never hardcodes a plugin id
/// anywhere else.
///
/// Why a compile-time list and not a loader: the app holds Accessibility, microphone,
/// and clipboard rights, so running third-party native code in-process would inherit
/// all of them (`docs/ROADMAP.md` §6 rejects SwiftPM/dylib plugins outright for this
/// reason). Compiling reviewed plugins in makes the trust model exactly as strong as
/// code review, and no stronger — which is honest, because that is all it is today.
/// Installing a plugin without a rebuild is the shipping requirement, and the route
/// to it is docs/PLUGINS.md 'Path to hot-swappable': manifest-driven plugins first,
/// then out-of-process executables, reusing the helper-binary and local-socket
/// precedents the app already ships. The manifest schema is forward-compatible with an
/// out-of-process loader (`PluginEntryKind.externalProcess`), which is the likelier
/// real answer.
///
/// Manifests live here as literals rather than being parsed from
/// `plugins/<id>/manifest.json` at runtime. The JSON files are checked in as the
/// authored source of truth and as the schema example for external plugins, but a
/// built-in plugin must not be able to go missing because a resource didn't get
/// copied into the bundle. `PluginSystemTests` asserts the two agree.
public enum PluginRegistry {

    /// Every plugin compiled into this build.
    ///
    /// The meme generator is the first plugin. Adding a second one
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
        version: "0.5.0",
        summary: "Dictate a meme description — the AI picks a template and writes the captions.",
        symbol: "photo.badge.plus",
        entry: .builtIn,
        // Template images are downloaded from two public, key-less catalogs. Captions
        // are rendered LOCALLY, so no text ever leaves the Mac — note memegen.link
        // also offers server-side captioning by URL and this plugin deliberately does
        // not use it. Templates the user imports themselves need no network at all.
        networkHosts: [
            "api.imgflip.com", "i.imgflip.com", "api.memegen.link",
        ],
        // ⌘M opens the window from the menu bar, the way ⌘S opens the Scratchpad.
        // Declared here rather than hardcoded in `AppMain` so a second plugin needs no
        // host change — the host resolves collisions (`PluginKeyEquivalent`).
        keyEquivalent: "m",
        // v10: the spoken phrases that route a REFINE instruction here instead of to
        // the refine LLM (MAK-100 trigger layer). Declared on the manifest — the
        // refine pipeline asks `PluginVoiceCommandRouter`, which knows only about
        // manifests, so a second plugin gains voice commands without a host change.
        //
        // English + Russian because the owner dictates in both. Kept to the natural
        // imperative openings for "make me a meme" and nothing looser: each phrase
        // here REDIRECTS a dictation away from the user's editor, so a phrase that
        // could plausibly begin an ordinary sentence would cost them text.
        voiceTriggers: [
            "create a meme", "make a meme", "generate a meme",
            "сделай мем", "создай мем",
        ]
        // Not declared, deliberately:
        //
        // - `clipboardAccess` — the plugin has an explicit ⌘V import for template
        //   IMAGES, which is a user action with visible consequences. Silently pulling
        //   caption TEXT from the clipboard on every invocation would be a different
        //   thing wearing the same name, and the disclosure it would force into the
        //   Plugins pane would be buying the user nothing.
        // - `destination` — defaults to `.ownWindow`, which is what a meme editor
        //   wants and the only route the host implements.
        // - `appAffinity` — "make a meme" is equally plausible in any app.
    )
}
