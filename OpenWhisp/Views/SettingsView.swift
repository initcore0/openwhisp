import SwiftUI
import Cocoa

// MARK: - Settings View
//
// Sidebar + detail layout (redesign spec §3): eight panes organized by the
// dictation pipeline — you speak → it transcribes → it cleans up → it lands in
// your app — instead of the old Basic/Advanced split by scariness. The pane set
// never changes; only groups within a pane adapt to the selected engine.

/// The sidebar panes, in frequency-weighted order after the conventional
/// General-first.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case insights
    case dictation
    case models
    case cleanup
    case output
    case profiles
    case agentBridge
    case privacy
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:     return "General"
        case .insights:    return "Insights"
        case .dictation:   return "Dictation"
        case .models:      return "Models"
        case .cleanup:     return "Cleanup"
        case .output:      return "Output"
        case .profiles:    return "Per-App Profiles"
        case .agentBridge: return "Agent Bridge"
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
        case .profiles:    return "square.grid.2x2"
        case .agentBridge: return "point.3.connected.trianglepath.dotted"
        case .privacy:     return "lock.shield"
        case .advanced:    return "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {

    @ObservedObject var appState: AppState

    @State private var selectedPane: SettingsPane = .general

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
                List(SettingsPane.allCases, selection: $selectedPane) { pane in
                    Label(pane.title, systemImage: pane.symbol)
                        .tag(pane)
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
        case .profiles:  ProfilesPane(appState: appState)
        case .agentBridge: AgentBridgePane(appState: appState)
        case .privacy:   PrivacyPane(appState: appState)
        case .advanced:  AdvancedPane(appState: appState)
        }
    }
}
