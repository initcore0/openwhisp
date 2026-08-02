import AppKit
import SwiftUI

/// The observable state behind the Meme Generator window (spike).
///
/// The pipeline, end to end:
///
/// 1. The user DICTATES a description (or types it) into `description`.
/// 2. `generate()` sends it to the configured LLM via the injected `aiCall` seam —
///    the same closure-injection `ScratchpadModel` uses, so this model never touches
///    AppState and stays stubbable.
/// 3. The reply is parsed by the pure `MemeAI.parse` into a template query + captions.
/// 4. The imgflip template catalog is fetched (once per session, then cached) and the
///    query is matched locally by `MemeTemplateMatcher`.
/// 5. The template image is downloaded and captioned LOCALLY by `MemeRenderer`.
///
/// Only steps 4–5 touch the network, and only to GET images — no user text is ever
/// sent to imgflip.
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

    /// The captions of the current meme, surfaced so the user can see what the model
    /// wrote (and tell a bad caption from a bad template).
    @Published private(set) var topText: String = ""
    @Published private(set) var bottomText: String = ""

    /// The template that was chosen, for the "used X" line.
    @Published private(set) var templateName: String = ""

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

    /// The template catalog, fetched once and reused for the rest of the session.
    private var catalog: [MemeTemplate] = []

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
        status = "Asking the model…"
        let prompt = MemeAI.userPayload(description: description)

        Task { [weak self] in
            do {
                let raw = try await aiCall(MemeAI.prompt, prompt, resolved)
                guard let self, !self.isCancelled, myTicket == self.ticket else { return }

                switch MemeAI.parse(raw) {
                case .failure(let rejection):
                    self.finish(myTicket, status: "Couldn't build the meme — \(rejection.reason).")
                case .success(let spec):
                    await self.buildMeme(spec, ticket: myTicket)
                }
            } catch {
                guard let self, !self.isCancelled, myTicket == self.ticket else { return }
                self.finish(myTicket, status: "The model request failed — \(Self.reason(error))")
            }
        }
    }

    /// Fetch the catalog (if needed), match a template, download it, caption it.
    private func buildMeme(_ spec: MemeAI.MemeSpec, ticket myTicket: Int) async {
        status = "Finding a template…"

        if catalog.isEmpty {
            do {
                catalog = try await MemeTemplateService.fetchCatalog()
            } catch {
                finish(myTicket, status:
                    "Couldn't reach imgflip.com for templates — \(Self.reason(error)) "
                    + "The meme generator needs a connection to fetch template images.")
                return
            }
        }
        guard !isCancelled, myTicket == ticket else { return }

        guard let match = MemeTemplateMatcher.bestMatch(for: spec.templateQuery, in: catalog) else {
            finish(myTicket, status: "imgflip returned no templates to choose from.")
            return
        }

        status = "Downloading \(match.template.name)…"
        let template: NSImage
        do {
            template = try await MemeTemplateService.fetchImage(match.template)
        } catch {
            finish(myTicket, status: "Couldn't download the template image — \(Self.reason(error))")
            return
        }
        guard !isCancelled, myTicket == ticket else { return }

        let rendered = MemeRenderer.render(
            template: template, topText: spec.topText, bottomText: spec.bottomText)

        meme = rendered
        topText = spec.topText
        bottomText = spec.bottomText
        templateName = match.template.name

        // Say so when the template was a guess — a confidently-wrong pick the user
        // can't explain is worse than an admitted fallback.
        let note = match.isFallback
            ? "Couldn't match \"\(spec.templateQuery)\" — used the most popular template instead."
            : "Used \(match.template.name)."
        finish(myTicket, status: note)
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

    /// Write the meme to a user-chosen file. Returns whether anything was written.
    @discardableResult
    func exportPNG() -> Bool {
        guard let meme, let data = MemeRenderer.pngData(for: meme) else {
            status = "Nothing to export yet."
            return false
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = MemeCaptionLayout.suggestedFileName(
            topText: topText, bottomText: bottomText)
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
