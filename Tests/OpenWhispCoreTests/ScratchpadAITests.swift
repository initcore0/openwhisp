import XCTest
@testable import OpenWhispCore

/// Tests for the Scratchpad's AI actions (MAK-99): the prompt builders, the
/// summary-note layout, and — the part that actually protects the user — the
/// response guard that decides whether an LLM result is allowed to replace a note.
final class ScratchpadAITests: XCTestCase {

    // MARK: - Actions

    func testBothActionsAreOffered() {
        XCTAssertEqual(ScratchpadAI.Action.allCases.count, 2)
    }

    /// Only the in-place transform is destructive — that flag drives both the
    /// preservation guard and the undo requirement.
    func testOnlyFormatMarkdownIsDestructive() {
        XCTAssertTrue(ScratchpadAI.Action.formatMarkdown.isDestructive)
        XCTAssertFalse(ScratchpadAI.Action.summarize.isDestructive)
    }

    func testEveryActionHasATitleSymbolAndBusyLabel() {
        for action in ScratchpadAI.Action.allCases {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.systemImage.isEmpty)
            XCTAssertFalse(action.busyLabel.isEmpty)
        }
    }

    // MARK: - Prompts

    /// Both prompts must pin the output language: tiny local models translate their
    /// input, and the pad holds dictation in whatever language the user speaks
    /// (the LLM cleanup language guard, PR #157).
    func testEveryPromptForbidsTranslation() {
        for action in ScratchpadAI.Action.allCases {
            let p = ScratchpadAI.prompt(for: action).lowercased()
            XCTAssertTrue(p.contains("do not translate"), "\(action)")
        }
    }

    /// The to-Markdown prompt's whole contract is that it does NOT summarize.
    func testFormatPromptForbidsSummarizing() {
        let p = ScratchpadAI.prompt(for: .formatMarkdown).lowercased()
        XCTAssertTrue(p.contains("do not summarize"))
        XCTAssertTrue(p.contains("preserve the content"))
    }

    func testPromptsAreDistinct() {
        XCTAssertNotEqual(
            ScratchpadAI.prompt(for: .formatMarkdown),
            ScratchpadAI.prompt(for: .summarize))
    }

    // MARK: - Summary note layout

    func testSummaryTitleNamesTheSource() {
        XCTAssertEqual(
            ScratchpadAI.summaryTitle(forSourceText: "Standup notes\nWe shipped it."),
            "Summary — Standup notes")
    }

    /// A source titled with Markdown must not leak its markers into the new title.
    func testSummaryTitleStripsMarkdownFromTheSourceTitle() {
        XCTAssertEqual(
            ScratchpadAI.summaryTitle(forSourceText: "# Meeting — Jul 28\n\nbody"),
            "Summary — Meeting — Jul 28")
    }

    /// An untitled source degrades to a bare "Summary", never "Summary — New note".
    func testUntitledSourceYieldsABareSummaryTitle() {
        XCTAssertEqual(ScratchpadAI.summaryTitle(forSourceText: ""), "Summary")
        XCTAssertEqual(ScratchpadAI.summaryTitle(forSourceText: "   \n\n "), "Summary")
    }

    func testSummaryNoteBodyIsAnH1TitleThenTheSummary() {
        let body = ScratchpadAI.summaryNoteText(
            summary: "  - Shipped it.  ", sourceText: "Standup notes\nbody")
        XCTAssertEqual(body, "# Summary — Standup notes\n\n- Shipped it.")
    }

    /// The new note must read as the summary in the sidebar, not "New note".
    func testSummaryNoteTitleIsTheSummaryTitle() {
        var notes = ScratchpadNotes()
        let id = notes.createNote()
        notes.setText(
            ScratchpadAI.summaryNoteText(summary: "Gist.", sourceText: "Standup notes"),
            for: id)
        XCTAssertEqual(notes.note(id)?.displayTitle, "# Summary — Standup notes")
        XCTAssertEqual(ScratchpadText.listTitle(for: notes.note(id)?.text ?? ""),
                       "Summary — Standup notes")
    }

    // MARK: - preservationRatio

    func testIdenticalTextPreservesEverything() {
        XCTAssertEqual(ScratchpadAI.preservationRatio(
            source: "Hello there, world.", output: "Hello there, world."), 1.0, accuracy: 0.001)
    }

    /// The whole point: adding Markdown structure must not lower the score.
    func testAddingMarkdownStructureStillScoresOne() {
        let source = "Agenda budget review timeline"
        let output = "## Agenda\n\n- budget review\n- timeline"
        XCTAssertEqual(ScratchpadAI.preservationRatio(source: source, output: output),
                       1.0, accuracy: 0.001)
    }

    /// Reordering and re-wrapping is legitimate reformatting — a substring or
    /// prefix-based check would wrongly reject it; a multiset comparison doesn't.
    func testReorderingAndRewrappingPreservesEverything() {
        let source = "one two three"
        let output = "three\n\ntwo\n\none"
        XCTAssertEqual(ScratchpadAI.preservationRatio(source: source, output: output),
                       1.0, accuracy: 0.001)
    }

    func testCaseChangesDoNotCountAsLoss() {
        XCTAssertEqual(ScratchpadAI.preservationRatio(source: "hello world", output: "Hello World"),
                       1.0, accuracy: 0.001)
    }

    func testEmptyOutputPreservesNothing() {
        XCTAssertEqual(ScratchpadAI.preservationRatio(source: "content", output: ""),
                       0.0, accuracy: 0.001)
    }

    /// Nothing to lose — an empty note can't fail the guard.
    func testEmptySourceScoresOne() {
        XCTAssertEqual(ScratchpadAI.preservationRatio(source: "", output: "anything"),
                       1.0, accuracy: 0.001)
        XCTAssertEqual(ScratchpadAI.preservationRatio(source: "   \n ", output: ""),
                       1.0, accuracy: 0.001)
    }

    func testDroppingHalfTheContentScoresAboutHalf() {
        let source = String(repeating: "abcd", count: 25)   // 100 content chars
        let output = String(repeating: "abcd", count: 12)   // 48
        XCTAssertEqual(ScratchpadAI.preservationRatio(source: source, output: output),
                       0.48, accuracy: 0.01)
    }

    // MARK: - validate: shared rejections

    func testEmptyOutputIsRejectedForEveryAction() {
        for action in ScratchpadAI.Action.allCases {
            XCTAssertEqual(
                ScratchpadAI.validate(output: "   \n\t ", source: "Some note.", action: action),
                .failure(.empty), "\(action)")
        }
    }

    func testRefusalIsRejectedForEveryAction() {
        for action in ScratchpadAI.Action.allCases {
            XCTAssertEqual(
                ScratchpadAI.validate(
                    output: "I'm sorry, I can't help with that.",
                    source: "Some note about the budget.", action: action),
                .failure(.notAnAnswer), "\(action)")
        }
    }

    /// A LONG output that merely opens with refusal-like words is the work itself.
    func testLongOutputOpeningWithRefusalWordsIsNotTreatedAsARefusal() {
        let long = "I can't believe how much we shipped. " + String(repeating: "Detail. ", count: 40)
        XCTAssertFalse(ScratchpadAI.looksLikeRefusal(long))
    }

    func testRefusalHeuristicIgnoresOrdinaryShortText() {
        XCTAssertFalse(ScratchpadAI.looksLikeRefusal("## Notes\n\n- Ship on Friday."))
    }

    /// The known tiny-local-model failure: the note comes back translated.
    func testTranslatedOutputIsRejected() {
        let russian = "Это заметка о бюджете и сроках проекта на следующий квартал."
        let english = "This is a note about the budget and project timeline for next quarter."
        XCTAssertEqual(
            ScratchpadAI.validate(output: english, source: russian, action: .summarize),
            .failure(.translated))
    }

    // MARK: - validate: the destructive-action preservation guard

    /// THE guard that matters: a "format" that actually summarized must not be
    /// allowed to overwrite the note.
    func testFormatThatSummarizedIsRejected() {
        let source = String(repeating: "The team discussed the budget in detail. ", count: 20)
        let result = ScratchpadAI.validate(
            output: "## Summary\n\n- Budget discussed.", source: source, action: .formatMarkdown)
        guard case .failure(.lostContent(let share)) = result else {
            return XCTFail("expected lostContent, got \(result)")
        }
        XCTAssertLessThan(share, ScratchpadAI.minPreservationRatio)
    }

    /// The same over-lossy output is ACCEPTED for summarize — losing content is the
    /// point there, and the result goes into a new note anyway.
    func testSummarizeAcceptsALossyResult() {
        let source = String(repeating: "The team discussed the budget in detail. ", count: 20)
        let result = ScratchpadAI.validate(
            output: "## Summary\n\n- Budget discussed.", source: source, action: .summarize)
        XCTAssertEqual(result, .success("## Summary\n\n- Budget discussed."))
    }

    /// A genuine reformat — same content, new structure — is accepted in place.
    func testFaithfulReformatIsAccepted() {
        let source = "agenda budget review timeline next steps ship on friday"
        let output = "## Agenda\n\n- budget review\n- timeline\n\n## Next steps\n\nship on friday"
        XCTAssertEqual(
            ScratchpadAI.validate(output: output, source: source, action: .formatMarkdown),
            .success(output))
    }

    /// Dropping dictation filler stays comfortably within the tolerance on
    /// realistic text — this is the calibration case for `minPreservationRatio`.
    ///
    /// Measured: a genuine reformat that strips "um"/"uh"/"you know" from a
    /// dictated paragraph scores ~0.95, while the failure we're guarding against
    /// (the same source summarized instead) scores ~0.27. The 0.80 threshold sits
    /// in the middle of that gap with a wide margin on both sides.
    func testDroppingFillerWordsIsStillAccepted() {
        let source = """
        So um I wanted to go over the quarterly numbers with everyone. Revenue came \
        in at about two point three million which is you know roughly twelve percent \
        above what we forecast. The main driver there was the enterprise segment, um, \
        particularly the renewals in EMEA. Uh, on the cost side we came in slightly \
        over on headcount but under on infrastructure so it roughly washes out.
        """
        let output = """
        ## Quarterly numbers

        I wanted to go over the quarterly numbers with everyone.

        - Revenue came in at about two point three million, roughly twelve percent \
        above what we forecast.
        - The main driver was the enterprise segment, particularly the renewals in EMEA.
        - On the cost side we came in slightly over on headcount but under on \
        infrastructure, so it roughly washes out.
        """
        let share = ScratchpadAI.preservationRatio(source: source, output: output)
        XCTAssertGreaterThanOrEqual(share, ScratchpadAI.minPreservationRatio, "share=\(share)")
        XCTAssertEqual(
            ScratchpadAI.validate(output: output, source: source, action: .formatMarkdown),
            .success(output))

        // The other side of the calibration: the SAME source, summarized instead of
        // formatted, must be rejected — with a wide margin, not a hair's breadth.
        let summarized = """
        ## Quarterly numbers

        - Revenue $2.3M, 12% above forecast
        - Driver: enterprise renewals in EMEA
        - Costs roughly flat
        """
        let lossyShare = ScratchpadAI.preservationRatio(source: source, output: summarized)
        XCTAssertLessThan(lossyShare, 0.5, "share=\(lossyShare)")
    }

    func testAcceptedOutputIsReturnedTrimmed() {
        let source = "hello world"
        XCTAssertEqual(
            ScratchpadAI.validate(output: "\n\n  hello world  \n\n", source: source,
                                  action: .formatMarkdown),
            .success("hello world"))
    }

    // MARK: - Rejection messages

    func testEveryRejectionHasANonEmptyReason() {
        let cases: [ScratchpadAI.Rejection] = [
            .empty, .notAnAnswer, .lostContent(preservedShare: 0.3), .translated,
        ]
        for c in cases { XCTAssertFalse(c.reason.isEmpty, "\(c)") }
    }

    /// The status line reads "Kept original — the result dropped 70% of the note".
    func testLostContentReasonReportsThePercentDropped() {
        XCTAssertTrue(ScratchpadAI.Rejection.lostContent(preservedShare: 0.30)
            .reason.contains("70%"))
    }

    // MARK: - End-to-end note effects
    //
    // The app model's `apply` step is AppKit-bound (it drives an NSTextView), but
    // the STORE half of it is pure — these pin what each action does to the notes,
    // which is what the user actually keeps.

    /// A rejected result must leave the source note byte-identical. This is the
    /// "failure NEVER clobbers the note" contract.
    func testARejectedFormatLeavesTheNoteUntouched() {
        var notes = ScratchpadNotes()
        let id = notes.createNote()
        let original = String(repeating: "The team discussed the budget in detail. ", count: 20)
        notes.setText(original, for: id)

        let result = ScratchpadAI.validate(
            output: "## Summary\n\n- Budget discussed.", source: original, action: .formatMarkdown)
        // The app only writes on .success — a rejection is a no-op by construction.
        if case .success(let accepted) = result { notes.setText(accepted, for: id) }

        XCTAssertEqual(notes.note(id)?.text, original)
        XCTAssertEqual(notes.notes.count, 1)
    }

    /// Summarize is non-destructive: a NEW note appears, the source keeps its text.
    func testSummarizeAddsANewNoteAndLeavesTheSourceIntact() {
        var notes = ScratchpadNotes()
        let sourceID = notes.createNote()
        let original = "Standup notes\nWe shipped the thing on Friday."
        notes.setText(original, for: sourceID)

        // What the app does on an accepted summary.
        let summaryID = notes.createNote()
        notes.setText(
            ScratchpadAI.summaryNoteText(summary: "- Shipped Friday.", sourceText: original),
            for: summaryID)
        notes.clearTypedProvenance(for: summaryID)

        XCTAssertEqual(notes.notes.count, 2)
        XCTAssertEqual(notes.note(sourceID)?.text, original, "source must be untouched")
        XCTAssertEqual(notes.note(summaryID)?.text,
                       "# Summary — Standup notes\n\n- Shipped Friday.")
        // The new note sorts to the front — the app selects it.
        XCTAssertEqual(notes.notes.first?.id, summaryID)
        // Machine-authored body: no typed/dictated provenance.
        XCTAssertNil(notes.note(summaryID)?.lastTypedAt)
        XCTAssertEqual(notes.note(summaryID)?.origin, .empty)
    }

    /// Two summaries of the same note stack up rather than overwriting each other.
    func testSummarizingTwiceYieldsTwoNotes() {
        var notes = ScratchpadNotes()
        let sourceID = notes.createNote()
        notes.setText("Standup notes\nbody", for: sourceID)
        for _ in 0..<2 {
            let id = notes.createNote()
            notes.setText(
                ScratchpadAI.summaryNoteText(summary: "gist", sourceText: "Standup notes"), for: id)
        }
        XCTAssertEqual(notes.notes.count, 3)
    }

    /// An accepted format replaces the note's text in place — one note, new body.
    func testAnAcceptedFormatReplacesTheNoteTextInPlace() {
        var notes = ScratchpadNotes()
        let id = notes.createNote()
        let original = "agenda budget review timeline next steps ship on friday"
        notes.setText(original, for: id)

        let output = "## Agenda\n\n- budget review\n- timeline\n\n## Next steps\n\nship on friday"
        guard case .success(let accepted) = ScratchpadAI.validate(
            output: output, source: original, action: .formatMarkdown) else {
            return XCTFail("expected the faithful reformat to be accepted")
        }
        notes.setText(accepted, for: id)

        XCTAssertEqual(notes.notes.count, 1, "format must not create a note")
        XCTAssertEqual(notes.note(id)?.text, output)
    }
}

// MARK: - Model override

/// Tests for the per-Scratchpad model override (MAK-99), which reuses the MAK-53
/// `SummaryModelResolver` decision and adds only the pad's storage keys and menu.
final class ScratchpadAIModelTests: XCTestCase {

    private func resolved(
        provider: String = ScratchpadAIModel.useDefaultID,
        model: String = "",
        endpoint: String = "",
        cleanupProvider: String = "bundled",
        cleanupModel: String = "qwen-tiny",
        cleanupEndpoint: String = ""
    ) -> SummaryModelResolver.Resolved {
        ScratchpadAIModel.resolve(
            override: .init(provider: provider, model: model, endpoint: endpoint),
            cleanupProvider: cleanupProvider,
            cleanupModel: cleanupModel,
            cleanupEndpoint: cleanupEndpoint)
    }

    /// The default: no override ⇒ exactly the user's current cleanup/refine model.
    func testDefaultFollowsTheCleanupModel() {
        let r = resolved(cleanupProvider: "openai", cleanupModel: "gpt-4o-mini")
        XCTAssertEqual(r.provider, "openai")
        XCTAssertEqual(r.model, "gpt-4o-mini")
    }

    func testDefaultSentinelMatchesTheMeetingOverrideSentinel() {
        XCTAssertEqual(ScratchpadAIModel.useDefaultID, SummaryModelResolver.sameAsCleanupID)
    }

    /// An explicit override wins over the cleanup settings.
    func testExplicitOverrideWins() {
        let r = resolved(provider: "local", model: "llama-70b", endpoint: "http://box:8080/v1",
                         cleanupProvider: "bundled", cleanupModel: "qwen-tiny")
        XCTAssertEqual(r.provider, "local")
        XCTAssertEqual(r.model, "llama-70b")
        XCTAssertEqual(r.endpoint, "http://box:8080/v1")
    }

    /// An override provider with a blank model asks the provider for its default.
    func testBlankOverrideModelFallsBackToTheProviderDefault() {
        XCTAssertEqual(resolved(provider: "openai", cleanupProvider: "bundled").model, "")
    }

    /// …except when the override names the SAME provider cleanup uses, where the
    /// cleanup model is the sensible default.
    func testBlankOverrideModelOnTheCleanupProviderReusesTheCleanupModel() {
        XCTAssertEqual(
            resolved(provider: "bundled", cleanupProvider: "bundled", cleanupModel: "qwen-tiny").model,
            "qwen-tiny")
    }

    /// The privacy classification must come from the shared source of truth, so the
    /// pad's gate can never drift from the cleanup/summarize gates.
    func testLocalityMatchesTheSharedLocalProviderSet() {
        for provider in ScreenContextGate.localRefineProviders {
            XCTAssertTrue(resolved(provider: provider).isLocal, provider)
        }
        XCTAssertFalse(resolved(provider: "openai").isLocal)
        XCTAssertFalse(resolved(provider: "agentCLI").isLocal)
    }

    // MARK: - Offered providers

    func testOfferedProvidersLeadWithTheDefault() {
        XCTAssertEqual(ScratchpadAIModel.offeredProviders.first, ScratchpadAIModel.useDefaultID)
    }

    /// agentCLI is deliberately NOT offered: the runtime path is OpenAI-shape only,
    /// and its fallback endpoint is the OpenAI cloud — so an agent-CLI resolution
    /// must never be reachable from the menu.
    func testAgentCLIIsNotOffered() {
        XCTAssertFalse(ScratchpadAIModel.offeredProviders.contains("agentCLI"))
    }

    func testOfferedProvidersMatchTheMeetingOverrideMenu() {
        XCTAssertEqual(ScratchpadAIModel.offeredProviders,
                       [SummaryModelResolver.sameAsCleanupID, "bundled", "local", "openai"])
    }

    func testEveryOfferedProviderHasALabel() {
        for id in ScratchpadAIModel.offeredProviders {
            XCTAssertFalse(ScratchpadAIModel.label(for: id).isEmpty, id)
            XCTAssertNotEqual(ScratchpadAIModel.label(for: id), id, id)
        }
    }

    // MARK: - Fail-closed

    /// Defense in depth: even if an agentCLI id reaches the resolver (a stale
    /// defaults value, say), the action must refuse rather than fall through to the
    /// OpenAI cloud endpoint the user never chose.
    func testAgentCLIResolutionIsRefused() {
        XCTAssertFalse(ScratchpadAIModel.isUsable(resolved(provider: "agentCLI")))
        XCTAssertFalse(ScratchpadAIModel.isUsable(
            resolved(cleanupProvider: "agentCLI", cleanupModel: "")))
    }

    func testOfferedProvidersAreAllUsable() {
        for id in ScratchpadAIModel.offeredProviders where id != ScratchpadAIModel.useDefaultID {
            XCTAssertTrue(ScratchpadAIModel.isUsable(resolved(provider: id)), id)
        }
    }

    func testEmptyProviderIsNotUsable() {
        XCTAssertFalse(ScratchpadAIModel.isUsable(
            .init(provider: "", model: "", endpoint: "")))
    }

    /// The keys are a stored contract — a rename silently orphans the user's setting.
    func testDefaultsKeysArePinned() {
        XCTAssertEqual(ScratchpadAIModel.providerKey, "scratchpadAIProvider")
        XCTAssertEqual(ScratchpadAIModel.modelKey, "scratchpadAIModel")
        XCTAssertEqual(ScratchpadAIModel.endpointKey, "scratchpadAIEndpoint")
    }

    /// The pad's keys must not collide with the meeting override's.
    func testDefaultsKeysAreDistinctFromTheMeetingOverride() {
        let padKeys = Set([ScratchpadAIModel.providerKey, ScratchpadAIModel.modelKey,
                           ScratchpadAIModel.endpointKey])
        let meetingKeys = Set(["summaryLLMProvider", "summaryLLMModel", "summaryLLMEndpoint"])
        XCTAssertTrue(padKeys.isDisjoint(with: meetingKeys))
    }
}
