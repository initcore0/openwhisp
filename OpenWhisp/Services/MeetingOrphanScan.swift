import Foundation

// MARK: - MeetingOrphanScan (pure crash-recovery name parsing + grouping)

/// Pure, Foundation-only parsing + grouping for Meeting-mode crash recovery
/// (MAK-50 mixed WAVs + MAK-52 leg WAVs). Extracted from `MeetingCaptureSession`
/// so the naming/grouping rules — which decide what gets salvaged and how the legs
/// re-attach to their mixed recording — are unit-tested via `swift test`; the
/// app-only capture session does the filesystem IO (`recoverInPlace`, size → frames)
/// around this.
///
/// In-flight capture files are named:
///   `meeting_<stamp>_<uuid>.wav`      → the mixed recording
///   `meeting_<stamp>_<uuid>_mic.wav`  → the mic ("Me") leg
///   `meeting_<stamp>_<uuid>_sys.wav`  → the system ("Them") leg
/// A successful ingest MOVES these to canonical `meeting-<uuid>*.wav` names, so
/// anything still matching the in-flight pattern at launch is an orphan.
public enum MeetingOrphanScan {

    public enum LegKind: Equatable { case mixed, mic, system }

    /// One parsed in-flight file.
    public struct Parsed: Equatable {
        public let stamp: TimeInterval
        public let id: UUID
        public let kind: LegKind
        public init(stamp: TimeInterval, id: UUID, kind: LegKind) {
            self.stamp = stamp; self.id = id; self.kind = kind
        }
    }

    /// A recovery group: one meeting id with whichever of its files survived.
    public struct Group: Equatable {
        public let id: UUID
        public let stamp: TimeInterval
        public let mixed: String?
        public let mic: String?
        public let system: String?
    }

    /// Parse one in-flight capture leaf name, or nil if it isn't one of ours.
    public static func parse(_ name: String) -> Parsed? {
        guard name.hasPrefix("meeting_"), name.hasSuffix(".wav") else { return nil }
        var stem = String(name.dropFirst("meeting_".count).dropLast(".wav".count))
        var kind: LegKind = .mixed
        if stem.hasSuffix("_mic") { kind = .mic; stem = String(stem.dropLast(4)) }
        else if stem.hasSuffix("_sys") { kind = .system; stem = String(stem.dropLast(4)) }
        let parts = stem.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let stamp = TimeInterval(parts[0]),
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        return Parsed(stamp: stamp, id: id, kind: kind)
    }

    /// Group a directory listing into per-meeting recovery groups. Non-matching
    /// names are ignored; each group carries the filenames of the files that were
    /// present (so a meeting can be recovered with whatever legs exist — even a leg
    /// with no mixed WAV). Order is not significant.
    public static func group(_ names: [String]) -> [Group] {
        struct Acc { var stamp: TimeInterval; var mixed: String?; var mic: String?; var system: String? }
        var acc: [UUID: Acc] = [:]
        for name in names {
            guard let p = parse(name) else { continue }
            var a = acc[p.id] ?? Acc(stamp: p.stamp, mixed: nil, mic: nil, system: nil)
            switch p.kind {
            case .mixed: a.mixed = name
            case .mic: a.mic = name
            case .system: a.system = name
            }
            acc[p.id] = a
        }
        return acc.map { Group(id: $0.key, stamp: $0.value.stamp, mixed: $0.value.mixed,
                               mic: $0.value.mic, system: $0.value.system) }
    }
}
