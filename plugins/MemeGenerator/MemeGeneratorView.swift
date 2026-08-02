import AppKit
import SwiftUI

/// The Meme Generator plugin's window content (spike).
///
/// Voice-first by construction: the description field is the first responder when the
/// window opens, so pressing the dictation hotkey and speaking lands the words here
/// with no typing and no clicking. "As fast as possible" is the whole point.
struct MemeGeneratorView: View {

    @ObservedObject var model: MemeGeneratorModel

    /// Focuses the description editor on open so a dictation lands immediately.
    @FocusState private var descriptionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            descriptionEditor
            controls
            if !model.status.isEmpty { statusLine }
            preview
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { descriptionFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: PluginRegistry.memeGenerator.symbol)
                .foregroundStyle(.secondary)
            Text("Describe the meme out loud — the model picks a template and writes the captions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var descriptionEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $model.description)
                .font(.body)
                .frame(minHeight: 70, maxHeight: 110)
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
        Text(model.status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var preview: some View {
        if let meme = model.meme {
            Image(nsImage: meme)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(
                    "Meme preview. Top caption: \(model.topText). Bottom caption: \(model.bottomText).")
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

    /// Share the rendered PNG through the system picker. Writes to a temp file first
    /// because `NSSharingServicePicker` shares URLs far more widely than raw images
    /// (Mail/Messages/AirDrop all want a file).
    private func share() {
        guard let meme = model.meme,
              let data = MemeRenderer.pngData(for: meme) else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                MemeCaptionLayout.suggestedFileName(
                    topText: model.topText, bottomText: model.bottomText))
        guard (try? data.write(to: url)) != nil else { return }

        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }
}
