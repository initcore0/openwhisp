import SwiftUI

/// Status + management row for the on-device translation assets one
/// source→target pair needs (Apple Translation, macOS 15+).
///
/// This is the ONLY place a language download starts — dictations themselves
/// never pop UI; when assets are missing they paste the original text with a
/// status pointing here. The row polls while visible, so a download started
/// here (or in the Translate app) flips to "downloaded" within seconds — the
/// visibility that was missing when the consent sheet was the whole story.
struct TranslationAssetStatusView: View {
    /// BCP-47-ish source tag, or "auto"/"" when the source is detected per
    /// dictation (no concrete pair to pre-check).
    let sourceTag: String
    let targetTag: String
    /// Shown for the "auto" source, where no concrete pair exists to check.
    var autoNote: String = "Auto Detect: the translation language for what you dictate downloads on first use. Pick a specific language above to download it ahead of time."

    @State private var status: AppleTextTranslation.AssetStatus?
    @State private var downloadRequested = false

    private var isAutoSource: Bool {
        let tag = sourceTag.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty || tag.lowercased() == "auto"
    }

    private var pairName: String {
        "\(LanguageResolver.displayName(for: sourceTag)) → \(LanguageResolver.displayName(for: targetTag))"
    }

    var body: some View {
        content
            .task(id: "\(sourceTag)→\(targetTag)") {
                // Poll while visible (downloads run in the background and macOS
                // gives no completion callback). 3s keeps the row honest without
                // meaningfully costing anything — status() is a local lookup.
                while !Task.isCancelled {
                    let latest = await AppleTextTranslation.assetStatus(from: sourceTag, to: targetTag)
                    status = latest
                    if latest == .installed { downloadRequested = false }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isAutoSource {
            SettingsFootnote(autoNote)
        } else {
            switch status {
            case .installed:
                Label("\(pairName) translation is downloaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .needsDownload:
                HStack(spacing: 8) {
                    Label(
                        downloadRequested
                            ? "Downloading \(pairName) — takes a few minutes; this row updates when it's ready"
                            : "\(pairName) translation isn't downloaded — dictations stay untranslated until it is",
                        systemImage: downloadRequested ? "arrow.down.circle" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(downloadRequested ? Color.secondary : Color.orange)
                    if !downloadRequested {
                        Button("Download…") {
                            downloadRequested = true
                            AppleTextTranslation.requestAssetDownload(from: sourceTag, to: targetTag)
                        }
                        .controlSize(.small)
                    }
                }
            case .unsupported:
                Label("\(pairName) isn't supported by macOS translation", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .unavailable:
                SettingsFootnote("On-device translation needs macOS 15 or later.")
            case nil:
                // First poll hasn't answered yet — render nothing rather
                // than a flash of the wrong state.
                EmptyView()
            }
        }
    }
}
