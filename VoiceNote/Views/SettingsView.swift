import SwiftUI
import Cocoa

// MARK: - Settings View

struct SettingsView: View {
    
    @ObservedObject var appState: AppState
    
    @State private var availableMics: [AudioDevice] = []
    @State private var selectedMicIndex: Int = 0
    @State private var selectedModel: String = "base"
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                engineSection
                modelSection
                microphoneSection
                languageSection
                translationSection
                hotkeySection
                outputSection
                permissionsSection
                whisperSection
                statusSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            selectedModel = appState.modelName
            refreshDevices()
        }
        .frame(minWidth: 660, minHeight: 620)
    }
    
    private var engineSection: some View {
        settingsSection("Engine") {
            Picker("Transcription Engine", selection: $appState.transcriptionEngine) {
                Text("Whisper Local").tag("whisper")
                Text("Apple Speech Streaming").tag("appleSpeech")
            }
            
            Text("Apple Speech gives native streaming partials. Whisper remains available for local file-based transcription and higher-quality model control.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var modelSection: some View {
        settingsSection("Model") {
            Picker("Whisper Model", selection: $selectedModel) {
                ForEach(appState.availableModelsList(), id: \.name) { model in
                    Text("\(model.label) (\(model.size))").tag(model.name)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .onChange(of: selectedModel) {
                appState.modelName = selectedModel
                appState.ensureModelExists()
            }
            
            Text("For better recognition, try Small English or Medium English. Larger models are slower and need more memory.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextField("Model Path", text: $appState.modelPath)
                .textFieldStyle(.roundedBorder)
            
            Button("Browse...") {
                browseModelPath()
            }
        }
    }
    
    private var microphoneSection: some View {
        settingsSection("Microphone") {
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
    }
    
    private var languageSection: some View {
        settingsSection("Language") {
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
    }
    
    private var translationSection: some View {
        settingsSection("Translation") {
            Toggle("Enable translation", isOn: $appState.translationEnabled)
            
            Picker("Target Language", selection: $appState.translationTargetLanguage) {
                Text("English").tag("en")
                Text("Russian").tag("ru")
            }
            
            Picker("OpenAI Model", selection: $appState.openAIModel) {
                Text("GPT-4o mini").tag("gpt-4o-mini")
                Text("GPT-4.1 mini").tag("gpt-4.1-mini")
                Text("GPT-4.1 nano").tag("gpt-4.1-nano")
            }
            
            TextField("Custom OpenAI model", text: $appState.openAIModel)
                .textFieldStyle(.roundedBorder)
            
            SecureField("OpenAI API Key", text: $appState.openAIAPIKey)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Button("Validate OpenAI Key") {
                    appState.validateOpenAIKey()
                }
                
                Spacer()
                
                Text(appState.translationStatus)
                    .foregroundColor(appState.translationStatus == "OpenAI key valid" || appState.translationStatus == "Translated" ? .green : .secondary)
            }
            
            Text("Translation runs only after the final transcript is ready. Live chunks are not sent to OpenAI.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var hotkeySection: some View {
        settingsSection("Hotkey") {
            Picker("Push-to-talk", selection: $appState.triggerMode) {
                Text("Control + Space").tag("controlSpace")
                Text("Fn / Globe (experimental)").tag("fn")
            }
            
            Text(appState.hotkeyHelpText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var outputSection: some View {
        settingsSection("Text Output") {
            Picker("Insertion Mode", selection: $appState.outputMode) {
                Text("Final paste only").tag("finalOnly")
                Text("Live chunks (experimental)").tag("liveChunks")
            }
            
            Picker("Live Chunk Duration", selection: $appState.liveChunkDuration) {
                Text("1.0 sec - fastest").tag(1.0)
                Text("1.5 sec").tag(1.5)
                Text("2.0 sec - balanced").tag(2.0)
                Text("3.0 sec - accurate").tag(3.0)
            }
            
            Toggle("Show overlay while recording", isOn: $appState.showOverlay)
            Toggle("Add trailing space after paste", isOn: $appState.addTrailingSpace)
            Toggle("Restore clipboard after paste", isOn: $appState.restoreClipboard)
            
            Text("Shorter chunks feel faster but can reduce Whisper accuracy. Live chunks transcribe up to two chunks in parallel and paste them in order.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("Clipboard restore reads your clipboard and may trigger macOS privacy prompts.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var permissionsSection: some View {
        settingsSection("Permissions") {
            permissionRow("Microphone", value: appState.microphonePermissionLabel)
            permissionRow("Speech Recognition", value: appState.speechPermissionLabel)
            permissionRow("Accessibility", value: appState.accessibilityPermissionLabel)
            permissionRow("Input Monitoring", value: appState.inputMonitoringPermissionLabel)
            
            HStack {
                Button("Request Accessibility") { appState.requestAccessibilityPermission() }
                Button("Open Accessibility") { appState.openAccessibilitySettings() }
                Button("Open Input Monitoring") { appState.openInputMonitoringSettings() }
                Button("Retry Hotkey") { appState.retryHotkeyMonitor() }
            }
            
            Text("Running app: \(appState.runningBundlePath)")
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            
            Button("Reveal Running App") {
                appState.revealRunningApp()
            }
        }
    }
    
    private var whisperSection: some View {
        settingsSection("whisper.cpp") {
            Picker("Whisper Backend", selection: $appState.whisperBackend) {
                Text("CLI - reliable").tag("cli")
                Text("Server API - warm model").tag("serverAPI")
            }
            
            HStack {
                Text("Server API")
                Spacer()
                Text(appState.whisperWorkerStatus)
                    .foregroundColor(appState.whisperWorkerStatus.hasPrefix("Loaded") ? .green : .secondary)
            }
            
            Text("CLI runs whisper-cli per recording. Server API starts whisper-server and sends audio over HTTP; failures are shown explicitly and do not silently switch back to CLI.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("Log: \(appState.whisperLogPath)")
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            
            TextField("Binary Path", text: $appState.whisperBinaryPath)
                .textFieldStyle(.roundedBorder)
            
            HStack {
                Button("Browse...") {
                    browseWhisperBinary()
                }
                
                Button("Verify") {
                    verifySetup()
                }
                
                Button("Stop Server API") {
                    appState.stopWhisperServer()
                }
                
                Button("Reveal Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appState.whisperLogPath)])
                }
            }
        }
    }
    
    private var statusSection: some View {
        settingsSection("Status") {
            HStack {
                Text("Status:")
                Spacer()
                Text(appState.statusMessage)
                    .foregroundColor(statusColor)
                    .frame(width: 180, alignment: .trailing)
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
    
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func permissionRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(value == "Granted" ? .green : .orange)
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
    
    private func browseModelPath() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.modelPath = url.path
        }
    }
    
    private func browseWhisperBinary() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.executable]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.whisperBinaryPath = url.path
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
