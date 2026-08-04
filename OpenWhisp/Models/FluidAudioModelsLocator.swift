import Foundation

/// Where FluidAudio (Parakeet) stages its CoreML model repos on disk, and which
/// variant folders are currently installed. Extracted from AppState (MAK-32
/// ratchet) — pure filesystem lookups with no AppState state, so they live in
/// their own type and AppState forwards to them.
enum FluidAudioModelsLocator {

    /// Base directory FluidAudio stages its CoreML model repos under
    /// (`~/Library/Application Support/FluidAudio/Models`). Mirrors FluidAudio's
    /// own `downloadVariant`/`defaultCacheDirectory` layout.
    static func modelsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Names of the variant subfolders currently staged under `modelsDirectory()`.
    static func installedFolders() -> Set<String> {
        let base = modelsDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return Set(names.filter { name in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(
                atPath: base.appendingPathComponent(name).path, isDirectory: &isDir)
            return isDir.boolValue
        })
    }

    /// Completeness verdict for a variant's model cache — the check that tells
    /// "installed" from "present but torn" (a killed first-run download leaves a
    /// folder FluidAudio's presence gate accepts but `MLModel.load` can't open).
    static func verdict(forVariant id: String) -> ParakeetModelIntegrity.Verdict {
        ParakeetModelIntegrity.verdict(forVariant: id, listing: fileListing(forVariant: id))
    }

    /// Recursive file listing (relative paths) of a variant's repo folder, or
    /// nil when the folder doesn't exist. Names only — no attributes — so it's
    /// cheap even for the ~600 MB repos (a few dozen entries).
    static func fileListing(forVariant id: String) -> Set<String>? {
        guard let folder = ParakeetDownloadStatePolicy.repoFolder(forVariant: id) else { return nil }
        return fileListing(forRepoFolder: folder)
    }

    static func fileListing(forRepoFolder folder: String) -> Set<String>? {
        let base = modelsDirectory().appendingPathComponent(folder, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir),
              isDir.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: base, includingPropertiesForKeys: nil,
                  options: [.producesRelativePathURLs])
        else { return nil }
        var paths = Set<String>()
        for case let url as URL in enumerator { paths.insert(url.relativePath) }
        return paths
    }

    /// Delete a repo folder (corrupt-cache repair / explicit "Redownload Model").
    /// A missing folder is a no-op, not an error.
    static func removeRepoFolder(_ folder: String) throws {
        let target = modelsDirectory().appendingPathComponent(folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }
}
