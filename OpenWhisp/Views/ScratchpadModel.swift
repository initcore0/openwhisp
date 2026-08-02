import SwiftUI
import Combine

/// The observable state behind the Scratchpad's SwiftUI content (MAK-95/96/97).
///
/// The `ScratchpadWindowController` stays a thin AppKit shell (panel lifecycle +
/// the AppState-facing dictation seam); everything the UI binds to lives here, and
/// every non-trivial *rule* it applies lives in OpenWhispCore (`ScratchpadText`,
/// `ScratchpadPersistencePolicy`, `MarkdownPreviewRenderer`, `ScratchpadExport`,
/// `ScratchpadFilter`, `ScratchpadTags`) where `swift test` covers it.
///
/// ## Persistence (the MAK-95 perf fix)
///
/// The old panel wrote the WHOLE store — a synchronous atomic JSON encode of every
/// note's full body — on **every keystroke**. Here, body edits and dictation
/// appends schedule a coalescing timer whose fire hands a value-type snapshot to a
/// serial background queue; structural mutations (create/delete/meeting-insert)
/// still write immediately and cancel any pending timer, so a stale snapshot can
/// never land after a delete and resurrect the note. `flush()` runs on panel close
/// and on `NSApplication.willTerminateNotification`.
///
/// ## The editor re-entrancy contract
///
/// An edit re-sorts its note to the front of the list. The old NSTableView code
/// needed `isSyncingList` because programmatic selection posts a *synchronous*
/// selection-change that would rewrite the editor's text mid-keystroke, resetting
/// the insertion point and destroying IME marked text. That hazard is structural,
/// not AppKit-specific, so the guard survives in two forms:
///
/// 1. `selectedID` is only ever assigned from an explicit user action
///    (`select(_:)`), never as a side effect of re-ordering. `select(_:)` early-
///    returns when the id is already selected — the old `selectID` guard.
/// 2. `editorText` is the single source of truth *while editing*: `applyEdit`
///    writes model→store but never writes back into `editorText`. Only an explicit
///    note switch or a dictation append (which must move the caret anyway) calls
///    `loadEditorText`, and that is fenced by `isSyncingEditor` so the resulting
///    `onChange` cannot be mistaken for a user keystroke.
@MainActor
final class ScratchpadModel: ObservableObject {

    // MARK: - Published state

    /// All notes, ordered most-recently-updated first (the core's ordering).
    @Published private(set) var notes: [ScratchpadNote] = []
    /// The note shown in the editor.
    @Published private(set) var selectedID: UUID?
    /// The editor's live text. Bound directly to the text view; the model is
    /// updated from it, never the other way around during editing.
    @Published var editorText: String = ""
    /// The provenance line under the editor.
    @Published private(set) var provenance: String = ""
    /// Whether the rendered Markdown preview replaces the editor (P2).
    @Published var showsPreview: Bool = false
    /// The live search query (P3).
    @Published var searchQuery: String = ""
    /// The selected tag filter, if any (P3).
    @Published var tagFilter: String?

    // MARK: - AI actions (MAK-99)

    /// The action currently in flight, if any — drives the toolbar spinner and
    /// disables the menu (one action at a time).
    @Published private(set) var aiBusyAction: ScratchpadAI.Action?
    /// The transient status line under the editor: a failure explanation
    /// ("Kept original — …") or a success note. Cleared on the next action, on a
    /// note switch, and on a keystroke.
    @Published private(set) var aiStatus: String = ""

    // MARK: - Private state

    private var store = ScratchpadNotes()
    private var loaded = false
    /// Set while WE are writing `editorText` programmatically (a note switch or a
    /// dictation append). The editor's change handler ignores changes seen while
    /// this is true — the SwiftUI equivalent of the old `isSyncingList` guard.
    private var isSyncingEditor = false
    private var saveTimer: Timer?
    /// Serial queue for the coalesced disk write, so writes stay ordered and never
    /// block the main actor. Snapshots are value types, so there is no shared state.
    private static let saveQueue = DispatchQueue(label: "com.openwhisp.app.scratchpad-save")
    private var terminationObserver: NSObjectProtocol?

    init() {
        // Flush pending edits when the app quits — the debounce window must never
        // be the reason a note loses its last sentence. Registered here (not in
        // AppState) to keep the AppState ratchet flat.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    // MARK: - Loading

    /// Load from disk once. Idempotent — the controller calls it on every open.
    func loadIfNeeded() {
        guard !loaded else { return }
        store = ScratchpadStore.load()
        loaded = true
        notes = store.notes
        if let first = notes.first?.id {
            select(first)
        } else {
            createNote()
        }
    }

    // MARK: - Derived (filtered) list — P3

    /// The notes the list actually shows: the full set narrowed by the search query
    /// and the tag filter, in the store's order.
    var visibleNotes: [ScratchpadNote] {
        ScratchpadFilter.filtered(notes: notes, query: searchQuery, tag: tagFilter)
    }

    /// Every tag across all notes with its note count, for the tag-filter menu.
    var allTags: [(tag: String, count: Int)] { ScratchpadTags.tagCounts(in: notes) }

    /// True when a filter is narrowing the list (drives the "clear filters" affordance).
    var isFiltering: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || tagFilter != nil
    }

    /// True when the selected note is hidden by the current filter. The editor keeps
    /// showing it (losing the user's place mid-search would be worse), and the UI
    /// surfaces this as a hint rather than silently re-selecting.
    var selectedNoteIsFilteredOut: Bool {
        guard let selectedID, isFiltering else { return false }
        return !visibleNotes.contains { $0.id == selectedID }
    }

    /// Clear both filters (⎋ in the search field, or the "show all" button).
    func clearFilters() {
        searchQuery = ""
        tagFilter = nil
    }

    // MARK: - In-note find (native find bar)

    /// The live editor NSTextView, registered by the representable — held
    /// weakly so a torn-down editor (preview mode, panel closed) can't be kept
    /// alive by the model.
    private weak var editorTextView: NSTextView?

    func registerEditorTextView(_ textView: NSTextView) {
        editorTextView = textView
    }

    /// The live editor, for the one caller that must drive it directly: the MAK-99
    /// in-place transform, which replaces the text through the text view's own
    /// undo-registering path so ⌘Z restores the note. Nil when the editor isn't on
    /// screen (preview mode, closed panel), which the caller treats as "fall back to
    /// a direct model write".
    var liveEditorTextView: NSTextView? {
        editorTextView?.window == nil ? nil : editorTextView
    }

    /// ⌘F: open the editor's native find bar (incremental, highlighted,
    /// Enter/⇧Enter navigation) — the in-note half of search; the toolbar
    /// field (⌘⇧F) filters across notes. No-op in preview mode.
    func showEditorFindBar() {
        guard let textView = editorTextView, textView.window != nil else { return }
        textView.window?.makeFirstResponder(textView)
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(action)
    }

    // MARK: - Selection

    /// Show a note in the editor. Early-returns when it is already selected and the
    /// editor already holds its text — a spurious re-selection must never reset the
    /// caret or destroy in-progress IME composition.
    func select(_ id: UUID) {
        let body = store.note(id)?.text ?? ""
        if id == selectedID, editorText == body { return }
        selectedID = id
        // MAK-99: switching notes cancels delivery of any in-flight AI result — it
        // must never paint into the note the user just moved to.
        if aiSession.noteChanged(to: id) { aiBusyAction = nil }
        aiStatus = ""
        loadEditorText(body, for: id)
    }

    /// The currently selected note, if it still exists.
    var selectedNote: ScratchpadNote? { selectedID.flatMap { store.note($0) } }

    // MARK: - Mutations

    /// Create an empty note, select it, and persist immediately (structural).
    func createNote() {
        let id = store.createNote()
        selectedID = id
        notes = store.notes
        loadEditorText("", for: id)
        persist(.create)
    }

    /// Delete a note and select whatever is now at the front. Immediate (structural).
    /// Creates a fresh note when the last one goes, so the pad is never empty.
    func delete(_ id: UUID) {
        store.delete(id)
        notes = store.notes
        persist(.delete)
        if let next = store.notes.first?.id {
            selectedID = next
            loadEditorText(store.note(next)?.text ?? "", for: next)
        } else {
            createNote()
        }
    }

    /// The editor's text changed. Coalesced — this is the per-keystroke path.
    ///
    /// Deliberately does NOT write back into `editorText` or reset the selection:
    /// the note re-sorts to the front of `notes` (the list re-renders, cheaply),
    /// but the editor keeps the user's caret exactly where it is.
    func applyEdit(_ text: String) {
        guard !isSyncingEditor, let id = selectedID else { return }
        // A keystroke retires the AI status line — it described the previous state.
        clearAIStatus()
        store.setText(text, for: id)
        notes = store.notes
        provenance = ScratchpadText.provenanceLine(store.note(id))
        persist(.edit)
    }

    /// Append a completed dictation to the selected note (creating one if needed).
    /// Returns the note's new full text. Coalesced — the flush paths cover the tail.
    @discardableResult
    func appendDictation(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        loadIfNeeded()
        if selectedID == nil || store.note(selectedID!) == nil {
            let id = store.createNote()
            selectedID = id
            notes = store.notes
        }
        guard let id = selectedID else { return nil }
        let updated = store.appendDictation(text, to: id) ?? ""
        notes = store.notes
        loadEditorText(updated, for: id)
        persist(.dictation)
        return updated
    }

    /// Insert a meeting as a new note and select it. Immediate (structural), and
    /// persisted BEFORE the caller shows the panel so first-open selection lands here.
    @discardableResult
    func insertMeetingNote(_ meeting: Meeting) -> UUID {
        loadIfNeeded()
        let id = store.insertMeetingNote(meeting)
        selectedID = id
        notes = store.notes
        loadEditorText(store.note(id)?.text ?? "", for: id)
        persist(.meetingInsert)
        return id
    }

    /// Insert a completed file transcription as a new note and select it (MAK-98).
    /// Immediate (structural), and persisted BEFORE the caller shows the panel so
    /// first-open selection lands here — same ordering contract as the meeting path.
    @discardableResult
    func insertFileTranscriptNote(
        fileName: String, date: Date, duration: TimeInterval, transcript: String
    ) -> UUID {
        loadIfNeeded()
        let id = store.insertFileTranscriptNote(
            fileName: fileName, date: date, duration: duration, transcript: transcript)
        selectedID = id
        notes = store.notes
        loadEditorText(store.note(id)?.text ?? "", for: id)
        persist(.fileTranscriptInsert)
        return id
    }

    // MARK: - AI actions (MAK-99)

    /// One LLM round-trip: (instruction, input, resolved model) → output.
    /// Injected by the controller so this model never touches AppState — the same
    /// seam `MeetingPipelineCoordinator.SummarizeCall` uses, and equally stubbable.
    typealias AICall = (
        _ instruction: String, _ input: String, _ resolved: SummaryModelResolver.Resolved
    ) async throws -> String

    private var aiCall: AICall?
    /// Re-evaluated per request so a mid-session settings change lands.
    private var resolveAIModel: () -> SummaryModelResolver.Resolved = {
        .init(provider: "", model: "", endpoint: "")
    }
    /// The delivery fence — pure and unit-tested (`ScratchpadAISession`).
    private var aiSession = ScratchpadAISession()

    /// Wire the LLM seam. Called once by the controller at construction.
    func configureAI(call: @escaping AICall, resolveModel: @escaping () -> SummaryModelResolver.Resolved) {
        aiCall = call
        resolveAIModel = resolveModel
    }

    /// Whether the AI menu is available at all (an LLM seam is wired).
    var aiAvailable: Bool { aiCall != nil }

    /// Whether an action can start right now: a wired LLM, nothing in flight, and a
    /// selected note with actual content to work on.
    var canRunAIAction: Bool {
        aiAvailable && aiBusyAction == nil
            && !(selectedNote?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The effective provider/model the actions will use, for the settings surface.
    var resolvedAIModel: SummaryModelResolver.Resolved { resolveAIModel() }

    /// Clear the status line (a keystroke or an explicit dismissal).
    func clearAIStatus() {
        guard !aiStatus.isEmpty else { return }
        aiStatus = ""
    }

    /// Run an AI action over the selected note.
    ///
    /// Failure NEVER clobbers the note: every exit that isn't an accepted result
    /// leaves the text exactly as it was and explains itself in `aiStatus`.
    ///
    /// - Parameter applyInPlace: how a destructive result reaches the note. The view
    ///   passes a closure that replaces the text THROUGH the NSTextView's
    ///   undo-registering path, so the transform is a single ⌘Z away (see
    ///   `ScratchpadTextEditor.replaceTextUndoably`). Nil falls back to a direct
    ///   model write (used only when the editor isn't on screen — e.g. preview mode).
    func runAIAction(
        _ action: ScratchpadAI.Action,
        applyInPlace: ((String) -> Bool)? = nil
    ) {
        guard let aiCall else {
            aiStatus = "No LLM is configured — set one up in Settings → Cleanup."
            return
        }
        guard aiBusyAction == nil else { return }
        guard let id = selectedID, let note = store.note(id) else { return }
        let source = note.text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Fail closed BEFORE the request: an agent-CLI resolution would otherwise
        // fall through to the OpenAI cloud endpoint the user never chose (the
        // MAK-53 hazard).
        let resolved = resolveAIModel()
        guard ScratchpadAIModel.isUsable(resolved) else {
            aiStatus = "Kept original — " + ScratchpadAIModel.unusableProviderMessage
            return
        }

        let ticket = aiSession.begin(noteID: id, action: action)
        aiBusyAction = action
        aiStatus = ""
        let instruction = ScratchpadAI.prompt(for: action)

        Task { [weak self] in
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await aiCall(instruction, source, resolved))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self?.deliverAIResult(
                    outcome, ticket: ticket, source: source, action: action,
                    applyInPlace: applyInPlace)
            }
        }
    }

    /// Land (or discard) an AI result. The fence decides whether this result is
    /// still wanted; the guard decides whether it is good enough to use.
    private func deliverAIResult(
        _ outcome: Result<String, Error>,
        ticket: ScratchpadAISession.Ticket,
        source: String,
        action: ScratchpadAI.Action,
        applyInPlace: ((String) -> Bool)?
    ) {
        // A late result for a note the user has left (or a cancelled/superseded
        // request) is dropped silently — painting it anywhere would be the bug.
        guard aiSession.accepts(ticket, currentNoteID: selectedID) else {
            aiSession.finish(ticket)
            if !aiSession.isBusy { aiBusyAction = nil }
            return
        }
        aiSession.finish(ticket)
        aiBusyAction = nil

        let output: String
        switch outcome {
        case .success(let text):
            output = text
        case .failure(let error):
            aiStatus = "Kept original — " + Self.aiFailureReason(error)
            return
        }

        switch ScratchpadAI.validate(output: output, source: source, action: action) {
        case .failure(let rejection):
            aiStatus = "Kept original — " + rejection.reason
        case .success(let accepted):
            apply(accepted, for: action, source: source, applyInPlace: applyInPlace)
        }
    }

    /// Route an ACCEPTED result to its destination: in place for the destructive
    /// transform, a brand-new note for the summary.
    private func apply(
        _ accepted: String,
        for action: ScratchpadAI.Action,
        source: String,
        applyInPlace: ((String) -> Bool)?
    ) {
        switch action {
        case .formatMarkdown:
            // Preferred path: through the text view, so the whole transform is ONE
            // undo group and ⌘Z restores the note exactly. `applyInPlace` returns
            // false when the editor refused (not on screen / not first responder),
            // in which case we still land the text — losing undo is much better
            // than losing the result.
            if applyInPlace?(accepted) == true {
                // The text view's change notification already drove `applyEdit`.
                aiStatus = "Formatted as Markdown — ⌘Z to undo."
            } else {
                guard let id = selectedID else { return }
                store.setText(accepted, for: id)
                notes = store.notes
                loadEditorText(accepted, for: id)
                persist(.edit)
                aiStatus = "Formatted as Markdown."
            }
        case .summarize:
            // Non-destructive: a NEW note, selected. The source is untouched.
            let id = store.createNote()
            store.setText(ScratchpadAI.summaryNoteText(summary: accepted, sourceText: source), for: id)
            store.clearTypedProvenance(for: id)
            selectedID = id
            notes = store.notes
            loadEditorText(store.note(id)?.text ?? "", for: id)
            persist(.create)
            aiStatus = "Summary saved as a new note."
        }
    }

    /// A short human reason for a failed LLM round-trip.
    private static func aiFailureReason(_ error: Error) -> String {
        if let wire = error as? BridgeWire.ErrorObject, !wire.message.isEmpty {
            return wire.message
        }
        let described = (error as NSError).localizedDescription
        return described.isEmpty ? "the request failed" : described
    }

    // MARK: - Editor sync

    /// Write text INTO the editor programmatically, fenced so the resulting change
    /// notification is not mistaken for a keystroke.
    private func loadEditorText(_ body: String, for id: UUID) {
        isSyncingEditor = true
        editorText = body
        provenance = ScratchpadText.provenanceLine(store.note(id))
        isSyncingEditor = false
    }

    // MARK: - Persistence

    /// Route a mutation through the persistence policy: immediate for structural
    /// changes, coalesced for the per-keystroke path.
    private func persist(_ mutation: ScratchpadPersistencePolicy.Mutation) {
        if ScratchpadPersistencePolicy.cancelsPendingWrite(mutation) {
            saveTimer?.invalidate()
            saveTimer = nil
        }
        if ScratchpadPersistencePolicy.requiresImmediateWrite(mutation) {
            writeSnapshot()
        } else {
            scheduleWrite()
        }
    }

    /// (Re)start the coalescing timer. Rapid typing collapses into one write.
    private func scheduleWrite() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(
            withTimeInterval: ScratchpadPersistencePolicy.debounceInterval, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveTimer = nil
                self.writeSnapshot()
            }
        }
    }

    /// Hand the CURRENT store (a value type) to the serial background queue.
    private func writeSnapshot() {
        let snapshot = store
        Self.saveQueue.async { ScratchpadStore.save(snapshot) }
    }

    /// Cancel delivery of any in-flight AI result (MAK-99) — the panel closed.
    /// The request itself keeps running to completion; its result is simply
    /// discarded on arrival rather than painting into a pad that isn't on screen.
    func cancelAIAction() {
        guard aiSession.isBusy else { return }
        aiSession.cancel()
        aiBusyAction = nil
        aiStatus = ""
    }

    /// Persist any pending edit immediately — panel close, app terminate.
    /// Safe to call when nothing is pending.
    func flush() {
        guard loaded else { return }
        saveTimer?.invalidate()
        saveTimer = nil
        // Fold in the editor's very last keystroke: the debounce may not have fired,
        // and a `setText` that is already a no-op costs nothing.
        if let id = selectedID { store.setText(editorText, for: id) }
        writeSnapshot()
    }
}
