import Foundation

/// Pure path/name resolution for the whisper.cpp toolchain and its GGML model
/// files (MAK-32 decomposition: extracted from `AppState` so the god-object
/// shrinks and the name/path fallback rules are `swift test`-able without
/// AppKit). Foundation-only, no state — every function is a total mapping over
/// its inputs plus the fixed install locations.
enum WhisperModelPaths {

    /// The on-disk GGML file name for a whisper.cpp model id.
    static func modelFileName(for modelName: String) -> String {
        switch modelName {
        case "tiny":          return "ggml-tiny.bin"
        case "tiny.en":       return "ggml-tiny.en.bin"
        case "base":          return "ggml-base.bin"
        case "base.en":       return "ggml-base.en.bin"
        case "small":         return "ggml-small.bin"
        case "small.en":      return "ggml-small.en.bin"
        case "medium":        return "ggml-medium.bin"
        case "medium.en":     return "ggml-medium.en.bin"
        case "large-v3":      return "ggml-large-v3.bin"
        case "large-v3-turbo": return "ggml-large-v3-turbo.bin"
        default:         return "ggml-base.bin"
        }
    }

    /// The whisper-cli binary to use: a saved path that still exists wins, then
    /// the bundled binary, then the conventional dev-build location.
    static func preferredWhisperCLIPath(savedPath: String) -> String {
        if !savedPath.isEmpty, FileManager.default.fileExists(atPath: savedPath) {
            return savedPath
        }

        if let bundled = bundledResourcePath("whisper/whisper-cli"),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        return "\(NSHomeDirectory())/whisper.cpp/build/bin/whisper-cli"
    }

    /// The GGML model file to use: a saved path that still exists wins, then a
    /// legacy whisper.cpp checkout location, then the app's models directory.
    static func preferredModelPath(savedPath: String, fileName: String) -> String {
        if !savedPath.isEmpty, FileManager.default.fileExists(atPath: savedPath) {
            return savedPath
        }

        let oldWhisperCppPath = "\(NSHomeDirectory())/whisper.cpp/models/\(fileName)"
        if FileManager.default.fileExists(atPath: oldWhisperCppPath) {
            return oldWhisperCppPath
        }

        return applicationSupportModelsDirectory()
            .appendingPathComponent(fileName)
            .path
    }

    /// Absolute path of a bundled resource, or nil when there is no resource URL
    /// (e.g. under `swift test`).
    static func bundledResourcePath(_ relativePath: String) -> String? {
        Bundle.main.resourceURL?
            .appendingPathComponent(relativePath)
            .path
    }

    /// `~/Library/Application Support/OpenWhisp/models` — where downloaded GGML
    /// and GGUF models are staged.
    static func applicationSupportModelsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenWhisp/models", isDirectory: true)
    }

    /// Reject a downloaded payload that isn't the expected model format before it
    /// is installed. Catches error/captive-portal pages served with HTTP 200 (a
    /// status check alone misses those): once a bogus file sits at the model path,
    /// ensure*ModelExists treats it as installed forever and every transcription
    /// fails with no in-app recovery.
    static func validateModelMagic(at url: URL, expected: [String], fileName: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        let magics = expected.compactMap { $0.data(using: .ascii) }
        guard magics.contains(head) else {
            throw ModelDownloadError(message: "Downloaded \(fileName) is not a valid model file (server may have returned an error page)")
        }
    }
}

/// One row of a bundled model manifest (models/manifest.json and
/// models/llm-manifest.json).
struct ModelManifestEntry: Decodable {
    let id: String
    let file: String
    let label: String
    let size: String
    let url: String
    /// Present in the LLM manifest (llm-manifest.json); absent in the whisper one.
    let license: String?
}

struct ModelDownloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
