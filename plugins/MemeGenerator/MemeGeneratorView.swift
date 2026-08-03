import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Meme Generator plugin's window content (spike v3).
///
/// Voice-first by construction: the description field is the first responder when the
/// window opens, so pressing the dictation hotkey and speaking lands the words here
/// with no typing and no clicking.
///
/// ## v3 layout — toward the imgflip.com editor shape
///
/// The owner asked for the familiar meme-editor arrangement, and for everything local
/// to feel instant. The window is now three columns:
///
/// ```
/// ┌──────────────┬─────────────────────────┬──────────────┐
/// │ TEMPLATES    │        CANVAS           │  TEXT BOXES  │
/// │ search +     │   (the rendered meme,   │  add/delete, │
/// │ browse grid  │    drag the captions)   │  text, size, │
/// │ + import     │                         │  width, font │
/// └──────────────┴─────────────────────────┴──────────────┘
/// ```
///
/// * **Left** — template search and browse are PROMINENT rather than behind a sheet,
///   because picking the template is the decision the corpus expansion exists to
///   serve. Import lives here too (button, drag-drop, or ⌘V).
/// * **Center** — the canvas, with the description and Generate above it.
/// * **Right** — per-box controls, with **Add text always visible** (feedback #4:
///   deleting the last box used to remove the only way to add one back).
///
/// Nothing local shows a spinner: switching templates, editing text, dragging a box,
/// and searching are all synchronous re-renders.
struct MemeGeneratorView: View {

    @ObservedObject var model: MemeGeneratorModel

    /// Focuses the description editor on open so a dictation lands immediately.
    @FocusState private var descriptionFocused: Bool

    /// True while a drag of image files is hovering the template column.
    @State private var isDropTargeted = false

    var body: some View {
        HSplitView {
            templateColumn
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)

            VStack(alignment: .leading, spacing: 10) {
                descriptionEditor
                controls
                statusLine
                if !model.candidates.isEmpty { candidateStrip }
                canvas
            }
            .padding(12)
            .frame(minWidth: 380)

            editorPanel
                .frame(minWidth: 230, idealWidth: 250, maxWidth: 320)
        }
        .frame(minWidth: 980, minHeight: 660)
        .onAppear { descriptionFocused = true }
    }

    // MARK: - Left column: templates

    private var templateColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Templates").font(.headline)
                Spacer()
                Menu {
                    Button("Import images…") { importViaPanel() }
                    Button("Paste image") { model.importFromPasteboard() }
                    Divider()
                    Button("Show library in Finder") { revealLibrary() }
                } label: {
                    Label("Import", systemImage: "plus.rectangle.on.folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add your own image as a template")
            }

            TextField("Search all templates", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            // The corpus is the feature — say how big it is and where it came from.
            HStack(spacing: 4) {
                Text(model.catalog.isEmpty
                     ? "No templates loaded."
                     : "\(model.searchResults.count) of \(model.catalog.count) templates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.catalogFailed {
                    Button("Retry") { model.openCatalog(forceRefresh: true) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            templateGrid
        }
        .padding(12)
        .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
            }
        }
        // Drag any image file onto the column to make it a template. The most direct
        // path from "I have a meme picture" to "it's in my corpus".
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var templateGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

        if model.catalog.isEmpty {
            emptyTemplatesHint
        } else if model.searchResults.isEmpty {
            // The honest no-match state, unchanged from v2: never a substitution.
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.title).foregroundStyle(.tertiary)
                Text("No template matches \"\(model.searchText)\".")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("Import your own image to add it to the corpus.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(model.searchResults) { template in
                        TemplateThumbnail(
                            template: template,
                            isSelected: template.id == model.selectedTemplate?.id,
                            width: 104)
                        .onTapGesture { model.select(template: template) }
                        .contextMenu {
                            if template.source == .userLibrary {
                                Button("Delete from my library", role: .destructive) {
                                    model.deleteUserTemplate(template)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var emptyTemplatesHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text(model.catalogFailed
                 ? "Couldn't reach the template services."
                 : "Loading templates…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Drag an image here, or use Import — your own templates work offline.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }

    // MARK: - Center column

    private var descriptionEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $model.description)
                .font(.body)
                .frame(minHeight: 50, maxHeight: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3)))
                .focused($descriptionFocused)
                .overlay(alignment: .topLeading) {
                    // TextEditor has no placeholder; this is the standard workaround.
                    if model.description.isEmpty {
                        Text("Describe the meme out loud — dictate into this window.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                model.generate()
            } label: {
                Label(model.isBusy ? "Generating…" : "Generate", systemImage: "wand.and.stars")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canGenerate)
            .help(model.generateBlockedReason ?? "Ask the model for templates and captions")

            // The escape hatch v2 lacked entirely. Only shown while something is
            // actually in flight, so it never reads as a dead control.
            if model.isBusy {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelGeneration() }
                    .keyboardShortcut(.cancelAction)
            }

            // Start from scratch (v5). ALWAYS present rather than appearing once
            // there's something to clear — a control that materializes is harder to
            // find than one that is simply dimmed, and this is the button a user
            // reaches for when the surface is in a state they don't understand.
            // Disabled (not hidden) on an untouched window so it never reads as broken.
            Button {
                model.startNewMeme()
            } label: {
                Label("New meme", systemImage: "arrow.counterclockwise")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.canStartNewMeme)
            .help("Clear the description, captions, and template and start over (⌘N)")

            Spacer()

            Button {
                model.exportPNG()
            } label: {
                Label("Export PNG…", systemImage: "square.and.arrow.down")
            }
            .disabled(model.meme == nil)

            Button {
                share()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(model.meme == nil)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if !model.status.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                // A fallback is called out with a symbol as well as words — the
                // owner's complaint was that the substitution was invisible.
                if model.didFallBack || model.catalogFailed || model.imageFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // A failed template image gets its OWN Retry (v4) — the catalog Retry
                // above re-fetches the catalog, which does nothing for an image that
                // failed to download.
                if model.imageFailed {
                    Button("Retry") { model.retryTemplate() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Spacer()
            }
        }
    }

    /// The model's ranked picks. Clicking one re-renders the same captions onto it —
    /// instantly, and even while a generation is still running.
    private var candidateStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.candidatesAreFallback
                 ? "Nothing matched — closest and most popular instead:"
                 : "The model's picks, best first:")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.candidates) { template in
                        TemplateThumbnail(
                            template: template,
                            isSelected: template.id == model.selectedTemplate?.id,
                            width: 88)
                        .onTapGesture { model.select(template: template) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var canvas: some View {
        if let meme = model.meme {
            // The base image is the RENDERED meme (captions already burned in by the
            // same code path the export uses, so this is genuinely WYSIWYG). The
            // overlaid boxes are invisible drag handles positioned by the same
            // normalized coordinates.
            GeometryReader { geo in
                let fitted = Self.fittedRect(imageSize: meme.size, in: geo.size)

                ZStack(alignment: .topLeading) {
                    Image(nsImage: meme)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityLabel(
                            "Meme preview. Captions: "
                            + model.boxes.map(\.text).filter { !$0.isEmpty }.joined(separator: ", "))

                    ForEach(model.boxes) { box in
                        DragHandle(
                            model: model,
                            box: box,
                            canvas: fitted,
                            isSelected: box.id == model.selectedBoxID)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        // The empty state INVITES the next action rather than just
                        // being blank (v5) — this is what the user is looking at
                        // straight after ⌘N, so it has to say what to do next.
                        Text(MemeComposition.emptyHint)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 24)
                        Text("Press ⌘⏎ to generate once you've described one.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 24)
                    })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Where a `scaledToFit` image actually lands inside its frame.
    ///
    /// SwiftUI letterboxes the image, so the drag handles must be positioned against
    /// the IMAGE's rect, not the frame's — otherwise a handle drifts off the text on
    /// any template whose aspect ratio differs from the pane's.
    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width, height: size.height)
    }

    // MARK: - Right column: the box editor

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // "Add text" is ALWAYS here — outside every conditional. v2 rendered this
            // whole panel only when `boxes` was non-empty, so deleting the last box
            // removed the only control that could add one back (feedback #4).
            HStack {
                Text("Text boxes").font(.headline)
                Spacer()
                Button {
                    model.addBox()
                } label: {
                    Label("Add text", systemImage: "plus")
                }
                .help("Add a caption box")
            }

            if model.boxes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "textformat")
                        .font(.title).foregroundStyle(.tertiary)
                    Text("No caption boxes.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Press Add text to put a caption on the meme.")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(model.boxes) { box in
                    BoxRow(model: model, box: box)
                }

                Divider()

                if let selected = model.selectedBox {
                    BoxControls(model: model, box: selected)
                } else {
                    Text("Select a text box to edit it.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(12)
    }

    // MARK: - Import

    private func importViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .tiff, .bmp, .webP]
        panel.message = "Choose images to add as meme templates."
        guard panel.runModal() == .OK else { return }
        model.importTemplates(from: panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Resolve every provider, then import once: importing per-callback would
        // reload the library N times and race the status line.
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, MemeUserLibrary.isAcceptedImage(fileName: url.lastPathComponent) {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            model.importTemplates(from: urls)
        }
        return true
    }

    private func revealLibrary() {
        let directory = MemeLibraryStore.templatesDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    /// Share the rendered PNG through the system picker. Writes to a temp file first
    /// because `NSSharingServicePicker` shares URLs far more widely than raw images
    /// (Mail/Messages/AirDrop all want a file).
    private func share() {
        guard let meme = model.meme,
              let data = MemeRenderer.pngData(for: meme) else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(model.suggestedFileName)
        guard (try? data.write(to: url)) != nil else { return }

        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }
}

// MARK: - Drag handle

/// The invisible, draggable hit area sitting on top of one rendered caption.
///
/// Deliberately NOT a second copy of the text: drawing the caption again in SwiftUI
/// would mean two renderers to keep in agreement, and they would drift (different
/// wrapping, different outline). Instead the burned-in render IS the visual, and this
/// is a positioned outline the user grabs.
private struct DragHandle: View {

    @ObservedObject var model: MemeGeneratorModel
    let box: MemeCaptionLayout.CaptionBox
    /// Where the image actually sits inside the preview frame.
    let canvas: CGRect
    let isSelected: Bool

    /// Live drag offset in points, applied on top of the box's committed position so
    /// the handle tracks the cursor without a re-render per frame fighting it.
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        let width = canvas.width * box.widthShare
        let height = max(24, canvas.height * box.fontSizeShare * MemeCaptionLayout.lineHeightRatio)
        let x = canvas.minX + canvas.width * box.centerX + dragOffset.width
        let y = canvas.minY + canvas.height * box.centerY + dragOffset.height

        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(
                isSelected ? Color.accentColor : Color.white.opacity(0.5),
                style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [4, 3]))
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(isSelected ? 0.10 : 0.001)))
            .frame(width: width, height: height)
            .position(x: x, y: y)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        model.selectedBoxID = box.id
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        // Commit in NORMALIZED units so the move survives the export's
                        // full-resolution render and a switch to another template.
                        guard canvas.width > 0, canvas.height > 0 else { return }
                        let dx = value.translation.width / canvas.width
                        let dy = value.translation.height / canvas.height
                        model.updateBox(id: box.id) { b in
                            b.centerX += dx
                            b.centerY += dy
                        }
                        dragOffset = .zero
                    })
            .onTapGesture { model.selectedBoxID = box.id }
            .help("Drag to move this caption")
    }
}

// MARK: - Editor rows

/// One row in the box list: selects the box and shows what it says.
private struct BoxRow: View {
    @ObservedObject var model: MemeGeneratorModel
    let box: MemeCaptionLayout.CaptionBox

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: box.id == model.selectedBoxID
                  ? "textformat.abc" : "textformat")
                .foregroundStyle(box.id == model.selectedBoxID ? Color.accentColor : .secondary)
            Text(box.text.isEmpty ? "(empty)" : box.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(box.text.isEmpty ? .tertiary : .primary)
            Spacer()
            Button {
                model.deleteBox(id: box.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this text box")
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedBoxID = box.id }
        .padding(.vertical, 2)
    }
}

/// Text / size / font controls for the selected box.
///
/// Every control funnels through `model.updateBox`, so clamping and re-rendering
/// happen in one place and the preview can never fall out of sync with the boxes.
private struct BoxControls: View {
    @ObservedObject var model: MemeGeneratorModel
    let box: MemeCaptionLayout.CaptionBox

    /// The size slider's range, hoisted out of the view builder: a multi-line range
    /// expression inside a `Slider(...)` argument list doesn't parse.
    private static let sizeRange =
        MemeCaptionLayout.CaptionBox.minimumFontSizeShare
        ... MemeCaptionLayout.CaptionBox.maximumFontSizeShare

    /// One binding factory for every numeric control. Written with explicit
    /// statement bodies because a bare `model.updateBox { ... }` in a `set:` closure
    /// makes Swift infer the binding's value type as `Void`.
    private func binding(
        _ get: @escaping (MemeCaptionLayout.CaptionBox) -> Double,
        _ set: @escaping (inout MemeCaptionLayout.CaptionBox, Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: { get(box) },
            set: { newValue in
                model.updateBox(id: box.id) { set(&$0, newValue) }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text").font(.caption).foregroundStyle(.secondary)
            TextField("Caption", text: Binding(
                get: { box.text },
                set: { newValue in
                    model.updateBox(id: box.id) { $0.text = newValue }
                }))
            .textFieldStyle(.roundedBorder)

            HStack {
                Text("Size").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.updateBox(id: box.id) { $0.fontSizeShare -= 0.01 }
                } label: { Image(systemName: "minus") }
                Button {
                    model.updateBox(id: box.id) { $0.fontSizeShare += 0.01 }
                } label: { Image(systemName: "plus") }
            }
            Slider(
                value: binding({ $0.fontSizeShare }, { $0.fontSizeShare = $1 }),
                in: Self.sizeRange)

            HStack {
                Text("Width").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: binding({ $0.widthShare }, { $0.widthShare = $1 }),
                    in: 0.1...1.0)
            }

            Text("Font").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { box.fontName ?? "" },
                set: { newValue in
                    model.updateBox(id: box.id) { $0.fontName = newValue.isEmpty ? nil : newValue }
                })) {
                    Text(MemeRenderer.defaultFontLabel).tag("")
                    // Only faces actually installed are listed — a picker offering a
                    // font that silently resolves to something else is a lie.
                    ForEach(MemeRenderer.availableCaptionFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    Text("System (bold)").tag(MemeRenderer.systemFontToken)
                }
                .labelsHidden()
        }
    }
}

// MARK: - Thumbnail

/// A template preview image plus its name and source badge.
///
/// Loads from the on-disk thumbnail cache first so a second open of the window paints
/// instantly and works with the network off; `AsyncImage` is the fallback for a
/// template whose thumbnail hasn't been cached yet. User-library templates are
/// `file:` URLs, which `AsyncImage` handles natively — one code path, three sources.
private struct TemplateThumbnail: View {
    let template: MemeTemplate
    let isSelected: Bool
    let width: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            thumbnailImage
                .frame(width: width, height: width * 0.75)
                .clipped()
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3))
                .overlay(alignment: .topTrailing) {
                    // The user's own templates are badged so a mixed grid is legible
                    // at a glance — "which of these are mine" is the question a merged
                    // corpus creates.
                    if template.source == .userLibrary {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(3)
                    }
                }

            Text(template.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: width)
        }
        .contentShape(Rectangle())
        .help("\(template.name) — \(template.source.label)")
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let cached = MemeLibraryStore.cachedThumbnail(for: template.id) {
            Image(nsImage: cached).resizable().scaledToFill()
        } else {
            AsyncImage(url: URL(string: template.url)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                default:
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}
