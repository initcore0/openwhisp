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
}
