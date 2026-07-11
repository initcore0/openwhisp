import Foundation

// MARK: - MeetingTalkState (live "who's talking" resolver)

/// Pure, Foundation-only resolver that turns the two per-leg live levels
/// (mic = "You", system = "Them") into a coarse talking indicator for Meeting
/// mode (MAK-52). It exists so the UI's live-recording row can say "You're
/// talking" / "They're talking" / "Both" / "…" without any AppKit dependency, and
/// so the hysteresis logic is unit-tested.
///
/// ## Why hysteresis
///
/// The raw per-leg levels (a coarse RMS mapped through `AudioLevel`) jitter around
/// the speech/silence boundary — a single frame can dip below any fixed threshold
/// mid-word. A naive `level > threshold` test therefore flaps the label many times
/// a second, which reads as flicker. We use two thresholds per leg (a Schmitt
/// trigger): a leg must rise ABOVE `onThreshold` to be considered active, and only
/// falls inactive once it drops BELOW the lower `offThreshold`. Between the two it
/// holds its previous active/inactive state. That band absorbs the jitter so the
/// label is stable while someone is actually talking.
public struct MeetingTalkState: Equatable {

    /// Who is currently talking, as far as the coarse levels can tell.
    public enum Speaker: Equatable {
        case silence
        case you    // mic leg active
        case them   // system leg active
        case both

        /// Short human label for the live row.
        public var label: String {
            switch self {
            case .silence: return "…"
            case .you: return "You're talking"
            case .them: return "They're talking"
            case .both: return "Both talking"
            }
        }

        /// A tiny glyph for the menu title (cheap; no SF Symbols needed).
        public var glyph: String {
            switch self {
            case .silence: return "🔴"
            case .you: return "🎙️"
            case .them: return "🔊"
            case .both: return "🗣️"
            }
        }
    }

    // MARK: Thresholds (on `AudioLevel`'s 0…1 normalized scale)

    /// A leg must exceed this normalized level to become "active". Sits comfortably
    /// above a quiet room (which maps near 0 after `AudioLevel.fromRMS`) but below
    /// normal conversational speech, which swings across most of the 0…1 range.
    public static let onThreshold: Float = 0.22
    /// A leg already active stays active until it drops below this lower level. The
    /// gap to `onThreshold` is the hysteresis band that suppresses per-frame
    /// flapping at the speech/silence boundary and across inter-word gaps.
    public static let offThreshold: Float = 0.12

    /// Whether each leg is currently considered active (the retained Schmitt state).
    public private(set) var youActive: Bool
    public private(set) var themActive: Bool

    public init(youActive: Bool = false, themActive: Bool = false) {
        self.youActive = youActive
        self.themActive = themActive
    }

    /// The current derived speaker from the retained active flags.
    public var speaker: Speaker {
        switch (youActive, themActive) {
        case (false, false): return .silence
        case (true, false): return .you
        case (false, true): return .them
        case (true, true): return .both
        }
    }

    /// Fold one (micLevel, systemLevel) sample into the state, applying per-leg
    /// hysteresis, and return the new speaker. Mutating so a caller can keep one
    /// value and feed it live levels.
    @discardableResult
    public mutating func update(micLevel: Float, systemLevel: Float) -> Speaker {
        youActive = Self.step(active: youActive, level: micLevel)
        themActive = Self.step(active: themActive, level: systemLevel)
        return speaker
    }

    /// Schmitt-trigger step for one leg: rise above `onThreshold` to activate, fall
    /// below `offThreshold` to deactivate, else hold.
    private static func step(active: Bool, level: Float) -> Bool {
        if active { return level >= offThreshold }
        return level >= onThreshold
    }
}
