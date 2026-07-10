import XCTest
@testable import OpenWhispCore

final class WatchFolderPolicyTests: XCTestCase {

    private func event(_ path: String, quietFor: Double) -> WatchedFileEvent {
        let observed = Date()
        return WatchedFileEvent(path: path, modifiedAt: observed.addingTimeInterval(-quietFor), observedAt: observed)
    }

    func testSupportedExtensions() {
        XCTAssertTrue(SupportedMediaExtensions.isSupported(path: "/a/b.mp3"))
        XCTAssertTrue(SupportedMediaExtensions.isSupported(path: "/a/b.MP4"))
        XCTAssertTrue(SupportedMediaExtensions.isSupported(path: "/a/b.webm"))
        XCTAssertFalse(SupportedMediaExtensions.isSupported(path: "/a/b.txt"))
        XCTAssertFalse(SupportedMediaExtensions.isSupported(path: "/a/b"))
    }

    func testUnsupportedExtensionNotEligible() {
        let p = WatchFolderPolicy(debounceSeconds: 2)
        XCTAssertFalse(p.isEligible(event("/a/note.txt", quietFor: 10)))
    }

    func testDebounceRejectsFreshlyModified() {
        let p = WatchFolderPolicy(debounceSeconds: 2)
        XCTAssertFalse(p.isEligible(event("/a/b.mp3", quietFor: 0.5))) // still being written
        XCTAssertTrue(p.isEligible(event("/a/b.mp3", quietFor: 3)))    // quiescent
    }

    func testSeenPathNotReEnqueued() {
        var p = WatchFolderPolicy(debounceSeconds: 1)
        let e = event("/a/b.mp3", quietFor: 5)
        XCTAssertTrue(p.isEligible(e))
        p.markSeen(e.path)
        XCTAssertFalse(p.isEligible(e))
        XCTAssertTrue(p.hasSeen("/a/b.mp3"))
    }

    func testForgetMakesEligibleAgain() {
        var p = WatchFolderPolicy(debounceSeconds: 1)
        p.markSeen("/a/b.mp3")
        p.forget("/a/b.mp3")
        XCTAssertTrue(p.isEligible(event("/a/b.mp3", quietFor: 5)))
    }

    func testEligibleBatchFilter() {
        let p = WatchFolderPolicy(debounceSeconds: 2)
        let events = [
            event("/a/ok.mp3", quietFor: 5),
            event("/a/fresh.mp4", quietFor: 0.1),
            event("/a/doc.pdf", quietFor: 5),
        ]
        let out = p.eligible(from: events).map(\.path)
        XCTAssertEqual(out, ["/a/ok.mp3"])
    }

    func testWatchFolderCodable() throws {
        let f = WatchFolder(path: "/Users/me/Downloads", enabled: true)
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(WatchFolder.self, from: data)
        XCTAssertEqual(back, f)
        XCTAssertEqual(back.displayName, "Downloads")
    }
}
