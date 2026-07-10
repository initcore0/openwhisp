import XCTest
@testable import OpenWhispCore

/// Unit tests for the pure decision inputs of the shared subprocess-lifecycle
/// helper (MAK-21): the `ManagedServerSpec` naming rules and the
/// `StalePIDReaper` PID-file parse gate. The `Process`/socket glue in
/// `ManagedServerProcess` is app-only and exercised by the real-engine E2E
/// (`./scripts/e2e-whisperkit.sh`), not here.
final class ManagedServerSpecTests: XCTestCase {

    // MARK: - ManagedServerSpec file naming

    func testWhisperSpecPidAndLogFilesLiveInCachesDir() {
        let spec = ManagedServerSpec(
            executableBasename: "whisper-server",
            logTag: "whisper-server",
            pidFileName: "whisper-server.pid",
            logFileName: "whisper-engine.log"
        )
        let caches = ManagedServerSpec.cachesDirectory()
        XCTAssertEqual(spec.pidFileURL, caches.appendingPathComponent("whisper-server.pid"))
        XCTAssertEqual(spec.logFileURL, caches.appendingPathComponent("whisper-engine.log"))
        // The two engines must never share a PID or log file, or one would reap
        // the other. Assert the whisper vs llama names are distinct.
        XCTAssertNotEqual(spec.pidFileName, "llama-server.pid")
        XCTAssertNotEqual(spec.logFileName, "llama-engine.log")
    }

    func testCachesDirectoryIsBundleScoped() {
        // The stale-reap + PID files must sit under the app's own bundle-scoped
        // Caches dir so one OpenWhisp instance never touches another app's files.
        XCTAssertTrue(
            ManagedServerSpec.cachesDirectory().path.hasSuffix("Library/Caches/com.openwhisp.app"),
            "PID/log files must live in the bundle-scoped Caches dir"
        )
    }

    // MARK: - StalePIDReaper.candidatePID

    func testCandidatePIDParsesPositivePID() {
        XCTAssertEqual(StalePIDReaper.candidatePID(fromFileContents: "4321"), 4321)
    }

    func testCandidatePIDTrimsWhitespaceAndNewlines() {
        XCTAssertEqual(StalePIDReaper.candidatePID(fromFileContents: "  4321\n"), 4321)
        XCTAssertEqual(StalePIDReaper.candidatePID(fromFileContents: "\t 999 \n"), 999)
    }

    func testCandidatePIDRejectsNilAndEmpty() {
        XCTAssertNil(StalePIDReaper.candidatePID(fromFileContents: nil))
        XCTAssertNil(StalePIDReaper.candidatePID(fromFileContents: ""))
        XCTAssertNil(StalePIDReaper.candidatePID(fromFileContents: "   \n"))
    }

    func testCandidatePIDRejectsNonNumeric() {
        XCTAssertNil(StalePIDReaper.candidatePID(fromFileContents: "not-a-pid"))
        XCTAssertNil(StalePIDReaper.candidatePID(fromFileContents: "12x34"))
    }

    func testCandidatePIDRejectsNonPositive() {
        // 0 and negative PIDs are never signal-eligible: signalling PID 0 or a
        // negative would target a process GROUP, potentially the whole app.
        XCTAssertNil(StalePIDReaper.candidatePID(fromFileContents: "0"))
        XCTAssertNil(StalePIDReaper.candidatePID(fromFileContents: "-1"))
        XCTAssertNil(StalePIDReaper.candidatePID(fromFileContents: "-4321"))
    }
}
