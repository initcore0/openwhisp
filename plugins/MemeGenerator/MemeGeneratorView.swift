import AppKit
import SwiftUI

/// The Meme Generator plugin's window content (spike).
///
/// Voice-first by construction: the description field is the first responder when the
/// window opens, so pressing the dictation hotkey and speaking lands the words here
/// with no typing and no clicking. "As fast as possible" is the whole point.
///
/// ## v2 — "AI makes its best guess, human makes it perfect"
///
/// Three surfaces sit between the model's answer and the finished meme:
///
/// * **The candidate strip** — the model's ranked template picks as thumbnails. The
///   best one auto-renders; clicking another re-renders the SAME captions onto it.
/// * **Browse all** — a searchable grid of the whole corpus, so the user can override
///   the model entirely. This is the honest answer when the corpus doesn't contain
///   what they asked for.
/// * **The editor** — every caption is a draggable box over the preview, with text,
///   size and font controls in a side panel.
struct MemeGeneratorView: View {

    @ObservedObject var model: MemeGeneratorModel

    /// Focuses the description editor on open so a dictation lands immediately.
    @FocusState private var descriptionFocused: Bool

    /// Whether the Browse-all grid is showing.
    @State private var isBrowsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            descriptionEditor
            controls
            if !model.status.isEmpty { statusLine }
            if !model.candidates.isEmpty { candidateStrip }

            HStack(alignment: .top, spacing: 12) {
                preview
                if !model.boxes.isEmpty { editorPanel }
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 640)
        .onAppear { descriptionFocused = true }
        .sheet(isPresented: $isBrowsing) {
            BrowseAllSheet(model: model, isPresented: $isBrowsing)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: PluginRegistry.memeGenerator.symbol)
                .foregroundStyle(.secondary)
            Text("Describe the meme out loud — the model proposes templates and writes the captions. Then edit anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var descriptionEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $model.description)
                .font(.body)
                .frame(minHeight: 54, maxHeight: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3)))
                .focused($descriptionFocused)
                .overlay(alignment: .topLeading) {
                    // TextEditor has no placeholder; this is the standard workaround.
                    if model.description.isEmpty {
                        Text("e.g. \"distracted boyfriend, but he's looking at Rust and his girlfriend is Python\"")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }

            Text("Dictate into this window and your words land here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                model.generate()
            } label: {
                Label(model.isBusy ? "Generating…" : "Generate",
                      systemImage: "wand.and.stars")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canGenerate)

            if model.isBusy {
                ProgressView().controlSize(.small)
            }

            // Always available (it loads the catalog on demand), so the user is never
            // stuck with the model's idea of which templates exist.
            Button {
                model.loadCatalogIfNeeded()
                isBrowsing = true
            } label: {
                Label("Browse all…", systemImage: "square.grid.2x2")
            }

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

    private var statusLine: some View {
        HStack(alignment: .top, spacing: 6) {
            // A fallback is called out with a symbol as well as words — the owner's
            // complaint was that the substitution was invisible.
            if model.didFallBack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Candidate strip

    /// The model's ranked picks. Clicking one re-renders the same captions onto it.
    private var candidateStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.candidatesAreFallback
                 ? "Nothing in the corpus matched — closest and most popular instead:"
                 : "The model's picks, best first:")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.candidates) { template in
                        TemplateThumbnail(
                            template: template,
                            isSelected: template.id == model.selectedTemplate?.id,
                            width: 96)
                        .onTapGesture { model.select(template: template) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Preview + editor overlay

    @ViewBuilder
    private var preview: some View {
        if let meme = model.meme {
            // The base image is the RENDERED meme (captions already burned in by the
            // same code path the export uses, so this is genuinely WYSIWYG). The
            // overlaid boxes are invisible drag handles positioned by the same
            // normalized coordinates, which is why a handle always sits exactly on
            // the text it moves.
            GeometryReader { geo in
                let fitted = Self.fittedRect(
                    imageSize: meme.size, in: geo.size)

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
                        Text("Your meme will appear here.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
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

    // MARK: - Editor side panel

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Text boxes").font(.headline)
                Spacer()
                Button {
                    model.addBox()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a text box")
            }

            // The box list doubles as the selector for the controls below.
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

            Spacer()
        }
        .frame(width: 240)
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
/// is a positioned outline the user grabs. The tradeoff is that the handle is a
/// rectangle rather than glyph-tight, which is fine at spike quality.
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
        // Height comes from the same lineHeightRatio the renderer uses; the handle is
        // sized for a single line, which is enough to grab. Width follows the box.
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

// MARK: - Browse all

/// A searchable grid over the WHOLE catalog.
///
/// The honest override: when the model's picks are all wrong — or the meme the user
/// wanted simply isn't in imgflip's top 100 — this is where they say so themselves.
/// The search is local, case-insensitive and pure (`MemeTemplateMatcher.search`), and
/// crucially it does NOT fall back: an empty result stays empty and says why.
private struct BrowseAllSheet: View {
    @ObservedObject var model: MemeGeneratorModel
    @Binding var isPresented: Bool

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Browse templates").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }

            TextField("Search templates", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            // State the corpus plainly. This is the sentence that would have saved
            // the "yoda meme" session.
            Text("This is imgflip's public top-100 template list — \(model.catalog.count) templates. "
                 + "If what you want isn't here, it isn't in the corpus.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.catalog.isEmpty {
                ProgressView("Loading templates…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.searchResults.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No template matches \"\(model.searchText)\".")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.searchResults) { template in
                            TemplateThumbnail(
                                template: template,
                                isSelected: template.id == model.selectedTemplate?.id,
                                width: 120)
                            .onTapGesture {
                                model.select(template: template)
                                isPresented = false
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 640, height: 560)
    }
}

// MARK: - Thumbnail

/// A template preview image plus its name.
///
/// `AsyncImage` rather than the plugin's own `MemeTemplateService.fetchImage`: the
/// grid can show 100 of these, and `AsyncImage` already handles per-view cancellation
/// and URLCache reuse. It's the same imgflip CDN GET either way — still no upload.
private struct TemplateThumbnail: View {
    let template: MemeTemplate
    let isSelected: Bool
    let width: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            AsyncImage(url: URL(string: template.url)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: width, height: width * 0.75)
            .clipped()
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3))

            Text(template.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: width)
        }
        .contentShape(Rectangle())
        .help(template.name)
    }
}
