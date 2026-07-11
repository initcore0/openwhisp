import SwiftUI
import UniformTypeIdentifiers

/// Settings pane for "Meeting mode" (MAK-50): the list of recorded meetings, each
/// with its transcript + summary and the Transcribe / Summarize / Export / Delete
/// actions. Summarize honors the privacy rule — auto for a local provider, an
/// explicit "transcript leaves this Mac" confirmation for a cloud/agent provider.
///
/// Recording itself (menu Start/Stop, system-audio capture) is the capture half; this
/// pane renders a live "recording in progress" row when the integrator drives
/// `recordingInProgress`.
struct MeetingsPane: View {
    @ObservedObject var coordinator: MeetingPipelineCoordinator
    @State private var cloudConsentMeeting: Meeting?

    var body: some View {
        Form {
            infoSection
            if coordinator.recordingInProgress != nil || !coordinator.meetings.isEmpty {
                listSection
            } else {
                Section { Text("No meetings recorded yet.").foregroundStyle(.secondary) }
            }
            if let msg = coordinator.lastMessage {
                Section { Text(msg).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Summarize this meeting?",
            isPresented: Binding(get: { cloudConsentMeeting != nil }, set: { if !$0 { cloudConsentMeeting = nil } }),
            presenting: cloudConsentMeeting
        ) { meeting in
            Button("Summarize (transcript leaves this Mac)", role: .destructive) {
                coordinator.summarize(meeting.id, confirmedCloud: true)
                cloudConsentMeeting = nil
            }
            Button("Cancel", role: .cancel) { cloudConsentMeeting = nil }
        } message: { _ in
            Text("Your configured LLM provider is not local, so the transcript will be sent to it to produce the summary.")
        }
    }

    private var infoSection: some View {
        Section {
            Text("Record a meeting from the menu bar (Start/Stop). Recordings are transcribed on-device; summaries run through your configured LLM.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Meetings")
        }
    }

    private var listSection: some View {
        Section {
            if let live = coordinator.recordingInProgress {
                HStack {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        // MAK-52: live "who's talking" indicator (mic = You, system = Them).
                        Text(coordinator.talkState.label)
                        Text("Recording · \(Self.dateString(live.startedAt))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
            ForEach(coordinator.meetings) { meeting in
                MeetingRow(
                    meeting: meeting,
                    coordinator: coordinator,
                    requestCloudConsent: { cloudConsentMeeting = meeting }
                )
            }
        } header: {
            Text("Recorded")
        }
    }

    static func dateString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Row

private struct MeetingRow: View {
    let meeting: Meeting
    @ObservedObject var coordinator: MeetingPipelineCoordinator
    let requestCloudConsent: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(MeetingsPane.dateString(meeting.startedAt)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
                actionsMenu
                Button(role: .destructive) { coordinator.delete(meeting.id) } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
            if case .failed(let reason) = meeting.status {
                Text(reason).font(.caption).foregroundStyle(.red)
            }
            if meeting.transcript != nil || meeting.summary != nil {
                Button(expanded ? "Hide details" : "Show details") { expanded.toggle() }
                    .buttonStyle(.borderless).font(.caption)
            }
            if expanded {
                if let summary = meeting.summary, !summary.isEmpty {
                    Text("Summary").font(.caption).bold()
                    Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                // MAK-52: prefer the attributed (Me/Them) transcript when present.
                if let attributed = meeting.attributedTranscript, !attributed.isEmpty {
                    Text("Transcript (attributed)").font(.caption).bold()
                    Text(attributed).font(.caption).foregroundStyle(.secondary).lineLimit(12).textSelection(.enabled)
                } else if let transcript = meeting.transcript, !transcript.isEmpty {
                    Text("Transcript").font(.caption).bold()
                    Text(transcript).font(.caption).foregroundStyle(.secondary).lineLimit(12).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var actionsMenu: some View {
        Menu {
            if meeting.transcript == nil {
                Button("Transcribe") { coordinator.transcribe(meeting.id) }
            } else {
                Button("Re-transcribe") { coordinator.transcribe(meeting.id) }
            }
            if meeting.transcript != nil, coordinator.summarizeAvailable {
                Button(coordinator.canAutoSummarize ? "Summarize" : "Summarize with cloud provider…") {
                    if coordinator.canAutoSummarize {
                        coordinator.summarize(meeting.id, confirmedCloud: false)
                    } else {
                        requestCloudConsent()
                    }
                }
            }
            if meeting.transcript != nil {
                Button("Export .md…") { exportMarkdown() }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }.fixedSize()
    }

    private func exportMarkdown() {
        guard let body = coordinator.exportMarkdown(meeting.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "meeting-\(Int(meeting.startedAt.timeIntervalSince1970)).md"
        if panel.runModal() == .OK, let url = panel.url {
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private var isBusy: Bool {
        switch meeting.status {
        case .transcribing, .summarizing: return true
        default: return false
        }
    }

    private var subtitle: String {
        var s = meeting.status.label
        if meeting.duration > 0 { s += " · \(Int(meeting.duration))s" }
        return s
    }

    private var icon: String {
        switch meeting.status {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "waveform"
        }
    }

    private var tint: Color {
        switch meeting.status {
        case .done: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }
}
