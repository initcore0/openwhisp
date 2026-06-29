import Foundation
import os

/// Developer timing instrumentation — **off in consumer builds**.
///
/// The whole signpost/logging body is compiled in ONLY under the
/// `OPENWHISP_INSTRUMENTATION` flag (`INSTRUMENTATION=1 ./build.sh`). Without it,
/// every entry point here is a trivial no-op, so call sites can be written
/// unconditionally with zero cost or footprint in the shipped app.
///
/// When enabled it emits, for each measured span:
///  - an `os_signpost` interval (visible in Instruments / Console.app under the
///    "com.openwhisp.app" subsystem, category "instrumentation"), and
///  - a plain console line on completion (`[instr] <label>: <ms>ms`) you can read
///    in Terminal / Console without Instruments.
///
/// The duration formatting is a pure function (`Instrumentation.format`) compiled
/// in every build, so it stays unit-testable regardless of the flag.
enum Instrumentation {

    /// True iff instrumentation was compiled in. Lets non-gated code branch without
    /// its own `#if` (e.g. skip computing an expensive label when it won't be used).
    static var isEnabled: Bool {
        #if OPENWHISP_INSTRUMENTATION
        return true
        #else
        return false
        #endif
    }

    /// Format a duration (seconds) as a compact millisecond string, e.g. "4231ms".
    /// Pure + always compiled so it's unit-tested independent of the build flag.
    static func format(seconds: Double) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }

    /// Measure a synchronous block, recording a signpost interval + console line.
    /// No-op (just runs the block) when instrumentation is compiled out.
    @discardableResult
    static func measure<T>(_ label: StaticString, _ body: () throws -> T) rethrows -> T {
        #if OPENWHISP_INSTRUMENTATION
        let span = begin(label)
        defer { end(span) }
        return try body()
        #else
        return try body()
        #endif
    }

    /// Measure an async block (e.g. the WhisperKit model load). No-op when off.
    @discardableResult
    static func measure<T>(_ label: StaticString, _ body: () async throws -> T) async rethrows -> T {
        #if OPENWHISP_INSTRUMENTATION
        let span = begin(label)
        defer { end(span) }
        return try await body()
        #else
        return try await body()
        #endif
    }

    // MARK: - Manual span API (for spans that start/end across callbacks)

    /// An in-flight timing span. Carries no data when instrumentation is off.
    struct Span {
        #if OPENWHISP_INSTRUMENTATION
        let label: StaticString
        let signpostID: OSSignpostID
        let startedAt: Date
        #endif
    }

    /// Begin a manual span. Pair with `end(_:)`. No-op when off.
    static func begin(_ label: StaticString) -> Span {
        #if OPENWHISP_INSTRUMENTATION
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: label, signpostID: id)
        return Span(label: label, signpostID: id, startedAt: Date())
        #else
        return Span()
        #endif
    }

    /// End a manual span, emitting the signpost end + console line. No-op when off.
    static func end(_ span: Span) {
        #if OPENWHISP_INSTRUMENTATION
        let elapsed = Date().timeIntervalSince(span.startedAt)
        os_signpost(.end, log: log, name: span.label, signpostID: span.signpostID)
        NSLog("[instr] %@: %@", String(describing: span.label), format(seconds: elapsed))
        #endif
    }

    #if OPENWHISP_INSTRUMENTATION
    private static let log = OSLog(subsystem: "com.openwhisp.app", category: "instrumentation")
    #endif
}
