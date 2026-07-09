import Foundation

/// Pure, testable resolver that decides — from the user's selected output-target
/// kind plus the three sink configs — WHICH `OutputTargetKind` should actually
/// handle a dictation, and whether the selected kind is even usable.
///
/// This is the decision the app-side glue (`AppState`) needs before it builds a
/// concrete sink: if the user picked `.webhook` but never entered a URL, there is
/// nothing to route to, so the resolver folds the choice back to `.focusedApp`
/// (today's behavior) rather than instantiating a sink that would only fail open.
/// Keeping this in `OpenWhispCore` means the "is this configured / which kind wins"
/// logic is `swift test`-covered without AppKit — the concrete sinks + `OutputRouter`
/// wiring in the app are then a thin, build-verified adapter over these answers.
///
/// Foundation-only (leans on the core `FileOutputConfig` / `WebhookConfig` /
/// `ShortcutInvocation`), so it compiles into `OpenWhispCore`.

/// The user's output-target configuration, as persisted: which kind is selected and
/// the config each concrete sink needs. Deliberately a plain aggregate (not folded
/// into `AppProfile`) so a Settings surface can persist it independently and it
/// round-trips in tests.
struct OutputTargetSettings: Codable, Equatable {
    /// The kind the user chose. `.focusedApp` is the default (today's behavior).
    var kind: OutputTargetKind
    /// File sink config (path / heading template / append-vs-overwrite). Consulted
    /// only when `kind == .file`.
    var file: FileOutputConfig
    /// Webhook sink config (URL / headers / timeout). Consulted only when
    /// `kind == .webhook`.
    var webhook: WebhookConfig
    /// The Shortcut display name to run. Consulted only when `kind == .shortcut`.
    var shortcutName: String

    init(
        kind: OutputTargetKind = .focusedApp,
        file: FileOutputConfig = FileOutputConfig(path: ""),
        webhook: WebhookConfig = WebhookConfig(url: ""),
        shortcutName: String = ""
    ) {
        self.kind = kind
        self.file = file
        self.webhook = webhook
        self.shortcutName = shortcutName
    }
}

/// Pure decision logic over an `OutputTargetSettings`.
enum OutputTargetResolver {

    /// Whether the selected kind is fully configured — i.e. there is a real
    /// destination to route to. `.focusedApp` is always configured (it's just the
    /// normal insert). The other kinds require their config to carry a usable value:
    ///   - `.file`     → a non-blank path,
    ///   - `.webhook`  → a non-blank, absolute URL (scheme + host),
    ///   - `.shortcut` → a non-blank, single-line name (`ShortcutInvocation` rules).
    ///
    /// A blank/invalid config means "the user picked this kind but hasn't finished
    /// setting it up", so the caller should NOT build a sink that could only fail
    /// open on every dictation.
    static func isConfigured(_ settings: OutputTargetSettings) -> Bool {
        switch settings.kind {
        case .focusedApp:
            return true
        case .file:
            return !settings.file.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .webhook:
            let trimmed = settings.webhook.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed) else { return false }
            return url.scheme != nil && url.host != nil
        case .shortcut:
            return ShortcutInvocation.normalizedName(settings.shortcutName) != nil
        }
    }

    /// The kind that should ACTUALLY handle a dictation given `settings`: the
    /// selected kind when it's configured, otherwise `.focusedApp`. This is the one
    /// number the app-side router builder needs — it never returns a kind whose sink
    /// couldn't do anything, so an unconfigured selection quietly behaves exactly
    /// like today's focused-app insert.
    static func effectiveKind(_ settings: OutputTargetSettings) -> OutputTargetKind {
        isConfigured(settings) ? settings.kind : .focusedApp
    }
}
