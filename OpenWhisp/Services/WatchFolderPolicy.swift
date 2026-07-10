import Foundation

/// Pure, testable rules for watch-folder auto-transcription (MAK-36).
///
/// The app-side watcher (FSEvents / DispatchSource) detects filesystem changes in
/// monitored directories; *whether* a detected file should be enqueued — the
/// extension allow-list, the debounce (a file still being written shouldn't be
/// grabbed mid-copy), and the already-seen dedupe — is decided here so it can be
/// unit-tested without touching the filesystem or FSEvents.

/// The media container extensions OpenWhisp will decode (MP3/MP4/M4A/WAV/WEBM plus
/// a few common siblings AVFoundation handles). Lower-cased, no leading dot.
enum SupportedMediaExtensions {
    static let all: Set<String> = [
        "mp3", "mp4", "m4a", "wav", "webm",
        "aac", "aiff", "aif", "caf", "flac", "mov", "m4v",
    ]

    /// True if `path`'s extension is a supported media container.
    static func isSupported(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return all.contains(ext)
    }
}

/// A monitored directory + the eligibility knobs for it. Codable so it persists.
struct WatchFolder: Identifiable, Codable, Equatable {
    let id: UUID
    /// Absolute path to the directory being watched.
    var path: String
    /// Whether monitoring is currently on for this folder.
    var enabled: Bool

    init(id: UUID = UUID(), path: String, enabled: Bool = true) {
        self.id = id
        self.path = path
        self.enabled = enabled
    }

    var displayName: String { (path as NSString).lastPathComponent }
}

/// A filesystem observation the watcher hands to the policy: a path and the time it
/// was observed (injected so debounce is testable without a real clock).
struct WatchedFileEvent: Equatable {
    let path: String
    /// Last-modified time of the file, if known.
    let modifiedAt: Date
    /// When the watcher observed the change.
    let observedAt: Date
}

/// Decides which observed files are ready to enqueue.
struct WatchFolderPolicy {
    /// A file must be quiescent (unmodified) for at least this long before it's
    /// enqueued, so in-progress copies/downloads aren't grabbed mid-write.
    let debounceSeconds: Double
    /// Paths already enqueued/seen — never re-enqueued.
    private var seen: Set<String>

    init(debounceSeconds: Double = 2.0, seen: Set<String> = []) {
        self.debounceSeconds = debounceSeconds
        self.seen = seen
    }

    /// Whether an observed file is eligible to enqueue *now*:
    ///   - supported extension,
    ///   - not already seen,
    ///   - last modification at least `debounceSeconds` in the past (quiescent).
    /// This is a pure query — it does NOT mark the path seen (call `markSeen`).
    func isEligible(_ event: WatchedFileEvent) -> Bool {
        guard SupportedMediaExtensions.isSupported(path: event.path) else { return false }
        guard !seen.contains(event.path) else { return false }
        let quietFor = event.observedAt.timeIntervalSince(event.modifiedAt)
        return quietFor >= debounceSeconds
    }

    /// True if the path has already been enqueued/seen.
    func hasSeen(_ path: String) -> Bool { seen.contains(path) }

    /// Record that a path has been enqueued so it's never picked up again.
    mutating func markSeen(_ path: String) { seen.insert(path) }

    /// Forget a path (e.g. it was removed from the folder) so a fresh drop of the
    /// same name is eligible again.
    mutating func forget(_ path: String) { seen.remove(path) }

    /// Filter a batch of observations to the eligible ones (does not mark seen).
    func eligible(from events: [WatchedFileEvent]) -> [WatchedFileEvent] {
        events.filter { isEligible($0) }
    }
}
