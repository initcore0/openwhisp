import Foundation

/// Local-only persistence for the `RuleSet` (JSON in Application Support), via the
/// shared `JSONStore` quarantine loader — so a hand-edited or version-skewed file
/// is moved aside to `rules.json.corrupt-<epoch>` and the engine starts empty,
/// never crashing and never silently overwriting the bad file on the next save.
///
/// On-device only: rules and their action configs (which may include a webhook URL
/// or a shell path the user wired up) live here and are never transmitted by this
/// store. Foundation-only, so it compiles into `OpenWhispCore` and the load/save +
/// quarantine path is `swift test`-covered.
enum RuleStore {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    static func load() -> RuleSet {
        JSONStore.load(from: fileURL, default: .empty, label: "RuleStore")
    }

    static func save(_ ruleSet: RuleSet) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        JSONStore.save(ruleSet, to: fileURL, label: "RuleStore", encoder: encoder)
    }
}
