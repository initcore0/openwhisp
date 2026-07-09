import XCTest
@testable import OpenWhispCore

/// Unit tests for the pure subprocess-identity decision logic — the sharpest
/// part of MAK-27 (basename-only identity check let OpenWhisp SIGKILL a user's
/// own Homebrew/manually-built server after a crash + PID reuse). The
/// path-resolution and `kill()` parts can't be unit-tested (they touch the live
/// process table), but this decision — given a resolved path — can and must.
final class ServerProcessIdentityTests: XCTestCase {

    private let bundlePrefix = "/Applications/OpenWhisp.app/Contents/Resources/whisper"
    private let devPrefix = "/Users/dev/whisper.cpp/build/bin"

    private func isOwned(_ path: String, basename: String = "whisper-server") -> Bool {
        ServerProcessIdentity.isOwnedServerProcess(
            executablePath: path,
            ownedPrefixes: [bundlePrefix, devPrefix],
            expectedBasename: basename
        )
    }

    // MARK: - Positive cases (a process we actually own)

    func testOwnedBundledServerIsOwned() {
        XCTAssertTrue(isOwned("\(bundlePrefix)/whisper-server"))
    }

    func testOwnedDevBuildServerIsOwned() {
        XCTAssertTrue(isOwned("\(devPrefix)/whisper-server"))
    }

    // MARK: - The MAK-27 bug: basename matches but path is NOT ours

    func testHomebrewServerWithMatchingBasenameIsNotOwned() {
        // The exact bug: a user's Homebrew whisper-server. Basename matches;
        // path is not under any prefix we own — must NOT be signalled.
        XCTAssertFalse(isOwned("/opt/homebrew/bin/whisper-server"))
    }

    func testUserBuiltServerElsewhereIsNotOwned() {
        XCTAssertFalse(isOwned("/Users/someone/code/whisper.cpp/whisper-server"))
    }

    func testUsrLocalBinServerIsNotOwned() {
        XCTAssertFalse(isOwned("/usr/local/bin/whisper-server"))
    }

    // MARK: - Basename mismatch

    func testDifferentBasenameUnderOwnedPrefixIsNotOwned() {
        // Even inside our owned dir, a PID whose executable is something else
        // (PID reuse gave the recycled PID to a different binary that happens to
        // live there) is not our server.
        XCTAssertFalse(isOwned("\(bundlePrefix)/whisper-cli"))
    }

    func testWrongBasenameIsNotOwned() {
        XCTAssertFalse(isOwned("\(devPrefix)/some-other-tool"))
    }

    // MARK: - Unresolvable path / empty inputs (conservative: never signal)

    func testEmptyPathIsNotOwned() {
        // proc_pidpath returned nothing — resolve failed — never signal.
        XCTAssertFalse(isOwned(""))
    }

    func testEmptyOwnedPrefixesIsNotOwned() {
        XCTAssertFalse(
            ServerProcessIdentity.isOwnedServerProcess(
                executablePath: "\(bundlePrefix)/whisper-server",
                ownedPrefixes: [],
                expectedBasename: "whisper-server"
            )
        )
    }

    func testEmptyStringPrefixesAreIgnored() {
        // A nil-derived empty prefix (e.g. Bundle.main.resourceURL was nil in a
        // test/CLI context) must not become a wildcard that matches everything.
        XCTAssertFalse(
            ServerProcessIdentity.isOwnedServerProcess(
                executablePath: "/opt/homebrew/bin/whisper-server",
                ownedPrefixes: ["", ""],
                expectedBasename: "whisper-server"
            )
        )
    }

    // MARK: - Prefix boundary safety (no partial-directory matches)

    func testSiblingDirectoryWithSharedPrefixIsNotOwned() {
        // `/…/whisper` must not match a sibling `/…/whisper-evil/…`: the prefix
        // is anchored to a directory boundary.
        XCTAssertFalse(isOwned("\(bundlePrefix)-evil/whisper-server"))
    }

    func testNestedPathUnderOwnedPrefixIsOwned() {
        // Deeper nesting under an owned dir still counts as owned.
        XCTAssertTrue(isOwned("\(bundlePrefix)/sub/whisper-server"))
    }

    func testOwnedPrefixWithTrailingSlashStillMatches() {
        XCTAssertTrue(
            ServerProcessIdentity.isOwnedServerProcess(
                executablePath: "\(bundlePrefix)/whisper-server",
                ownedPrefixes: ["\(bundlePrefix)/"],
                expectedBasename: "whisper-server"
            )
        )
    }

    // MARK: - Llama basename (same helper, both engines)

    func testLlamaServerBasenameUnderOwnedPrefixIsOwned() {
        let llamaBundle = "/Applications/OpenWhisp.app/Contents/Resources/llama"
        XCTAssertTrue(
            ServerProcessIdentity.isOwnedServerProcess(
                executablePath: "\(llamaBundle)/llama-server",
                ownedPrefixes: [llamaBundle],
                expectedBasename: "llama-server"
            )
        )
    }

    func testHomebrewLlamaServerIsNotOwned() {
        let llamaBundle = "/Applications/OpenWhisp.app/Contents/Resources/llama"
        XCTAssertFalse(
            ServerProcessIdentity.isOwnedServerProcess(
                executablePath: "/opt/homebrew/bin/llama-server",
                ownedPrefixes: [llamaBundle],
                expectedBasename: "llama-server"
            )
        )
    }
}
