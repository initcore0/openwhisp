import Foundation

/// Pure, testable validation for the Agent Bridge `transcribe.file` verb (MAK-83).
///
/// An agent hands OpenWhisp a local path; before any decode/engine work runs, the
/// path is vetted here so the rules — absolute, exists, readable, a supported
/// audio/video extension, under the size cap, and canonicalized so no `..`
/// traversal or symlink surprises change what the extension check saw — live in
/// one Foundation-only place `swift test` exercises directly (no sockets, no
/// engines, no AppKit). The bridge host calls ``validate(path:language:fileManager:)``
/// and either decodes the returned canonical path or answers the mapped
/// ``BridgeWire.ErrorObject``.
///
/// This is emphatically NOT a filesystem-access grant: OpenWhisp only ever reads
/// the single file the agent already named (and could already read itself). The
/// validation exists to fail fast and safely, not to widen reach.
public enum TranscribeFileRequest {

    /// The upper bound on an accepted source file. A generous 1 GiB — long
    /// recordings decode fine, but a pathological or hostile path can't make the
    /// app try to memory-map a runaway file.
    public static let maxFileSizeBytes: Int = 1 << 30 // 1 GiB

    /// Why a `transcribe.file` request was refused, mapped 1:1 onto a
    /// ``BridgeWire.ErrorObject`` by ``errorObject``. Kept as a value so the pure
    /// validator has no dependency on the wire error's construction.
    public enum Rejection: Equatable, Error {
        /// The path was empty or not absolute.
        case notAbsolute
        /// The extension isn't one the file engines can decode.
        case unsupportedExtension(String)
        /// No file exists at the (canonical) path, or it's a directory.
        case notFound
        /// The file exists but isn't readable by this process.
        case notReadable
        /// The file is larger than ``maxFileSizeBytes``.
        case tooLarge(bytes: Int)

        /// A human-readable, non-leaky message for the wire error.
        public var message: String {
            switch self {
            case .notAbsolute:
                return "path must be an absolute path to an audio file"
            case .unsupportedExtension(let ext):
                let known = SupportedMediaExtensions.all.sorted().joined(separator: ", ")
                return ext.isEmpty
                    ? "the file has no extension; supported: \(known)"
                    : "unsupported file type '.\(ext)'; supported: \(known)"
            case .notFound:
                return "no readable file exists at that path"
            case .notReadable:
                return "the file exists but OpenWhisp can't read it"
            case .tooLarge(let bytes):
                return "the file is \(bytes) bytes, over the \(TranscribeFileRequest.maxFileSizeBytes)-byte limit"
            }
        }

        private var wireCode: BridgeWire.ErrorCode {
            switch self {
            case .unsupportedExtension: return .unsupportedFormat
            // A bad/missing/unreadable/oversized path is a caller mistake, not a
            // server fault; surface it as a malformed request the agent can fix.
            case .notAbsolute, .notFound, .notReadable, .tooLarge:
                return .malformedRequest
            }
        }

        /// The wire error a rejected request answers with.
        public var errorObject: BridgeWire.ErrorObject {
            let code = wireCode == .unsupportedFormat
                ? BridgeWire.ErrorObject.serverError
                : BridgeWire.ErrorObject.invalidParams
            return BridgeWire.ErrorObject(
                code: code,
                message: message,
                data: BridgeWire.ErrorData(reason: wireCode)
            )
        }
    }

    /// A vetted request: the CANONICAL absolute path to hand the decoder (symlinks
    /// resolved, `..` collapsed) plus the optional language hint, unchanged.
    public struct Validated: Equatable {
        public let canonicalPath: String
        public let language: String?

        public init(canonicalPath: String, language: String?) {
            self.canonicalPath = canonicalPath
            self.language = language
        }
    }

    /// Minimal filesystem seam so the validator is unit-testable against a fake.
    /// Production passes `FileManager.default`.
    public protocol FileProbing {
        /// Whether a file (not a directory) exists at `path`.
        func regularFileExists(atPath path: String) -> Bool
        /// Whether `path` is readable by this process.
        func isReadable(atPath path: String) -> Bool
        /// The file's size in bytes, or nil if unknown.
        func fileSize(atPath path: String) -> Int?
    }

    /// Validate a raw client-supplied path. Returns the canonical path to decode,
    /// or a ``Rejection`` explaining the refusal. `fileManager` is injectable for
    /// tests; production uses ``FileManager/default``.
    ///
    /// Order matters: the cheap syntactic checks (absolute, extension) run BEFORE
    /// any filesystem probe, and the extension is re-checked on the CANONICAL path
    /// so a symlink whose name ends in `.wav` but resolves to `secret.txt` can't
    /// smuggle a non-audio target past the whitelist.
    public static func validate(
        path: String,
        language: String?,
        fileManager: FileProbing = DefaultFileProbe()
    ) -> Result<Validated, Rejection> {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            return .failure(.notAbsolute)
        }

        // Canonicalize FIRST (resolve symlinks + collapse `..`) so every later
        // check — extension, existence, size — sees the real target, never a
        // deceptive alias.
        let canonical = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().path

        let ext = (canonical as NSString).pathExtension.lowercased()
        guard SupportedMediaExtensions.all.contains(ext) else {
            return .failure(.unsupportedExtension(ext))
        }

        guard fileManager.regularFileExists(atPath: canonical) else {
            return .failure(.notFound)
        }
        guard fileManager.isReadable(atPath: canonical) else {
            return .failure(.notReadable)
        }
        if let size = fileManager.fileSize(atPath: canonical), size > maxFileSizeBytes {
            return .failure(.tooLarge(bytes: size))
        }

        let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(Validated(
            canonicalPath: canonical,
            language: (lang?.isEmpty ?? true) ? nil : lang
        ))
    }

    /// The production ``FileProbing`` over ``FileManager/default``.
    public struct DefaultFileProbe: FileProbing {
        public init() {}
        public func regularFileExists(atPath path: String) -> Bool {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return exists && !isDir.boolValue
        }
        public func isReadable(atPath path: String) -> Bool {
            FileManager.default.isReadableFile(atPath: path)
        }
        public func fileSize(atPath path: String) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int
        }
    }
}
