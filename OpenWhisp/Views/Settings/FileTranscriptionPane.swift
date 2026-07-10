import SwiftUI
import UniformTypeIdentifiers

/// Settings pane for audio/video **file** transcription (MAK-36): add files to a
/// batch queue, watch its per-file progress, export transcripts to txt/srt/vtt,
/// and manage auto-transcribe watch folders.
struct FileTranscriptionPane: View {
    @ObservedObject var coordinator: FileTranscriptionCoordinator
    @State private var enhanceEnabled = false

    var body: some View {
        Form {
            addSection
            queueSection
            watchSection
        }
        .formStyle(.grouped)
        .onAppear { coordinator.restartWatching() }
    }

    // MARK: - Add / options

    private var addSection: some View {
        Section {
            Button {
                addFiles()
            } label: {
                Label("Add audio or video files…", systemImage: "plus.circle")
            }
            SubtitledToggle(
                "Enhance transcripts with the LLM",
                subtitle: "Run the local refine pass over each finished transcript. Requires an LLM configured in Cleanup.",
                isOn: Binding(get: { enhanceEnabled }, set: { enhanceEnabled = $0; coordinator.setEnhanceEnabled($0) })
            )
        } header: {
            Text("Transcribe files")
        } footer: {
            Text("Decodes MP3/MP4/M4A/WAV/WEBM (and more) to 16 kHz audio and runs your on-device engine. Long files are chunked automatically.")
        }
    }

    // MARK: - Queue

    private var queueSection: some View {
        Section {
            if coordinator.queue.jobs.isEmpty {
                Text("No files queued.").foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.queue.jobs) { job in
                    JobRow(job: job, coordinator: coordinator)
                }
                if coordinator.queue.doneCount + coordinator.queue.failedCount > 0 {
                    Button("Clear finished") { coordinator.clearFinished() }
                }
            }
            if let msg = coordinator.lastExportMessage {
                Text(msg).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Queue")
        }
    }

    // MARK: - Watch folders

    private var watchSection: some View {
        Section {
            Button {
                addWatchFolder()
            } label: {
                Label("Add a watch folder…", systemImage: "folder.badge.plus")
            }
            ForEach(coordinator.watchFolders) { folder in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { folder.enabled },
                        set: { coordinator.setWatchFolderEnabled(folder.id, $0) }
                    )).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.displayName)
                        Text(folder.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        coordinator.removeWatchFolder(folder.id)
                    } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Watch folders")
        } footer: {
            Text("New media files dropped into these folders are auto-transcribed. Files still being copied are picked up once they stop changing.")
        }
    }

    // MARK: - Pickers

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav]
        if panel.runModal() == .OK {
            coordinator.addFiles(panel.urls)
        }
    }

    private func addWatchFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.addWatchFolder(url)
        }
    }
}

// MARK: - Job row

private struct JobRow: View {
    let job: FileTranscriptionJob
    @ObservedObject var coordinator: FileTranscriptionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.displayName).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if job.stage == .done {
                    Menu {
                        Button("Export .txt") { coordinator.export(job.id, format: .txt) }
                        Button("Export .srt") { coordinator.export(job.id, format: .srt) }
                        Button("Export .vtt") { coordinator.export(job.id, format: .vtt) }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }.fixedSize()
                } else if !job.stage.isTerminal {
                    ProgressView().controlSize(.small)
                }
                Button(role: .destructive) {
                    coordinator.removeJob(job.id)
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
            }
            if job.stage == .done, !job.fullText.isEmpty {
                Text(job.fullText).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if job.stage == .failed, let err = job.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if job.stage == .failed { return "Failed" }
        var s = job.stage.label
        if job.durationSeconds > 0 { s += " · \(Int(job.durationSeconds))s" }
        if job.fromWatchFolder { s += " · watched" }
        return s
    }

    private var icon: String {
        switch job.stage {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "waveform"
        }
    }

    private var tint: Color {
        switch job.stage {
        case .done: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }
}
