import Foundation

/// The app-side file sink (MAK-12): an `OutputTarget` that appends (or overwrites)
/// each final dictation to a user-chosen file — a daily note in an Obsidian/Logseq
/// vault, a scratch `.md`, whatever the path points at.
///
/// Deliberately THIN: every decision about *what* to write lives in the pure
/// `FileOutputFormatter` (in `OpenWhispCore`, unit-tested); this type only does the
/// I/O — resolve the path, read the tail for the append separator, write on a
/// background queue, and report the fail-open outcome on the main thread.
///
/// Fail-open contract (see `OutputTarget`): on ANY problem — no path, unwritable
/// location, encoding failure — it reports `.failedFallback(reason:)` so the
/// `OutputRouter` re-routes the SAME payload to the focused-app insert. Text is
/// never dropped just because a file couldn't be written.
///
/// Lives in `OpenWhisp/` (compiled by build.sh) but NOT in Package.swift, so it's
/// app-only; the testable logic it leans on is the core formatter.
final class FileOutputTarget: OutputTarget {
    let kind: OutputTargetKind = .file

    private let config: FileOutputConfig
    /// Injected so tests can supply a deterministic timestamp; the app uses `Date()`.
    private let now: () -> Date
    /// Serial queue so concurrent writers can't interleave file writes. STATIC:
    /// a fresh FileOutputTarget is constructed per delivery (the output router
    /// builds one per finalized dictation, RuleEngineRunner one per appendFile
    /// action), so a per-instance queue would serialize nothing — both can
    /// target the same file in the same finalize call.
    private static let queue = DispatchQueue(label: "com.openwhisp.app.file-output")
    private let fileManager = FileManager.default

    init(config: FileOutputConfig, now: @escaping () -> Date = { Date() }) {
        self.config = config
        self.now = now
    }

    func deliver(_ payload: OutputPayload, completion: @escaping (OutputDelivery) -> Void) {
        // Live chunks are incremental mid-session inserts; a file sink only wants the
        // final result. Report a fallback so live chunks keep typing into the focused
        // app as before — the file gets the one clean final entry, not every partial.
        guard !payload.isLiveChunk else {
            completion(.failedFallback(reason: "file target ignores live chunks"))
            return
        }

        let config = self.config
        let timestamp = now()
        Self.queue.async { [fileManager] in
            let outcome: OutputDelivery
            do {
                try FileOutputTarget.write(
                    text: payload.text,
                    config: config,
                    date: timestamp,
                    fileManager: fileManager
                )
                outcome = .delivered
            } catch let error as FileWriteSkipped {
                // Nothing to write (empty dictation) — not an error, but there's no
                // file entry, so fall open to the normal insert path so the (blank)
                // result is handled exactly as it would be without a file target.
                outcome = .failedFallback(reason: error.reason)
            } catch {
                outcome = .failedFallback(reason: "file write failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Signals "the formatter produced no content" (empty/whitespace dictation) so
    /// `deliver` can fall open without treating it as a real I/O error.
    private struct FileWriteSkipped: Error { let reason: String }

    /// Do the actual write. Pure-ish: only touches the filesystem, using the core
    /// formatter for all content decisions. Throws on any I/O failure (→ fail-open).
    private static func write(
        text: String,
        config: FileOutputConfig,
        date: Date,
        fileManager: FileManager
    ) throws {
        let url = resolvedURL(for: config.path)

        // Ensure the containing directory exists (a fresh daily note in a new folder
        // shouldn't fail the first write).
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        switch config.mode {
        case .overwrite:
            guard let contents = FileOutputFormatter.renderOverwriteContents(
                text: text, config: config, date: date
            ) else {
                throw FileWriteSkipped(reason: "empty dictation — nothing to write")
            }
            try contents.write(to: url, atomically: true, encoding: .utf8)

        case .append:
            // Only the file's last two bytes decide the separator — reading the
            // whole (ever-growing daily-note) file per dictation was O(size).
            let tail = tailBytes(of: url, count: 2)
            guard let chunk = FileOutputFormatter.renderAppendChunk(
                text: text, config: config, existingTailBytes: tail, date: date
            ) else {
                throw FileWriteSkipped(reason: "empty dictation — nothing to append")
            }
            try appendUTF8(chunk, to: url, fileManager: fileManager)
        }
    }

    /// The last (up to) `count` bytes of the file; [] when missing, empty, or
    /// unreadable (matching the old whole-file read's `?? ""` fallback).
    private static func tailBytes(of url: URL, count: Int) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }
        let offset = size > UInt64(count) ? size - UInt64(count) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count) else { return [] }
        return [UInt8](data)
    }

    /// Append UTF-8 `chunk` to the file at `url`, creating it if absent. Uses a file
    /// handle so we don't re-read + re-write the whole file each time.
    private static func appendUTF8(_ chunk: String, to url: URL, fileManager: FileManager) throws {
        guard let data = chunk.data(using: .utf8) else {
            throw NSError(domain: "FileOutputTarget", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not encode entry as UTF-8"])
        }
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Resolve the configured path to a URL. Absolute paths are used as-is; `~` and
    /// relative paths resolve against the user's home directory so a config like
    /// `Documents/notes.md` still lands somewhere sensible.
    private static func resolvedURL(for path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(expanded)
    }
}
