import XCTest
@testable import OpenWhispCore

/// The starter pack (MAK-101): the plugins that ship inside the app bundle and install
/// into the user's plugins folder in one click.
///
/// Two things are under test, and the first matters more than it looks:
///
/// 1. **Every SHIPPED manifest decodes and resolves at head.** These files are not
///    fixtures written to make a test pass — they are the exact bytes copied onto a
///    user's disk, and nothing else in the build reads them. A starter plugin that fails
///    `PluginScriptPlan.resolve` would install cleanly, list cleanly, and refuse the
///    moment the user actually spoke to it. The suite has to be the thing that notices.
/// 2. **The install decision layer**, especially the never-overwrite rule. A starter
///    install that clobbered an edited plugin folder would destroy user work silently.
final class PluginStarterPackTests: XCTestCase {

    // MARK: - Helpers

    /// The in-repo pack directory — the same bytes `package.sh` copies into
    /// `Contents/Resources/StarterPlugins/`.
    private var packDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenWhispCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("OpenWhisp/Resources/StarterPlugins")
    }

    private func offerings(installed: Set<String> = []) -> [PluginStarterPack.Offering] {
        PluginStarterPack.offerings(in: packDirectory, installedIDs: installed)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StarterPackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // MARK: - The shipped pack

    /// The pack is not empty and holds exactly the plugins we mean to ship.
    ///
    /// Pinned by id so DELETING a starter plugin is a deliberate edit to this list rather
    /// than something a stray `rm -rf` in a build script can do quietly.
    func testThePackShipsTheExpectedPlugins() {
        XCTAssertEqual(
            offerings().map(\.id).sorted(),
            ["commit-message", "daily-note", "polish", "task-capture"])
    }

    /// EVERY shipped manifest decodes, validates, and resolves into a runnable plan.
    ///
    /// The load-bearing test of this whole feature. It drives the same
    /// `PluginScriptPlan.resolve` the runner calls, against the same bytes the user gets
    /// — not a re-encoded copy — so a manifest that would refuse at runtime refuses here
    /// first.
    func testEveryShippedManifestResolvesIntoARunnablePlan() throws {
        let all = offerings()
        XCTAssertFalse(all.isEmpty, "the pack must not be empty")

        for offering in all {
            let manifest = offering.manifest
            XCTAssertTrue(manifest.isValid, "\(manifest.id): invalid manifest")
            XCTAssertEqual(manifest.entry, .script, "\(manifest.id): must be a script plugin")
            XCTAssertFalse(
                manifest.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(manifest.id): a starter plugin needs a summary — it is what the pane offers")

            // Script consent is granted here because the resolver checks it LAST: what is
            // under test is the pipeline, and a `runScript` plugin would otherwise report
            // only `.scriptConsentRequired` and hide a real error behind it.
            switch PluginScriptPlan.resolve(manifest: manifest, hasScriptConsent: true) {
            case .success(let plan):
                XCTAssertFalse(plan.steps.isEmpty, "\(manifest.id): resolved to no steps")
            case .failure(let failure):
                XCTFail("\(manifest.id) does not resolve: \(failure.reason)")
            }
        }
    }

    /// Each shipped plugin's step pipeline, pinned exactly.
    ///
    /// This is what each starter plugin IS. Pinning it means a prompt can be reworded
    /// freely, but silently turning `polish` into something that writes a file — or
    /// dropping `commit-message`'s script step, the pack's only demonstration of the
    /// script-consent flow — fails the suite.
    func testEachShippedPluginHasItsIntendedPipeline() {
        let pipelines = Dictionary(
            uniqueKeysWithValues: offerings().map { ($0.id, $0.manifest.steps.map(\.kind)) })

        XCTAssertEqual(pipelines["commit-message"], [.llm, .runScript, .insertAtCursor])
        XCTAssertEqual(pipelines["daily-note"], [.writeFile])
        XCTAssertEqual(pipelines["task-capture"], [.llm, .writeFile])
        XCTAssertEqual(pipelines["polish"], [.llm, .insertAtCursor])
    }

    /// No starter plugin declares a network host.
    ///
    /// A script plugin cannot make a network call at all today (no step does), so a
    /// declared host would be a disclosure with nothing behind it — and the pack is the
    /// worked example third parties copy. It should model the local-first default.
    func testNoStarterPluginDeclaresANetworkHost() {
        for offering in offerings() {
            XCTAssertTrue(
                offering.manifest.networkHosts.isEmpty,
                "\(offering.id) declares network hosts; the pack is local-only")
        }
    }

    /// Every starter plugin is reachable by voice, and no two claim the same phrase.
    ///
    /// A collision would not crash — `PluginVoiceCommandRouter` resolves longest-first
    /// and then deterministically — but it would mean one shipped plugin is unreachable
    /// by the route the pane advertises for it, which is worse than a compile error
    /// because nothing reports it.
    func testStarterTriggersAreDistinct() {
        var seen: [String: String] = [:]
        for offering in offerings() {
            let triggers = offering.manifest.normalizedVoiceTriggers
            XCTAssertFalse(triggers.isEmpty, "\(offering.id) has no usable voice trigger")
            for trigger in triggers {
                if let owner = seen[trigger] {
                    XCTFail("“\(trigger)” is claimed by both \(owner) and \(offering.id)")
                }
                seen[trigger] = offering.id
            }
        }
    }

    /// Every declared script really exists inside its own plugin folder, and is
    /// executable in the repo.
    ///
    /// The exec bit is the half of an install that a plain file copy loses, so the
    /// SOURCE having it is the precondition the app layer's restore step depends on. A
    /// script checked in without `+x` would install as a plugin that fails at the moment
    /// it runs, with a message about `chmod`.
    func testShippedScriptsExistInsideTheirFolderAndAreExecutable() throws {
        var scriptsChecked = 0

        for offering in offerings() {
            let names = PluginStarterPack.executableScriptNames(in: offering.manifest)
            XCTAssertEqual(
                names.count,
                offering.manifest.steps.filter { $0.kind == .runScript }.count,
                "\(offering.id): a runScript step declared an unusable path")

            for name in names {
                let url = try XCTUnwrap(
                    PluginScriptPath.resolve(name, in: offering.sourceDirectory),
                    "\(offering.id): \(name) did not resolve inside its own folder")
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: url.path),
                    "\(offering.id): \(name) is declared but missing on disk")
                XCTAssertTrue(
                    FileManager.default.isExecutableFile(atPath: url.path),
                    "\(offering.id): \(name) is not executable in the repo — "
                    + "run chmod +x, or the installed copy fails at run time")
                XCTAssertTrue(url.path.hasPrefix(offering.sourceDirectory.standardizedFileURL.path + "/"))
                scriptsChecked += 1
            }
        }

        XCTAssertGreaterThan(
            scriptsChecked, 0,
            "the pack should include at least one script plugin — it is the only "
            + "demonstration of the script-consent flow")
    }

    /// The pack's consent disclosures are non-empty and honest about writing files.
    ///
    /// The disclosure is what the user reads before enabling, so a starter plugin that
    /// wrote to disk without saying so would be the pack teaching the wrong lesson.
    func testFileWritingStartersDiscloseTheirPaths() {
        for offering in offerings() {
            let consent = PluginConsent.derive(from: offering.manifest)
            XCTAssertFalse(
                consent.disclosures.isEmpty,
                "\(offering.id): every starter plugin does something worth disclosing")

            let writes = offering.manifest.steps.contains { $0.kind == .writeFile }
            XCTAssertEqual(
                writes, !consent.filePaths.isEmpty,
                "\(offering.id): a writeFile step must produce a disclosed path")
        }
    }

    // MARK: - Install decisions

    func testAFreshPluginIsCopiedIntoThePluginsDirectory() throws {
        let root = try makeTemporaryRoot()
        let offering = try XCTUnwrap(offerings().first { $0.id == "polish" })

        let decision = PluginStarterPack.decide(offering, destinationRoot: root)
        guard case let .copy(source, destination) = decision else {
            return XCTFail("expected a copy, got \(decision)")
        }
        XCTAssertEqual(source, offering.sourceDirectory)
        XCTAssertEqual(destination, root.appendingPathComponent("polish", isDirectory: true))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "the decision must only ever name a destination that does not exist yet")
    }

    /// **The rule this layer exists for.** An installed folder is the user's — possibly
    /// with their own edits in it — so the pack never overwrites it. Reinstalling means
    /// deleting the folder first, which is a deliberate act rather than a click.
    func testAnAlreadyInstalledPluginIsNeverOverwritten() throws {
        let root = try makeTemporaryRoot()
        let offering = try XCTUnwrap(
            offerings(installed: ["commit-message"]).first { $0.id == "commit-message" })
        XCTAssertTrue(offering.isInstalled)

        let decision = PluginStarterPack.decide(offering, destinationRoot: root)
        XCTAssertFalse(decision.isCopy, "an install must never clobber the user's folder")
        XCTAssertEqual(decision.refusal, .alreadyInstalled(id: "commit-message"))
        XCTAssertTrue(
            decision.refusal?.reason.contains("already in your plugins folder") == true)
    }

    /// The id is re-validated at the moment it becomes a directory that gets WRITTEN to,
    /// not merely trusted because validation happened somewhere upstream.
    func testATraversalShapedIdIsRefusedAtInstallTime() throws {
        let root = try makeTemporaryRoot()
        let hostile = PluginManifest(
            id: "../../escape", name: "Escape", version: "1.0.0", summary: "",
            symbol: "hammer", entry: .script,
            steps: [PluginStep(kind: .insertAtCursor)])

        let decision = PluginStarterPack.decide(
            PluginStarterPack.Offering(
                manifest: hostile,
                sourceDirectory: URL(fileURLWithPath: "/tmp/whatever"),
                isInstalled: false),
            destinationRoot: root)

        XCTAssertEqual(decision.refusal, .unsafeIdentifier(id: "../../escape"))
    }

    /// A pack entry that isn't a script plugin is refused rather than installed into a
    /// folder where it could only ever be listed-and-refused.
    func testANonScriptEntryIsRefused() throws {
        let root = try makeTemporaryRoot()
        let builtIn = PluginManifest(
            id: "impostor", name: "Impostor", version: "1.0.0", summary: "",
            symbol: "hammer", entry: .builtIn)

        let decision = PluginStarterPack.decide(
            PluginStarterPack.Offering(
                manifest: builtIn,
                sourceDirectory: URL(fileURLWithPath: "/tmp/whatever"),
                isInstalled: false),
            destinationRoot: root)

        XCTAssertEqual(decision.refusal, .notAScriptPlugin(id: "impostor"))
    }

    // MARK: - Enumeration

    /// A folder whose manifest claims a DIFFERENT id than its directory name is skipped.
    /// The directory name is what an install writes to, so disagreement is the one case
    /// where a pack entry could install itself under someone else's id.
    func testAnEntryWhoseIdDisagreesWithItsFolderIsSkipped() throws {
        let pack = try makeTemporaryRoot()
        let folder = pack.appendingPathComponent("honest-name", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"""
        {"id":"meme-generator","name":"Impostor","symbol":"hammer","entry":"script",
         "steps":[{"type":"insertAtCursor"}]}
        """#.write(
            to: folder.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)

        XCTAssertTrue(
            PluginStarterPack.offerings(in: pack, installedIDs: []).isEmpty,
            "a folder must not be able to claim another plugin's id")
    }

    /// A malformed entry is skipped, not thrown — one bad folder must not empty the
    /// whole starter list. Same fail-soft posture as `loadExternalManifests`.
    func testAMalformedEntryIsSkippedWithoutLosingTheGoodOnes() throws {
        let pack = try makeTemporaryRoot()

        let broken = pack.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "{ not json".write(
            to: broken.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)

        let good = pack.appendingPathComponent("good", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try #"""
        {"id":"good","name":"Good","symbol":"hammer","entry":"script",
         "steps":[{"type":"insertAtCursor"}]}
        """#.write(
            to: good.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8)

        XCTAssertEqual(
            PluginStarterPack.offerings(in: pack, installedIDs: []).map(\.id), ["good"])
    }

    /// A missing pack directory yields an empty list rather than a crash — a `PLUGINS=0`
    /// or otherwise trimmed bundle must degrade to "no starters offered".
    func testAMissingPackDirectoryIsEmptyRatherThanFatal() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-pack-\(UUID().uuidString)")
        XCTAssertTrue(PluginStarterPack.offerings(in: missing, installedIDs: []).isEmpty)
    }

    /// Ordering is by display name, matching `PluginDiscovery.merge`, so the pane's
    /// starter list is stable across launches and independent of enumeration order.
    func testOfferingsAreSortedByDisplayName() {
        let names = offerings().map(\.manifest.name)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    // MARK: - End to end

    /// The whole install path as the pane performs it: decide, copy, and then the
    /// ORDINARY external provider discovers what landed and the ORDINARY resolver runs
    /// it. No starter-specific route anywhere.
    ///
    /// One test on purpose. Each half passing alone is exactly how this repo has
    /// previously shipped a green suite over a broken chain.
    func testInstallingAStarterMakesItAnOrdinaryInstalledPlugin() throws {
        let root = try makeTemporaryRoot()

        // 1. Nothing installed yet, so the pack offers the plugin.
        let installedBefore = Set(
            PluginDiscovery.loadExternalManifests(in: root).map(\.id))
        XCTAssertTrue(installedBefore.isEmpty)
        let offering = try XCTUnwrap(
            PluginStarterPack.offerings(in: packDirectory, installedIDs: installedBefore)
                .first { $0.id == "commit-message" })

        // 2. The decision layer says copy, and the app layer performs exactly that copy.
        guard case let .copy(source, destination) = PluginStarterPack.decide(
            offering, destinationRoot: root)
        else { return XCTFail("expected a copy") }
        try FileManager.default.copyItem(at: source, to: destination)

        // 3. The ordinary external provider finds it — no starter-specific discovery.
        let discovered = PluginDiscovery.merge(providers: [
            .init(source: .builtIn) { [] },
            .init(source: .external) { PluginDiscovery.loadExternalManifests(in: root) },
        ])
        XCTAssertEqual(discovered.map(\.id), ["commit-message"])
        XCTAssertTrue(discovered[0].isRunnable)

        // 4. The runner's own re-read resolves it into a plan.
        let reloaded = try XCTUnwrap(
            PluginDiscovery.reloadManifest(id: "commit-message", in: root))
        guard case let .success(plan) = PluginScriptPlan.resolve(
            manifest: reloaded, hasScriptConsent: true)
        else { return XCTFail("the installed starter must resolve") }
        XCTAssertEqual(plan.steps.map(\.kind), [.llm, .runScript, .insertAtCursor])

        // 5. Its script landed inside the installed folder and survived the copy
        //    executable — the exec bit is the half a naive install loses.
        let scriptURL = try XCTUnwrap(
            PluginScriptPath.resolve(plan.steps[1].script, in: destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: scriptURL.path),
            "the installed script must be executable or the plugin fails at run time")

        // 6. Installing again is refused — the user's copy is theirs.
        let installedAfter = Set(PluginDiscovery.loadExternalManifests(in: root).map(\.id))
        let second = try XCTUnwrap(
            PluginStarterPack.offerings(in: packDirectory, installedIDs: installedAfter)
                .first { $0.id == "commit-message" })
        XCTAssertTrue(second.isInstalled)
        XCTAssertEqual(
            PluginStarterPack.decide(second, destinationRoot: root).refusal,
            .alreadyInstalled(id: "commit-message"))
    }
}
