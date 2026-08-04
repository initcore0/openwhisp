import Foundation

/// What a plugin actually receives when it is invoked (MAK-100).
///
/// The host builds one of these per invocation and hands it to the plugin. Everything
/// optional in it is a CAPABILITY the manifest had to declare — a plugin that did not
/// ask for the clipboard receives `clipboard == nil`, and has no way to ask again
/// through this seam.
///
/// ## Why the decision is a pure value
///
/// The alternative is each call site reading `NSPasteboard` and remembering to check
/// the manifest first. That is precisely the wiring shape this repo keeps getting
/// wrong: the check is one `if` away from being forgotten, the mistake is invisible in
/// review, and no test can reach it because the call site is AppKit-only. So the RULE
/// — who gets the clipboard, and what happens to an empty one — lives here as a pure
/// function that `swift test` covers, and the host supplies only the raw pasteboard
/// string.
///
/// The gate is real: the host genuinely withholds the pasteboard from an undeclared
/// plugin. It is not a SANDBOX, though — an in-process plugin could read
/// `NSPasteboard` itself, and only a process boundary changes that. See
/// docs/PLUGINS.md §"Security and trust".
public struct PluginInvocationContext: Equatable, Sendable {

    /// The material the plugin was invoked with — the spoken remainder, the user's
    /// selection, or both. Never nil: an invocation with nothing to act on is
    /// represented by an empty string, because "no material" is a state the plugin
    /// must handle anyway.
    public let material: String

    /// The pasteboard contents, or nil when this plugin did not declare
    /// `clipboardAccess` (or the pasteboard held no usable string).
    ///
    /// A plugin cannot distinguish "you didn't ask" from "the clipboard was empty",
    /// and deliberately so: both mean the same thing to it — there is nothing here —
    /// and a plugin able to tell them apart could probe whether the user has anything
    /// copied, which is itself a small privacy leak.
    public let clipboard: String?

    public init(material: String, clipboard: String? = nil) {
        self.material = material
        self.clipboard = clipboard
    }

    /// Build the context for one invocation.
    ///
    /// - Parameters:
    ///   - manifest: the invoked plugin's manifest — the ONLY thing that decides
    ///     whether the clipboard is passed through.
    ///   - material: what the user supplied for this invocation.
    ///   - pasteboardString: the current pasteboard contents as read by the host, or
    ///     nil if it holds no string. Passed IN rather than read here so this stays
    ///     Foundation-only and fully testable — the host owns the AppKit call, this
    ///     owns the rule.
    ///
    /// An all-whitespace pasteboard is treated as empty: handing a plugin `"  \n "`
    /// as though it were content just moves the emptiness check into every plugin.
    public static func make(
        manifest: PluginManifest,
        material: String,
        pasteboardString: String?
    ) -> PluginInvocationContext {
        guard manifest.clipboardAccess else {
            return PluginInvocationContext(material: material, clipboard: nil)
        }
        let trimmed = pasteboardString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipboard = (trimmed?.isEmpty ?? true) ? nil : pasteboardString
        return PluginInvocationContext(material: material, clipboard: clipboard)
    }

    /// Whether the host needs to read the pasteboard at all for this manifest.
    ///
    /// Checked BEFORE the read so a plugin that never declared the capability doesn't
    /// even cause an `NSPasteboard` access — the cheapest kind of privacy guarantee,
    /// and one that shows up honestly in a syscall trace rather than only in a comment.
    public static func needsPasteboard(_ manifest: PluginManifest) -> Bool {
        manifest.clipboardAccess
    }
}
