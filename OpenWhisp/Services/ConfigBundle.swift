import Foundation

/// A portable, versioned snapshot of OpenWhisp's user-editable configuration —
/// per-app profiles and custom vocabulary. This is the interchange format for
/// **export/import** (back up or move your setup between machines) and the basis
/// for shippable config **packs** (Phase 3).
///
/// Foundation-only and `Codable`, so it lives in OpenWhispCore and the
/// serialization/merge logic is unit-tested. AppState maps its `@Published`
/// settings to/from this type; the bundle itself knows nothing about AppKit.
///
/// **Tolerant by design:** every section is optional on decode, so a partial
/// bundle (e.g. a vocab-only pack) round-trips cleanly and forward-compatible
/// fields a newer app adds won't break an older importer.
public struct ConfigBundle: Codable, Equatable {
    /// Schema version for forward/backward compatibility. Bump on breaking change.
    public var schemaVersion: Int
    /// Per-app override profiles (nil = section absent, distinct from empty list).
    public var profiles: [AppProfile]?
    /// First-class user-authored Modes (MAK-39). nil = section absent (an older
    /// bundle, or a profiles/vocab-only pack), distinct from an empty list. Because
    /// every section is optional-on-decode, a v1 bundle with no `modes` still
    /// round-trips cleanly; a v2 bundle a v1 app can't fully represent is rejected
    /// by the schema-version guard rather than mis-parsed.
    public var modes: [Mode]?
    /// Custom vocabulary (terms + substitutions).
    public var vocabulary: Vocabulary?

    /// Bumped 1 → 2 for the `modes` section (MAK-39). The decode path stays
    /// tolerant (all sections optional), so the bump only stops a v1 app from
    /// silently dropping Modes it can't represent.
    public static let currentSchemaVersion = 2

    public init(
        schemaVersion: Int = ConfigBundle.currentSchemaVersion,
        profiles: [AppProfile]? = nil,
        modes: [Mode]? = nil,
        vocabulary: Vocabulary? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.modes = modes
        self.vocabulary = vocabulary
    }

    // MARK: - Serialization

    public enum DecodeError: Error, Equatable {
        /// The data wasn't a valid ConfigBundle JSON object.
        case malformed(String)
        /// The bundle's schemaVersion is newer than this app understands.
        case unsupportedVersion(found: Int, supported: Int)
    }

    /// Encode to pretty, stable JSON suitable for a file the user might read/edit.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decode a bundle, rejecting a schema from the future (we can't know what a
    /// higher version means). Lower/equal versions decode tolerantly.
    public static func decode(from data: Data) throws -> ConfigBundle {
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
    public var summary: String {
        var parts: [String] = []
        if let profiles, !profiles.isEmpty {
            parts.append("\(profiles.count) app profile\(profiles.count == 1 ? "" : "s")")
        }
        if let modes, !modes.isEmpty {
            parts.append("\(modes.count) mode\(modes.count == 1 ? "" : "s")")
        }
        if let vocabulary {
            let t = vocabulary.terms.count
            let s = vocabulary.substitutions.count
            if t > 0 { parts.append("\(t) vocab term\(t == 1 ? "" : "s")") }
            if s > 0 { parts.append("\(s) substitution\(s == 1 ? "" : "s")") }
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
    }
}
