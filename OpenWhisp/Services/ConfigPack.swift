import Foundation

/// A named, shippable configuration pack — a `ConfigBundle` plus display
/// metadata. Packs are config-only (no code): curated vocabularies, prompt
/// setups, or per-app profile sets a user can apply in one click. OpenWhisp
/// bundles a few built-ins; the same format works for community/user packs.
///
/// On apply, a pack goes through the exact same `ConfigBundle` import path as a
/// hand-exported file, so it only touches the sections it contains. Foundation-
/// only and `Codable`, so it lives in OpenWhispCore and the parsing/listing logic
/// is unit-tested.
struct ConfigPack: Codable, Equatable, Identifiable {
    /// Stable identifier (used for the SwiftUI list and de-duplication).
    var id: String
    /// Short display name, e.g. "Developer Vocabulary".
    var name: String
    /// One-line description of what applying it does.
    var packDescription: String
    /// The configuration this pack applies.
    var bundle: ConfigBundle

    enum CodingKeys: String, CodingKey {
        case id, name
        case packDescription = "description"
        case bundle
    }

    /// What applying this pack will change, derived from the bundle ("2 vocab
    /// terms, 1 prompt"). Surfaced in the UI so the action is never opaque.
    var contentsSummary: String { bundle.summary }

    enum DecodeError: Error, Equatable {
        case malformed(String)
        case unsupportedVersion(found: Int, supported: Int)
    }

    /// Decode a single pack, validating the embedded bundle's schema version the
    /// same way a hand-imported file is validated.
    static func decode(from data: Data) throws -> ConfigPack {
        let pack: ConfigPack
        do {
            pack = try JSONDecoder().decode(ConfigPack.self, from: data)
        } catch {
            throw DecodeError.malformed(error.localizedDescription)
        }
        guard pack.bundle.schemaVersion <= ConfigBundle.currentSchemaVersion else {
            throw DecodeError.unsupportedVersion(
                found: pack.bundle.schemaVersion,
                supported: ConfigBundle.currentSchemaVersion
            )
        }
        return pack
    }

    /// Parse a directory listing of `(filename, data)` pairs into valid packs,
    /// sorted by name and de-duplicated by id (first occurrence wins). Malformed
    /// or too-new files are skipped rather than failing the whole listing — a bad
    /// pack must never hide the good ones. Pure, so it's unit-tested without IO.
    static func parseAll(_ files: [(name: String, data: Data)]) -> [ConfigPack] {
        var seen = Set<String>()
        var packs: [ConfigPack] = []
        for file in files.sorted(by: { $0.name < $1.name }) {
            guard let pack = try? decode(from: file.data) else { continue }
            guard !seen.contains(pack.id) else { continue }
            seen.insert(pack.id)
            packs.append(pack)
        }
        return packs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
