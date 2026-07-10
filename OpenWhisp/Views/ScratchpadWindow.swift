import AppKit

/// The floating Scratchpad panel (MAK-49): an always-on-top, ACTIVATING NSPanel
/// with a note list on the left and an editable NSTextView on the right — a
/// target-free surface to dictate into when no other app has focus.
///
/// Why an *activating* titled panel (not the `.nonactivatingPanel` the dictation
/// overlay uses): the pad is a thing you TYPE and DICTATE into, so it must be able
/// to become key and give its text view first-responder. When it's frontmost,
/// `AppState.insertCompletedText` appends the dictation straight into the active
/// note (see `appendDictationIfKey`) rather than through the focused-app insert
/// path — whose paste fallback deliberately declines when our own app is frontmost.
///
/// All the pure logic (note model, ordering, provenance, persistence) lives in
/// `ScratchpadNotes` / `ScratchpadStore` in OpenWhispCore and is unit-tested; this
/// controller is the AppKit shell that renders it and persists after each edit.
@MainActor
final class ScratchpadWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {

    private unowned let appState: AppState

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private var textView: NSTextView?
    private var provenanceLabel: NSTextField?

    /// The note model. Loaded lazily from disk on first open; persisted after every
    /// mutation via `ScratchpadStore`.
    private var notes = ScratchpadNotes()
    /// The id of the note currently shown in the editor.
    private var selectedID: UUID?
    private var loaded = false

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    // MARK: - Show / focus

    /// Open the pad, bring it to front, and make its text view first responder so
    /// the very next dictation (or keystroke) lands in the active note. Idempotent.
    func showAndFocus() {
        loadIfNeeded()
        let panel = panel ?? makePanel()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let textView { panel.makeFirstResponder(textView) }
    }

    /// True while the pad is the frontmost key window — the signal AppState uses to
    /// route a completed dictation here instead of the focused app.
    var isKeyWindow: Bool { panel?.isKeyWindow ?? false }

    /// Append a completed dictation to the active note IF the pad is the key window.
    /// Returns whether it handled the text (so AppState skips its focused-app
    /// insert). Creates a first note on demand so a dictation is never dropped.
    /// Always lands the text — the pad is a local model, so there is no fail path.
    @discardableResult
    func appendDictationIfKey(_ text: String) -> Bool {
        guard isKeyWindow, !text.isEmpty else { return false }
        loadIfNeeded()
        if selectedID == nil || notes.note(selectedID!) == nil {
            selectedID = notes.createNote()
        }
        guard let id = selectedID else { return false }
        let updated = notes.appendDictation(text, to: id) ?? ""
        persist()
        reloadList()
        showNoteInEditor(id, body: updated)
        return true
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "OpenWhisp Scratchpad"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 460, height: 260)
        panel.delegate = self
        panel.contentView = buildContentView()
        panel.center()
        reloadList()
        // Show the most-recent note (or a fresh one) on first open.
        if let first = notes.notes.first?.id {
            selectID(first)
        } else {
            newNote()
        }
        return panel
    }

    /// A split layout: a narrow note list on the left, the editor + provenance on
    /// the right, with a small toolbar (New / Delete) above the list.
    private func buildContentView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))

        // Left: toolbar + table in a scroll view.
        let newButton = NSButton(title: "＋ New", target: self, action: #selector(newNoteAction))
        newButton.bezelStyle = .rounded
        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteNoteAction))
        deleteButton.bezelStyle = .rounded
        let toolbar = NSStackView(views: [newButton, deleteButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.title = "Notes"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(tableClicked)
        self.tableView = table

        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        let leftColumn = NSStackView(views: [toolbar, tableScroll])
        leftColumn.orientation = .vertical
        leftColumn.spacing = 6
        leftColumn.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 4)
        leftColumn.translatesAutoresizingMaskIntoConstraints = false

        // Right: editor + provenance line.
        let editor = NSTextView()
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 14)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.delegate = self
        editor.textContainerInset = NSSize(width: 6, height: 8)
        self.textView = editor

        let editorScroll = NSScrollView()
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.borderType = .bezelBorder
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true

        let provenance = NSTextField(labelWithString: "")
        provenance.font = .systemFont(ofSize: 11)
        provenance.textColor = .secondaryLabelColor
        provenance.translatesAutoresizingMaskIntoConstraints = false
        self.provenanceLabel = provenance

        let rightColumn = NSStackView(views: [editorScroll, provenance])
        rightColumn.orientation = .vertical
        rightColumn.spacing = 6
        rightColumn.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        rightColumn.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(leftColumn)
        split.addArrangedSubview(rightColumn)
        split.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(split)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leftColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        return container
    }

    // MARK: - Persistence + model loading

    private func loadIfNeeded() {
        guard !loaded else { return }
        notes = ScratchpadStore.load()
        selectedID = notes.notes.first?.id
        loaded = true
    }

    private func persist() { ScratchpadStore.save(notes) }

    // MARK: - Actions

    @objc private func newNoteAction() { newNote() }

    private func newNote() {
        let id = notes.createNote()
        selectedID = id
        persist()
        reloadList()
        showNoteInEditor(id, body: "")
        if let textView, let panel { panel.makeFirstResponder(textView) }
    }

    @objc private func deleteNoteAction() {
        guard let id = selectedID else { return }
        notes.delete(id)
        persist()
        selectedID = notes.notes.first?.id
        reloadList()
        if let id = selectedID { selectID(id) } else { newNote() }
    }

    @objc private func tableClicked() {
        guard let table = tableView else { return }
        let row = table.selectedRow
        guard row >= 0, row < notes.notes.count else { return }
        selectID(notes.notes[row].id)
    }

    private func selectID(_ id: UUID) {
        selectedID = id
        showNoteInEditor(id, body: notes.note(id)?.text ?? "")
    }

    // MARK: - View sync

    private func reloadList() {
        tableView?.reloadData()
        if let id = selectedID, let row = notes.notes.firstIndex(where: { $0.id == id }) {
            tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func showNoteInEditor(_ id: UUID, body: String) {
        textView?.string = body
        provenanceLabel?.stringValue = Self.provenanceLine(notes.note(id))
    }

    /// The human-readable provenance line derived purely from the note's timestamps.
    static func provenanceLine(_ note: ScratchpadNote?) -> String {
        guard let note else { return "" }
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        var parts: [String] = []
        if let d = note.lastDictatedAt { parts.append("dictated \(fmt.string(from: d))") }
        if let t = note.lastTypedAt { parts.append("typed \(fmt.string(from: t))") }
        if parts.isEmpty { return "New note" }
        let line = parts.joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView, let id = selectedID else { return }
        notes.setText(textView.string, for: id)
        persist()
        // Refresh the list title/order and provenance line without stealing focus.
        provenanceLabel?.stringValue = Self.provenanceLine(notes.note(id))
        tableView?.reloadData()
        if let row = notes.notes.firstIndex(where: { $0.id == id }) {
            tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Persist any last edit; keep the model in memory so a re-open is instant.
        if let textView, let id = selectedID {
            notes.setText(textView.string, for: id)
        }
        persist()
    }
}

// MARK: - Table data source / delegate

extension ScratchpadWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { notes.notes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < notes.notes.count else { return nil }
        let note = notes.notes[row]
        let id = NSUserInterfaceItemIdentifier("ScratchpadRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        cell.stringValue = note.displayTitle
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        tableClicked()
    }
}
