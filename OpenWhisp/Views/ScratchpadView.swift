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
        // ⌘F focuses the field. A zero-size button carries the shortcut so it works
        // regardless of which subview currently holds first responder.
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
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
                ScratchpadTextEditor(text: $model.editorText, onEdit: model.applyEdit)
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

/// One note in the sidebar: stripped title, relative date, origin glyph and a
/// two-line stripped snippet. P3 (MAK-97) adds derived #tag chips, highlighting
/// whichever tag is the active filter.
private struct ScratchpadRow: View {
    let note: ScratchpadNote
    /// The tag currently filtering the list, so its chip can be highlighted (P3).
    let activeTag: String?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

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
                Text(Self.relativeFormatter.localizedString(for: note.updatedAt, relativeTo: Date()))
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
            // P3 (MAK-97) adds derived #tag chips here.
        }
        .padding(.vertical, 2)
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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
        textView.string = text

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
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScratchpadTextEditor
        weak var textView: NSTextView?

        init(_ parent: ScratchpadTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Ignore changes while the IME holds marked text: the composition is not
            // committed yet, so persisting it would store half-typed characters.
            guard !textView.hasMarkedText() else { return }
            let value = textView.string
            parent.text = value
            parent.onEdit(value)
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
