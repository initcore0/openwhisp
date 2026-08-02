import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Scratchpad's SwiftUI content (MAK-95/96/97), hosted in the same floating
/// `NSPanel` the pad has always used. Layout: a toolbar, then a sidebar note list
/// beside the editor (or its rendered Markdown preview), with the provenance line
/// beneath.
///
/// Every rule this view applies — titles, snippets, provenance, filtering, tags,
/// preview rendering, export naming — comes from OpenWhispCore. The view is
/// deliberately dumb so the behavior is covered by `swift test`.
struct ScratchpadView: View {
    @ObservedObject var model: ScratchpadModel
    @FocusState private var searchFocused: Bool
    @State private var pendingDelete: ScratchpadNote?
    /// Whether the AI model-override popover is showing (MAK-99).
    @State private var showsAISettings = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                editorPane.frame(minWidth: 280)
            }
        }
        .frame(minWidth: 460, minHeight: 260)
        .confirmationDialog(
            "Delete “\(pendingDelete.map { ScratchpadText.listTitle(for: $0.text) } ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { note in
            Button("Delete", role: .destructive) {
                model.delete(note.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This permanently deletes the note. It can't be undone.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: model.createNote) {
                Label("New", systemImage: "square.and.pencil")
            }
            .help("New note (⌘N)")
            .keyboardShortcut("n", modifiers: .command)

            Button(action: requestDelete) {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete note (⌘⌫)")
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model.selectedNote == nil)

            Divider().frame(height: 16)

            Button { model.showsPreview.toggle() } label: {
                Label(model.showsPreview ? "Edit" : "Preview",
                      systemImage: model.showsPreview ? "eye.fill" : "eye")
            }
            .help(model.showsPreview ? "Back to editing (⌘⇧P)" : "Preview Markdown (⌘⇧P)")
            .keyboardShortcut("p", modifiers: [.command, .shift])

            exportMenu

            aiMenu

            Spacer()

            searchField
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// Export is a menu, not a bare button: ⌘E fires the default (.md save), and the
    /// menu also carries .txt and the clipboard route.
    private var exportMenu: some View {
        Menu {
            Button("Export as Markdown (.md)…") { export(.md) }
            Button("Export as Plain Text (.txt)…") { export(.txt) }
            Divider()
            Button("Copy as Markdown") { copyAsMarkdown() }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        } primaryAction: {
            export(.md)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Export this note (⌘E)")
        .keyboardShortcut("e", modifiers: .command)
        .disabled(model.selectedNote == nil)
    }

    // MARK: - AI actions (MAK-99)

    /// The AI actions menu, plus a spinner while a request runs. One action in
    /// flight at a time — the whole control disables while busy, and it is disabled
    /// on an empty note (there is nothing to format or summarize).
    @ViewBuilder
    private var aiMenu: some View {
        if model.aiBusyAction != nil {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(model.aiBusyAction?.busyLabel ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .help("An AI action is running — one at a time")
        } else {
            Menu {
                ForEach(ScratchpadAI.Action.allCases, id: \.self) { action in
                    Button {
                        run(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                }
                Divider()
                Button {
                    showsAISettings = true
                } label: {
                    Label("AI model…", systemImage: "gearshape")
                }
            } label: {
                Label("AI actions", systemImage: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(model.aiAvailable
                  ? "Format or summarize this note with the LLM"
                  : "Set up an LLM in Settings → Cleanup to use AI actions")
            .disabled(!model.canRunAIAction)
            .popover(isPresented: $showsAISettings, arrowEdge: .bottom) {
                ScratchpadAISettingsView()
            }
        }
    }

    /// Kick off an action, handing the destructive one an undo-registering applier
    /// so the whole transform is a single ⌘Z away.
    private func run(_ action: ScratchpadAI.Action) {
        // Formatting rewrites the note; showing the result means leaving preview.
        if action.isDestructive { model.showsPreview = false }
        model.runAIAction(action, applyInPlace: { newText in
            ScratchpadTextEditor.replaceTextUndoably(in: model.liveEditorTextView, with: newText)
        })
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .frame(width: 130)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
            if model.isFiltering {
                Button {
                    model.clearFilters()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear search and tag filter")
                .accessibilityLabel("Clear filters")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor))
        )
        // Two searches, standard Mac split: ⌘F = find IN the open note (the
        // editor's native find bar, with highlighting and Enter/⇧Enter
        // navigation); ⌘⇧F = the cross-note filter field here. Zero-size
        // buttons carry the shortcuts so they work regardless of which subview
        // holds first responder.
        .background(
            Group {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("") { model.showEditorFindBar() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !model.allTags.isEmpty { tagFilterBar }
            List(selection: selectionBinding) {
                ForEach(model.visibleNotes) { note in
                    ScratchpadRow(note: note, activeTag: model.tagFilter)
                        .tag(note.id)
                        .contextMenu {
                            Button("Export as Markdown (.md)…") { export(.md, note: note) }
                            Button("Export as Plain Text (.txt)…") { export(.txt, note: note) }
                            Button("Copy as Markdown") { copyAsMarkdown(note: note) }
                            Divider()
                            Button("Delete", role: .destructive) { pendingDelete = note }
                        }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.visibleNotes.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "No matching notes",
                        systemImage: "magnifyingglass",
                        message: "Nothing matches the current search or tag."
                    )
                }
            }
        }
    }

    /// A tag menu that ANDs with the search query. Lists every tag with its count.
    private var tagFilterBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("All tags") { model.tagFilter = nil }
                Divider()
                ForEach(model.allTags, id: \.tag) { entry in
                    Button("#\(entry.tag) (\(entry.count))") { model.tagFilter = entry.tag }
                }
            } label: {
                Label(model.tagFilter.map { "#\($0)" } ?? "Tags", systemImage: "tag")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// List selection routed through the model's guarded `select(_:)`, so a spurious
    /// re-selection of the already-shown note can never reset the editor's caret.
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { model.selectedID },
            set: { if let id = $0 { model.select(id) } }
        )
    }

    // MARK: - Editor / preview

    private var editorPane: some View {
        VStack(spacing: 0) {
            if model.showsPreview {
                MarkdownPreviewView(text: model.editorText)
            } else {
                ScratchpadTextEditor(
                    text: $model.editorText,
                    onEdit: model.applyEdit,
                    // Global filter query lights up its matches in the open
                    // note and jumps to the first one (the "where IS it in
                    // this long transcript" gap).
                    highlightQuery: model.searchQuery,
                    noteID: model.selectedID,
                    onTextViewReady: { model.registerEditorTextView($0) })
            }
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(model.provenance)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if model.selectedNoteIsFilteredOut {
                // The selected note is hidden by the filter. Keeping it in the editor
                // preserves the user's place; this says why it's not in the list.
                Label("Hidden by filter", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // MAK-99: the AI action's outcome. A rejected result reads
            // "Kept original — <reason>" and the note is untouched.
            if !model.aiStatus.isEmpty {
                Label(model.aiStatus, systemImage: model.aiStatus.hasPrefix("Kept original")
                      ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.aiStatus)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: - Actions

    private func requestDelete() {
        guard let note = model.selectedNote else { return }
        // Empty notes delete in one click; anything with content asks first, since
        // deletion is permanent and not undoable.
        if note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.delete(note.id)
        } else {
            pendingDelete = note
        }
    }

    /// Save the note through an NSSavePanel (the MeetingsPane pattern). The bytes
    /// and the suggested file name both come from the pure `ScratchpadExport`.
    private func export(_ format: ScratchpadExport.Format, note: ScratchpadNote? = nil) {
        guard let note = note ?? model.selectedNote else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = ScratchpadExport.exportFileName(for: note, format: format)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body = ScratchpadExport.render(note: note, format: format)
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Put the note's Markdown source on the pasteboard.
    private func copyAsMarkdown(note: ScratchpadNote? = nil) {
        guard let note = note ?? model.selectedNote else { return }
        let body = ScratchpadExport.render(note: note, format: .md)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }
}

// MARK: - List row

/// One note in the sidebar: stripped title, relative date, origin glyph, a
/// two-line stripped snippet, and up to three derived #tag chips.
private struct ScratchpadRow: View {
    let note: ScratchpadNote
    /// The tag currently filtering the list, so its chip can be highlighted.
    let activeTag: String?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// A fresh note's `updatedAt` can sit a rounding-hair in the FUTURE, which
    /// RelativeDateTimeFormatter renders as the nonsense "in 0s". Clamp: not
    /// yet a minute old (or future) reads as "now".
    private static func relativeLabel(_ date: Date) -> String {
        let now = Date()
        guard date < now, now.timeIntervalSince(date) >= 60 else { return "now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let symbol = ScratchpadText.originSymbol(note.origin) {
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(ScratchpadText.originLabel(note.origin))
                }
                Text(ScratchpadText.listTitle(for: note.text))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Self.relativeLabel(note.updatedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            let snippet = ScratchpadText.snippet(for: note.text)
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            tagChips
        }
        .padding(.vertical, 2)
    }

    /// Up to three derived #tag chips, with a "+N" overflow. The chip matching the
    /// active filter is highlighted so it's clear why the row is in the list.
    @ViewBuilder
    private var tagChips: some View {
        let tags = ScratchpadTags.tags(in: note)
        if !tags.isEmpty {
            HStack(spacing: 3) {
                ForEach(tags.prefix(3), id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(tag == activeTag
                                           ? Color.accentColor.opacity(0.25)
                                           : Color.secondary.opacity(0.15))
                        )
                }
                if tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Editor

/// The note editor: a real `NSTextView` behind an `NSViewRepresentable`.
///
/// **Why not `TextEditor`**: an edit re-sorts its note to the front of the list, so
/// the surrounding view re-renders on every keystroke. SwiftUI's `TextEditor`
/// round-trips its binding through that re-render, which fights the caret and can
/// drop IME marked text — precisely the hazard the old AppKit code's
/// `isSyncingList` guard existed to prevent. An `NSTextView` owns its own text
/// storage: re-rendering the list cannot touch the caret, marked text is AppKit's
/// business, and `allowsUndo` gives real ⌘Z (which matters because edits persist
/// without a save step).
///
/// `updateNSView` therefore writes into the text view ONLY when the incoming text
/// actually differs from what it already holds — the guard that makes a note switch
/// or a dictation append land, while an ordinary keystroke re-render is a no-op.
struct ScratchpadTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onEdit: (String) -> Void
    /// The active GLOBAL filter query — its matches are highlighted in the
    /// editor (temporary layout attributes, so the text storage and undo stack
    /// are untouched) and the first match is scrolled into view when the note
    /// opens. Empty = no highlights. In-note ad-hoc search is the native find
    /// bar (⌘F), which manages its own highlighting.
    var highlightQuery: String = ""
    /// Identity of the shown note — with `highlightQuery`, decides when the
    /// scroll-to-first-match should fire (once per note-under-query, never on
    /// every keystroke re-render).
    var noteID: UUID?
    /// Hands the created NSTextView to the owner so toolbar/⌘F can drive the
    /// native find bar. Weakly held by the model.
    var onTextViewReady: (NSTextView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Replace the whole note text THROUGH the text view's undo-registering path
    /// (MAK-99), so an AI transform is a single ⌘Z away.
    ///
    /// Why this and not a direct `textView.string = new` or a model write: assigning
    /// `string` bypasses `NSTextView`'s undo coalescing entirely — the transform
    /// would be irreversible, which is unacceptable for an action that overwrites
    /// text the user dictated. Going through
    /// `shouldChangeText` → `replaceCharacters` → `didChangeText` makes AppKit
    /// register the edit on the view's own undo manager as ONE group, and posts the
    /// change notification that drives `applyEdit` (so persistence and the note list
    /// update exactly as they would for a paste).
    ///
    /// Returns false when there is no live editor to drive (preview mode, closed
    /// panel) or when the text view refuses the edit; the caller then falls back to
    /// a direct model write rather than dropping the result.
    @discardableResult
    static func replaceTextUndoably(in textView: NSTextView?, with newText: String) -> Bool {
        guard let textView, textView.window != nil else { return false }
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: full, replacementString: newText) else { return false }
        // Name the undo group so ⌘Z reads "Undo Format as Markdown" in the Edit menu.
        textView.undoManager?.setActionName("Format as Markdown")
        textView.textStorage?.replaceCharacters(in: full, with: newText)
        textView.didChangeText()
        // Put the caret at the start rather than leaving it past the end of what is
        // now different text.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        return true
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        // ⌘Z must work: edits persist without an explicit save, so an accidental
        // Select-All + Delete would otherwise be irreversible.
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        // Native find bar (⌘F): incremental find with match highlighting and
        // Enter/⇧Enter navigation — the in-note half of search. The toolbar
        // field stays the cross-note filter (⌘⇧F).
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.string = text
        onTextViewReady(textView)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // ONLY write when the text genuinely differs. Without this guard, every
        // keystroke's re-render would reassign `string`, resetting the insertion
        // point and destroying in-progress IME composition.
        if textView.string != text {
            // Never clobber marked (in-composition) text — the IME owns it until
            // the user commits.
            guard !textView.hasMarkedText() else { return }
            let selected = textView.selectedRange()
            textView.string = text
            // Restore the caret when it still fits (a dictation append grows the
            // text from the end, so the user's position stays valid).
            let length = (text as NSString).length
            if selected.location <= length {
                textView.setSelectedRange(NSRange(location: min(selected.location, length), length: 0))
            }
        }
        context.coordinator.applyHighlights(
            query: highlightQuery, noteID: noteID, to: textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScratchpadTextEditor
        weak var textView: NSTextView?
        /// The (note, query) pair the current highlights were applied for —
        /// scroll-to-first-match fires only when this changes, so keystroke
        /// re-renders never yank the viewport.
        private var appliedHighlight: (noteID: UUID?, query: String) = (nil, "")

        init(_ parent: ScratchpadTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Ignore changes while the IME holds marked text: the composition is not
            // committed yet, so persisting it would store half-typed characters.
            guard !textView.hasMarkedText() else { return }
            let value = textView.string
            parent.text = value
            parent.onEdit(value)
            // Edits shift character positions — recompute the ranges in place
            // (same pair, so no scroll).
            reapplyHighlightRanges(to: textView)
        }

        /// Paint the global filter query's matches with TEMPORARY layout
        /// attributes — visible like the find bar's highlight, but the text
        /// storage (and with it the undo stack and persistence) is untouched.
        func applyHighlights(query: String, noteID: UUID?, to textView: NSTextView) {
            let pairChanged = appliedHighlight.noteID != noteID || appliedHighlight.query != query
            appliedHighlight = (noteID, query)
            let first = reapplyHighlightRanges(to: textView)
            // A newly opened note under an active query jumps to the first
            // match — the whole point for long meeting transcripts.
            if pairChanged, let first {
                textView.scrollRangeToVisible(first)
            }
        }

        /// Recompute + repaint; returns the first match range (NSRange) if any.
        @discardableResult
        private func reapplyHighlightRanges(to textView: NSTextView) -> NSRange? {
            guard let layoutManager = textView.layoutManager else { return nil }
            let text = textView.string
            let full = NSRange(location: 0, length: (text as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            let query = appliedHighlight.query
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var firstRange: NSRange?
            for range in ScratchpadFilter.matchRanges(of: query, in: text) {
                let nsRange = NSRange(range, in: text)
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: NSColor.findHighlightColor, forCharacterRange: nsRange)
                // findHighlightColor is a light yellow in both appearances —
                // force dark glyphs so dark-mode text stays readable on it.
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: NSColor.black, forCharacterRange: nsRange)
                if firstRange == nil { firstRange = nsRange }
            }
            return firstRange
        }
    }
}

// MARK: - Preview

/// The read-only rendered view of the same note. Blocks come from the pure
/// `MarkdownPreviewRenderer`; this maps them to typography and nothing else.
struct MarkdownPreviewView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(MarkdownPreviewRenderer.render(text).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownPreviewRenderer.Block) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level == 1 ? 4 : 8)
                .padding(.bottom, 3)
        case .paragraph:
            Text(block.text)
                .font(.system(size: 13))
                .padding(.vertical, 2)
        case .listItem(let depth):
            Text(block.text)
                .font(.system(size: 13))
                .padding(.leading, CGFloat(depth) * 16)
                .padding(.vertical, 1)
        case .codeBlock:
            Text(block.text)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12))
        case .blockQuote:
            HStack(spacing: 6) {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(block.text).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case .horizontalRule:
            Divider().padding(.vertical, 6)
        case .blank:
            Spacer().frame(height: 6)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1:  return 20
        case 2:  return 17
        case 3:  return 15
        default: return 13
        }
    }
}

// MARK: - AI model override (MAK-99)

/// The Scratchpad's AI model picker, shown as a gear popover from the AI menu.
///
/// It lives IN the pad rather than in a Settings pane because it configures a
/// control that is also in the pad — you pick the model from the same menu you run
/// the action from. The choices and their wording mirror the MAK-53 meeting
/// summarization override (Settings → Meetings) exactly, and the resolution is the
/// same pure `SummaryModelResolver` decision.
///
/// State is read/written through `ScratchpadWindowController`'s static accessors,
/// which own the UserDefaults keys — AppState is at its MAK-32 LOC budget and must
/// not grow.
struct ScratchpadAISettingsView: View {
    @State private var provider = ScratchpadWindowController.overrideProvider
    @State private var model = ScratchpadWindowController.overrideModel
    @State private var endpoint = ScratchpadWindowController.overrideEndpoint

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI model for this Scratchpad", systemImage: "wand.and.stars")
                .font(.headline)

            Picker("Model", selection: $provider) {
                ForEach(ScratchpadAIModel.offeredProviders, id: \.self) { id in
                    Text(ScratchpadAIModel.label(for: id)).tag(id)
                }
            }
            .onChange(of: provider) { ScratchpadWindowController.overrideProvider = provider }

            if provider != ScratchpadAIModel.useDefaultID {
                TextField("Model", text: $model, prompt: Text(modelPlaceholder))
                    .onChange(of: model) { ScratchpadWindowController.overrideModel = model }
                if provider == "local" {
                    TextField("Server URL", text: $endpoint,
                              prompt: Text("http://localhost:8080/v1"))
                        .onChange(of: endpoint) { ScratchpadWindowController.overrideEndpoint = endpoint }
                }
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
    }

    /// Show what the resolver WOULD pick, so "empty means default" is visible
    /// rather than mysterious (the MeetingsPane trick).
    private var modelPlaceholder: String {
        let resolved = ScratchpadWindowController.resolvedAIModel()
        return resolved.model.isEmpty ? "Server / provider default" : resolved.model
    }

    private var footnote: String {
        let resolved = ScratchpadWindowController.resolvedAIModel()
        let privacy = resolved.isLocal
            ? "Notes stay on this Mac."
            : "Note text is sent to this cloud provider when you run an action."
        return "Dictation cleanup favors a small, fast model. Scratchpad actions run "
            + "only when you ask, over a whole note, so they can afford a larger one. "
            + privacy
    }
}

// MARK: - Empty state

/// A minimal stand-in for `ContentUnavailableView` (macOS 14+) that also reads
/// correctly on the app's macOS 15 floor without version-gating the call site.
private struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(message).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding()
    }
}
