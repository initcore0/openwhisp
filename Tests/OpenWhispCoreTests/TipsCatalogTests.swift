import XCTest
@testable import OpenWhispCore

/// Integrity checks for the static Tips & Commands catalog (MAK-25). Guards the
/// truth contract: content is present, hint ids are stable and unique (so a
/// dismissed hint stays dismissed), and Settings paths look real (rooted at
/// "Settings ›") so a typo can't ship a dead path.
final class TipsCatalogTests: XCTestCase {

    func testGroupsAndRowsNonEmpty() {
        XCTAssertFalse(TipsCatalog.groups.isEmpty)
        for group in TipsCatalog.groups {
            XCTAssertFalse(group.title.isEmpty, "empty group title")
            XCTAssertFalse(group.subtitle.isEmpty, "empty subtitle in \(group.title)")
            XCTAssertFalse(group.rows.isEmpty, "no rows in \(group.title)")
            for row in group.rows {
                XCTAssertFalse(row.invocation.isEmpty, "empty invocation in \(group.title)")
                XCTAssertFalse(row.effect.isEmpty, "empty effect in \(group.title)")
            }
        }
    }

    func testSettingsPathsAreRooted() {
        // Every non-nil path is a real Settings path (rooted at "Settings ›"), never
        // an aspirational or malformed one.
        let allPaths = TipsCatalog.groups.flatMap { $0.rows }.compactMap { $0.settingsPath }
            + TipsCatalog.whatsNext.map { $0.settingsPath }
        XCTAssertFalse(allPaths.isEmpty)
        for path in allPaths {
            XCTAssertTrue(path.hasPrefix("Settings ›"), "path not rooted at Settings: \(path)")
        }
    }

    func testHintIdsAreUniqueAndStable() {
        let ids = TipsCatalog.hints.map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate hint id — dismissal would be ambiguous")
        for hint in TipsCatalog.hints {
            XCTAssertFalse(hint.id.isEmpty, "empty hint id")
            XCTAssertFalse(hint.text.isEmpty, "empty hint text for \(hint.id)")
        }
    }

    func testWhatsNextHasTwoOrThreeEntries() {
        XCTAssertTrue((2...3).contains(TipsCatalog.whatsNext.count),
                      "What's next card should point at 2–3 features")
        for step in TipsCatalog.whatsNext {
            XCTAssertFalse(step.title.isEmpty)
            XCTAssertFalse(step.pitch.isEmpty)
        }
    }
}
