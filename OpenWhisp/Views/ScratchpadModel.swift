import SwiftUI
import Combine

/// The observable state behind the Scratchpad's SwiftUI content (MAK-95/96/97).
///
/// The `ScratchpadWindowController` stays a thin AppKit shell (panel lifecycle +
/// the AppState-facing dictation seam); everything the UI binds to lives here, and
/// every non-trivial *rule* it applies lives in OpenWhispCore (`ScratchpadText`,
/// `ScratchpadPersistencePolicy`, and — as the later phases land — the preview,
/// export, filter and tag types) where `swift test` covers it.
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

    /// The notes the list actually shows. P3 (MAK-97) narrows this by the search
    /// query and tag filter; until then it is the full set.
    var visibleNotes: [ScratchpadNote] { notes }

    /// Every tag across all notes with its note count, for the tag-filter menu.
    /// Populated in P3 (MAK-97).
    var allTags: [(tag: String, count: Int)] { [] }

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

    // MARK: - Selection

    /// Show a note in the editor. Early-returns when it is already selected and the
    /// editor already holds its text — a spurious re-selection must never reset the
    /// caret or destroy in-progress IME composition.
    func select(_ id: UUID) {
        let body = store.note(id)?.text ?? ""
        if id == selectedID, editorText == body { return }
        selectedID = id
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
