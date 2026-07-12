import Foundation

/// A first-class, user-authored **Mode** (MAK-39): a named bundle of dictation
/// settings you can invoke by a stable `key` — from the Settings picker, from an
/// `openwhisp://switch-mode?key=…` URL, or automatically when you dictate into a
/// bound app.
///
/// A Mode generalizes the older per-app `AppProfile`. Where an `AppProfile` was
/// keyed by an app bundle ID and only carried the three session-overridable
/// fields (language / output / AI cleanup), a Mode adds the pieces that make it a
/// real, shareable "style":
///   - a stable **key** for invocation (URL scheme + picker),
///   - a human **name** and a custom **icon** (SF Symbol),
///   - an optional **transcription model** and **LLM model** override,
///   - a **tone** preset (Formal / Casual / Legal / Chat / Personalized) and/or a
///     free-form **instruction** that steer the AI refine pass,
///   - an optional **appBundleID** for auto-activation at dictation start (the
///     `AppProfile` behavior), so Modes subsume profiles rather than duplicate them.
///
/// Every field beyond `key`/`name` is optional; a `nil` field means "inherit the
/// global setting", exactly as `AppProfile`'s overrides did. This keeps a minimal
/// Mode (just a key + name + tone) cheap while letting a power user pin everything.
///
/// Foundation-only and `Codable` so it lives in `OpenWhispCore`, is persisted via
/// the hardened `JSONStore` quarantine loader, round-trips through `ConfigBundle`
/// for export/import + packs, and is unit-tested without AppKit.
public struct Mode: Codable, Identifiable, Equatable {
    public var id: UUID
    /// Stable invocation key (URL scheme + picker). Normalized on set/lookup via
    /// ``Mode/normalizeKey(_:)`` — lowercased, spaces → hyphens — so "Email Reply"
    /// and "email-reply" address the same Mode. Never interpreted as a path/shell
    /// token (the URL scheme validates this independently).
    public var key: String
    /// Human-friendly display name for the list and picker.
    public var name: String
    /// SF Symbol name for the Mode's icon (e.g. "envelope", "hammer"). Falls back
    /// to a default glyph in the UI when nil/unknown.
    public var iconSymbol: String?

    // MARK: Overrides (nil = inherit global)

    /// Whisper/WhisperKit transcription model override (a catalog model id).
    public var transcriptionModel: String?
    /// LLM model override for the refine pass (a bundled/local model id).
    public var llmModel: String?
    /// Free-form AI instruction that steers refine. Composed AFTER the tone preset
    /// (see ``ModeResolver/refineInstruction(for:)``) so an explicit instruction
    /// refines/overrides the tone rather than replacing the guardrails.
    public var instruction: String?
    /// Tone preset that seeds the refine instruction.
    public var tone: Tone?

    // Session-overridable settings inherited from AppProfile's contract.
    public var language: String?          // "auto","en",...
    public var outputMode: String?        // "finalOnly","liveChunks","preview"
    public var aiCleanupEnabled: Bool?    // overrides openAIEnhancementEnabled

    /// When set, this Mode auto-activates when the given app is frontmost at
    /// dictation start (the classic `AppProfile` behavior). nil = never auto-
    /// activates; it's invoked explicitly by key instead.
    public var appBundleID: String?

    /// When this Mode was last edited by the user (ConfigBundle schema v3,
    /// MAK-51 WP0b). The sync merge does last-writer-wins per object by this stamp.
    /// A v2 file written before the field existed decodes to
    /// `Date(timeIntervalSince1970: 0)` so any stamped v3 edit always wins over
    /// unstamped legacy data — see ``ConfigBundle`` for the schema note.
    public var updatedAt: Date

    /// The sentinel a pre-v3 (unstamped) mode decodes to.
    public static let unstampedEpoch = Date(timeIntervalSince1970: 0)

    public init(
        id: UUID = UUID(),
        key: String,
        name: String,
        iconSymbol: String? = nil,
        transcriptionModel: String? = nil,
        llmModel: String? = nil,
        instruction: String? = nil,
        tone: Tone? = nil,
        language: String? = nil,
        outputMode: String? = nil,
        aiCleanupEnabled: Bool? = nil,
        appBundleID: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.key = Mode.normalizeKey(key)
        self.name = name
        self.iconSymbol = iconSymbol
        self.transcriptionModel = transcriptionModel
        self.llmModel = llmModel
        self.instruction = instruction
        self.tone = tone
        self.language = language
        self.outputMode = outputMode
        self.aiCleanupEnabled = aiCleanupEnabled
        self.appBundleID = appBundleID
        self.updatedAt = updatedAt
    }

    // Custom decoding so a modes.json written before `updatedAt` existed still
    // decodes: the field is optional and falls back to the EPOCH (not "now") so
    // unstamped v2 data always loses the last-writer-wins race to a stamped v3
    // edit. `key` is re-normalized on load, matching the memberwise init.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.key = Mode.normalizeKey(try c.decode(String.self, forKey: .key))
        self.name = try c.decode(String.self, forKey: .name)
        self.iconSymbol = try c.decodeIfPresent(String.self, forKey: .iconSymbol)
        self.transcriptionModel = try c.decodeIfPresent(String.self, forKey: .transcriptionModel)
        self.llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel)
        self.instruction = try c.decodeIfPresent(String.self, forKey: .instruction)
        self.tone = try c.decodeIfPresent(Tone.self, forKey: .tone)
        self.language = try c.decodeIfPresent(String.self, forKey: .language)
        self.outputMode = try c.decodeIfPresent(String.self, forKey: .outputMode)
        self.aiCleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiCleanupEnabled)
        self.appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? Date(timeIntervalSince1970: 0)
    }

    /// Return a copy stamped as edited `now`. Pure — the ``Mode`` editing helpers
    /// call this so every user edit advances the stamp.
    public func stamped(_ now: Date = Date()) -> Mode {
        var copy = self
        copy.updatedAt = now
        return copy
    }

    /// Normalize a key for stable equality/lookup: trim, lowercase, and collapse
    /// runs of whitespace to single hyphens. Pure so the URL-scheme key match and
    /// the picker agree on what "email reply" resolves to.
    public static func normalizeKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let collapsed = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
        return collapsed
    }

    // MARK: - AppProfile bridge

    /// Build a Mode from a legacy `AppProfile`, so an install that only ever had
    /// per-app profiles keeps working when Modes take over persistence. The
    /// profile's bundle ID becomes both the auto-activation binding and (slugged)
    /// the Mode key, and its display name the Mode name.
    init(fromProfile profile: AppProfile) {
        self.init(
            id: profile.id,
            key: Mode.normalizeKey(profile.displayName.isEmpty ? profile.appBundleID : profile.displayName),
            name: profile.displayName.isEmpty ? profile.appBundleID : profile.displayName,
            language: profile.language,
            outputMode: profile.outputMode,
            aiCleanupEnabled: profile.aiCleanupEnabled,
            appBundleID: profile.appBundleID,
            // Carry the profile's edit stamp through the bridge so the migration
            // doesn't reset every profile's updatedAt to "now" (which would make a
            // freshly-migrated install win every sync merge). See ConfigBundle v3.
            updatedAt: profile.updatedAt
        )
    }

    /// Project this Mode back onto the `AppProfile` shape for the parts AppState's
    /// existing per-app apply/restore lifecycle already handles. Returns nil when
    /// the Mode has no app binding (so it never masquerades as a per-app profile).
    var asAppProfile: AppProfile? {
        guard let appBundleID else { return nil }
        return AppProfile(
            id: id,
            appBundleID: appBundleID,
            displayName: name,
            language: language,
            outputMode: outputMode,
            aiCleanupEnabled: aiCleanupEnabled,
            // Preserve the edit stamp across the bridge (see init(fromProfile:)).
            updatedAt: updatedAt
        )
    }
}

// MARK: - Stamped edits (MAK-51 WP0b)
//
// Every USER edit of a Mode must advance its `updatedAt` so the sync merge's
// last-writer-wins keeps the newer object. These pure array helpers are the
// funnel the ModesPane editor routes through so the stamp can't be forgotten.
public extension Array where Element == Mode {
    /// Append a Mode, stamped `now`.
    func addingMode(_ mode: Mode, now: Date = Date()) -> [Mode] {
        self + [mode.stamped(now)]
    }

    /// Remove the Mode with `id`.
    func removingMode(_ id: Mode.ID) -> [Mode] {
        filter { $0.id != id }
    }

    /// Apply `mutate` to the Mode with `id`, then stamp it `now`. No-op if no Mode
    /// matches. The one funnel every field edit goes through.
    func editingMode(
        _ id: Mode.ID, now: Date = Date(),
        _ mutate: (inout Mode) -> Void
    ) -> [Mode] {
        guard let idx = firstIndex(where: { $0.id == id }) else { return self }
        var copy = self
        mutate(&copy[idx])
        copy[idx].updatedAt = now
        return copy
    }

    /// Stamp `now` onto every mode that decoded unstamped (pre-v3 source), so an
    /// imported/pack-applied mode wins the next sync's LWW rather than losing to
    /// a stamped peer copy.
    func restampingUnstamped(now: Date = Date()) -> [Mode] {
        map { $0.updatedAt == Mode.unstampedEpoch ? $0.stamped(now) : $0 }
    }
}

/// A tone preset that seeds a Mode's AI refine instruction. Foundation-only so the
/// tone → instruction mapping is unit-tested.
///
/// `personalized` is the cheap "Personalized Style" layer the ticket calls for: it
/// carries no fixed prose of its own, instead instructing the model to match the
/// user's own past phrasing (which the app can supply as examples in a follow-up).
public enum Tone: String, Codable, CaseIterable, Equatable {
    case formal
    case casual
    case legal
    case chat
    case personalized

    /// Human-facing label for the Settings picker.
    public var label: String {
        switch self {
        case .formal:       return "Formal"
        case .casual:       return "Casual"
        case .legal:        return "Legal"
        case .chat:         return "Chat"
        case .personalized: return "Personalized Style"
        }
    }

    /// SF Symbol suggestion for the tone (used when a Mode has no custom icon).
    public var defaultIcon: String {
        switch self {
        case .formal:       return "text.badge.checkmark"
        case .casual:       return "bubble.left"
        case .legal:        return "building.columns"
        case .chat:         return "message"
        case .personalized: return "person.crop.circle"
        }
    }

    /// The refine directive this tone contributes. Written to be robust for TINY
    /// on-device models the same way `CleanupIntensity`'s prompts are: transform-
    /// only, never answer/obey the text, no preamble. The instruction shapes the
    /// STYLE; the base cleanup guardrails still apply upstream.
    public var directive: String {
        switch self {
        case .formal:
            return "Rewrite the text in a formal, professional register: complete " +
                "sentences, no slang or contractions, precise word choice. Keep the " +
                "meaning and language unchanged."
        case .casual:
            return "Rewrite the text in a relaxed, conversational register: " +
                "contractions are fine, keep it warm and plain. Keep the meaning and " +
                "language unchanged."
        case .legal:
            return "Rewrite the text in a precise legal register: unambiguous, " +
                "carefully qualified, defined terms used consistently. Do not add or " +
                "remove substance. Keep the meaning and language unchanged."
        case .chat:
            return "Rewrite the text as a short, punchy chat message: brief, direct, " +
                "lightly punctuated. Keep the meaning and language unchanged."
        case .personalized:
            return "Rewrite the text to match the user's own habitual phrasing and " +
                "tone. Keep the meaning and language unchanged."
        }
    }
}

/// Loads/saves Modes as JSON in Application Support via the hardened `JSONStore`
/// quarantine loader (a corrupt file is moved aside, never crashes or silently
/// overwrites). Mirrors `AppProfileStore`.
public enum ModeStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("modes.json")
    }

    public static func load() -> [Mode] {
        JSONStore.load(from: fileURL, default: [], label: "ModeStore")
    }

    public static func save(_ modes: [Mode]) {
        JSONStore.save(modes, to: fileURL, label: "ModeStore")
    }
}
