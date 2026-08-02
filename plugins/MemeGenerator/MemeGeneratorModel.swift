import AppKit
import SwiftUI

/// The observable state behind the Meme Generator window (spike).
///
/// The pipeline, end to end:
///
/// 1. The user DICTATES a description (or types it) into `description`.
/// 2. The imgflip template catalog is fetched (once per session, then cached).
/// 3. `generate()` sends the description **plus the catalog's actual template names**
///    to the configured LLM via the injected `aiCall` seam — the same
///    closure-injection `ScratchpadModel` uses, so this model never touches AppState
///    and stays stubbable.
/// 4. The reply is parsed by the pure `MemeAI.parseRanked`, which keeps only names
///    that really exist in the catalog. The result is a RANKED candidate list.
/// 5. The best candidate auto-renders; the rest sit in a thumbnail strip. The user
///    can click another candidate, or open "Browse all" and pick any of the 100.
/// 6. The chosen template is downloaded and captioned LOCALLY by `MemeRenderer` from
///    the caption BOX model, which the manual editor then mutates.
///
/// Only steps 2 and 6 touch the network, and only to GET images — no user text is
/// ever sent to imgflip.
///
/// ## v2 — why candidates
///
/// v1 asked the model for a free-text template name and lexically matched it. "yoda
/// meme" scored below threshold and silently rendered onto Drake. v2 constrains the
/// model to the real corpus and, when nothing fits, SAYS SO — the fallback still
/// happens (a meme is better than an error) but never without the candidate strip and
/// Browse-all visible, so the user immediately sees it was a guess.
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

    /// True while a generate round-trip is in flight (disables the button).
    @Published private(set) var isBusy: Bool = false

    /// The editable caption boxes. This is the SINGLE source of truth for what the
    /// meme says and where — the AI seeds it, the editor mutates it, and both the
    /// preview and the export render from it (WYSIWYG).
    @Published var boxes: [MemeCaptionLayout.CaptionBox] = []

    /// The box the editor's side panel is editing, if any.
    @Published var selectedBoxID: UUID?

    /// The ranked template candidates the model proposed, best first. Empty until a
    /// generate has run.
    @Published private(set) var candidates: [MemeTemplate] = []

    /// The template currently rendered.
    @Published private(set) var selectedTemplate: MemeTemplate?

    /// The whole catalog, for "Browse all". Empty until fetched.
    @Published private(set) var catalog: [MemeTemplate] = []

    /// True when the model named only templates that don't exist in the corpus and we
    /// fell back. Drives the honest "not in this corpus" warning — the candidate strip
    /// and Browse all stay visible so the fallback is never silent. Cleared once the
    /// user picks a template themselves; the choice is theirs from then on.
    @Published private(set) var didFallBack: Bool = false

    /// True when the CURRENT candidate strip is a fallback list rather than the
    /// model's own picks. Unlike `didFallBack` this describes the strip's contents, so
    /// it survives the user selecting a template and the strip's label stays accurate.
    @Published private(set) var candidatesAreFallback: Bool = false

    /// The user's Browse-all search text. Filtering is local and pure.
    @Published var searchText: String = ""

    /// The templates matching `searchText`, in popularity order.
    var searchResults: [MemeTemplate] {
        MemeTemplateMatcher.search(searchText, in: catalog)
    }

    /// The template name shown in the "used X" line.
    var templateName: String { selectedTemplate?.name ?? "" }

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

    func configureAI(
        call: @escaping AICall,
        resolveModel: @escaping () -> SummaryModelResolver.Resolved
    ) {
        aiCall = call
        resolveAIModel = resolveModel
    }

    /// Downloaded template images, keyed by template id, so clicking back and forth
    /// between candidates doesn't re-download.
    private var imageCache: [String: NSImage] = [:]

    /// The base image of the currently selected template — kept so an editor tweak
    /// re-renders instantly without a network round-trip.
    private var baseImage: NSImage?

    /// Monotonic ticket so a late result from a superseded request can't overwrite a
    /// newer meme (the `ScratchpadAISession` fence, simplified for one surface).
    private var ticket: Int = 0

    /// True once the window is gone — stops a late async result touching the UI.
    private var isCancelled = false

    // MARK: - Dictation

    /// Append dictated text to the description, matching the Scratchpad's join rule
    /// (a space between the existing text and the new words).
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

    var canGenerate: Bool {
        !isBusy && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True once there is something to browse — gates the "Browse all" affordance.
    var canBrowse: Bool { !catalog.isEmpty }

    // MARK: - Generate

    func generate() {
        guard canGenerate else { return }
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

        ticket += 1
        let myTicket = ticket
        isBusy = true

        Task { [weak self] in
            guard let self else { return }

            // The catalog is fetched BEFORE the LLM call now — v2 puts the real
            // template names in the prompt, so we can't ask until we have them.
            guard await self.ensureCatalog(ticket: myTicket) else { return }
            guard !self.isCancelled, myTicket == self.ticket else { return }

            self.status = "Asking the model…"
            let names = self.catalog.map(\.name)
            let payload = MemeAI.rankedUserPayload(
                description: self.description, templateNames: names)

            do {
                let raw = try await aiCall(MemeAI.rankedPrompt, payload, resolved)
                guard !self.isCancelled, myTicket == self.ticket else { return }

                switch MemeAI.parseRanked(raw, catalogNames: names) {
                case .failure(let rejection):
                    self.finish(myTicket, status: "Couldn't build the meme — \(rejection.reason).")
                case .success(let spec):
                    await self.applyRanked(spec, ticket: myTicket)
                }
            } catch {
                guard !self.isCancelled, myTicket == self.ticket else { return }
                self.finish(myTicket, status: "The model request failed — \(Self.reason(error))")
            }
        }
    }

    /// Fetch the catalog once per session. Returns false when it failed (and has
    /// already reported why).
    private func ensureCatalog(ticket myTicket: Int) async -> Bool {
        guard catalog.isEmpty else { return true }

        status = "Loading templates…"
        do {
            let fetched = try await MemeTemplateService.fetchCatalog()
            guard !isCancelled, myTicket == ticket else { return false }
            catalog = fetched
            return true
        } catch {
            finish(myTicket, status:
                "Couldn't reach imgflip.com for templates — \(Self.reason(error)) "
                + "The meme generator needs a connection to fetch template images.")
            return false
        }
    }

    /// Turn a validated ranked spec into candidates + a rendered best guess.
    private func applyRanked(_ spec: MemeAI.RankedSpec, ticket myTicket: Int) async {
        // Resolve names back to templates. `parseRanked` guarantees every name is in
        // the catalog, so a nil here would be a bug rather than model noise.
        var picks = spec.templateNames.compactMap { name in
            catalog.first { $0.name == name }
        }

        didFallBack = picks.isEmpty
        candidatesAreFallback = picks.isEmpty
        if picks.isEmpty {
            // Nothing the model named exists in the corpus. Still render something —
            // the user asked for a meme — but ONLY alongside a visible candidate strip
            // and Browse all, so the substitution is obvious rather than silent. That
            // is the whole fix for the "yoda → Drake with no explanation" report.
            //
            // Rank by the user's OWN words first: if the description happens to
            // mention something that is in the catalog, that beats blind popularity.
            // Popularity is the last resort, and only to fill the strip.
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
            finish(myTicket, status: "imgflip returned no templates to choose from.")
            return
        }

        await renderTemplate(best, ticket: myTicket, isNewGeneration: true)
    }

    // MARK: - Template selection

    /// Re-render the current captions onto another template.
    ///
    /// The captions carry over unchanged — that is the point of the candidate strip
    /// and of normalized box geometry: switching templates is a *presentation* choice,
    /// not a reason to lose the user's text or their box positions.
    func select(template: MemeTemplate) {
        guard !isBusy else { return }
        guard template.id != selectedTemplate?.id else { return }

        // Seed boxes if the user picked a template before ever generating (Browse all
        // is reachable as soon as the catalog is loaded).
        if boxes.isEmpty {
            boxes = MemeCaptionLayout.seedBoxes(topText: "", bottomText: "")
            selectedBoxID = boxes.first?.id
        }

        // The user has now chosen deliberately, so this is no longer a fallback —
        // leaving the warning up would be nagging about a decision they just made.
        didFallBack = false

        ticket += 1
        let myTicket = ticket
        isBusy = true
        Task { [weak self] in
            await self?.renderTemplate(template, ticket: myTicket, isNewGeneration: false)
        }
    }

    /// Load a template's image (cached) and render the current boxes onto it.
    private func renderTemplate(
        _ template: MemeTemplate, ticket myTicket: Int, isNewGeneration: Bool
    ) async {
        let image: NSImage
        if let cached = imageCache[template.id] {
            image = cached
        } else {
            status = "Downloading \(template.name)…"
            do {
                image = try await MemeTemplateService.fetchImage(template)
            } catch {
                finish(myTicket, status:
                    "Couldn't download the template image — \(Self.reason(error))")
                return
            }
            guard !isCancelled, myTicket == ticket else { return }
            imageCache[template.id] = image
        }
        guard !isCancelled, myTicket == ticket else { return }

        baseImage = image
        selectedTemplate = template
        redraw()

        finish(myTicket, status: statusLine(isNewGeneration: isNewGeneration))
    }

    /// The line under the controls: honest about a fallback, quiet otherwise.
    private func statusLine(isNewGeneration: Bool) -> String {
        guard let selectedTemplate else { return "" }
        if didFallBack, isNewGeneration {
            return "Nothing in the corpus matched — this is imgflip's top 100, and your "
                + "meme isn't one of them. Showing \(selectedTemplate.name); pick another "
                + "below or Browse all."
        }
        return "Used \(selectedTemplate.name). Drag the captions to reposition them."
    }

    // MARK: - Manual editor

    /// Re-render the current boxes onto the current template.
    ///
    /// Called on every editor mutation. Rendering is local CoreGraphics onto an
    /// already-downloaded image, so this is cheap enough to run per keystroke and per
    /// drag frame — no debounce, and the preview is therefore literally the export.
    func redraw() {
        guard let baseImage else { return }
        meme = MemeRenderer.render(template: baseImage, boxes: boxes)
    }

    /// Mutate one box and re-render. The single funnel for every editor edit, so
    /// clamping and redrawing can't be forgotten at a call site.
    func updateBox(id: UUID, _ mutate: (inout MemeCaptionLayout.CaptionBox) -> Void) {
        guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        var box = boxes[index]
        mutate(&box)
        boxes[index] = MemeCaptionLayout.clamped(box)
        redraw()
    }

    /// Add an empty caption box, placed so it doesn't land on the previous one.
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

    /// The currently selected box, for the side panel's bindings.
    var selectedBox: MemeCaptionLayout.CaptionBox? {
        guard let selectedBoxID else { return nil }
        return boxes.first { $0.id == selectedBoxID }
    }

    // MARK: - Browse all

    /// Load the catalog so "Browse all" works before any generate has run.
    func loadCatalogIfNeeded() {
        guard catalog.isEmpty, !isBusy else { return }
        ticket += 1
        let myTicket = ticket
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            if await self.ensureCatalog(ticket: myTicket) {
                self.finish(myTicket, status: "Loaded \(self.catalog.count) templates.")
            }
        }
    }

    private func finish(_ myTicket: Int, status newStatus: String) {
        guard myTicket == ticket else { return }
        isBusy = false
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
        isBusy = false
    }

    // MARK: - Export / share

    /// The filename an export should suggest — driven by the EDITED boxes, so a meme
    /// the user rewrote saves under what it actually says.
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
