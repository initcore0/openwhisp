import SwiftUI
import Cocoa

// MARK: - Settings View

struct SettingsView: View {
    
    @ObservedObject var appState: AppState
    
    @State private var availableMics: [AudioDevice] = []
    @State private var selectedMicIndex: Int = 0
    @State private var selectedModel: String = "base"
    
    var body: some View {
        Form {
            // Model Section
            Section("Model") {
                Picker("Model Size", selection: $selectedModel) {
                    ForEach(appState.availableModelsList(), id: \.name) { model in
                        Text("\(model.name) (\(model.size))").tag(model.name)
                    }
                }
                .onChange(of: selectedModel) {
                    appState.modelName = selectedModel
                    appState.ensureModelExists()
                }
                
                TextField("Model Path", text: $appState.modelPath)
                    .textFieldStyle(.roundedBorder)
                
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.item]
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        appState.modelPath = url.path
                    }
                }
            }
            
            // Microphone Section
            Section("Microphone") {
                Picker("Input Device", selection: $selectedMicIndex) {
                    ForEach(availableMics.indices, id: \.self) { index in
                        Text(availableMics[index].name).tag(index)
                    }
                }
                .onChange(of: selectedMicIndex) {
                    if selectedMicIndex < availableMics.count {
                        appState.microphoneID = availableMics[selectedMicIndex].uid
                    }
                }
                
                Button("Refresh Devices") {
                    refreshDevices()
                }
            }
            
            // Language Section
            Section("Language") {
                Picker("Transcription Language", selection: $appState.language) {
                    Text("Auto Detect").tag("auto")
                    Text("English").tag("en")
                    Text("Russian").tag("ru")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Japanese").tag("ja")
                    Text("Chinese").tag("zh")
                    Text("Korean").tag("ko")
                    Text("Arabic").tag("ar")
                }
            }
            
            // Hotkey Section
            Section("Hotkey") {
                Picker("Push-to-talk", selection: $appState.triggerMode) {
                    Text("Control + Space").tag("controlSpace")
                    Text("Fn / Globe (experimental)").tag("fn")
                }
                
                Text(appState.hotkeyHelpText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Output Section
            Section("Text Output") {
                Picker("Insertion Mode", selection: $appState.outputMode) {
                    Text("Final paste only").tag("finalOnly")
                    Text("Live chunks (experimental)").tag("liveChunks")
                }
                
                Toggle("Show overlay while recording", isOn: $appState.showOverlay)
                Toggle("Add trailing space after paste", isOn: $appState.addTrailingSpace)
                Toggle("Restore clipboard after paste", isOn: $appState.restoreClipboard)
                
                Text("Clipboard restore reads your clipboard and may trigger macOS privacy prompts.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Permissions Section
            Section("Permissions") {
                HStack {
                    Text("Microphone")
                    Spacer()
                    Text(appState.microphonePermissionLabel)
                        .foregroundColor(appState.microphonePermissionLabel == "Granted" ? .green : .orange)
                }
                
                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(appState.accessibilityPermissionLabel)
                        .foregroundColor(appState.accessibilityPermissionLabel == "Granted" ? .green : .orange)
                }
                
                HStack {
                    Text("Input Monitoring")
                    Spacer()
                    Text(appState.inputMonitoringPermissionLabel)
                        .foregroundColor(appState.inputMonitoringPermissionLabel == "Granted" ? .green : .orange)
                }
                
                HStack {
                    Button("Request Accessibility") {
                        appState.requestAccessibilityPermission()
                    }
                    
                    Button("Open Privacy Settings") {
                        appState.openPrivacySettings()
                    }
                    
                    Button("Retry Hotkey") {
                        appState.retryHotkeyMonitor()
                    }
                }
            }
            
            // whisper.cpp Section
            Section("whisper.cpp") {
                TextField("Binary Path", text: $appState.whisperBinaryPath)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.allowedContentTypes = [.executable]
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            appState.whisperBinaryPath = url.path
                        }
                    }
                    
                    Button("Verify") {
                        verifySetup()
                    }
                }
            }
            
            // Status Section
            Section("Status") {
                HStack {
                    Text("Status:")
                    Spacer()
                    Text(appState.statusMessage)
                        .foregroundColor(statusColor)
                        .frame(width: 150, alignment: .trailing)
                }
                
                if let error = appState.error, !error.isEmpty {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                if let last = appState.lastTranscription, !last.isEmpty {
                    Text("Last: \"\(last.prefix(80))\(last.count > 80 ? "..." : "")\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .onAppear {
            selectedModel = appState.modelName
            refreshDevices()
        }
        .frame(minWidth: 500, minHeight: 450)
    }
    
    private var statusColor: Color {
        switch appState.statusMessage {
        case "Ready", "Done": return .green
        case "Recording...": return .red
        default:
            if appState.statusMessage.hasPrefix("Transcribing") || appState.statusMessage == "Finalizing..." { return .orange }
            if appState.error != nil { return .red }
            return .gray
        }
    }
    
    private func refreshDevices() {
        availableMics = AudioDevice.availableInputs()
        if !availableMics.isEmpty {
            if !appState.microphoneID.isEmpty {
                if let index = availableMics.firstIndex(where: { $0.uid == appState.microphoneID }) {
                    selectedMicIndex = index
                }
            }
        }
    }
    
    private func verifySetup() {
        let binaryExists = FileManager.default.fileExists(atPath: appState.whisperBinaryPath)
        let modelExists = FileManager.default.fileExists(atPath: appState.modelPath)
        
        if binaryExists && modelExists {
            appState.statusMessage = "Setup verified ✓"
            appState.error = nil
        } else {
            var msg = "Setup incomplete.\n"
            if !binaryExists { msg += "✗ whisper.cpp binary not found\n" }
            if !modelExists { msg += "✗ Model file not found\n" }
            appState.error = msg
        }
    }
}
