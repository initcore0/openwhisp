import Foundation

/// App-side disk IO for opt-in retained raw audio (MAK-40).
///
/// The pure decisions — the filename scheme and the sweep — live in
/// `AudioRetentionPolicy` (OpenWhispCore, `swift test`-covered). This type is the
/// thin, Foundation-only adapter that actually touches the filesystem: it copies a
/// session's WAV into the app's `audio/` directory, resolves stored clips, and
/// executes a sweep the policy computed.
///
/// **Safety invariant (never delete a file the app didn't create):** every delete
/// path here routes through `AudioRetentionPolicy.isRetainedAudioFileName` AND is
/// scoped to `RetainedAudioStore.directoryURL`. A sweep never lists the directory
/// and deletes blindly — it deletes only the specific `retained-<uuid>.<ext>` leaf
/// the policy named, and only after re-validating the leaf.
enum AudioRetentionManager {

    /// The staging directory for a session WAV copied out before the engine deletes
    /// the original (a subdir of the retained-audio dir, so the same 0o700 scoping
    /// applies). Staging files are named `staging-<uuid>.wav`.
    private static var stagingDirectoryURL: URL {
        RetainedAudioStore.directoryURL.appendingPathComponent("staging", isDirectory: true)
    }

    /// Copy `sourceWAV` into the staging dir under a fresh name and return the copy's
    /// URL, or nil on failure. Used to preserve a session WAV before the transcription
    /// engine deletes it (deleteWhenDone), so retention can adopt it once the entry
    /// ID is known.
    static func stageCopy(of sourceWAV: URL) -> URL? {
        let dir = stagingDirectoryURL
        let dest = dir.appendingPathComponent("staging-\(UUID().uuidString).wav")
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.copyItem(at: sourceWAV, to: dest)
            return dest
        } catch {
            print("[AudioRetentionManager] stageCopy failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Move a staged WAV into the retained-audio dir under the canonical name for
    /// `entryID`, returning the stored leaf filename or nil on failure. Best-effort.
    static func adopt(stagedWAV: URL, entryID: UUID, ext: String = "wav") -> String? {
        let fileName = AudioRetentionPolicy.fileName(for: entryID, ext: ext)
        let dir = RetainedAudioStore.directoryURL
        let dest = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: stagedWAV, to: dest)
            return fileName
        } catch {
            print("[AudioRetentionManager] adopt failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Whether a stored clip's file is actually present on disk.
    static func audioExists(fileName: String) -> Bool {
        guard AudioRetentionPolicy.isRetainedAudioFileName(fileName) else { return false }
        return FileManager.default.fileExists(atPath: RetainedAudioStore.url(for: fileName).path)
    }

    /// Delete one stored clip by leaf filename. No-ops (and refuses) on any name
    /// that isn't a valid retained-audio filename — the delete guard.
    @discardableResult
    static func deleteAudio(fileName: String) -> Bool {
        guard AudioRetentionPolicy.isRetainedAudioFileName(fileName) else {
            print("[AudioRetentionManager] refused to delete non-retained file: \(fileName)")
            return false
        }
        let url = RetainedAudioStore.url(for: fileName)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            print("[AudioRetentionManager] delete failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Delete every retained clip (used by "Clear History" and by turning retention
    /// off). Lists the app's own audio directory and removes only files that pass
    /// the retained-audio name guard — a foreign file dropped in there is left alone.
    static func deleteAllAudio() {
        let dir = RetainedAudioStore.directoryURL
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in names where AudioRetentionPolicy.isRetainedAudioFileName(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        // Also clear any leftover staging copies (owned solely by this app).
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }
}
