import Foundation

/// The visual style of the recording overlay's voice indicator. User-selectable in
/// Settings → Appearance. Foundation-only (string-backed) so it lives in
/// OpenWhispCore, is persisted via UserDefaults, and is unit-testable.
///
/// Styles are added across phases: `.waveform` ships first; `.bars` (FFT-driven
/// spectral bars) and `.orb` (Metal-shader glow) land in subsequent phases. The
/// overlay renders the best available style and falls back to `.waveform` for any
/// not-yet-implemented case, so an unknown/stored value is always safe.
enum VoiceIndicatorStyle: String, CaseIterable, Identifiable {
    /// Smooth mirrored waveform (SwiftUI Canvas). Always available.
    case waveform
    /// Spectral bars driven by an FFT of the live mic (SwiftUI Canvas).
    case bars
    /// Glowing, breathing orb (Metal shader).
    case orb

    var id: String { rawValue }

    /// Human label for the Settings picker.
    var displayName: String {
        switch self {
        case .waveform: return "Waveform"
        case .bars:     return "Spectral bars"
        case .orb:      return "Glowing orb"
        }
    }

    /// One-line description shown under the picker.
    var detail: String {
        switch self {
        case .waveform: return "A smooth mirrored wave that tracks your voice."
        case .bars:     return "Reactive frequency bars — clear, legible motion."
        case .orb:      return "A fluid glowing orb that breathes with your voice."
        }
    }

    /// The default style for a fresh install.
    static let defaultStyle: VoiceIndicatorStyle = .bars

    /// Parse a stored raw value, defaulting safely.
    static func from(_ raw: String?) -> VoiceIndicatorStyle {
        guard let raw, let style = VoiceIndicatorStyle(rawValue: raw) else { return defaultStyle }
        return style
    }
}
