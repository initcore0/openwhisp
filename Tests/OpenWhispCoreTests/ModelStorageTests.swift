import XCTest
@testable import OpenWhispCore

/// Pure accounting for the Settings "Storage" view: sorting, totals, and byte
/// formatting. The disk walk itself is app-side; this covers the display logic.
final class ModelStorageTests: XCTestCase {

    private func item(
        _ kind: ModelStorage.Kind,
        _ label: String,
        _ path: String,
        _ bytes: Int64,
        active: Bool = false
    ) -> ModelStorage.Item {
        ModelStorage.Item(kind: kind, label: label, path: path, bytes: bytes, isActive: active)
    }

    func testTotalBytesSums() {
        let items = [
            item(.whisperKit, "small", "/a", 500),
            item(.whisperCpp, "base", "/b", 100),
            item(.bundledLLM, "qwen", "/c", 400),
        ]
        XCTAssertEqual(ModelStorage.totalBytes(items), 1000)
    }

    func testTotalBytesEmptyIsZero() {
        XCTAssertEqual(ModelStorage.totalBytes([]), 0)
    }

    func testTotalBytesClampsNegative() {
        // A failed measurement (-1) must not drag the total below the real sum.
        let items = [item(.whisperKit, "x", "/x", -1), item(.whisperKit, "y", "/y", 200)]
        XCTAssertEqual(ModelStorage.totalBytes(items), 200)
    }

    func testSortByKindThenSizeThenLabel() {
        let items = [
            item(.bundledLLM, "qwen", "/llm", 400),
            item(.whisperCpp, "base", "/cpp", 100),
            item(.whisperKit, "tiny", "/wk-tiny", 73),
            item(.whisperKit, "turbo", "/wk-turbo", 1500),
        ]
        let sorted = ModelStorage.sorted(items)
        // whisperKit first (turbo before tiny — larger first), then whisperCpp, then LLM.
        XCTAssertEqual(sorted.map(\.label), ["turbo", "tiny", "base", "qwen"])
    }

    func testSortTieBreaksOnLabel() {
        let items = [
            item(.whisperKit, "b", "/b", 100),
            item(.whisperKit, "a", "/a", 100),
        ]
        XCTAssertEqual(ModelStorage.sorted(items).map(\.label), ["a", "b"])
    }

    func testItemIdIsPath() {
        XCTAssertEqual(item(.whisperKit, "small", "/path/to/model", 1).id, "/path/to/model")
    }

    func testFormatBytes() {
        // ByteCountFormatter(.file) uses decimal units on macOS (matches Finder).
        XCTAssertEqual(ModelStorage.format(bytes: 0), "Zero KB")
        XCTAssertTrue(ModelStorage.format(bytes: 1_500_000_000).contains("GB"))
        XCTAssertTrue(ModelStorage.format(bytes: 464_000_000).contains("MB"))
        // Negative clamps to zero, never a negative string.
        XCTAssertFalse(ModelStorage.format(bytes: -5).contains("-"))
    }
}
