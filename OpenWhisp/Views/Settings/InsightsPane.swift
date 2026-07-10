import SwiftUI
import Cocoa

/// Local Usage Insights (MAK-38): words dictated, WPM, estimated time saved,
/// streaks, and a per-app breakdown — all derived on-device from the
/// metadata-only `DictationStats` (no transcript text, no accounts, no cloud).
///
/// The numbers come from `AppState.insightsSummary`, which is pure
/// `InsightsSummary` aggregation (unit-tested in core). This pane is presentation
/// only: stat tiles, breakdown bars, and a locally-rendered share card
/// (`ImageRenderer` → PNG) the user can save, copy, or share.
struct InsightsPane: View {
    @ObservedObject var appState: AppState

    /// Recomputed on appear so freshly-recorded dictations show up when the pane
    /// is revisited. `DictationStats` folds are cheap; no need to observe.
    @State private var summary = InsightsSummary(stats: DictationStats(), today: "")
    @State private var shareStatus: String?

    var body: some View {
        Form {
            if summary.totalSessions == 0 {
                emptySection
            } else {
                heroSection
                timeSavedSection
                streaksSection
                appBreakdownSection
                engineBreakdownSection
                shareSection
            }
        }
        .formStyle(.grouped)
        .onAppear { summary = appState.insightsSummary }
    }

    // MARK: - Empty

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("No dictations yet")
                    .font(.headline)
                Text("Your usage insights — words dictated, speaking speed, estimated time saved, and streaks — appear here after your first dictation. Everything is computed on this Mac from metadata only (counts and durations); your transcripts are never part of it.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Hero tiles

    private var heroSection: some View {
        Section {
            HStack(spacing: 12) {
                StatTile(
                    title: "Words dictated",
                    value: decimal(summary.totalWords),
                    symbol: "text.word.spacing",
                    tint: .accentColor
                )
                StatTile(
                    title: "Speaking speed",
                    value: summary.wordsPerMinute.map { "\(Int($0.rounded())) wpm" } ?? "—",
                    symbol: "gauge.with.dots.needle.67percent",
                    tint: .blue
                )
                StatTile(
                    title: "Dictations",
                    value: decimal(summary.totalSessions),
                    symbol: "mic.fill",
                    tint: .purple
                )
            }
        } header: {
            Text("Lifetime")
        } footer: {
            SettingsFootnote("All on-device, metadata only — no transcript text is ever part of these stats, and nothing is sent anywhere.")
        }
    }

    // MARK: - Time saved

    private var timeSavedSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.title2)
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.estimatedSecondsSaved.map(InsightsSummary.formatDuration) ?? "—")
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.green)
                        .monospacedDigit()
                    Text("Estimated time saved")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Time saved")
        } footer: {
            SettingsFootnote("An estimate: typing \(decimal(summary.totalWords)) words at \(Int(InsightsSummary.typingBaselineWPM)) words-per-minute (a common average sustained typing speed) would take longer than the time you spent speaking them. Your real typing speed will differ.")
        }
    }

    // MARK: - Streaks

    private var streaksSection: some View {
        Section {
            HStack(spacing: 12) {
                StatTile(
                    title: "Current streak",
                    value: dayCount(summary.currentStreakDays),
                    symbol: "flame.fill",
                    tint: summary.currentStreakDays > 0 ? .orange : .secondary
                )
                StatTile(
                    title: "Longest streak",
                    value: dayCount(summary.longestStreakDays),
                    symbol: "trophy.fill",
                    tint: .yellow
                )
                StatTile(
                    title: "Active days",
                    value: decimal(summary.activeDays),
                    symbol: "calendar",
                    tint: .teal
                )
            }
            if summary.sessionsToday > 0 {
                Text("Today: \(decimal(summary.wordsToday)) words across \(dictationCount(summary.sessionsToday)).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Streaks")
        } footer: {
            SettingsFootnote("A streak is consecutive calendar days (UTC) with at least one dictation.")
        }
    }

    // MARK: - Per-app breakdown

    private var appBreakdownSection: some View {
        Section {
            ForEach(summary.appBreakdown, id: \.bundleID) { app in
                BreakdownBar(
                    label: app.displayName,
                    detail: "\(dictationCount(app.sessions)) · \(percent(app.fraction))",
                    fraction: app.fraction
                )
            }
        } header: {
            Text("Where you dictate")
        } footer: {
            SettingsFootnote("The app each dictation landed in. Only a coarse per-app count is kept — never what you said. Sessions with no known target app show as “Unattributed”.")
        }
    }

    // MARK: - Per-engine breakdown

    @ViewBuilder
    private var engineBreakdownSection: some View {
        if summary.engineBreakdown.count > 1 || summary.averageLatencySeconds != nil {
            Section {
                ForEach(summary.engineBreakdown, id: \.engine) { engine in
                    BreakdownBar(
                        label: engine.displayName,
                        detail: "\(dictationCount(engine.sessions)) · \(percent(engine.fraction))",
                        fraction: engine.fraction
                    )
                }
                if let latency = summary.averageLatencySeconds {
                    LabeledContent("Average transcription latency") {
                        Text(String(format: "%.1fs", latency))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Engines")
            }
        }
    }

    // MARK: - Share card

    private var shareSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    saveShareCard()
                } label: {
                    Label("Save share card…", systemImage: "square.and.arrow.down")
                }
                Button {
                    copyShareCard()
                } label: {
                    Label("Copy image", systemImage: "doc.on.clipboard")
                }
            }
            if let shareStatus {
                TestResultLine(text: shareStatus, isGood: true)
            }
        } header: {
            Text("Share")
        } footer: {
            SettingsFootnote("Renders a small card of these numbers to a PNG on this Mac — nothing is uploaded. Save it or copy it to the clipboard to share it yourself.")
        }
    }

    private var shareCard: ShareCard { ShareCard(summary: summary) }

    /// Render the SwiftUI share card to a PNG on this device.
    @MainActor
    private func renderCardPNG() -> Data? {
        let renderer = ImageRenderer(content: shareCard)
        renderer.scale = 2 // crisp on retina
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    private func saveShareCard() {
        guard let png = renderCardPNG() else {
            shareStatus = "Couldn't render the card."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "openwhisp-insights.png"
        panel.prompt = "Save"
        panel.message = "Save your OpenWhisp insights card"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            shareStatus = "Saved to \(url.lastPathComponent)."
        } catch {
            shareStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    private func copyShareCard() {
        guard let png = renderCardPNG(), let image = NSImage(data: png) else {
            shareStatus = "Couldn't render the card."
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        shareStatus = "Copied the card to your clipboard."
    }

    // MARK: - Formatting helpers

    private func decimal(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
    private func percent(_ f: Double) -> String {
        "\(Int((f * 100).rounded()))%"
    }
    private func dayCount(_ n: Int) -> String {
        "\(n) day\(n == 1 ? "" : "s")"
    }
    private func dictationCount(_ n: Int) -> String {
        "\(decimal(n)) dictation\(n == 1 ? "" : "s")"
    }
}

// MARK: - Stat tile

/// One compact metric: symbol, big value, small caption. Uniform tiles across the
/// hero and streak rows.
private struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .foregroundColor(tint)
                .imageScale(.large)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Breakdown bar

/// A labeled proportion bar for the per-app / per-engine breakdowns.
private struct BreakdownBar: View {
    let label: String
    let detail: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.callout).lineLimit(1)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(detail)")
    }
}

// MARK: - Share card

/// The locally-rendered image the user can share — a self-contained SwiftUI view
/// with fixed dimensions so `ImageRenderer` produces a consistent PNG. Uses only
/// the metadata-derived summary (no transcript text).
struct ShareCard: View {
    let summary: InsightsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.title2)
                Text("OpenWhisp")
                    .font(.title2.weight(.bold))
                Spacer()
                Text("Usage Insights")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                cardMetric(big(summary.totalWords), "words dictated")
                cardMetric(
                    summary.estimatedSecondsSaved.map(InsightsSummary.formatDuration) ?? "—",
                    "time saved*"
                )
                cardMetric(
                    summary.wordsPerMinute.map { "\(Int($0.rounded()))" } ?? "—",
                    "words / min"
                )
            }

            HStack(spacing: 24) {
                cardMetric("\(summary.currentStreakDays)", "day streak")
                cardMetric("\(summary.activeDays)", "active days")
                cardMetric(big(summary.totalSessions), "dictations")
            }

            Text("*vs typing at \(Int(InsightsSummary.typingBaselineWPM)) wpm · computed on-device · openwhisp.app")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 520, height: 300, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.19, blue: 0.22),
                         Color(red: 0.02, green: 0.11, blue: 0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .foregroundStyle(.white)
    }

    private func cardMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func big(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }
}
