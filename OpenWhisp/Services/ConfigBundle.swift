import Foundation

/// A portable, versioned snapshot of OpenWhisp's user-editable configuration —
/// per-app profiles, custom vocabulary, and named-command prompts. This is the
/// interchange format for **export/import** (back up or move your setup between
/// machines) and the basis for shippable config **packs** (Phase 3).
///
/// Foundation-only and `Codable`, so it lives in OpenWhispCore and the
/// serialization/merge logic is unit-tested. AppState maps its `@Published`
/// settings to/from this type; the bundle itself knows nothing about AppKit.
///
/// **Tolerant by design:** every section is optional on decode, so a partial
/// bundle (e.g. a vocab-only pack) round-trips cleanly and forward-compatible
/// fields a newer app adds won't break an older importer.
struct ConfigBundle: Codable, Equatable {
    /// Schema version for forward/backward compatibility. Bump on breaking change.
    var schemaVersion: Int
    /// Per-app override profiles (nil = section absent, distinct from empty list).
    var profiles: [AppProfile]?
    /// Custom vocabulary (terms + substitutions).
    var vocabulary: Vocabulary?
    /// Named voice actions to add or override (by id) on top of the built-ins —
    /// e.g. retune the Telegram prompt, or add a brand-new "make a tweet" action.
    var actions: [VoiceAction]?
    /// Misc voice-command config that isn't a named action.
    var prompts: Prompts?

    static let currentSchemaVersion = 1

    /// Voice-command config that isn't a per-action prompt.
    struct Prompts: Codable, Equatable {
        /// Wake word that introduces a spoken command (e.g. "computer").
        var voiceCommandWakeWord: String?
    }

    init(
        schemaVersion: Int = ConfigBundle.currentSchemaVersion,
        profiles: [AppProfile]? = nil,
        vocabulary: Vocabulary? = nil,
        actions: [VoiceAction]? = nil,
        prompts: Prompts? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.vocabulary = vocabulary
        self.actions = actions
        self.prompts = prompts
    }

    // MARK: - Serialization

    enum DecodeError: Error, Equatable {
        /// The data wasn't a valid ConfigBundle JSON object.
        case malformed(String)
        /// The bundle's schemaVersion is newer than this app understands.
        case unsupportedVersion(found: Int, supported: Int)
    }

    /// Encode to pretty, stable JSON suitable for a file the user might read/edit.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decode a bundle, rejecting a schema from the future (we can't know what a
    /// higher version means). Lower/equal versions decode tolerantly.
    static func decode(from data: Data) throws -> ConfigBundle {
        let bundle: ConfigBundle
        do {
            bundle = try JSONDecoder().decode(ConfigBundle.self, from: data)
        } catch {
            throw DecodeError.malformed(error.localizedDescription)
        }
        guard bundle.schemaVersion <= currentSchemaVersion else {
            throw DecodeError.unsupportedVersion(
                found: bundle.schemaVersion, supported: currentSchemaVersion
            )
        }
        return bundle
    }

    // MARK: - Summary

    /// Human-readable summary of what a bundle contains, for import confirmation
    /// and pack listings. Empty sections are omitted.
    var summary: String {
        var parts: [String] = []
        if let profiles, !profiles.isEmpty {
            parts.append("\(profiles.count) app profile\(profiles.count == 1 ? "" : "s")")
        }
        if let vocabulary {
            let t = vocabulary.terms.count
            let s = vocabulary.substitutions.count
            if t > 0 { parts.append("\(t) vocab term\(t == 1 ? "" : "s")") }
            if s > 0 { parts.append("\(s) substitution\(s == 1 ? "" : "s")") }
        }
        if let actions, !actions.isEmpty {
            parts.append("\(actions.count) voice action\(actions.count == 1 ? "" : "s")")
        }
        if let w = prompts?.voiceCommandWakeWord, !w.isEmpty {
            parts.append("wake word")
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
}
