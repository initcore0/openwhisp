import Foundation

/// Build-independent catalog of locally-staged WhisperKit CoreML models.
///
/// WhisperKit models are staged as folders of compiled sub-models under
/// Application Support (see docs/WHISPERKIT_PILOT.md). This type lists what's
/// actually installed and gives each a friendly label, so the Settings UI can
/// offer a picker of *loadable* models without importing WhisperKit (it's pure
/// Foundation, so it compiles in the default build and is unit-testable).
enum WhisperKitModelCatalog {
    /// Base dir where staged WhisperKit model folders live.
    static var baseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("whisperkit-models", isDirectory: true)
    }

    /// The three compiled sub-models a staged WhisperKit model must contain to load.
    static let requiredSubmodels = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]

    /// True iff `model` is staged with all required compiled sub-models present.
    static func isStaged(_ model: String) -> Bool {
        isStaged(model, fileExists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Testable core: `fileExists` is injected so tests don't touch the real disk.
    static func isStaged(_ model: String, fileExists: (String) -> Bool) -> Bool {
        let folder = baseDir.appendingPathComponent(model, isDirectory: true)
        return requiredSubmodels.allSatisfy {
            fileExists(folder.appendingPathComponent($0).path)
        }
    }

    /// Models staged on disk (folder names), sorted by our preferred display order.
    static func stagedModels() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: baseDir.path)) ?? []
        return names.filter { isStaged($0) }.sorted(by: orderedBefore)
    }

    /// Curated WhisperKit model ids OpenWhisp offers for in-app download, in display
    /// order. These map to folders in the `argmaxinc/whisperkit-coreml` HF repo. The
    /// download UI shows this list and marks which are already staged.
    static let downloadableModels = [
        "openai_whisper-small",
        "openai_whisper-tiny.en",
        "openai_whisper-large-v3-turbo",
    ]

    /// All models to surface in the picker/download UI: the curated downloadable set
    /// unioned with anything already staged on disk (so a manually-staged or
    /// previously-downloaded model isn't hidden), in preferred display order.
    static func selectableModels() -> [String] {
        var seen = Set<String>()
        let merged = downloadableModels + stagedModels()
        return merged.filter { seen.insert($0).inserted }.sorted(by: orderedBefore)
    }

    // MARK: - Display

    /// A human label + one-line hint for a WhisperKit model id. Pure string logic so
    /// it's the same in every build and easy to test.
    static func displayInfo(for model: String) -> (label: String, hint: String?) {
        switch model {
        case "openai_whisper-small":
            return ("Small (multilingual, recommended)", "Best balance for EN + RU streaming.")
        case "openai_whisper-tiny.en":
            return ("Tiny (English only)", "Fastest, English-only — no Russian.")
        case "openai_whisper-large-v3-turbo", "openai_whisper-large-v3-v20240930_turbo_632MB":
            return ("Turbo (heavy)", "Most accurate but a very slow first load; impractical on 16 GB Macs.")
        default:
            // Unknown staged model: prettify the id (drop the namespace prefix).
            let pretty = model.replacingOccurrences(of: "openai_whisper-", with: "")
            return (pretty, nil)
        }
    }

    /// Preferred ordering: small first, then tiny, then turbo, then anything else
    /// alphabetically. Keeps the recommended model at the top of the picker.
    private static func orderedBefore(_ a: String, _ b: String) -> Bool {
        rank(a) == rank(b) ? a < b : rank(a) < rank(b)
    }

    private static func rank(_ model: String) -> Int {
        switch model {
        case "openai_whisper-small": return 0
        case "openai_whisper-tiny.en": return 1
        case "openai_whisper-large-v3-turbo", "openai_whisper-large-v3-v20240930_turbo_632MB": return 2
        default: return 3
        }
    }
}
