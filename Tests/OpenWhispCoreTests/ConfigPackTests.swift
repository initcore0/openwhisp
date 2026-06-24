import XCTest
@testable import OpenWhispCore

final class ConfigPackTests: XCTestCase {

    private func packJSON(id: String, name: String, version: Int = 1, terms: [String] = ["x"]) -> Data {
        let termsJSON = terms.map { "\"\($0)\"" }.joined(separator: ",")
        return Data("""
        {
          "id": "\(id)",
          "name": "\(name)",
          "description": "desc for \(name)",
          "bundle": { "schemaVersion": \(version), "vocabulary": { "terms": [\(termsJSON)], "substitutions": [] } }
        }
        """.utf8)
    }

    // MARK: decode

    func testDecodeValidPack() throws {
        let pack = try ConfigPack.decode(from: packJSON(id: "a", name: "Alpha"))
        XCTAssertEqual(pack.id, "a")
        XCTAssertEqual(pack.name, "Alpha")
        XCTAssertEqual(pack.packDescription, "desc for Alpha")
        XCTAssertEqual(pack.contentsSummary, "1 vocab term")
    }

    func testDescriptionMapsFromJSONKey() throws {
        // The Swift property is `packDescription` but the JSON key is "description".
        let pack = try ConfigPack.decode(from: packJSON(id: "a", name: "Alpha"))
        XCTAssertEqual(pack.packDescription, "desc for Alpha")
    }

    func testRejectsPackWithNewerBundleVersion() {
        XCTAssertThrowsError(try ConfigPack.decode(from: packJSON(id: "a", name: "A", version: 999))) { error in
            XCTAssertEqual(error as? ConfigPack.DecodeError,
                           .unsupportedVersion(found: 999, supported: ConfigBundle.currentSchemaVersion))
        }
    }

    func testMalformedPackThrows() {
        XCTAssertThrowsError(try ConfigPack.decode(from: Data("garbage".utf8))) { error in
            guard case ConfigPack.DecodeError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    // MARK: parseAll

    func testParseAllSortsByName() {
        let files = [
            (name: "z.json", data: packJSON(id: "1", name: "Zebra")),
            (name: "a.json", data: packJSON(id: "2", name: "Apple")),
            (name: "m.json", data: packJSON(id: "3", name: "Mango"))
        ]
        XCTAssertEqual(ConfigPack.parseAll(files).map(\.name), ["Apple", "Mango", "Zebra"])
    }

    func testParseAllDedupesByIdFirstWins() {
        // Two files share id "dup"; sorted by filename, "a.json" wins.
        let files = [
            (name: "b.json", data: packJSON(id: "dup", name: "Second")),
            (name: "a.json", data: packJSON(id: "dup", name: "First"))
        ]
        let packs = ConfigPack.parseAll(files)
        XCTAssertEqual(packs.count, 1)
        XCTAssertEqual(packs.first?.name, "First")
    }

    func testParseAllSkipsBadFilesButKeepsGoodOnes() {
        let files = [
            (name: "good.json", data: packJSON(id: "g", name: "Good")),
            (name: "broken.json", data: Data("not json".utf8)),
            (name: "future.json", data: packJSON(id: "f", name: "Future", version: 999))
        ]
        // A malformed or too-new pack must never hide the valid ones.
        XCTAssertEqual(ConfigPack.parseAll(files).map(\.name), ["Good"])
    }

    func testParseAllEmpty() {
        XCTAssertTrue(ConfigPack.parseAll([]).isEmpty)
    }

    // MARK: Shipped packs are valid

    /// Loads the actual pack files shipped in OpenWhisp/Resources/packs and
    /// asserts they decode — so an authoring typo fails CI, not a user's import.
    func testShippedPacksAreValid() throws {
        // Walk up from this test file to the repo root, then into Resources/packs.
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()  // OpenWhispCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let packsDir = repoRoot
            .appendingPathComponent("OpenWhisp/Resources/packs", isDirectory: true)

        let names = try FileManager.default.contentsOfDirectory(atPath: packsDir.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertFalse(names.isEmpty, "expected shipped packs in \(packsDir.path)")

        var ids = Set<String>()
        for name in names {
            let data = try Data(contentsOf: packsDir.appendingPathComponent(name))
            let pack = try ConfigPack.decode(from: data)  // throws on any authoring error
            XCTAssertFalse(pack.name.isEmpty, "\(name): empty name")
            XCTAssertFalse(pack.packDescription.isEmpty, "\(name): empty description")
            XCTAssertNotEqual(pack.contentsSummary, "nothing", "\(name): pack applies nothing")
            XCTAssertTrue(ids.insert(pack.id).inserted, "\(name): duplicate pack id \(pack.id)")
        }
    }
}
