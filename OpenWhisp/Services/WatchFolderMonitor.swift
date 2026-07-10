import Foundation

/// App-side directory watcher for auto-transcription (MAK-36). Uses the FSEvents
/// stream API to notice files appearing in monitored folders, then hands each
/// candidate to `WatchFolderPolicy` (the pure eligibility/debounce logic) before
/// enqueuing.
///
/// FSEvents fires on directory-level changes; on each event this rescans the
/// watched folder's shallow contents and reports files, letting the pure policy
/// filter out unsupported types, in-progress copies (debounce), and already-seen
/// paths. Eligibility/debounce rules are unit-tested in `WatchFolderPolicyTests`;
/// this class is the thin OS glue.
final class WatchFolderMonitor {
    /// Called (on the main queue) with observed files when a watched folder changes.
    var onFilesObserved: (([WatchedFileEvent]) -> Void)?

    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private let queue = DispatchQueue(label: "app.openwhisp.watchfolders")

    /// Start (or restart) monitoring the given directory paths. Passing an empty
    /// list stops monitoring.
    func start(paths: [String]) {
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        self.paths = existing

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<WatchFolderMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.rescan()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        // Do an initial scan so files already present when monitoring starts are
        // considered (the pure policy still debounces/dedupes them).
        queue.async { [weak self] in self?.rescan() }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private func rescan() {
        let fm = FileManager.default
        var observed: [WatchedFileEvent] = []
        let now = Date()
        for dir in paths {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries {
                let full = (dir as NSString).appendingPathComponent(name)
                guard SupportedMediaExtensions.isSupported(path: full) else { continue }
                let attrs = try? fm.attributesOfItem(atPath: full)
                let modified = (attrs?[.modificationDate] as? Date) ?? now
                observed.append(WatchedFileEvent(path: full, modifiedAt: modified, observedAt: now))
            }
        }
        guard !observed.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onFilesObserved?(observed)
        }
    }
}
