import XCTest
@testable import OpenWhispCore

/// The v5 live-soak defects: template downloads that stop working after ~a day of app
/// uptime, and the absence of any way to start a meme from scratch.
///
/// Both reports came from leaving the app RUNNING for a day, which is the one thing a
/// unit test cannot literally do. What it CAN do is pin the mechanisms behind each
/// report — the cache's staleness arithmetic against an injected clock, the predicate
/// that decides a connection pool is suspect, and the totality of the reset — so the
/// long-idle behaviour is a consequence of tested rules rather than of a hope.
final class MemeRecoveryTests: XCTestCase {

    // MARK: - Cache staleness against an injected clock
    //
    // Suspect (a) from the report: does an expired cache plus a failing refresh wedge
    // the catalog? These pin the arithmetic at the exact boundaries a day-long uptime
    // walks through, using an injected `now` rather than a real clock.

    private let templates = [
        MemeTemplate(id: "imgflip:1", name: "Drake Hotline Bling", url: "u1",
                     width: 1200, height: 1200, source: .imgflip)
    ]

    private func cached(ageSeconds: TimeInterval, now: Date) -> MemeCatalogCache.Cached {
        MemeCatalogCache.Cached(
            fetchedAt: now.addingTimeInterval(-ageSeconds), templates: templates)
    }

    /// A day and a second of uptime makes the cache stale — but stale means SHOW IT
    /// AND REFRESH, never "stop working". This is the decision the owner's day-long
    /// session crosses, and the one a wedged-catalog theory would have to blame.
    func testCacheOneSecondPastTheTTLIsShownAndRefreshedRatherThanDiscarded() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let decision = MemeCatalogCache.decide(
            cached: cached(ageSeconds: MemeCatalogCache.maxAge + 1, now: now), now: now)
        XCTAssertEqual(decision, .useCacheAndRefresh)
    }

    /// One second BEFORE the TTL is still fresh — the other side of the same boundary,
    /// so an off-by-one can't silently turn every open into a fetch.
    func testCacheOneSecondBeforeTheTTLStillAvoidsTheNetwork() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let decision = MemeCatalogCache.decide(
            cached: cached(ageSeconds: MemeCatalogCache.maxAge - 1, now: now), now: now)
        XCTAssertEqual(decision, .useCache)
    }

    /// A WEEK of uptime is still only "stale", not "unusable". The catalog must never
    /// degrade into `.fetchNow` with age alone: that would make an offline user's
    /// working plugin start demanding the network, which is the failure mode the disk
    /// cache exists to prevent.
    func testAWeekOldCacheIsStillServedRatherThanForcingAFetch() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let decision = MemeCatalogCache.decide(
            cached: cached(ageSeconds: MemeCatalogCache.maxAge * 7, now: now), now: now)
        XCTAssertEqual(decision, .useCacheAndRefresh)
        XCTAssertNotEqual(decision, .fetchNow)
    }

    /// A refresh that FAILS while a stale cache is on screen stays silent.
    ///
    /// This is the "is refresh failure silent in a way that becomes a permanent
    /// download failure?" question from the report, answered directly: silence here is
    /// correct and deliberate, because the user is still looking at a usable corpus.
    /// The permanence came from elsewhere (the session and the lifecycle), not here.
    func testAFailedRefreshBehindAStaleCacheStaysSilent() {
        XCTAssertNil(MemeCatalogCache.refreshFailureMessage(
            hasCachedTemplates: true, reason: "The request timed out."))
    }

    /// ...but with NOTHING on screen the same failure must name the Retry. A silent
    /// failure there is indistinguishable from a hang, which is exactly what the owner
    /// reported seeing.
    func testAFailedRefreshWithNothingCachedSurfacesTheErrorAndTheRetry() {
        let message = MemeCatalogCache.refreshFailureMessage(
            hasCachedTemplates: false, reason: "The request timed out.")
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("Retry"))
        XCTAssertTrue(message!.contains("The request timed out."))
    }

    // MARK: - Transport health: which failures throw the connection pool away
    //
    // Suspect (b): the process-lifetime URLSession. A pooled connection can outlive
    // its validity across a sleep/wake, after which every request through that session
    // fails identically — forever. These pin WHICH errors mean "the pool is suspect".

    private func urlError(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code)
    }

    /// The sleep/wake signatures. Each of these is a real thing a Mac that has been
    /// awake for a day produces, and each must recycle the session rather than being
    /// retried forever through the same broken pool.
    func testSleepWakeTransportFailuresRecycleTheSession() {
        for code in [
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorSecureConnectionFailed,
        ] {
            XCTAssertTrue(
                MemeGenerationState.isTransportFailure(urlError(code)),
                "URL error \(code) should be treated as a suspect transport")
        }
    }

    /// A 404, a cancelled request, or an unparseable body says NOTHING about the
    /// transport. Recycling on these would throw away healthy connections on every
    /// missing template — a fix that costs more than the bug.
    func testNonTransportFailuresKeepTheSession() {
        XCTAssertFalse(MemeGenerationState.isTransportFailure(urlError(NSURLErrorCancelled)))
        XCTAssertFalse(MemeGenerationState.isTransportFailure(
            urlError(NSURLErrorBadServerResponse)))
        XCTAssertFalse(MemeGenerationState.isTransportFailure(
            NSError(domain: NSCocoaErrorDomain, code: 4)))
    }

    /// Errors from another domain are not transport verdicts. Matched on CODE within
    /// `NSURLErrorDomain` rather than on message text, because the text is localized —
    /// a Russian-locale Mac must recycle exactly like an English one.
    func testForeignErrorDomainsAreNotTreatedAsTransportFailures() {
        XCTAssertFalse(MemeGenerationState.isTransportFailure(
            NSError(domain: "MemeGenerator", code: NSURLErrorTimedOut)))
    }

    // MARK: - The state machine across a long idle
    //
    // Suspect (c): the download ceiling and `windowDidOpen`'s reset.

    /// A `.downloading` phase stranded by a close/reopen is cleared unconditionally.
    ///
    /// This is the state half of the owner's report. `reset` must not be
    /// ticket-guarded: the whole point is that the stranded phase's owner is GONE, so
    /// there is no correct ticket left to present.
    func testResetClearsAStrandedDownloadingPhaseWithoutATicket() {
        var state = MemeGenerationState()
        _ = state.begin(.downloading(templateName: "Drake Hotline Bling"))
        XCTAssertTrue(state.isGenerating)

        state.reset()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.isGenerating)
        XCTAssertTrue(state.canGenerate)
    }

    /// The work stranded by a reset can never come back and re-wedge the surface: its
    /// ticket is dead, so its `finish` is a no-op. Without this a download that
    /// returns after the reset would write its status over a fresh window.
    func testWorkStrandedByAResetCannotFinishOverTheFreshState() {
        var state = MemeGenerationState()
        let stranded = state.begin(.downloading(templateName: "Drake Hotline Bling"))

        state.reset()
        let newWork = state.begin(.asking)

        XCTAssertFalse(state.finish(ticket: stranded),
                       "a reset-stranded ticket must not be able to finish anything")
        XCTAssertEqual(state.phase, .asking, "the stranded finish must not clear newer work")
        XCTAssertTrue(state.finish(ticket: newWork))
    }

    /// A download that fails and is then retried recovers: the failure clears the
    /// phase (so the surface isn't stuck), and the retry takes a NEW ticket that can
    /// legitimately complete. This is the failure-then-recovery ordering the report
    /// asks to be pinned.
    func testADownloadFailureThenRetryRecoversTheSurface() {
        var state = MemeGenerationState()

        // Attempt 1: begins, then fails.
        let first = state.begin(.downloading(templateName: "Drake Hotline Bling"))
        XCTAssertTrue(state.finish(ticket: first), "the failure path must clear the phase")
        XCTAssertFalse(state.isGenerating)
        XCTAssertTrue(state.canGenerate, "a failed download must leave the surface usable")

        // Attempt 2 (Retry): a fresh ticket, which completes.
        let retry = state.begin(.downloading(templateName: "Drake Hotline Bling"))
        XCTAssertNotEqual(retry, first, "Retry must not reuse the failed attempt's ticket")
        XCTAssertTrue(state.finish(ticket: retry))
        XCTAssertEqual(state.phase, .idle)
    }

    /// The download ceiling is finite and far tighter than the generate one. An image
    /// is a few hundred KB; anything past this is a hang, not slowness — and a finite
    /// ceiling is what turns "Downloading… forever" into an error with a Retry.
    func testTheDownloadCeilingIsFiniteAndTighterThanTheGenerateCeiling() {
        XCTAssertLessThan(
            MemeGenerationState.downloadTimeout, MemeGenerationState.generateTimeout)
        XCTAssertGreaterThan(MemeGenerationState.downloadTimeout, 0)
        XCTAssertTrue(
            MemeGenerationState.downloadTimeoutMessage("Drake").contains("Retry"),
            "the timeout message must point at the way out")
    }

    /// Template selection stays live through a failed download. The owner's earlier
    /// report was a surface frozen by a stuck flag; a v5 download failure must not
    /// reintroduce it by any other route.
    func testTemplateSelectionSurvivesAFailedDownload() {
        var state = MemeGenerationState()
        let ticket = state.begin(.downloading(templateName: "Drake Hotline Bling"))
        XCTAssertTrue(state.canSelectTemplate)
        _ = state.finish(ticket: ticket)
        XCTAssertTrue(state.canSelectTemplate)
    }
}

/// "Start from scratch" — the v5 reset, proved TOTAL.
///
/// The value of testing `MemeComposition` rather than the AppKit model is that this
/// asserts the property that actually matters: after a reset, EVERY field equals its
/// initial value. A test that checked six named fields would pass while a seventh
/// silently survived, which is the exact bug a "New meme" button must not have.
final class MemeCompositionResetTests: XCTestCase {

    /// A composition with every single field dirtied, so nothing is reset by accident.
    private func fullyPopulated() -> MemeComposition {
        let boxes = MemeCaptionLayout.seedBoxes(topText: "when the", bottomText: "build is green")
        return MemeComposition(
            description: "a meme about flaky tests",
            boxes: boxes,
            selectedBoxID: boxes.first?.id,
            candidateIDs: ["imgflip:1", "imgflip:2", "memegen:drake"],
            selectedTemplateID: "imgflip:1",
            status: "Couldn't load Drake Hotline Bling — The request timed out. Press Retry.",
            didFallBack: true,
            candidatesAreFallback: true,
            catalogFailed: true,
            imageFailed: true,
            failedTemplateID: "imgflip:1",
            hasMeme: true)
    }

    /// Nothing survives. One equality against `.empty` covers every field there is —
    /// including any added later, which is the whole reason this is a value type.
    func testResetReturnsEveryFieldToTheInitialEmptyState() {
        var composition = fullyPopulated()
        XCTAssertNotEqual(composition, .empty, "the fixture must actually be dirty")

        composition.reset()

        XCTAssertEqual(composition, .empty)
    }

    /// The individually-named checks, so a failure says WHICH field survived rather
    /// than only that the whole value differed.
    func testResetClearsThePromptCaptionsCandidatesAndErrors() {
        var composition = fullyPopulated()
        composition.reset()

        XCTAssertEqual(composition.description, "")
        XCTAssertTrue(composition.boxes.isEmpty)
        XCTAssertNil(composition.selectedBoxID)
        XCTAssertTrue(composition.candidateIDs.isEmpty)
        XCTAssertNil(composition.selectedTemplateID)
        XCTAssertEqual(composition.status, "")
        XCTAssertFalse(composition.didFallBack)
        XCTAssertFalse(composition.candidatesAreFallback)
        XCTAssertFalse(composition.catalogFailed)
        XCTAssertFalse(composition.imageFailed)
        XCTAssertNil(composition.failedTemplateID)
        XCTAssertFalse(composition.hasMeme)
    }

    /// Resetting twice is the same as resetting once — the button is idempotent, so a
    /// double-press (or ⌘N on an already-clear window) can't reach a different state.
    func testResetIsIdempotent() {
        var composition = fullyPopulated()
        composition.reset()
        composition.reset()
        XCTAssertEqual(composition, .empty)
    }

    /// An untouched surface reports itself empty, which is what dims the New meme
    /// button. A control that is live but does nothing is the papercut this avoids.
    func testAnUntouchedCompositionIsEmpty() {
        XCTAssertTrue(MemeComposition.empty.isEmpty)
    }

    /// An error ALONE counts as something to clear. This is the state a user most
    /// wants a way out of, so New meme must be offered even when nothing was produced.
    func testACompositionHoldingOnlyAnErrorIsNotEmpty() {
        let failed = MemeComposition(
            status: "Couldn't load Drake — the request timed out.",
            imageFailed: true,
            failedTemplateID: "imgflip:1")
        XCTAssertFalse(failed.isEmpty)
    }

    /// A dictated description alone counts too — the commonest "I misspoke, start
    /// over" case, and the one voice-first users hit most.
    func testACompositionHoldingOnlyADictatedDescriptionIsNotEmpty() {
        XCTAssertFalse(MemeComposition(description: "a meme about mondays").isEmpty)
    }

    /// The empty state INVITES rather than just being blank, and names both routes in
    /// (dictate, or pick a template) because the window offers both.
    func testTheEmptyHintNamesBothWaysToStart() {
        let hint = MemeComposition.emptyHint
        XCTAssertFalse(hint.isEmpty)
        XCTAssertTrue(hint.lowercased().contains("describe"))
        XCTAssertTrue(hint.lowercased().contains("template"))
    }
}

/// Manifest-declared menu shortcuts (v5, item 3), and who is allowed one.
///
/// The host owns the keyboard because only the host can see the whole menu. A plugin
/// asks; `PluginKeyEquivalent` decides. These pin the decision rather than leaving it
/// to be discovered by a user whose ⌘Q stopped quitting.
final class PluginKeyEquivalentTests: XCTestCase {

    func testASingleLowercaseLetterIsAccepted() {
        XCTAssertEqual(PluginKeyEquivalent.normalized("m"), "m")
    }

    /// An uppercase request means ⌘M, not ⇧⌘M — `NSMenuItem` reads an uppercase key
    /// equivalent as shifted, so normalizing is what stops a manifest silently getting
    /// a different shortcut than the one it declared.
    func testAnUppercaseRequestIsLowercasedRatherThanBecomingAShiftShortcut() {
        XCTAssertEqual(PluginKeyEquivalent.normalized("M"), "m")
    }

    func testSurroundingWhitespaceIsTolerated() {
        XCTAssertEqual(PluginKeyEquivalent.normalized(" m "), "m")
    }

    /// Multi-character, empty, and absent requests are all "no shortcut" rather than
    /// errors — the field is optional and cosmetic.
    func testUnusableRequestsYieldNoShortcut() {
        XCTAssertNil(PluginKeyEquivalent.normalized("mm"))
        XCTAssertNil(PluginKeyEquivalent.normalized(""))
        XCTAssertNil(PluginKeyEquivalent.normalized("   "))
        XCTAssertNil(PluginKeyEquivalent.normalized(nil))
        XCTAssertNil(PluginKeyEquivalent.normalized("⌘"))
    }

    /// A plugin may not shadow the app's own shortcuts. ⌘Q is the one that matters
    /// most — a manifest that could take it would be a genuine hazard, not a papercut.
    func testAPluginCannotTakeAShortcutTheAppAlreadyOwns() {
        for reserved in ["q", "s", ",", "c", "x", "v", "a", "z"] {
            XCTAssertNil(
                PluginKeyEquivalent.assignable(reserved, taken: []),
                "\(reserved) is the app's and must not be grantable")
        }
    }

    /// ⌘M specifically IS free — this app has no Window menu, which is what makes the
    /// meme plugin's request grantable. Pinned so padding the reserved set later
    /// doesn't silently revoke a shipped shortcut.
    func testTheMemePluginsRequestedShortcutIsGrantable() {
        XCTAssertEqual(PluginKeyEquivalent.assignable("m", taken: []), "m")
    }

    /// Two plugins asking for the same key resolve by list order — deterministically,
    /// rather than both rendering ⌘M and one of them silently never firing.
    func testTwoPluginsAskingForTheSameKeyResolveByListOrder() {
        let assigned = PluginKeyEquivalent.assign(requests: [
            (id: "meme-generator", keyEquivalent: "m"),
            (id: "metronome", keyEquivalent: "m"),
        ])
        XCTAssertEqual(assigned["meme-generator"], "m")
        XCTAssertNil(assigned["metronome"], "the loser gets no shortcut, not a duplicate")
    }

    /// A refused plugin still appears — it just gets no key. Losing the whole row over
    /// a shortcut collision would be a far worse trade than losing the shortcut.
    func testARefusedShortcutDoesNotRemoveThePlugin() {
        let assigned = PluginKeyEquivalent.assign(requests: [
            (id: "shadow", keyEquivalent: "q"),
            (id: "meme-generator", keyEquivalent: "m"),
        ])
        XCTAssertNil(assigned["shadow"])
        XCTAssertEqual(assigned["meme-generator"], "m",
                       "a refusal must not disturb the next plugin's grant")
    }

    func testPluginsAskingForNothingGetNothing() {
        let assigned = PluginKeyEquivalent.assign(requests: [
            (id: "quiet", keyEquivalent: nil),
        ])
        XCTAssertTrue(assigned.isEmpty)
    }
}

/// The manifest side of the shortcut field: decode, validation, and display.
final class PluginManifestKeyEquivalentTests: XCTestCase {

    private func manifest(keyEquivalent: String?) -> PluginManifest {
        PluginManifest(
            id: "test-plugin", name: "Test", version: "1.0", summary: "s",
            symbol: "gear", entry: .builtIn, keyEquivalent: keyEquivalent)
    }

    /// The field is OPTIONAL: a manifest written before it existed — including one
    /// already sitting in a user's plugins folder — must still decode.
    func testAManifestWithoutTheFieldStillDecodes() throws {
        let json = """
        {"id":"legacy","name":"Legacy","version":"1.0","summary":"s",
         "symbol":"gear","entry":"builtIn"}
        """
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertNil(decoded.keyEquivalent)
        XCTAssertTrue(decoded.isValid)
    }

    func testTheFieldRoundTripsThroughJSON() throws {
        let original = manifest(keyEquivalent: "m")
        let decoded = try JSONDecoder().decode(
            PluginManifest.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded.keyEquivalent, "m")
        XCTAssertEqual(decoded, original)
    }

    /// A malformed shortcut is REPORTED but not fatal: the plugin still lists and
    /// still runs, it just gets no key. Losing a working plugin over a cosmetic field
    /// would be the wrong trade.
    func testAMalformedShortcutIsReportedButDoesNotInvalidateThePlugin() {
        let bad = manifest(keyEquivalent: "cmd+m")
        XCTAssertEqual(bad.validate(), .invalidKeyEquivalent("cmd+m"))
        XCTAssertTrue(bad.isValid, "a bad shortcut must not disqualify the plugin")
        XCTAssertNil(bad.keyEquivalentDisplay)
    }

    /// The structural failures still ARE fatal — the permissiveness above is scoped to
    /// the shortcut and must not have leaked into id/name/symbol validation.
    func testStructuralFailuresRemainFatal() {
        let traversal = PluginManifest(
            id: "../escape", name: "Bad", version: "1", summary: "",
            symbol: "gear", entry: .builtIn)
        XCTAssertFalse(traversal.isValid)
    }

    func testDisplayFormIsTheUppercasedCommandForm() {
        XCTAssertEqual(manifest(keyEquivalent: "m").keyEquivalentDisplay, "⌘M")
        XCTAssertNil(manifest(keyEquivalent: nil).keyEquivalentDisplay)
    }

    /// The shipped plugin declares ⌘M, and the registry literal is what actually runs.
    func testTheMemeGeneratorDeclaresCommandM() {
        XCTAssertEqual(PluginRegistry.memeGenerator.keyEquivalent, "m")
        XCTAssertEqual(PluginRegistry.memeGenerator.keyEquivalentDisplay, "⌘M")
        XCTAssertNil(PluginRegistry.memeGenerator.validate())
    }
}
