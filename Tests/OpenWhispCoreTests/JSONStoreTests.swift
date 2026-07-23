import XCTest
@testable import OpenWhispCore

/// Tests for the shared `JSONStore` load-with-quarantine / save helper that the
/// five on-device JSON stores were deduped onto (MAK-22).
final class JSONStoreTests: XCTestCase {

    // A small Codable payload standing in for the real store types; the helper is
    // generic, so exercising it with one value type covers all five callers.
    private struct Payload: Codable, Equatable {
        var name: String
        var count: Int
    }

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        try super.tearDownWithError()
    }

    private func fileURL(_ name: String = "store.json") -> URL {
        dir.appendingPathComponent(name)
    }

    /// Sibling files created in the same directory as `url` (the `.corrupt-*`
    /// backups the quarantine path leaves behind).
    private func siblings(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    }

    // MARK: - Load

    func testValidFileDecodes() throws {
        let url = fileURL()
        let value = Payload(name: "hello", count: 3)
        try JSONEncoder().encode(value).write(to: url)

        let loaded = JSONStore.load(from: url, default: Payload(name: "", count: 0), label: "Test")
        XCTAssertEqual(loaded, value)
    }

    func testMissingFileReturnsDefault() {
        let fallback = Payload(name: "default", count: 42)
        let loaded = JSONStore.load(from: fileURL("does-not-exist.json"),
                                    default: fallback, label: "Test")
        XCTAssertEqual(loaded, fallback)
    }

    func testCorruptFileReturnsDefaultAndQuarantines() throws {
        let url = fileURL()
        try Data("{ this is not valid json ]".utf8).write(to: url)

        let fallback = Payload(name: "default", count: 0)
        let loaded = JSONStore.load(from: url, default: fallback, label: "Test")

        // 1. Returns the default rather than crashing.
        XCTAssertEqual(loaded, fallback)

        // 2. The original (undecodable) file was moved aside, not left in place —
        //    so the next save can't silently overwrite the user's recoverable data.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "corrupt file should have been moved aside")

        // 3. A `.corrupt-*` sibling now exists.
        let corruptSiblings = try siblings(of: url).filter { $0.contains(".corrupt-") }
        XCTAssertEqual(corruptSiblings.count, 1,
                       "expected exactly one .corrupt-* backup, found \(corruptSiblings)")

        // 4. The backup still holds the original bytes (nothing lost).
        let backup = url.deletingLastPathComponent().appendingPathComponent(corruptSiblings[0])
        XCTAssertEqual(try Data(contentsOf: backup), Data("{ this is not valid json ]".utf8))
    }

    func testEmptyFileIsTreatedAsCorruptAndQuarantines() throws {
        // An empty file is not decodable JSON; it must be quarantined, not treated
        // as "missing".
        let url = fileURL()
        try Data().write(to: url)

        let fallback = Payload(name: "default", count: 0)
        let loaded = JSONStore.load(from: url, default: fallback, label: "Test")

        XCTAssertEqual(loaded, fallback)
        let corruptSiblings = try siblings(of: url).filter { $0.contains(".corrupt-") }
        XCTAssertEqual(corruptSiblings.count, 1)
    }

    func testUnreadableExistingFileReturnsDefaultAndQuarantines() throws {
        // A file that exists but can't be READ (vs. decoded) must not be left in
        // place: booting with the default and then saving would overwrite the
        // intact store. It gets moved aside to `.unreadable-*` instead.
        let url = fileURL()
        let original = Data("{\"name\":\"real\",\"count\":9}".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        if (try? Data(contentsOf: url)) != nil {
            throw XCTSkip("running as a user that can read mode-000 files (root?)")
        }

        let fallback = Payload(name: "default", count: 0)
        let loaded = JSONStore.load(from: url, default: fallback, label: "Test")

        XCTAssertEqual(loaded, fallback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "unreadable file should have been moved aside")
        let quarantined = try siblings(of: url).filter { $0.contains(".unreadable-") }
        XCTAssertEqual(quarantined.count, 1,
                       "expected exactly one .unreadable-* backup, found \(quarantined)")
        // The backup still holds the original bytes (verifiable after chmod).
        let backup = url.deletingLastPathComponent().appendingPathComponent(quarantined[0])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testTransformAppliedToDecodedValue() throws {
        let url = fileURL()
        try JSONEncoder().encode(Payload(name: "raw", count: 1)).write(to: url)

        let loaded = JSONStore.load(from: url, default: Payload(name: "", count: 0), label: "Test") {
            Payload(name: $0.name.uppercased(), count: $0.count + 100)
        }
        XCTAssertEqual(loaded, Payload(name: "RAW", count: 101))
    }

    func testTransformNotAppliedToDefaultOnMissingFile() {
        // The transform should only touch a decoded value; a missing file returns
        // the caller's default untouched.
        let fallback = Payload(name: "untouched", count: 0)
        let loaded = JSONStore.load(from: fileURL("nope.json"), default: fallback, label: "Test") {
            Payload(name: $0.name.uppercased(), count: $0.count + 100)
        }
        XCTAssertEqual(loaded, fallback)
    }

    func testCustomDecoderIsUsed() throws {
        // Prove the decoder parameter is honored: encode dates as epoch seconds and
        // decode them back with a matching strategy.
        struct Dated: Codable, Equatable { var when: Date }
        let url = fileURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(Dated(when: Date(timeIntervalSince1970: 1000))).write(to: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let loaded = JSONStore.load(from: url, default: Dated(when: .distantPast),
                                    label: "Test", decoder: decoder)
        XCTAssertEqual(loaded, Dated(when: Date(timeIntervalSince1970: 1000)))
    }

    // MARK: - Save

    func testSaveThenLoadRoundTrips() throws {
        let url = fileURL("nested/deeper/store.json")
        let value = Payload(name: "round", count: 7)

        JSONStore.save(value, to: url, label: "Test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let loaded = JSONStore.load(from: url, default: Payload(name: "", count: 0), label: "Test")
        XCTAssertEqual(loaded, value)
    }

    func testSaveCreatesDirectoryWith0700() throws {
        // The uniform-permissions fix: save() must create the store dir with 0o700.
        let subdir = dir.appendingPathComponent("perm-check", isDirectory: true)
        let url = subdir.appendingPathComponent("store.json")

        JSONStore.save(Payload(name: "x", count: 1), to: url, label: "Test")

        let attrs = try FileManager.default.attributesOfItem(atPath: subdir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o700, "store dir should be created with 0o700")
    }

    func testCustomEncoderIsUsed() throws {
        // AgentClientStore saves with pretty-printed + sorted keys; prove a custom
        // encoder is honored by checking the on-disk bytes are pretty-printed.
        let url = fileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        JSONStore.save(Payload(name: "x", count: 1), to: url, label: "Test", encoder: encoder)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "pretty-printed output should contain newlines")
        // sortedKeys → "count" before "name".
        let countIdx = try XCTUnwrap(text.range(of: "count")).lowerBound
        let nameIdx = try XCTUnwrap(text.range(of: "name")).lowerBound
        XCTAssertLessThan(countIdx, nameIdx)
    }
}
