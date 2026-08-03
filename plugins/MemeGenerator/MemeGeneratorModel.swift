import AppKit
import SwiftUI

/// The observable state behind the Meme Generator window (spike v3).
///
/// The pipeline, end to end:
///
/// 1. The window OPENS: the LLM is warmed and the template catalog is opened from
///    disk (then refreshed in the background). Neither blocks the user.
/// 2. The user DICTATES a description (or types it) into `description`.
/// 3. `generate()` sends the description **plus the merged catalog's template names**
///    to the configured LLM via the injected `aiCall` seam — the same
///    closure-injection `ScratchpadModel` uses, so this model never touches AppState
///    and stays stubbable.
/// 4. The reply is parsed by the pure `MemeAI.parseRanked`, which keeps only names
///    that really exist in the catalog. The result is a RANKED candidate list.
/// 5. The best candidate auto-renders; the rest sit in a thumbnail strip. The user
///    can click another candidate, or open "Browse" and pick any of the ~300.
/// 6. The chosen template is loaded (from disk or the network) and captioned LOCALLY
///    by `MemeRenderer` from the caption BOX model, which the editor then mutates.
///
/// Only the catalog fetch and the image GETs touch the network, and only to READ —
/// no user text is ever sent anywhere.
///
/// ## v3 — what the owner's live testing changed
///
/// * **The corpus is now three providers** (imgflip + memegen + the user's own
///   imported library), merged and cached on disk. The user library is the answer to
///   "the templates are America-centric": any image can become a template, in any
///   language, and it works offline.
/// * **The LLM is warmed on window open.** The reported "first Generate fails with a
///   network error and model loading" was a request hitting a llama-server that
///   hadn't started. Generate now WAITS behind an honest "Preparing model…" instead.
/// * **The busy flag is a state machine** (`MemeGenerationState`). The reported stuck
///   spinner was a `Bool` that several exit paths never cleared; every exit path now
///   goes through one idempotent `finish`, plus a Cancel button and a hard timeout.
/// * **Template switching is never blocked** — it is a local re-render, so it stays
///   live even while a generation is in flight.
@MainActor
final class MemeGeneratorModel: ObservableObject {

    /// What the user described, and what dictation lands in.
    @Published var description: String = ""

    /// The finished meme, if one has been generated.
    @Published private(set) var meme: NSImage?

    /// Human-readable status, shown under the buttons. Doubles as the error channel —
    /// this is a prototype surface, so failures are stated plainly rather than
    /// swallowed.
    @Published private(set) var status: String = ""

    /// The busy-state machine. Replaces v2's `isBusy` Bool — see
    /// `MemeGenerationState` for why the stuck-spinner bug was structural.
    @Published private(set) var state = MemeGenerationState()

    /// The editable caption boxes. This is the SINGLE source of truth for what the
    /// meme says and where — the AI seeds it, the editor mutates it, and both the
    /// preview and the export render from it (WYSIWYG).
    @Published var boxes: [MemeCaptionLayout.CaptionBox] = []

    /// The box the editor's side panel is editing, if any.
    @Published var selectedBoxID: UUID?

    /// The ranked template candidates the model proposed, best first.
    @Published private(set) var candidates: [MemeTemplate] = []

    /// The template currently rendered.
    @Published private(set) var selectedTemplate: MemeTemplate?

    /// The whole merged catalog, for Browse.
    @Published private(set) var catalog: [MemeTemplate] = []

    /// True when the model named only templates that don't exist in the corpus and we
    /// fell back. Drives the honest "not in this corpus" warning.
    @Published private(set) var didFallBack: Bool = false

    /// True when the CURRENT candidate strip is a fallback list rather than the
    /// model's own picks.
    @Published private(set) var candidatesAreFallback: Bool = false

    /// The user's Browse search text. Filtering is local and pure.
    @Published var searchText: String = ""

    /// Set when the catalog couldn't be loaded AND nothing was cached — the only case
    /// where the user must act. Drives the Retry affordance.
    @Published private(set) var catalogFailed: Bool = false

    /// Set when a TEMPLATE IMAGE failed to load. Drives its own Retry affordance
    /// (v4).
    ///
    /// Separate from `catalogFailed` because they fail independently and recover
    /// differently: a catalog failure retries the fetch, an image failure retries one
    /// template. v3 had no image-failure signal at all, so a failed download had
    /// nowhere to surface — which is half of why "Downloading…" looked like it hung
    /// rather than like it had failed.
    @Published private(set) var imageFailed: Bool = false

    /// The template whose image failed, so Retry knows what to re-fetch.
    @Published private(set) var failedTemplate: MemeTemplate?

    /// The templates matching `searchText`, across names AND keywords so a merged,
    /// multi-lingual corpus is actually findable.
    var searchResults: [MemeTemplate] {
        MemeTemplateCatalog.search(searchText, in: catalog)
    }

    var templateName: String { selectedTemplate?.name ?? "" }

    // MARK: - Derived UI state

    var isBusy: Bool { state.isGenerating }

    var canGenerate: Bool {
        state.canGenerate && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Why Generate is unavailable right now, for the button's tooltip and the status
    /// line. Nil when it is available.
    var generateBlockedReason: String? { state.generateBlockedReason() }

    /// Browse is available as soon as ANYTHING is loadable — including a user library
    /// with the network off.
    var canBrowse: Bool { !catalog.isEmpty }

    /// The user's own imported templates, for the library management UI.
    var userTemplates: [MemeTemplate] { catalog.filter { $0.source == .userLibrary } }

    // MARK: - Injected seams

    /// One LLM round-trip: (instruction, input, resolved model) -> output. Injected
    /// by the window controller, exactly like `ScratchpadModel.AICall`.
    typealias AICall = (
        _ instruction: String, _ input: String, _ resolved: SummaryModelResolver.Resolved
    ) async throws -> String

    private var aiCall: AICall?
    private var resolveAIModel: () -> SummaryModelResolver.Resolved = {
        .init(provider: "", model: "", endpoint: "")
    }
    /// Warms the LLM and REPORTS READINESS (v4).
    ///
    /// The completion carries whether the model can actually take a request — it is
    /// driven by llama-server's `/health` poll, not by a timer. v3's seam returned
    /// `Void`, which is precisely why this model had to guess how long to wait.
    /// Injected so the model stays AppState-free and the readiness is stubbable.
    typealias WarmCall = (
        _ resolved: SummaryModelResolver.Resolved, _ ready: @escaping (Bool) -> Void
    ) -> Void

    private var warmModel: WarmCall = { _, ready in ready(true) }

    func configureAI(
        call: @escaping AICall,
        resolveModel: @escaping () -> SummaryModelResolver.Resolved,
        warm: @escaping WarmCall = { _, ready in ready(true) }
    ) {
        aiCall = call
        resolveAIModel = resolveModel
        warmModel = warm
    }

    /// Downloaded template images, keyed by template id, so clicking back and forth
    /// between candidates doesn't re-download.
    private var imageCache: [String: NSImage] = [:]

    /// The base image of the currently selected template — kept so an editor tweak
    /// re-renders instantly without a network round-trip.
    private var baseImage: NSImage?

    /// True once the window is gone — stops a late async result touching the UI.
    private var isCancelled = false

    // MARK: - Window lifecycle

    /// Everything that must happen when the window OPENS, so the first Generate is
    /// never the thing that pays for a cold start.
    ///
    /// Both halves of the owner's report #2 are addressed here: the LLM is warmed, and
    /// the catalog is opened from disk immediately (refreshing behind the UI when
    /// stale). Neither blocks the user — they can browse and edit while both run.
    func windowDidOpen() {
        isCancelled = false
        // v4: a reopened window must never INHERIT a phase. `cancel()` on close bumps
        // the ticket and returns to idle, but any exit path that failed to finish left
        // the machine parked — and clearing `isCancelled` here is what used to revive
        // a stranded `.downloading` with no task, no timeout, and no Retry behind it.
        // Resetting is cheap and makes the window's initial state unconditional.
        state.reset()
        imageFailed = false
        failedTemplate = nil
        status = ""
        warmLLM()
        openCatalog()
    }

    /// Start the local model loading, and hold "Preparing model…" until it is REALLY
    /// ready.
    ///
    /// ## v4 — readiness, not a stopwatch
    ///
    /// v3 showed the warming phase for a guessed 2.5 seconds and then allowed Generate
    /// regardless. That is why the owner still saw the first TWO generates fail with a
    /// raw network error: on a cold start llama-server needs far longer than 2.5s to
    /// bind its port, so the guess expired while the socket was still refusing
    /// connections, and the UI cheerfully fired into it.
    ///
    /// The readiness signal existed all along and was being discarded:
    /// `LlamaServerEngine.ensureRunning` polls the server's `/health` endpoint and
    /// calls back only when it answers. `AppState.warmLlamaServerIfPossible` dropped
    /// that completion (`{ _ in }`); it now forwards it, and the `warm` seam carries it
    /// here. So the warming phase ends when the model can actually take a request —
    /// immediately on a warm server, a minute later on a cold one, and never on a
    /// guess.
    ///
    /// A warm that FAILS is stated rather than hidden, because the alternative is the
    /// original bug in a new costume: an available-looking Generate button in front of
    /// a model that isn't there.
    private func warmLLM() {
        let resolved = resolveAIModel()
        guard ScratchpadAIModel.isUsable(resolved) else { return }

        let ticket = state.begin(.warming)
        status = MemeGenerationState.Phase.warming.statusText

        // A ceiling on the warm itself: a server that never becomes healthy must not
        // leave Generate blocked behind "Preparing model…" forever — that would be the
        // stuck-state bug moved into the warm path. On expiry we simply stop blocking;
        // the request's own retry (`MemeGenerateRetry`) becomes the safety net.
        startTimeout(ticket: ticket,
                     after: Self.warmTimeout,
                     message: "The model is taking a while to start — Generate will try anyway.")

        warmModel(resolved) { [weak self] ready in
            guard let self, !self.isCancelled else { return }
            guard self.state.finish(ticket: ticket) else { return }
            // Only clear a status we ourselves wrote; anything newer wins.
            if ready {
                if self.status == MemeGenerationState.Phase.warming.statusText { self.status = "" }
            } else {
                self.status = "The built-in model isn't available — check Settings → Cleanup."
            }
        }
    }

    /// How long the warm may block Generate before it gives up and lets the request
    /// try on its own.
    private static let warmTimeout: TimeInterval = 180

    // MARK: - Catalog

    /// Open the catalog: disk cache first, network second.
    ///
    /// This is what makes browsing instant and the plugin usable offline. The cache is
    /// authoritative for what the user SEES immediately; the network only ever
    /// upgrades it. A refresh that fails while templates are on screen is silent —
    /// reporting it would make a working plugin look broken.
    func openCatalog(forceRefresh: Bool = false) {
        let cached = MemeLibraryStore.loadCachedCatalog()
        let library = MemeLibraryStore.libraryTemplates()
        let decision = forceRefresh
            ? MemeCatalogCache.Decision.fetchNow
            : MemeCatalogCache.decide(cached: cached, now: Date())

        // Show whatever we already have RIGHT NOW, before any network work.
        if let cached, decision != .fetchNow {
            catalog = MemeTemplateCatalog.merge([library, cached.templates])
            catalogFailed = false
        } else if !library.isEmpty {
            // Offline with an empty cache but a populated library: still a usable
            // corpus, and the whole point of letting people import their own.
            catalog = library
        }

        guard decision != .useCache else {
            if status.isEmpty { status = MemeCatalogCache.summary(catalog) }
            return
        }
        refreshCatalog(showProgress: catalog.isEmpty)
    }

    /// Fetch the remote catalogs and merge them in.
    ///
    /// `showProgress` distinguishes the two callers, and with them the TICKET
    /// OWNERSHIP — the distinction the v2 stuck-state bug came from getting muddled:
    ///
    /// * **Blocking** (nothing on screen yet) — takes its own ticket, shows a phase,
    ///   and must clear it on every exit path.
    /// * **Background refresh** (a cached catalog is already visible) — owns NO
    ///   ticket and never touches the phase. It is invisible by design: the user is
    ///   already browsing, and a background refresh must not be able to disturb, or
    ///   worse un-stick, whatever they are doing in the meantime.
    private func refreshCatalog(showProgress: Bool) {
        let ticket: Int? = showProgress ? state.begin(.loadingCatalog) : nil
        if showProgress { status = MemeGenerationState.Phase.loadingCatalog.statusText }

        Task { [weak self] in
            guard let self else { return }
            let library = MemeLibraryStore.libraryTemplates()
            do {
                let merged = try await MemeTemplateService.fetchMergedCatalog(
                    userTemplates: library)
                guard !self.isCancelled else { return }

                self.catalog = merged
                self.catalogFailed = false
                MemeLibraryStore.saveCachedCatalog(merged)

                if let ticket {
                    if self.state.finish(ticket: ticket) {
                        self.status = MemeCatalogCache.summary(merged)
                    }
                } else if self.status.isEmpty {
                    self.status = MemeCatalogCache.summary(merged)
                }
            } catch {
                guard !self.isCancelled else { return }
                // With templates already on screen this is a non-event — the cache is
                // doing exactly its job.
                let message = MemeCatalogCache.refreshFailureMessage(
                    hasCachedTemplates: !self.catalog.isEmpty,
                    reason: MemeTemplateService.reason(error))
                if let ticket { self.state.finish(ticket: ticket) }
                if let message {
                    self.catalogFailed = true
                    self.status = message
                }
            }
        }
    }

    /// Re-read the user library and merge it into the live catalog, without a fetch.
    ///
    /// Called after every import/delete so the grid updates instantly — an import
    /// that required a network round-trip to become visible would be absurd.
    func reloadUserLibrary() {
        let library = MemeLibraryStore.libraryTemplates()
        let remote = catalog.filter { $0.source != .userLibrary }
        catalog = MemeTemplateCatalog.merge([library, remote])
        catalogFailed = catalog.isEmpty
    }

    // MARK: - Dictation

    /// Append dictated text to the description, matching the Scratchpad's join rule.
    func appendDictation(_ text: String) {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            description = incoming
        } else {
            description += " " + incoming
        }
        status = ""
    }

    // MARK: - Generate

    func generate() {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Honest wait instead of a failed request: the v2 report was a Generate fired
        // at a model that hadn't finished loading.
        if let blocked = state.generateBlockedReason() {
            status = blocked
            return
        }
        guard let aiCall else {
            status = "No LLM is configured — set one up in Settings → Cleanup."
            return
        }

        // Fail closed BEFORE the request: an agent-CLI resolution would otherwise
        // fall through to a cloud endpoint the user never chose (the MAK-53 hazard
        // ScratchpadModel guards the same way).
        let resolved = resolveAIModel()
        guard ScratchpadAIModel.isUsable(resolved) else {
            status = ScratchpadAIModel.unusableProviderMessage
            return
        }

        let ticket = state.begin(.loadingCatalog)
        status = MemeGenerationState.Phase.loadingCatalog.statusText
        startTimeout(ticket: ticket)

        Task { [weak self] in
            guard let self else { return }

            // The catalog must exist before we can ask — the prompt carries the real
            // template names. Normally it is already warm from window open.
            guard await self.ensureCatalogForGenerate(ticket: ticket) else { return }
            guard !self.isCancelled, self.state.accepts(ticket: ticket) else { return }

            self.state.advance(.asking, ticket: ticket)
            self.status = MemeGenerationState.Phase.asking.statusText

            // v4: shortlist LOCALLY before asking. Scoring the user's own words
            // against the whole merged corpus (name AND keywords) is what lets a
            // description of the meme's CONTENT reach a template whose name shares no
            // words with it — and it guarantees the relevant template is in the
            // prompt at all, rather than truncated off the end of a popularity list.
            let shortlist = MemeTemplateCatalog.prefilter(
                for: self.description, in: self.catalog, limit: MemeAI.candidateShortlist)
            // The model is shown names + keywords, but validated against NAMES —
            // `promptLines` keeps the name first and unadorned precisely so the two
            // stay in sync.
            let names = MemeTemplateCatalog.promptNames(shortlist, limit: shortlist.count)
            let lines = MemeTemplateCatalog.promptLines(shortlist, limit: shortlist.count)
            let payload = MemeAI.rankedUserPayload(
                description: self.description, templateNames: lines,
                limit: MemeAI.candidateShortlist)

            do {
                let raw = try await self.askWithRetry(
                    aiCall, payload: payload, resolved: resolved, ticket: ticket)
                guard !self.isCancelled, self.state.accepts(ticket: ticket) else { return }

                switch MemeAI.parseRanked(raw, catalogNames: names) {
                case .failure(let rejection):
                    self.finish(ticket, status: "Couldn't build the meme — \(rejection.reason).")
                case .success(let spec):
                    await self.applyRanked(spec, ticket: ticket)
                }
            } catch {
                guard !self.isCancelled, self.state.accepts(ticket: ticket) else { return }
                self.finish(ticket, status: "The model request failed — \(Self.reason(error))")
            }
        }
    }

    /// Run the LLM round-trip, retrying while the failure is "the server isn't
    /// accepting connections yet" (v4).
    ///
    /// This is the second line of defence behind the readiness gate. Readiness covers
    /// the cold start; this covers the gap readiness cannot see — llama-server can
    /// pass a health check and still refuse the very next connection when it is
    /// mid-restart (idle teardown, a model swap). Without it that shows up as the raw
    /// "network error" the owner reported.
    ///
    /// The decision of WHETHER to retry lives in `MemeGenerateRetry` so it is pinned
    /// by `swift test`; only the sleeping and the status writing happen here. A
    /// non-transport failure (a real model error) is rethrown on the first attempt —
    /// retrying it would just make the user wait longer for the same message.
    private func askWithRetry(
        _ aiCall: AICall, payload: String,
        resolved: SummaryModelResolver.Resolved, ticket: Int
    ) async throws -> String {
        var attempt = 1
        while true {
            do {
                return try await aiCall(MemeAI.rankedPrompt, payload, resolved)
            } catch {
                guard MemeGenerateRetry.shouldRetry(error, attempt: attempt) else { throw error }
                // A superseded or cancelled request must not keep retrying in the
                // background — rethrow and let the caller's guards drop it.
                guard !isCancelled, state.accepts(ticket: ticket) else { throw error }

                attempt += 1
                status = MemeGenerateRetry.retryingMessage(attempt: attempt)
                let delay = MemeGenerateRetry.delay(beforeAttempt: attempt)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !isCancelled, state.accepts(ticket: ticket) else { throw error }
                status = MemeGenerationState.Phase.asking.statusText
            }
        }
    }

    /// A hard ceiling on one generate.
    ///
    /// v2 had none: an LLM call that never returned left the surface busy forever with
    /// no way back but closing the window. `finish` is ticket-guarded and idempotent,
    /// so this fires harmlessly when the work already completed.
    private func startTimeout(
        ticket: Int,
        after seconds: TimeInterval = MemeGenerationState.generateTimeout,
        message: String = MemeGenerationState.timeoutMessage
    ) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !self.isCancelled else { return }
            if self.state.finish(ticket: ticket) {
                self.status = message
            }
        }
    }

    /// Cancel whatever is in flight. The user's escape hatch from a slow model.
    func cancelGeneration() {
        guard state.isGenerating else { return }
        state.cancel()
        status = "Cancelled."
    }

    /// Make sure there is a catalog to prompt with. Returns false when it failed and
    /// has already reported why.
    private func ensureCatalogForGenerate(ticket: Int) async -> Bool {
        guard catalog.isEmpty else { return true }

        let library = MemeLibraryStore.libraryTemplates()
        do {
            let merged = try await MemeTemplateService.fetchMergedCatalog(userTemplates: library)
            guard !isCancelled, state.accepts(ticket: ticket) else { return false }
            catalog = merged
            catalogFailed = false
            MemeLibraryStore.saveCachedCatalog(merged)
            return true
        } catch {
            guard !isCancelled, state.accepts(ticket: ticket) else { return false }
            catalogFailed = true
            finish(ticket, status:
                "Couldn't load meme templates — \(MemeTemplateService.reason(error)) "
                + "Press Retry, or import your own template to work offline.")
            return false
        }
    }

    /// Turn a validated ranked spec into candidates + a rendered best guess.
    private func applyRanked(_ spec: MemeAI.RankedSpec, ticket: Int) async {
        var picks = spec.templateNames.compactMap { name in
            catalog.first { $0.name == name }
        }

        didFallBack = picks.isEmpty
        candidatesAreFallback = picks.isEmpty
        if picks.isEmpty {
            // Nothing the model named exists in the corpus. Still render something —
            // the user asked for a meme — but ONLY alongside a visible candidate strip
            // and Browse, so the substitution is obvious rather than silent.
            let lexical = MemeTemplateMatcher.ranked(
                for: description, in: catalog, limit: MemeAI.maxCandidates)
            let popular = catalog.prefix(MemeAI.maxCandidates)
            picks = lexical + popular.filter { candidate in
                !lexical.contains { $0.id == candidate.id }
            }
            picks = Array(picks.prefix(MemeAI.maxCandidates))
        }

        candidates = picks
        boxes = MemeCaptionLayout.seedBoxes(topText: spec.topText, bottomText: spec.bottomText)
        selectedBoxID = boxes.first?.id

        guard let best = picks.first else {
            finish(ticket, status: "There are no templates to choose from — import one to get started.")
            return
        }

        await renderTemplate(best, ticket: ticket, isNewGeneration: true)
    }

    // MARK: - Template selection

    /// Re-render the current captions onto another template.
    ///
    /// **Never blocked by a generation in flight** (feedback #3). Switching templates
    /// re-renders the same boxes onto an image that is cached or one GET away — no
    /// LLM round-trip — so gating it on the busy flag was pure reflex, and it is what
    /// turned a stuck flag into a frozen window.
    ///
    /// It runs on its OWN ticket, so picking a template while the model is thinking
    /// supersedes the generation rather than racing it: the user's explicit choice
    /// wins over the machine's pending guess.
    func select(template: MemeTemplate) {
        guard template.id != selectedTemplate?.id else { return }

        // Seed boxes if the user picked a template before ever generating.
        if boxes.isEmpty {
            boxes = MemeCaptionLayout.seedBoxes(topText: "", bottomText: "")
            selectedBoxID = boxes.first?.id
        }

        // The user has now chosen deliberately, so this is no longer a fallback.
        didFallBack = false

        let ticket = state.begin(.downloading(templateName: template.name))
        // v4: an image download gets the SAME hard ceiling a generate does. v3 started
        // this ticket with no timeout at all, so a download that never came back left
        // "Downloading <name>…" on screen forever — the owner's report #2.
        startTimeout(ticket: ticket,
                     after: MemeGenerationState.downloadTimeout,
                     message: MemeGenerationState.downloadTimeoutMessage(template.name))
        Task { [weak self] in
            await self?.renderTemplate(template, ticket: ticket, isNewGeneration: false)
        }
    }

    /// Re-run the last template load that failed. The Retry affordance's action.
    func retryTemplate() {
        guard let template = failedTemplate else { return }
        // Clear it first: `select` early-returns when the template is already
        // selected, and a stale failure must not survive a successful retry.
        failedTemplate = nil
        imageFailed = false
        // The failed template is NOT the selected one (the load never completed), so
        // `select` will proceed — but drop any cached corpse just in case.
        imageCache[template.id] = nil
        select(template: template)
    }

    /// Load a template's image (cached, from disk or network) and render the boxes.
    ///
    /// ## v4 — every exit clears the phase
    ///
    /// The owner's "Downloading <name> forever" was caused by the two BARE `return`s
    /// this function used to have: a superseded/cancelled ticket returned without ever
    /// touching the state machine. That is only safe if some other task owns the
    /// phase, which is exactly the assumption v3's own doc comment identified as the
    /// bug class — and it is false in the ordering the owner hit: closing the window
    /// (`cancel()` sets `isCancelled`) and reopening it (`windowDidOpen` resets
    /// `isCancelled = false`) left the machine parked in `.downloading` with no
    /// in-flight task left to clear it, no timeout, and no Retry.
    ///
    /// Now every path — cache hit, fetch failure, decode failure, stale ticket,
    /// cancellation — ends at a `finish` for its OWN ticket. `finish` is
    /// ticket-guarded and idempotent, so finishing a superseded ticket is a harmless
    /// no-op that cannot disturb newer work; what it CANNOT do any more is leave the
    /// phase set with nobody responsible for it.
    private func renderTemplate(
        _ template: MemeTemplate, ticket: Int, isNewGeneration: Bool
    ) async {
        let image: NSImage
        if let cached = imageCache[template.id] {
            image = cached
        } else {
            state.advance(.downloading(templateName: template.name), ticket: ticket)
            status = MemeGenerationState.Phase.downloading(templateName: template.name).statusText
            do {
                image = try await MemeTemplateService.fetchImage(template)
            } catch {
                // Honest error + a way out, for EVERY failure the fetch can produce:
                // transport, non-2xx, an undecodable image, and the timeout.
                noteImageFailure(template, ticket: ticket, error: error)
                return
            }
            guard !isCancelled, state.accepts(ticket: ticket) else {
                finish(ticket, status: status)
                return
            }
            imageCache[template.id] = image
            MemeLibraryStore.storeThumbnail(image, for: template.id)
        }
        guard !isCancelled, state.accepts(ticket: ticket) else {
            finish(ticket, status: status)
            return
        }

        baseImage = image
        selectedTemplate = template
        imageFailed = false
        failedTemplate = nil
        redraw()

        finish(ticket, status: statusLine(isNewGeneration: isNewGeneration))
    }

    /// Record a template-image failure: clear the phase, say what happened, and offer
    /// Retry. One funnel so no image failure can reach the UI without all three.
    private func noteImageFailure(_ template: MemeTemplate, ticket: Int, error: Error) {
        guard state.accepts(ticket: ticket) else {
            // Superseded — still end our own ticket rather than returning bare.
            finish(ticket, status: status)
            return
        }
        failedTemplate = template
        imageFailed = true
        finish(ticket, status:
            "Couldn't load \(template.name) — \(Self.reason(error)) Press Retry, or pick another template.")
    }

    /// The line under the controls: honest about a fallback, quiet otherwise.
    private func statusLine(isNewGeneration: Bool) -> String {
        guard let selectedTemplate else { return "" }
        if didFallBack, isNewGeneration {
            return "Nothing in the corpus matched your description. Showing "
                + "\(selectedTemplate.name) — pick another below, Browse all "
                + "\(catalog.count) templates, or import your own."
        }
        return "Used \(selectedTemplate.name). Drag the captions to reposition them."
    }

    // MARK: - Manual editor

    /// Re-render the current boxes onto the current template.
    ///
    /// Local CoreGraphics onto an already-loaded image, so this is cheap enough to run
    /// per keystroke and per drag frame — no debounce, and the preview is therefore
    /// literally the export.
    func redraw() {
        guard let baseImage else { return }
        meme = MemeRenderer.render(template: baseImage, boxes: boxes)
    }

    /// Mutate one box and re-render. The single funnel for every editor edit.
    func updateBox(id: UUID, _ mutate: (inout MemeCaptionLayout.CaptionBox) -> Void) {
        guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        var box = boxes[index]
        mutate(&box)
        boxes[index] = MemeCaptionLayout.clamped(box)
        redraw()
    }

    /// Add an empty caption box, placed so it doesn't land on the previous one.
    ///
    /// **Always available** (feedback #4). v2 only rendered the editor panel when
    /// `boxes` was non-empty, so deleting the last box deleted the only Add button
    /// with it — a dead end with no way back except regenerating.
    func addBox() {
        let center = MemeCaptionLayout.newBoxCenter(existingCount: boxes.count)
        let box = MemeCaptionLayout.CaptionBox(
            text: "New text", centerX: center.x, centerY: center.y)
        boxes.append(box)
        selectedBoxID = box.id
        redraw()
    }

    func deleteBox(id: UUID) {
        boxes.removeAll { $0.id == id }
        if selectedBoxID == id { selectedBoxID = boxes.first?.id }
        redraw()
    }

    var selectedBox: MemeCaptionLayout.CaptionBox? {
        guard let selectedBoxID else { return nil }
        return boxes.first { $0.id == selectedBoxID }
    }

    // MARK: - User library

    /// Import image files as templates, then show the first one.
    ///
    /// Returns how many were imported so the caller can report a partial failure —
    /// dropping five files and silently getting four templates would be the kind of
    /// quiet data loss this spike keeps trying to eliminate.
    @discardableResult
    func importTemplates(from urls: [URL]) -> Int {
        var imported: MemeUserLibrary.Entry?
        var count = 0
        for url in urls {
            if let entry = MemeLibraryStore.importImage(at: url) {
                imported = imported ?? entry
                count += 1
            }
        }
        reloadUserLibrary()

        if count == 0 {
            status = "Couldn't import — pick a PNG, JPEG, GIF, WebP, or HEIC image."
        } else {
            status = count == urls.count
                ? "Imported \(count) template\(count == 1 ? "" : "s")."
                : "Imported \(count) of \(urls.count) — the rest weren't readable images."
            if let imported, let template = catalog.first(where: {
                $0.id == MemeTemplateCatalog.qualifiedID(.userLibrary, imported.id)
            }) {
                select(template: template)
            }
        }
        return count
    }

    /// Import an image straight from the pasteboard (⌘V into the Browse grid).
    @discardableResult
    func importFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general

        // A file URL on the pasteboard is preferred over raw image data: it keeps the
        // original filename, which becomes the template's name and a search keyword.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty,
           urls.contains(where: { MemeUserLibrary.isAcceptedImage(fileName: $0.lastPathComponent) }) {
            return importTemplates(from: urls) > 0
        }

        guard let image = NSImage(pasteboard: pasteboard) else {
            status = "Nothing on the clipboard to import."
            return false
        }
        let name = MemeUserLibrary.uniqueName(
            "Pasted template", existing: userTemplates.map(\.name))
        guard let entry = MemeLibraryStore.importImage(image, name: name) else {
            status = "Couldn't import the pasted image."
            return false
        }
        reloadUserLibrary()
        status = "Imported \(entry.name)."
        if let template = catalog.first(where: {
            $0.id == MemeTemplateCatalog.qualifiedID(.userLibrary, entry.id)
        }) {
            select(template: template)
        }
        return true
    }

    /// Delete a user-library template.
    func deleteUserTemplate(_ template: MemeTemplate) {
        guard template.source == .userLibrary,
              let separator = template.id.firstIndex(of: ":") else { return }
        let rawID = String(template.id[template.id.index(after: separator)...])

        MemeLibraryStore.remove(id: rawID)
        imageCache[template.id] = nil
        reloadUserLibrary()

        // Deleting the template that is on screen must not leave a meme rendered from
        // a template the user just removed.
        if selectedTemplate?.id == template.id {
            selectedTemplate = nil
            baseImage = nil
            meme = nil
        }
        candidates.removeAll { $0.id == template.id }
        status = "Deleted \(template.name)."
    }

    func renameUserTemplate(_ template: MemeTemplate, to newName: String) {
        guard template.source == .userLibrary,
              let separator = template.id.firstIndex(of: ":"),
              !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let rawID = String(template.id[template.id.index(after: separator)...])

        MemeLibraryStore.rename(id: rawID, to: newName)
        reloadUserLibrary()
        if selectedTemplate?.id == template.id {
            selectedTemplate = catalog.first { $0.id == template.id }
        }
    }

    // MARK: - Lifecycle

    private func finish(_ ticket: Int, status newStatus: String) {
        guard state.finish(ticket: ticket) else { return }
        status = newStatus
    }

    private static func reason(_ error: Error) -> String {
        if let wire = error as? BridgeWire.ErrorObject, !wire.message.isEmpty {
            return wire.message
        }
        let described = (error as NSError).localizedDescription
        return described.isEmpty ? "the request failed." : described
    }

    /// Stop accepting async results — called when the window closes.
    func cancel() {
        isCancelled = true
        state.cancel()
    }

    // MARK: - Export / share

    /// The filename an export should suggest — driven by the EDITED boxes.
    var suggestedFileName: String {
        MemeCaptionLayout.suggestedFileName(boxes: boxes)
    }

    /// Write the meme to a user-chosen file. Returns whether anything was written.
    @discardableResult
    func exportPNG() -> Bool {
        guard let meme, let data = MemeRenderer.pngData(for: meme) else {
            status = "Nothing to export yet."
            return false
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url)
            status = "Saved to \(url.lastPathComponent)."
            return true
        } catch {
            status = "Couldn't save — \(error.localizedDescription)"
            return false
        }
    }
}
