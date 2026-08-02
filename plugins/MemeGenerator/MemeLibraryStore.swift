import AppKit
import Foundation

/// Disk IO for the Meme Generator's user template library and catalog cache (v3).
///
/// The *policy* lives in the pure, tested `MemeUserLibrary` and `MemeCatalogCache`;
/// this type does only the reading, writing, and image copying. That split is the same
/// one the rest of the plugin uses, and it is what lets `swift test` cover the index
/// rules (uniqueness, pruning, traversal refusal) without touching a filesystem.
///
/// Everything lives under
/// `~/Library/Application Support/OpenWhisp/Plugins/MemeGenerator/`, which is the
/// directory `PluginHost.externalDirectory` already establishes for per-plugin data.
@MainActor
enum MemeLibraryStore {

    /// `…/Plugins/MemeGenerator`.
    static var pluginDirectory: URL {
        PluginHost.externalDirectory
            .appendingPathComponent(PluginRegistry.memeGenerator.id, isDirectory: true)
    }

    /// `…/Plugins/MemeGenerator/templates` — the imported images plus `index.json`.
    static var templatesDirectory: URL {
        pluginDirectory.appendingPathComponent("templates", isDirectory: true)
    }

    private static var indexURL: URL {
        templatesDirectory.appendingPathComponent(MemeUserLibrary.indexFileName)
    }

    private static var cacheURL: URL {
        pluginDirectory.appendingPathComponent(MemeCatalogCache.fileName)
    }

    // MARK: - User library

    /// Read the index, dropping entries whose image file has disappeared.
    ///
    /// A missing or unreadable index is an EMPTY library, never an error: the library
    /// is empty on first run by definition, and a corrupt index must not block the
    /// plugin from opening — the remote providers still work.
    static func loadIndex() -> MemeUserLibrary.Index {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode(MemeUserLibrary.Index.self, from: data)
        else { return MemeUserLibrary.Index() }

        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: templatesDirectory.path)) ?? []
        return MemeUserLibrary.pruned(decoded, existingFiles: Set(files))
    }

    @discardableResult
    static func save(_ index: MemeUserLibrary.Index) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: templatesDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // The index is small and hand-inspectable on purpose: this is a spike, and
            // a user who wants to rename twenty templates should be able to open the
            // file and do it.
            try encoder.encode(index).write(to: indexURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Import an image file as a user template.
    ///
    /// The source file is COPIED rather than referenced. A template that points at
    /// `~/Downloads` breaks the moment the user tidies up, and the whole promise of
    /// the library is that it keeps working offline and indefinitely.
    ///
    /// Returns the new entry, or nil when the file isn't a readable image.
    @discardableResult
    static func importImage(at source: URL, name: String? = nil) -> MemeUserLibrary.Entry? {
        guard MemeUserLibrary.isAcceptedImage(fileName: source.lastPathComponent) else {
            return nil
        }
        // Decode BEFORE copying: an unreadable file must not leave a stray image in
        // the library directory that pruning would then have to clean up.
        guard let image = NSImage(contentsOf: source), image.size.width > 0 else { return nil }

        let id = UUID().uuidString
        let file = MemeUserLibrary.storageFileName(
            id: id, sourceExtension: source.pathExtension)
        let destination = templatesDirectory.appendingPathComponent(file)

        do {
            try FileManager.default.createDirectory(
                at: templatesDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return nil
        }

        let pixels = pixelSize(of: image)
        let entry = MemeUserLibrary.Entry(
            id: id,
            name: name ?? MemeUserLibrary.suggestedName(fromFileName: source.lastPathComponent),
            file: file,
            width: pixels.width, height: pixels.height)

        var index = loadIndex()
        index = MemeUserLibrary.adding(entry, to: index)
        guard save(index) else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        // `adding` may have uniquified the name, so return what was actually stored
        // rather than what was requested.
        return index.entries.last
    }

    /// Import an image already in memory — the paste and drag-drop paths, where there
    /// is no source file to copy.
    @discardableResult
    static func importImage(_ image: NSImage, name: String) -> MemeUserLibrary.Entry? {
        guard let data = MemeRenderer.pngData(for: image) else { return nil }

        let id = UUID().uuidString
        let file = MemeUserLibrary.storageFileName(id: id, sourceExtension: "png")
        let destination = templatesDirectory.appendingPathComponent(file)

        do {
            try FileManager.default.createDirectory(
                at: templatesDirectory, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch {
            return nil
        }

        let pixels = pixelSize(of: image)
        let entry = MemeUserLibrary.Entry(
            id: id, name: name, file: file, width: pixels.width, height: pixels.height)

        var index = loadIndex()
        index = MemeUserLibrary.adding(entry, to: index)
        guard save(index) else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        return index.entries.last
    }

    /// Delete a template and its image.
    static func remove(id: String) {
        let index = loadIndex()
        if let entry = index.entries.first(where: { $0.id == id }),
           MemeUserLibrary.isSafeFileName(entry.file) {
            try? FileManager.default.removeItem(
                at: templatesDirectory.appendingPathComponent(entry.file))
        }
        save(MemeUserLibrary.removing(id: id, from: index))
    }

    static func rename(id: String, to newName: String) {
        save(MemeUserLibrary.renaming(id: id, to: newName, in: loadIndex()))
    }

    /// The library projected into catalog templates.
    static func libraryTemplates() -> [MemeTemplate] {
        MemeUserLibrary.templates(from: loadIndex(), directory: templatesDirectory)
    }

    private static func pixelSize(of image: NSImage) -> (width: Int, height: Int) {
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let best = reps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return (best.pixelsWide, best.pixelsHigh)
        }
        return (Int(image.size.width), Int(image.size.height))
    }

    // MARK: - Catalog cache

    static func loadCachedCatalog() -> MemeCatalogCache.Cached? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(MemeCatalogCache.Cached.self, from: data)
    }

    /// Persist the REMOTE catalog only.
    ///
    /// User-library templates are deliberately excluded: they are already durable in
    /// `index.json`, and caching them would mean a deleted import could come back
    /// from the cache. The cache's job is to stand in for the network, nothing else.
    static func saveCachedCatalog(_ templates: [MemeTemplate], now: Date = Date()) {
        let remote = templates.filter { $0.source != .userLibrary }
        guard !remote.isEmpty else { return }
        let payload = MemeCatalogCache.Cached(fetchedAt: now, templates: remote)
        do {
            try FileManager.default.createDirectory(
                at: pluginDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(payload).write(to: cacheURL, options: .atomic)
        } catch {
            // A cache that can't be written costs a fetch next launch — not worth
            // interrupting the user over.
        }
    }

    // MARK: - Thumbnails

    /// `…/Plugins/MemeGenerator/thumbnails` — downscaled template previews.
    ///
    /// Browsing ~300 templates means ~300 image loads; caching a small JPEG per
    /// template is what makes the grid instant on the second open and functional with
    /// the network off. Keyed by the QUALIFIED id, hashed so a slug id with awkward
    /// characters can't shape the filename.
    static var thumbnailsDirectory: URL {
        pluginDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    }

    static func thumbnailURL(for templateID: String) -> URL {
        // A stable, filesystem-safe name derived from the id. Hex of the id's UTF-8
        // bytes: reversible, collision-free, and free of path characters — the
        // property that matters, since this string becomes a path component.
        let hex = templateID.utf8.map { String(format: "%02x", $0) }.joined()
        // Long ids would exceed the 255-byte filename limit; the suffix keeps the
        // tail (where the distinguishing part of an id lives) rather than the head.
        let safe = hex.count <= 200 ? hex : String(hex.suffix(200))
        return thumbnailsDirectory.appendingPathComponent("\(safe).jpg")
    }

    static func cachedThumbnail(for templateID: String) -> NSImage? {
        NSImage(contentsOf: thumbnailURL(for: templateID))
    }

    /// Downscale and store a thumbnail. Failures are silent — a missing thumbnail
    /// just means the grid refetches next time.
    static func storeThumbnail(_ image: NSImage, for templateID: String) {
        guard let scaled = downscaled(image, maxDimension: 320),
              let tiff = scaled.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return }

        try? FileManager.default.createDirectory(
            at: thumbnailsDirectory, withIntermediateDirectories: true)
        try? data.write(to: thumbnailURL(for: templateID), options: .atomic)
    }

    private static func downscaled(_ image: NSImage, maxDimension: CGFloat) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return image }

        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        output.unlockFocus()
        return output
    }
}
