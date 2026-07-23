import Foundation

/// Shared load/save primitives for OpenWhisp's on-device JSON stores.
///
/// Five stores (`TranscriptionHistoryStore`, `AppProfileStore`,
/// `DictationStatsStore`, `VocabularyStore`, `AgentClientStore`) all persist a
/// `Codable` value as JSON in `~/Library/Application Support/OpenWhisp/`. They
/// used to each copy-paste the same "read, decode, and on corruption move the bad
/// file aside to `.corrupt-<epoch>` rather than crash" block — and a fix was once
/// missed in one store because of that duplication. This enum owns the logic in
/// exactly one place.
///
/// Two invariants folded in from the July-2026 bug scan (MAK-22):
///   - **Quarantine** lives here once: a missing/empty file yields the default; an
///     undecodable file is moved to `<name>.corrupt-<epoch>` and the default is
///     returned (never a crash, never a silent overwrite on the next save).
///   - **Directory permissions** are uniform: `save` always creates the store dir
///     with `0o700`. Previously only `AgentClientStore.save()` set that mode, so
///     the effective permissions depended on whichever store's `save()` ran first.
///
/// Pure and Foundation-only, so the corruption/quarantine path is unit-testable
/// via `swift test`.
public enum JSONStore {
    /// Load and decode `T` from `url`.
    ///
    /// - Missing file → `default` (a fresh store; not an error).
    /// - Existing file that cannot be read (permissions, I/O error) → the file is
    ///   moved aside to `<name>.unreadable-<epoch>` and `default` is returned, so
    ///   the next save can't overwrite the intact data.
    /// - Decodable file → the decoded value, with `transform` applied (default:
    ///   identity). `AgentClientStore` uses `transform` to run its
    ///   `demoteRunScopedGrants()` step on load.
    /// - Undecodable file (corruption, hand-edit, version skew) → the file is
    ///   moved aside to `<name>.corrupt-<epoch>` and `default` is returned. Moving
    ///   it (rather than returning `default` silently) means the next `save` can't
    ///   overwrite it and make the loss permanent — the bad file is recoverable.
    ///
    /// - Parameters:
    ///   - url: The JSON file to read.
    ///   - default: The value to return when the file is missing or corrupt.
    ///   - label: Log prefix identifying the calling store (e.g. `"VocabularyStore"`).
    ///   - decoder: JSON decoder (defaults to a plain `JSONDecoder`).
    ///   - transform: Applied to the decoded value before returning (default: identity).
    public static func load<T: Decodable>(
        from url: URL,
        default defaultValue: T,
        label: String,
        decoder: JSONDecoder = JSONDecoder(),
        transform: (T) -> T = { $0 }
    ) -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // Fresh store: no file yet.
            return defaultValue
        } catch {
            // The file EXISTS but could not be read (permissions, I/O error, a
            // stalled cloud-synced Application Support). Returning the default
            // silently would let the next save overwrite the intact file — move
            // it aside first, same as the undecodable branch below.
            let backup = url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            print("[\(label)] read failed: \(error); moved file to \(backup.lastPathComponent)")
            return defaultValue
        }
        do {
            return transform(try decoder.decode(T.self, from: data))
        } catch {
            // The file exists but is undecodable (corruption, hand-edit, version
            // skew). Move it aside instead of returning the default silently — the
            // next save would otherwise overwrite it and make the loss permanent.
            let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: backup)
            print("[\(label)] load failed: \(error); moved file to \(backup.lastPathComponent)")
            return defaultValue
        }
    }

    /// Encode `value` and atomically write it to `url`.
    ///
    /// The containing directory is always (re)created with `0o700` so the store
    /// dir's permissions are uniform regardless of which store writes first.
    /// Failures are logged and swallowed — a store save is best-effort, never
    /// fatal.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - url: The destination JSON file.
    ///   - label: Log prefix identifying the calling store.
    ///   - encoder: JSON encoder (defaults to a plain `JSONEncoder`).
    public static func save<T: Encodable>(
        _ value: T,
        to url: URL,
        label: String,
        encoder: JSONEncoder = JSONEncoder()
    ) {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[\(label)] save failed: \(error.localizedDescription)")
        }
    }
}
