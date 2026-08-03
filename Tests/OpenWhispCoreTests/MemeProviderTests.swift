import XCTest
@testable import OpenWhispCore

/// Covers the Meme Generator plugin's v3 pure layer (spike/plugin-system): the
/// multi-source template providers and their merge/precedence rules, the keyword
/// search that makes a merged corpus findable, the catalog disk-cache policy, the
/// user template library's index, and the busy-state machine behind the "stuck
/// loading" report.
final class MemeProviderTests: XCTestCase {

    private func template(
        _ source: MemeTemplateSource, _ rawID: String, _ name: String,
        keywords: [String] = []
    ) -> MemeTemplate {
        MemeTemplate(
            id: MemeTemplateCatalog.qualifiedID(source, rawID),
            name: name, url: "https://example.test/\(rawID).jpg",
            width: 100, height: 100, source: source, keywords: keywords)
    }

    // MARK: - Merge + precedence

    func testMergeConcatenatesSourcesInOrder() {
        let merged = MemeTemplateCatalog.merge([
            [template(.userLibrary, "u1", "Кот в шоке")],
            [template(.imgflip, "i1", "Drake Hotline Bling")],
            [template(.memegen, "m1", "Ancient Aliens Guy")],
        ])
        XCTAssertEqual(merged.map(\.name),
                       ["Кот в шоке", "Drake Hotline Bling", "Ancient Aliens Guy"])
    }

    /// The rule that matters: a template the USER imported outranks a remote one with
    /// the same name. Their file, their corpus, their meme.
    func testUserLibraryWinsANameCollisionAgainstRemoteSources() {
        let merged = MemeTemplateCatalog.merge([
            [template(.userLibrary, "u1", "Drake Hotline Bling")],
            [template(.imgflip, "i1", "Drake Hotline Bling")],
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .userLibrary)
    }

    /// imgflip and memegen genuinely both carry Distracted Boyfriend under different
    /// ids — de-duplicating by id would silently do nothing and show it twice.
    func testDuplicateNamesAcrossRemoteSourcesCollapseDespiteDifferentIDs() {
        let merged = MemeTemplateCatalog.merge([
            [template(.imgflip, "112126428", "Distracted Boyfriend")],
            [template(.memegen, "db", "Distracted Boyfriend")],
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].source, .imgflip)
    }

    func testMergeDeduplicatesCaseAndPunctuationInsensitively() {
        let merged = MemeTemplateCatalog.merge([
            [template(.imgflip, "i1", "Two Buttons")],
            [template(.memegen, "m1", "two  buttons!")],
        ])
        XCTAssertEqual(merged.count, 1)
    }

    func testMergeDropsUnnameableTemplates() {
        let merged = MemeTemplateCatalog.merge([[
            template(.memegen, "m1", "   "),
            template(.memegen, "m2", "Success Kid"),
        ]])
        XCTAssertEqual(merged.map(\.name), ["Success Kid"])
    }

    func testMergePreservesPopularityOrderWithinASource() {
        let merged = MemeTemplateCatalog.merge([[
            template(.imgflip, "1", "First"),
            template(.imgflip, "2", "Second"),
            template(.imgflip, "3", "Third"),
        ]])
        XCTAssertEqual(merged.map(\.name), ["First", "Second", "Third"])
    }

    func testQualifiedIDsKeepSourcesFromCollidingOnTheImageCache() {
        let a = MemeTemplateCatalog.qualifiedID(.imgflip, "drake")
        let b = MemeTemplateCatalog.qualifiedID(.memegen, "drake")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(MemeTemplateCatalog.source(ofQualifiedID: a), .imgflip)
        XCTAssertEqual(MemeTemplateCatalog.source(ofQualifiedID: b), .memegen)
    }

    func testSourceOfUnqualifiedIDIsNil() {
        XCTAssertNil(MemeTemplateCatalog.source(ofQualifiedID: "181913649"))
    }

    // MARK: - Keyword search (the merged corpus has to be findable)

    /// memegen names this template "Sweet Brown"; nobody searches for that. The
    /// keyword is the phrase people actually type.
    func testSearchMatchesKeywordsAsWellAsNames() {
        let catalog = [template(.memegen, "aint-got-time", "Sweet Brown",
                                keywords: ["Ain't Nobody Got Time For That"])]
        XCTAssertEqual(MemeTemplateCatalog.search("nobody got time", in: catalog).count, 1)
    }

    /// The cross-field case a naive per-field search misses.
    func testSearchTokensMaySpanNameAndKeywords() {
        let catalog = [template(.userLibrary, "u1", "Кот", keywords: ["russian cat"])]
        XCTAssertEqual(MemeTemplateCatalog.search("кот cat", in: catalog).count, 1)
    }

    func testSearchFindsCyrillicNamesInTheirOwnScript() {
        let catalog = [
            template(.userLibrary, "u1", "Кот в шоке"),
            template(.imgflip, "i1", "Drake Hotline Bling"),
        ]
        let hits = MemeTemplateCatalog.search("шоке", in: catalog)
        XCTAssertEqual(hits.map(\.name), ["Кот в шоке"])
    }

    func testSearchNeverSubstitutesAPopularTemplateForNoMatch() {
        let catalog = [template(.imgflip, "i1", "Drake Hotline Bling")]
        XCTAssertTrue(MemeTemplateCatalog.search("yoda", in: catalog).isEmpty)
    }

    func testEmptySearchReturnsTheWholeMergedCatalog() {
        let catalog = [template(.imgflip, "i1", "A"), template(.memegen, "m1", "B")]
        XCTAssertEqual(MemeTemplateCatalog.search("  ", in: catalog).count, 2)
    }

    // MARK: - v4: ranked search (the owner's "worst day" repro)

    /// A corpus shaped like the real merged one: the Bart template is present, buried
    /// well down the popularity order, and its relevance lives partly in keywords.
    private var worstDayCatalog: [MemeTemplate] {
        var out: [MemeTemplate] = (0..<40).map {
            template(.imgflip, "i\($0)", "Popular Template \($0)")
        }
        out.append(template(.memegen, "worst-day", "Worst Day Of My Life So Far",
                            keywords: ["Bart Simpson", "chalkboard", "bad day"]))
        return out
    }

    /// **The owner's exact report.** "the worst day for the planet" must surface the
    /// Bart template. v3 returned NOTHING: its all-tokens rule required "planet" to
    /// appear in the name or keywords, so one unmatched token vetoed the three that
    /// matched perfectly.
    func testWorstDayDescriptionFindsTheBartTemplate() {
        let hits = MemeTemplateCatalog.search("the worst day for the planet", in: worstDayCatalog)
        XCTAssertEqual(hits.first?.name, "Worst Day Of My Life So Far",
                       "describing the meme's content must find it, and rank it first")
    }

    /// The owner's second phrasing of the same query.
    func testWorstDaySoFarDescriptionFindsTheBartTemplate() {
        let hits = MemeTemplateCatalog.search("the worst day so far", in: worstDayCatalog)
        XCTAssertEqual(hits.first?.name, "Worst Day Of My Life So Far")
    }

    /// Relevance beats popularity: the Bart template is at index 40 and still wins.
    func testARelevantTemplateOutranksPopularOnesThatDoNotMatch() {
        let hits = MemeTemplateCatalog.search("worst day", in: worstDayCatalog)
        XCTAssertEqual(hits.first?.name, "Worst Day Of My Life So Far")
        XCTAssertFalse(hits.contains { $0.name.hasPrefix("Popular Template") },
                       "templates that match nothing must not be padded in")
    }

    /// A name-token match is stronger evidence than a keyword match, so the template
    /// actually NAMED for the query ranks above one that merely lists it as an alias.
    func testANameMatchOutranksAKeywordMatch() {
        let catalog = [
            template(.memegen, "alias", "Something Else", keywords: ["chalkboard"]),
            template(.imgflip, "named", "Chalkboard"),
        ]
        XCTAssertEqual(MemeTemplateCatalog.search("chalkboard", in: catalog).first?.name,
                       "Chalkboard")
    }

    /// Partial/prefix matches count, but count LESS — they are weaker evidence.
    func testAPrefixMatchScoresBelowAWholeTokenMatch() {
        let whole = template(.imgflip, "w", "Planet")
        let prefix = template(.imgflip, "p", "Planetarium Nights")
        let hits = MemeTemplateCatalog.search("planet", in: [prefix, whole])
        XCTAssertEqual(hits.first?.name, "Planet",
                       "exact token beats prefix even though prefix came first in the catalog")
        XCTAssertEqual(hits.count, 2, "the prefix match is still shown, just ranked lower")
    }

    /// v4 ranks partial matches — it must still never INVENT one. Ranking and
    /// falling back are different things, and the fallback is the original bug.
    func testRankedSearchStillReturnsNothingWhenNothingMatchesAtAll() {
        XCTAssertTrue(
            MemeTemplateCatalog.search("zzzzz qqqqq", in: worstDayCatalog).isEmpty)
    }

    /// A query of pure stopwords must still narrow rather than silently resetting the
    /// grid to the whole catalog.
    func testAStopwordOnlyQueryStillFilters() {
        let catalog = [
            template(.imgflip, "i1", "The Rock Driving"),
            template(.imgflip, "i2", "Success Kid"),
        ]
        XCTAssertEqual(MemeTemplateCatalog.search("the", in: catalog).map(\.name),
                       ["The Rock Driving"])
    }

    // MARK: - v4: the LLM shortlist

    /// The prefilter is what lets the LLM benefit from the same scoring: the relevant
    /// template is at index 40 of the corpus and would be truncated off a
    /// popularity-ordered prompt, but it leads the shortlist.
    func testPrefilterPutsTheRelevantTemplateInFrontOfTheModel() {
        let shortlist = MemeTemplateCatalog.prefilter(
            for: "the worst day for the planet", in: worstDayCatalog, limit: 30)
        XCTAssertEqual(shortlist.first?.name, "Worst Day Of My Life So Far")
        XCTAssertEqual(shortlist.count, 30, "the model still gets a full shortlist to rank")
    }

    /// A description matching nothing still gets the model a corpus to choose from —
    /// the UI, not the prompt, is where "nothing matched" is stated.
    func testPrefilterFallsBackToPopularityWhenNothingMatches() {
        let shortlist = MemeTemplateCatalog.prefilter(
            for: "zzzzz qqqqq", in: worstDayCatalog, limit: 5)
        XCTAssertEqual(shortlist.map(\.name), (0..<5).map { "Popular Template \($0)" })
    }

    func testPrefilterNeverRepeatsATemplateWhenToppingUp() {
        let shortlist = MemeTemplateCatalog.prefilter(
            for: "worst day", in: worstDayCatalog, limit: 10)
        XCTAssertEqual(Set(shortlist.map(\.id)).count, shortlist.count)
    }

    /// The model is shown keywords — that is what connects a CONTENT description to a
    /// template — but the name stays first and unadorned so it can be copied verbatim
    /// and validated against the catalog.
    func testPromptLinesCarryKeywordsAfterAnUnadornedName() {
        let catalog = [
            template(.memegen, "m1", "Sweet Brown", keywords: ["Ain't Nobody Got Time For That"]),
            template(.imgflip, "i1", "Drake Hotline Bling"),
        ]
        let lines = MemeTemplateCatalog.promptLines(catalog, limit: 10)
        XCTAssertEqual(lines[0], "Sweet Brown (Ain't Nobody Got Time For That)")
        XCTAssertEqual(lines[1], "Drake Hotline Bling", "no keywords -> no empty parentheses")
    }

    /// The name a `promptLines` entry starts with must be the one `MemeAI.validate`
    /// accepts — otherwise every keyword-carrying template would read as a
    /// hallucination and be dropped.
    func testAModelCopyingTheNameOffAPromptLineValidates() {
        let catalog = [template(.memegen, "m1", "Sweet Brown", keywords: ["no time"])]
        let names = MemeTemplateCatalog.promptNames(catalog, limit: 10)
        XCTAssertEqual(MemeAI.validate(["Sweet Brown"], against: names), ["Sweet Brown"])
    }

    /// The user's own templates sort first, so the prompt cap can never exclude them.
    func testPromptNamesCapTheCorpusButKeepUserTemplates() {
        let merged = MemeTemplateCatalog.merge([
            [template(.userLibrary, "u1", "Кот в шоке")],
            (0..<200).map { template(.imgflip, "i\($0)", "Template \($0)") },
        ])
        let names = MemeTemplateCatalog.promptNames(merged, limit: 100)
        XCTAssertEqual(names.count, 100)
        XCTAssertEqual(names.first, "Кот в шоке")
    }

    // MARK: - Provider wire shapes

    func testImgflipTemplatesAreSourceQualified() throws {
        let json = """
        {"success":true,"data":{"memes":[
          {"id":"181913649","name":"Drake Hotline Bling","url":"https://i.imgflip.com/30b1gx.jpg",
           "width":1200,"height":1200,"box_count":2}]}}
        """
        let decoded = try JSONDecoder().decode(
            MemeTemplateCatalogResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.templates[0].id, "imgflip:181913649")
        XCTAssertEqual(decoded.templates[0].source, .imgflip)
    }

    /// Pinned against the real memegen.link `/templates` payload shape.
    func testMemegenResponseDecodesTheLiveShape() throws {
        let json = """
        [{"id":"aint-got-time","name":"Sweet Brown","lines":2,"overlays":0,"styles":[],
          "blank":"https://api.memegen.link/images/aint-got-time.jpg",
          "keywords":["Ain't Nobody Got Time For That"],
          "_self":"https://api.memegen.link/templates/aint-got-time"}]
        """
        let decoded = try JSONDecoder().decode(
            MemegenTemplateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.templates.count, 1)
        XCTAssertEqual(decoded.templates[0].id, "memegen:aint-got-time")
        XCTAssertEqual(decoded.templates[0].name, "Sweet Brown")
        XCTAssertEqual(decoded.templates[0].url,
                       "https://api.memegen.link/images/aint-got-time.jpg")
        XCTAssertEqual(decoded.templates[0].keywords, ["Ain't Nobody Got Time For That"])
    }

    func testMemegenTemplatesWithoutKeywordsStillDecode() throws {
        let json = """
        [{"id":"aag","name":"Ancient Aliens Guy","blank":"https://api.memegen.link/images/aag.jpg"}]
        """
        let decoded = try JSONDecoder().decode(
            MemegenTemplateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.templates[0].keywords, [])
    }

    func testMemegenTemplatesWithoutAUsableNameOrImageAreDropped() throws {
        let json = """
        [{"id":"a","name":"  ","blank":"https://x/a.jpg"},
         {"id":"b","name":"Fine","blank":""},
         {"id":"c","name":"Kept","blank":"https://x/c.jpg"}]
        """
        let decoded = try JSONDecoder().decode(
            MemegenTemplateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.templates.map(\.name), ["Kept"])
    }

    /// A cache written before v3 has no `source`/`keywords`. It must still load —
    /// discarding it would reintroduce the cold-start failure on every upgrade.
    func testTemplateFromAnOlderCacheDecodesWithDefaults() throws {
        let json = #"{"id":"imgflip:1","name":"Drake","url":"u","width":10,"height":10}"#
        let decoded = try JSONDecoder().decode(MemeTemplate.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.source, .imgflip)
        XCTAssertEqual(decoded.keywords, [])
    }

    // MARK: - Catalog cache policy

    private func cached(ageSeconds: TimeInterval, count: Int = 3, version: Int = 1)
    -> MemeCatalogCache.Cached {
        MemeCatalogCache.Cached(
            version: version,
            fetchedAt: Date(timeIntervalSince1970: 10_000 - ageSeconds),
            templates: (0..<count).map { template(.imgflip, "i\($0)", "T\($0)") })
    }

    private var now: Date { Date(timeIntervalSince1970: 10_000) }

    func testNoCacheMeansFetchBeforeBrowsing() {
        XCTAssertEqual(MemeCatalogCache.decide(cached: nil, now: now), .fetchNow)
    }

    func testFreshCacheIsUsedWithoutTouchingTheNetwork() {
        XCTAssertEqual(MemeCatalogCache.decide(cached: cached(ageSeconds: 60), now: now),
                       .useCache)
    }

    /// The instant-browsing rule: a stale cache is shown immediately and refreshed
    /// behind it, so the user never waits on the network.
    func testStaleCacheIsShownImmediatelyAndRefreshedBehindIt() {
        let old = MemeCatalogCache.maxAge + 60
        XCTAssertEqual(MemeCatalogCache.decide(cached: cached(ageSeconds: old), now: now),
                       .useCacheAndRefresh)
    }

    func testEmptyCacheIsTreatedAsAbsentRatherThanAnEmptyCorpus() {
        XCTAssertEqual(MemeCatalogCache.decide(cached: cached(ageSeconds: 10, count: 0), now: now),
                       .fetchNow)
    }

    func testCacheFromAFutureVersionIsNotTrusted() {
        XCTAssertEqual(MemeCatalogCache.decide(cached: cached(ageSeconds: 10, version: 99), now: now),
                       .fetchNow)
    }

    /// A restored backup or a skewed clock must not pin the catalog forever.
    func testFutureTimestampIsTreatedAsStale() {
        XCTAssertEqual(MemeCatalogCache.decide(cached: cached(ageSeconds: -5_000), now: now),
                       .useCacheAndRefresh)
    }

    /// The offline win: with templates already on screen, a failed refresh is a
    /// non-event and must not raise an error.
    func testRefreshFailureIsSilentWhenTemplatesAreAlreadyShown() {
        XCTAssertNil(MemeCatalogCache.refreshFailureMessage(
            hasCachedTemplates: true, reason: "offline."))
    }

    func testRefreshFailureWithNothingCachedNamesTheRetryAndTheImportEscape() {
        let message = MemeCatalogCache.refreshFailureMessage(
            hasCachedTemplates: false, reason: "offline.")
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("Retry"))
        XCTAssertTrue(message!.contains("import"))
    }

    func testSummaryNamesEverySourceThatContributed() {
        let summary = MemeCatalogCache.summary([
            template(.imgflip, "i1", "A"),
            template(.memegen, "m1", "B"),
            template(.userLibrary, "u1", "C"),
        ])
        XCTAssertTrue(summary.contains("3 templates"))
        XCTAssertTrue(summary.contains("1 imgflip"))
        XCTAssertTrue(summary.contains("1 memegen"))
        XCTAssertTrue(summary.contains("1 My library"))
    }

    func testSummaryOmitsSourcesThatContributedNothing() {
        let summary = MemeCatalogCache.summary([template(.imgflip, "i1", "A")])
        XCTAssertFalse(summary.contains("memegen"))
    }

    // MARK: - User library: naming

    /// The whole point of the library: a Cyrillic filename stays Cyrillic.
    func testSuggestedNamePreservesNonLatinScripts() {
        XCTAssertEqual(
            MemeUserLibrary.suggestedName(fromFileName: "кот-в-шоке.png"), "кот в шоке")
    }

    func testSuggestedNameTurnsSeparatorsIntoSpaces() {
        XCTAssertEqual(
            MemeUserLibrary.suggestedName(fromFileName: "distracted_boyfriend.jpg"),
            "distracted boyfriend")
    }

    func testSuggestedNameFallsBackForAnUnnameableFile() {
        XCTAssertEqual(MemeUserLibrary.suggestedName(fromFileName: "___.png"),
                       "Imported template")
    }

    func testAcceptedImageExtensionsAreCaseInsensitive() {
        XCTAssertTrue(MemeUserLibrary.isAcceptedImage(fileName: "a.PNG"))
        XCTAssertTrue(MemeUserLibrary.isAcceptedImage(fileName: "b.jpeg"))
        XCTAssertFalse(MemeUserLibrary.isAcceptedImage(fileName: "c.pdf"))
        XCTAssertFalse(MemeUserLibrary.isAcceptedImage(fileName: "noextension"))
    }

    /// Names must stay distinct: the LLM picks BY NAME and the merge de-duplicates by
    /// name, so a duplicate would make one template unreachable.
    func testDuplicateImportNamesAreSuffixed() {
        XCTAssertEqual(MemeUserLibrary.uniqueName("Кот", existing: ["Кот"]), "Кот 2")
        XCTAssertEqual(MemeUserLibrary.uniqueName("Кот", existing: ["Кот", "Кот 2"]), "Кот 3")
    }

    func testUniqueNameComparesOnTheNormalizedForm() {
        XCTAssertEqual(MemeUserLibrary.uniqueName("two buttons!", existing: ["Two Buttons"]),
                       "two buttons! 2")
    }

    func testUniqueNameLeavesADistinctNameAlone() {
        XCTAssertEqual(MemeUserLibrary.uniqueName("Success Kid", existing: ["Кот"]),
                       "Success Kid")
    }

    func testBlankImportNameFallsBackRatherThanCreatingAnUnreachableEntry() {
        XCTAssertEqual(MemeUserLibrary.uniqueName("   ", existing: []), "Imported template")
    }

    func testStorageFileNameNeverCarriesTheUsersName() {
        let file = MemeUserLibrary.storageFileName(id: "abc-123", sourceExtension: "PNG")
        XCTAssertEqual(file, "abc-123.png")
    }

    func testStorageFileNameRejectsAnUnknownExtension() {
        XCTAssertEqual(
            MemeUserLibrary.storageFileName(id: "abc", sourceExtension: "exe"), "abc.png")
    }

    // MARK: - User library: index rules

    private func entry(_ id: String, _ name: String, file: String? = nil)
    -> MemeUserLibrary.Entry {
        MemeUserLibrary.Entry(id: id, name: name, file: file ?? "\(id).png",
                              width: 100, height: 100)
    }

    func testAddingKeepsNamesUnique() {
        var index = MemeUserLibrary.Index()
        index = MemeUserLibrary.adding(entry("1", "Кот"), to: index)
        index = MemeUserLibrary.adding(entry("2", "Кот"), to: index)
        XCTAssertEqual(index.entries.map(\.name), ["Кот", "Кот 2"])
    }

    func testRemovingDropsOnlyTheNamedEntry() {
        var index = MemeUserLibrary.Index(entries: [entry("1", "A"), entry("2", "B")])
        index = MemeUserLibrary.removing(id: "1", from: index)
        XCTAssertEqual(index.entries.map(\.id), ["2"])
    }

    func testRenamingAnEntryToItsOwnNameDoesNotSuffixIt() {
        var index = MemeUserLibrary.Index(entries: [entry("1", "Кот"), entry("2", "Пёс")])
        index = MemeUserLibrary.renaming(id: "1", to: "Кот", in: index)
        XCTAssertEqual(index.entries[0].name, "Кот")
    }

    func testRenamingOntoAnotherEntrysNameIsSuffixed() {
        var index = MemeUserLibrary.Index(entries: [entry("1", "Кот"), entry("2", "Пёс")])
        index = MemeUserLibrary.renaming(id: "2", to: "Кот", in: index)
        XCTAssertEqual(index.entries[1].name, "Кот 2")
    }

    /// The user can delete files in Finder; the index self-heals rather than showing
    /// broken cells.
    func testPruningDropsEntriesWhoseImageIsGone() {
        let index = MemeUserLibrary.Index(entries: [entry("1", "A"), entry("2", "B")])
        let pruned = MemeUserLibrary.pruned(index, existingFiles: ["1.png"])
        XCTAssertEqual(pruned.entries.map(\.id), ["1"])
    }

    /// The index is a plain JSON file in a user-writable directory — untrusted input
    /// that becomes a path component, so it is validated before it is ever joined.
    func testTraversalShapedFileNamesAreRefused() {
        XCTAssertFalse(MemeUserLibrary.isSafeFileName("../../../../etc/passwd"))
        XCTAssertFalse(MemeUserLibrary.isSafeFileName(".."))
        XCTAssertFalse(MemeUserLibrary.isSafeFileName("sub/dir.png"))
        XCTAssertFalse(MemeUserLibrary.isSafeFileName("back\\slash.png"))
        XCTAssertFalse(MemeUserLibrary.isSafeFileName(".hidden.png"))
        XCTAssertFalse(MemeUserLibrary.isSafeFileName(""))
        XCTAssertTrue(MemeUserLibrary.isSafeFileName("abc-123.png"))
    }

    func testUnsafeAndUnnamedEntriesAreExcludedFromTheCatalog() {
        let index = MemeUserLibrary.Index(entries: [
            entry("1", "Good"),
            entry("2", "Traversal", file: "../evil.png"),
            entry("3", "   "),
        ])
        XCTAssertEqual(MemeUserLibrary.safeEntries(index).map(\.name), ["Good"])
    }

    func testLibraryProjectsIntoFileURLTemplates() {
        let directory = URL(fileURLWithPath: "/tmp/templates", isDirectory: true)
        let index = MemeUserLibrary.Index(entries: [entry("abc", "Кот в шоке")])
        let templates = MemeUserLibrary.templates(from: index, directory: directory)

        XCTAssertEqual(templates.count, 1)
        XCTAssertEqual(templates[0].id, "userLibrary:abc")
        XCTAssertEqual(templates[0].name, "Кот в шоке")
        XCTAssertEqual(templates[0].source, .userLibrary)
        XCTAssertTrue(templates[0].url.hasPrefix("file://"))
        XCTAssertTrue(templates[0].url.hasSuffix("/tmp/templates/abc.png"))
    }

    func testLibraryIndexRoundTripsThroughCodable() throws {
        let index = MemeUserLibrary.Index(entries: [entry("1", "Кот в шоке")])
        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(MemeUserLibrary.Index.self, from: data)
        XCTAssertEqual(decoded, index)
    }

    // MARK: - Busy-state machine (the "stuck loading" report)

    func testAFreshStateIsIdleAndCanGenerate() {
        let state = MemeGenerationState()
        XCTAssertFalse(state.isGenerating)
        XCTAssertTrue(state.canGenerate)
        XCTAssertNil(state.generateBlockedReason())
    }

    func testBeginTakesAFreshTicketAndMarksTheSurfaceBusy() {
        var state = MemeGenerationState()
        let ticket = state.begin(.loadingCatalog)
        XCTAssertTrue(state.isGenerating)
        XCTAssertFalse(state.canGenerate)
        XCTAssertTrue(state.accepts(ticket: ticket))
    }

    func testAdvanceMovesPhaseWithinTheSameUnitOfWork() {
        var state = MemeGenerationState()
        let ticket = state.begin(.loadingCatalog)
        XCTAssertTrue(state.advance(.asking, ticket: ticket))
        XCTAssertEqual(state.phase, .asking)
    }

    func testFinishClearsTheBusyFlag() {
        var state = MemeGenerationState()
        let ticket = state.begin(.asking)
        XCTAssertTrue(state.finish(ticket: ticket))
        XCTAssertFalse(state.isGenerating)
        XCTAssertTrue(state.canGenerate)
    }

    /// The regression this whole type exists for: EVERY exit path clears the flag, so
    /// a failure, a rejection, or a timeout can't leave the surface stuck.
    func testFinishingIsIdempotentSoDoubleExitPathsCannotStick() {
        var state = MemeGenerationState()
        let ticket = state.begin(.asking)
        XCTAssertTrue(state.finish(ticket: ticket))
        XCTAssertFalse(state.finish(ticket: ticket))
        XCTAssertFalse(state.isGenerating)
    }

    /// A late result from superseded work must not clear the NEWER work's phase —
    /// the other half of the stuck-state bug, in the opposite direction.
    func testAStaleFinishCannotUnstickNewerWork() {
        var state = MemeGenerationState()
        let stale = state.begin(.asking)
        let current = state.begin(.downloading(templateName: "Drake"))

        XCTAssertFalse(state.finish(ticket: stale))
        XCTAssertTrue(state.isGenerating)
        XCTAssertTrue(state.accepts(ticket: current))
    }

    func testAStaleAdvanceCannotDragTheUIBackToItsOwnPhase() {
        var state = MemeGenerationState()
        let stale = state.begin(.loadingCatalog)
        _ = state.begin(.asking)
        XCTAssertFalse(state.advance(.downloading(templateName: "X"), ticket: stale))
        XCTAssertEqual(state.phase, .asking)
    }

    func testCancelReturnsToIdleAndRefusesTheAbandonedResult() {
        var state = MemeGenerationState()
        let ticket = state.begin(.asking)
        state.cancel()

        XCTAssertFalse(state.isGenerating)
        XCTAssertTrue(state.canGenerate)
        XCTAssertFalse(state.accepts(ticket: ticket))
        XCTAssertFalse(state.finish(ticket: ticket))
    }

    /// Feedback #3: the candidate strip and the Browse grid stay live while a
    /// generation runs. Switching templates is a local re-render, not an LLM call.
    func testTemplateSelectionStaysAvailableInEveryPhase() {
        var state = MemeGenerationState()
        XCTAssertTrue(state.canSelectTemplate)
        _ = state.begin(.loadingCatalog)
        XCTAssertTrue(state.canSelectTemplate)
        _ = state.begin(.asking)
        XCTAssertTrue(state.canSelectTemplate)
        _ = state.begin(.downloading(templateName: "Drake"))
        XCTAssertTrue(state.canSelectTemplate)
    }

    /// Feedback #2: warming is honest and non-blocking — the user can browse, and
    /// Generate says what it is waiting for instead of failing.
    func testWarmingBlocksGenerateHonestlyButNotBrowsing() {
        var state = MemeGenerationState()
        _ = state.begin(.warming)

        XCTAssertFalse(state.isGenerating)
        XCTAssertFalse(state.canGenerate)
        XCTAssertEqual(state.generateBlockedReason(), "Preparing model…")
        XCTAssertTrue(state.canSelectTemplate)
    }

    func testEveryBusyPhaseNamesItselfInTheStatusLine() {
        XCTAssertEqual(MemeGenerationState.Phase.idle.statusText, "")
        XCTAssertEqual(MemeGenerationState.Phase.warming.statusText, "Preparing model…")
        XCTAssertEqual(MemeGenerationState.Phase.loadingCatalog.statusText, "Loading templates…")
        XCTAssertEqual(MemeGenerationState.Phase.asking.statusText, "Asking the model…")
        XCTAssertEqual(
            MemeGenerationState.Phase.downloading(templateName: "Drake").statusText,
            "Downloading Drake…")
    }

    func testTimeoutMessageOffersBothRecoveries() {
        XCTAssertTrue(MemeGenerationState.timeoutMessage.contains("Generate again"))
        XCTAssertTrue(MemeGenerationState.timeoutMessage.contains("Browse all"))
        XCTAssertGreaterThan(MemeGenerationState.generateTimeout, 0)
    }

    // MARK: - v4: the stuck-download orderings

    /// **The owner's report #2 ordering.** A download that is superseded/abandoned and
    /// then followed by a window REOPEN must not leave the surface parked in
    /// `.downloading`. v3's `renderTemplate` returned bare on a stale ticket and
    /// `windowDidOpen` only cleared `isCancelled`, so the phase survived with no task,
    /// no timeout and no Retry behind it — "Downloading <name>" forever.
    func testAReopenedWindowNeverInheritsADownloadingPhase() {
        var state = MemeGenerationState()
        _ = state.begin(.downloading(templateName: "Drake"))
        XCTAssertTrue(state.isGenerating)

        state.reset()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.isGenerating)
        XCTAssertNil(state.generateBlockedReason(), "Generate must be live again after a reopen")
    }

    /// `reset` also refuses the abandoned work's late result, so a download that
    /// completes after the reopen can't drag the fresh window back into its phase.
    func testResetRefusesTheAbandonedDownloadsLateResult() {
        var state = MemeGenerationState()
        let stale = state.begin(.downloading(templateName: "Drake"))
        state.reset()

        XCTAssertFalse(state.accepts(ticket: stale))
        XCTAssertFalse(state.finish(ticket: stale))
        XCTAssertFalse(state.advance(.asking, ticket: stale))
        XCTAssertEqual(state.phase, .idle)
    }

    /// Every download exit — success, failure, timeout, supersession — ends at a
    /// `finish` for its OWN ticket, and finishing a superseded ticket is a harmless
    /// no-op. This is the property that makes "no exit can leave the phase set" true
    /// without a superseded task being able to unstick newer work.
    func testFinishingASupersededDownloadCannotDisturbTheNewerOne() {
        var state = MemeGenerationState()
        let first = state.begin(.downloading(templateName: "Drake"))
        let second = state.begin(.downloading(templateName: "Bart"))

        XCTAssertFalse(state.finish(ticket: first), "the superseded exit is a no-op")
        XCTAssertEqual(state.phase, .downloading(templateName: "Bart"),
                       "the newer download still owns the phase")

        XCTAssertTrue(state.finish(ticket: second))
        XCTAssertEqual(state.phase, .idle)
    }

    /// A download ticket now carries a FINITE ceiling — v3 started one with no timer
    /// at all, which is why a wedged GET hung the surface indefinitely.
    func testADownloadHasItsOwnFiniteCeilingShorterThanAGenerates() {
        XCTAssertGreaterThan(MemeGenerationState.downloadTimeout, 0)
        XCTAssertLessThan(MemeGenerationState.downloadTimeout,
                          MemeGenerationState.generateTimeout,
                          "an image is not a model load — it must give up much sooner")
    }

    /// The download give-up message names the template and offers a way out, rather
    /// than leaving a spinner with no explanation.
    func testDownloadTimeoutMessageNamesTheTemplateAndOffersRetry() {
        let message = MemeGenerationState.downloadTimeoutMessage("Drake Hotline Bling")
        XCTAssertTrue(message.contains("Drake Hotline Bling"))
        XCTAssertTrue(message.contains("Retry"))
    }

    // MARK: - v4: generate retry (the "first two generates fail" report)

    /// A refused connection is "the server isn't up YET", not a failure to report —
    /// this is exactly what surfaced as the owner's raw "network error".
    func testARefusedConnectionIsTreatedAsNotReadyYet() {
        let refused = NSError(domain: NSURLErrorDomain,
                              code: NSURLErrorCannotConnectToHost, userInfo: nil)
        XCTAssertTrue(MemeGenerateRetry.isNotReadyYet(refused))
        XCTAssertTrue(MemeGenerateRetry.shouldRetry(refused, attempt: 1))
    }

    /// A real model error is reported immediately — retrying it would only make the
    /// user wait longer for the same message.
    func testARealFailureIsNotRetried() {
        let real = NSError(domain: "OpenWhisp", code: 42, userInfo: nil)
        XCTAssertFalse(MemeGenerateRetry.isNotReadyYet(real))
        XCTAssertFalse(MemeGenerateRetry.shouldRetry(real, attempt: 1))
    }

    /// The retry budget is finite: the third refusal surfaces honestly instead of
    /// looping forever.
    func testRetriesAreBoundedAndThenReportHonestly() {
        let refused = NSError(domain: NSURLErrorDomain,
                              code: NSURLErrorCannotConnectToHost, userInfo: nil)
        XCTAssertTrue(MemeGenerateRetry.shouldRetry(refused, attempt: 2))
        XCTAssertFalse(
            MemeGenerateRetry.shouldRetry(refused, attempt: MemeGenerateRetry.maxAttempts),
            "the budget is spent — say so rather than retrying forever")
        XCTAssertGreaterThanOrEqual(MemeGenerateRetry.maxAttempts, 2)
    }

    /// Backoff, not a fixed sleep: the first retry is quick (the server is usually one
    /// instant from binding) and later ones wait longer.
    func testRetryDelaysBackOff() {
        XCTAssertEqual(MemeGenerateRetry.delay(beforeAttempt: 1), 0,
                       "the first attempt never waits")
        XCTAssertGreaterThan(MemeGenerateRetry.delay(beforeAttempt: 2), 0)
        XCTAssertGreaterThan(MemeGenerateRetry.delay(beforeAttempt: 3),
                             MemeGenerateRetry.delay(beforeAttempt: 2))
    }

    /// Matching is on the URL error CODE, not on message text — the text is localized,
    /// so a non-English Mac would silently stop retrying if this keyed on English.
    func testNotReadyDetectionDoesNotDependOnLocalizedText() {
        let localized = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: "Не удалось подключиться к серверу"])
        XCTAssertTrue(MemeGenerateRetry.isNotReadyYet(localized))
    }

    /// The wait is visible rather than a frozen button.
    func testRetryStatusNamesTheAttempt() {
        let message = MemeGenerateRetry.retryingMessage(attempt: 2)
        XCTAssertTrue(message.contains("2"))
        XCTAssertTrue(message.contains("\(MemeGenerateRetry.maxAttempts)"))
    }

    // MARK: - v4: what "warmed" means per provider

    /// The bundled provider has a local server, so readiness is its health check —
    /// this is the case the plugin must WAIT for rather than guess at.
    func testTheBundledProviderIsWarmedByWaitingForItsLocalServer() {
        XCTAssertEqual(
            LLMWarmReadiness.decide(provider: "bundled", isExplicit: true,
                                    modelInstalled: true, cleanupEnabled: false),
            .awaitLocalServer)
    }

    /// A cloud/remote provider has no local server to start, so it is ready by
    /// definition. Gating it on a llama-server that will never launch would leave
    /// "Preparing model…" on screen forever — the stuck-state bug in a new costume.
    func testANonBundledProviderIsReadyImmediately() {
        XCTAssertEqual(
            LLMWarmReadiness.decide(provider: "openai", isExplicit: true,
                                    modelInstalled: false, cleanupEnabled: false),
            .alreadyReady)
    }

    /// Bundled but never downloaded is genuinely unavailable — the caller must say so
    /// rather than blocking Generate behind a warm that can't finish.
    func testTheBundledProviderWithoutItsModelIsUnavailable() {
        XCTAssertEqual(
            LLMWarmReadiness.decide(provider: "bundled", isExplicit: true,
                                    modelInstalled: false, cleanupEnabled: true),
            .unavailable)
    }

    /// The MAK-53 split: a surface that resolved its OWN provider to bundled warms
    /// even when Settings → Cleanup is off, while the implicit global case still
    /// respects the toggle.
    func testAnExplicitlyResolvedProviderBypassesTheCleanupToggle() {
        XCTAssertEqual(
            LLMWarmReadiness.decide(provider: "bundled", isExplicit: true,
                                    modelInstalled: true, cleanupEnabled: false),
            .awaitLocalServer)
        XCTAssertEqual(
            LLMWarmReadiness.decide(provider: "bundled", isExplicit: false,
                                    modelInstalled: true, cleanupEnabled: false),
            .unavailable)
    }

    /// Warming blocks Generate with an honest reason — and `reset` clears it, so a
    /// warm that never completed can't leave the button permanently "Preparing model…".
    func testAWarmThatNeverCompletesCannotBlockGenerateForever() {
        var state = MemeGenerationState()
        _ = state.begin(.warming)
        XCTAssertEqual(state.generateBlockedReason(), "Preparing model…")

        state.reset()
        XCTAssertNil(state.generateBlockedReason())
    }
}
