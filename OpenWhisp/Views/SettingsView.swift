import SwiftUI
import Cocoa

// MARK: - Settings View
//
// Sidebar + detail layout (redesign spec §3): panes organized by the dictation
// pipeline — you speak → it transcribes → it cleans up → it lands in your app —
// instead of the old Basic/Advanced split by scariness. The pane set never
// changes; only groups within a pane adapt to the selected engine.
//
// MAK-62: the sidebar is split into two sections so the everyday surface stays
// small. "Setup" holds the panes a first-run user might touch (General,
// Dictation, Models, Cleanup, Output) plus Privacy and Advanced; the optional
// feature panes (Insights, Modes, Rules, File Transcription, Meetings, Per-App
// Profiles, Agent Bridge, Sync) live under a collapsible "More features" group
// so they stop crowding the frozen vertical list. Defaults are good enough that
// a first run needs to touch none of them.

/// The sidebar panes, in frequency-weighted order after the conventional
/// General-first. Declaration order is also the sidebar order within each group.
enum SettingsPane: String, CaseIterable, Identifiable {
    // Setup group — the everyday surface.
    case general
    case dictation
    case models
    case cleanup
    case output
    case privacy
    case advanced
    // More features group — optional panes, collapsed by default.
    case insights
    case modes
    case rules
    case files
    case meetings
    case profiles
    case agentBridge
    case sync
    case streamOverlay

    var id: String { rawValue }

    /// Which sidebar section a pane belongs to. "More features" is collapsed by
    /// default so the everyday surface stays small (MAK-62).
    enum Group {
        case setup
        case moreFeatures
    }

    var group: Group {
        switch self {
        case .general, .dictation, .models, .cleanup, .output, .privacy, .advanced:
            return .setup
        case .insights, .modes, .rules, .files, .meetings, .profiles, .agentBridge, .sync, .streamOverlay:
            return .moreFeatures
        }
    }

    static var setupPanes: [SettingsPane] { allCases.filter { $0.group == .setup } }
    static var moreFeaturePanes: [SettingsPane] { allCases.filter { $0.group == .moreFeatures } }

    var title: String {
        switch self {
        case .general:     return "General"
        case .insights:    return "Insights"
        case .dictation:   return "Dictation"
        case .models:      return "Models"
        case .cleanup:     return "Cleanup"
        case .output:      return "Output"
        case .rules:       return "Rules"
        case .modes:       return "Modes"
        case .files:       return "File Transcription"
        case .meetings:    return "Meetings"
        case .profiles:    return "Per-App Profiles"
        case .agentBridge: return "Agent Bridge"
        case .sync:        return "Sync"
        case .streamOverlay: return "Stream Overlay"
        case .privacy:     return "Privacy & Permissions"
        case .advanced:    return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general:     return "gearshape"
        case .insights:    return "chart.bar.xaxis"
        case .dictation:   return "mic"
        case .models:      return "cpu"
        case .cleanup:     return "wand.and.stars"
        case .output:      return "text.cursor"
        case .rules:       return "flowchart"
        case .modes:       return "square.stack.3d.up"
        case .files:       return "waveform.and.magnifyingglass"
        case .meetings:    return "person.2.wave.2"
        case .profiles:    return "square.grid.2x2"
        case .agentBridge: return "point.3.connected.trianglepath.dotted"
        case .sync:        return "arrow.triangle.2.circlepath"
        case .streamOverlay: return "captions.bubble"
        case .privacy:     return "lock.shield"
        case .advanced:    return "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {

    @ObservedObject var appState: AppState

    @State private var selectedPane: SettingsPane = .general
    // Optional feature panes stay collapsed until the user asks for them, so the
    // sidebar opens as a short everyday list (MAK-62). Auto-expands if a feature
    // pane is somehow the current selection (e.g. deep-linked).
    @State private var moreFeaturesExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Launch-recheck banners: shown when a needed permission is missing
            // (e.g. a reinstall revoked Accessibility). Auto-clears once granted —
            // refreshPermissionBanners() runs on every app-became-active. Pinned
            // above the split view so it's visible from every pane.
            if !appState.missingPermissionBanners.isEmpty {
                PermissionBannerStack(appState: appState)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }

            NavigationSplitView {
                List(selection: $selectedPane) {
                    Section {
                        ForEach(SettingsPane.setupPanes) { pane in
                            Label(pane.title, systemImage: pane.symbol)
                                .tag(pane)
                        }
                    }

                    // Everything the everyday user can ignore, folded away so the
                    // frozen vertical list stops being 15 rows long (MAK-62).
                    Section {
                        DisclosureGroup(isExpanded: $moreFeaturesExpanded) {
                            ForEach(SettingsPane.moreFeaturePanes) { pane in
                                Label(pane.title, systemImage: pane.symbol)
                                    .tag(pane)
                            }
                        } label: {
                            Label("More features", systemImage: "ellipsis.circle")
                        }
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            } detail: {
                detailView
                    .navigationTitle(selectedPane.title)
            }
            .navigationSplitViewStyle(.balanced)
        }
        .onAppear {
            appState.refreshPermissionBanners()
            // Keeps the microphone list current without a manual refresh button.
            AudioDeviceMonitor.shared.start()
            // Keep a deep-linked feature pane visible in the collapsed sidebar.
            if selectedPane.group == .moreFeatures { moreFeaturesExpanded = true }
        }
        .onChange(of: selectedPane) { newValue in
            if newValue.group == .moreFeatures { moreFeaturesExpanded = true }
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedPane {
        case .general:   GeneralPane(appState: appState)
        case .insights:  InsightsPane(appState: appState)
        case .dictation: DictationPane(appState: appState)
        case .models:    ModelsPane(appState: appState)
        case .cleanup:   CleanupPane(appState: appState)
        case .output:    OutputPane(appState: appState)
        case .rules:     RulesPane(appState: appState)
        case .modes:     ModesPane(appState: appState)
        case .files:     FileTranscriptionPane(coordinator: appState.fileCoordinator)
        case .meetings:  MeetingsPane(appState: appState, coordinator: appState.meetingCoordinator)
        case .profiles:  ProfilesPane(appState: appState)
        case .agentBridge: AgentBridgePane(appState: appState)
        case .sync:      SyncPane(appState: appState)
        case .streamOverlay: StreamOverlayPane(overlay: appState.streamOverlay, dictationLanguage: appState.language)
        case .privacy:   PrivacyPane(appState: appState)
        case .advanced:  AdvancedPane(appState: appState)
        }
    }
}
