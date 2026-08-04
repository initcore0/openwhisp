import Foundation

/// The user's own imported meme templates.
///
/// This is the plugin's answer to "the corpus is America-centric". imgflip's top 100
/// and memegen's ~200 are both English-language, US-internet lists; no amount of
/// merging remote catalogs produces a Russian, Ukrainian, or Brazilian template that
/// nobody uploaded to those services. The only source that can is the user, so the
/// plugin lets them import any image as a template.
///
/// It also happens to be the only source that works with the network off, which is
/// the local-first posture the rest of the app already takes.
///
/// ## Layout on disk
///
/// ```
/// ~/Library/Application Support/OpenWhisp/Plugins/MemeGenerator/templates/
///   index.json          <- MemeUserLibrary.Index
///   <uuid>.png          <- the imported images, copied in
/// ```
///
/// The index is a small JSON file of `{name, file}` records rather than a directory
/// scan, because the NAME is the load-bearing part: it is what the user searches for,
/// and what the LLM is asked to copy verbatim. A filename can't carry a name with a
/// slash, a colon, or an emoji in it — all of which are perfectly reasonable in the
/// languages this feature exists to serve — so the display name is stored as data and
/// the file on disk gets an opaque UUID name.
///
/// Everything here is pure: paths in, records out. The app layer does the actual
/// copying and reading (`MemeUserLibraryStore`).
public enum MemeUserLibrary {

    /// One imported template.
    public struct Entry: Equatable, Sendable, Codable, Identifiable {
        /// Stable id, also used as the qualified catalog id's raw part.
        public let id: String
        /// The display name the user typed or that was derived from the filename.
        /// This is what search matches and what the LLM is asked to copy.
        public var name: String
        /// The image's filename WITHIN the templates directory. Deliberately a bare
        /// filename, never a path: the index must not be able to point outside its
        /// own directory (see `imageURL`), and a relative name survives the whole
        /// Application Support folder being moved or restored from a backup.
        public var file: String
        /// Pixel dimensions, captured at import so the Browse grid can lay out
        /// without decoding every image.
        public var width: Int
        public var height: Int

        public init(id: String = UUID().uuidString, name: String, file: String, width: Int, height: Int) {
            self.id = id
            self.name = name
            self.file = file
            self.width = width
            self.height = height
        }
    }

    /// The on-disk index file's shape.
    ///
    /// Versioned from the start: this is a user-authored data store — the images are
    /// theirs and are not re-downloadable — so a future format change has to migrate
    /// rather than discard. Same posture as the profiles/vocabulary stores the app
    /// already treats as a versioned contract.
    public struct Index: Equatable, Sendable, Codable {
        public var version: Int
        public var entries: [Entry]

        public init(version: Int = MemeUserLibrary.currentVersion, entries: [Entry] = []) {
            self.version = version
            self.entries = entries
        }
    }

    public static let currentVersion = 1

    /// The index file's name within the templates directory.
    public static let indexFileName = "index.json"

    /// Image types the importer accepts. Anything `NSImage` can decode would work,
    /// but the picker needs a concrete list and these cover what people actually have
    /// saved from a chat app.
    public static let acceptedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    public static func isAcceptedImage(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return !ext.isEmpty && acceptedExtensions.contains(ext)
    }

    // MARK: - Naming

    /// Derive a display name from an imported file's name.
    ///
    /// "кот-в-шоке.png" → "кот в шоке". Separators become spaces and the result is
    /// trimmed, but the SCRIPT IS PRESERVED — no transliteration, no ASCII folding,
    /// no case forcing beyond capitalizing a leading letter. Mangling a Cyrillic
    /// filename into Latin would defeat the entire purpose of this feature.
    ///
    /// An unnameable file (all separators, or no stem) falls back to a generic name
    /// so the entry is still visible and renameable rather than blank.
    public static func suggestedName(fromFileName fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let spaced = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return spaced.isEmpty ? "Imported template" : spaced
    }

    /// The on-disk filename for a newly imported image: an opaque id plus the
    /// original extension.
    ///
    /// The user's name never touches the filesystem. That avoids every path-injection
    /// and encoding question a user-supplied, possibly non-Latin name would raise,
    /// and means renaming a template is a pure index edit rather than a file move.
    public static func storageFileName(id: String, sourceExtension: String) -> String {
        let ext = sourceExtension.lowercased()
        let safeExt = acceptedExtensions.contains(ext) ? ext : "png"
        return "\(id).\(safeExt)"
    }

    /// Make a name unique within the library by suffixing " 2", " 3", …
    ///
    /// Names must be distinct because the LLM picks templates BY NAME and the merged
    /// catalog de-duplicates by name — two templates called "кот" would mean one of
    /// them is unreachable. Comparison is on the normalized form so "Кот" and "кот "
    /// are treated as the same name, matching how search and the LLM validator behave.
    public static func uniqueName(_ desired: String, existing: [String]) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Imported template" : trimmed

        var taken = Set(existing.map { MemeTemplateMatcher.normalize($0) })
        // An empty normalization (a name that is entirely punctuation or emoji)
        // can't be compared meaningfully, so it never blocks another name.
        taken.remove("")

        guard taken.contains(MemeTemplateMatcher.normalize(base)) else { return base }

        var suffix = 2
        while true {
            let candidate = "\(base) \(suffix)"
            if !taken.contains(MemeTemplateMatcher.normalize(candidate)) { return candidate }
            suffix += 1
            // Defensive ceiling: an unbounded loop here would hang the import on a
            // pathological library rather than failing visibly.
            if suffix > 9999 { return "\(base) \(UUID().uuidString.prefix(8))" }
        }
    }

    // MARK: - Index rules

    /// Add an entry, keeping names unique.
    public static func adding(_ entry: Entry, to index: Index) -> Index {
        var out = index
        var newEntry = entry
        newEntry.name = uniqueName(entry.name, existing: index.entries.map(\.name))
        out.entries.append(newEntry)
        out.version = currentVersion
        return out
    }

    public static func removing(id: String, from index: Index) -> Index {
        var out = index
        out.entries.removeAll { $0.id == id }
        return out
    }

    /// Rename an entry, keeping the new name unique against the OTHER entries.
    ///
    /// The entry's own current name is excluded from the uniqueness check, so
    /// re-saving a name unchanged doesn't turn it into "кот 2".
    public static func renaming(id: String, to newName: String, in index: Index) -> Index {
        guard let position = index.entries.firstIndex(where: { $0.id == id }) else { return index }
        var out = index
        let others = index.entries.filter { $0.id != id }.map(\.name)
        out.entries[position].name = uniqueName(newName, existing: others)
        return out
    }

    /// Drop entries whose image file is gone.
    ///
    /// The user can delete files out from under the index in Finder; an entry
    /// pointing at a missing file would render as a broken cell in the grid and fail
    /// at generate time. Pruning at load turns that into a quiet self-heal.
    /// `existingFiles` is supplied by the app layer so this stays pure.
    public static func pruned(_ index: Index, existingFiles: Set<String>) -> Index {
        var out = index
        out.entries.removeAll { !existingFiles.contains($0.file) }
        return out
    }

    /// Validate a `file` value read off disk before it is joined onto a directory URL.
    ///
    /// The index is a plain JSON file in a user-writable directory, so it is UNTRUSTED
    /// input even though the user owns it: a hand-edited (or maliciously supplied)
    /// `"file": "../../../../etc/passwd"` must not become a readable path. Same rule
    /// `PluginManifest` applies to plugin ids for the same reason — a string that
    /// becomes a path component gets checked before it is joined, never after.
    public static func isSafeFileName(_ file: String) -> Bool {
        guard !file.isEmpty, file.count <= 255 else { return false }
        guard !file.contains("/"), !file.contains("\\"), !file.contains("\0") else { return false }
        guard file != ".", file != ".." else { return false }
        // A leading dot would hide the file from the user in Finder, which makes the
        // library's contents dishonest about what it holds.
        guard !file.hasPrefix(".") else { return false }
        return true
    }

    /// The entries safe to use, with unsafe ones dropped.
    public static func safeEntries(_ index: Index) -> [Entry] {
        index.entries.filter { isSafeFileName($0.file) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Catalog projection

    /// Project the library into catalog templates.
    ///
    /// `url` is a FILE url string here rather than an http one — the renderer and the
    /// thumbnail view both take "a string that locates the image", and keeping the
    /// shape identical to a remote template is what lets the user's own images flow
    /// through the exact same merge, search, prompt, and render path as imgflip's.
    /// One code path, three sources.
    ///
    /// The filename stem rides along as a keyword so a user who imported
    /// "kot-v-shoke.png" and renamed it "Кот в шоке" can still find it by typing the
    /// Latin filename they remember.
    public static func templates(from index: Index, directory: URL) -> [MemeTemplate] {
        safeEntries(index).map { entry in
            MemeTemplate(
                id: MemeTemplateCatalog.qualifiedID(.userLibrary, entry.id),
                name: entry.name,
                url: directory.appendingPathComponent(entry.file).absoluteString,
                width: entry.width,
                height: entry.height,
                source: .userLibrary,
                keywords: [suggestedName(fromFileName: entry.file)].filter { $0 != "Imported template" })
        }
    }
}
