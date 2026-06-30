#if OPENWHISP_INSTRUMENTATION
import SwiftUI

// MARK: - LLM Lab (dev-only)
//
// In-app A/B harness for built-in refinement models. Pick a model, download it,
// then "Run all cases" to see per-case output + latency through the REAL
// refinement path (LLMBenchRunner → OpenAITranslationService → loopback
// llama-server). Compiled in ONLY under OPENWHISP_INSTRUMENTATION.
struct LLMLabView: View {
    @ObservedObject var appState: AppState
    @StateObject private var lab = LLMLabModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare built-in refinement models on quality + speed. Dev-only.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Model", selection: $lab.selectedModelID) {
                ForEach(appState.bundledLLMModelsList(), id: \.id) { m in
                    Text("\(m.label) · \(m.size)").tag(m.id)
                }
            }

            HStack {
                if appState.isLLMModelDownloadingForLab(lab.selectedModelID) {
                    ProgressView(value: appState.llmModelDownloadProgress ?? 0).frame(width: 120)
                    Text(appState.llmModelDownloadStatus).font(.caption).foregroundColor(.secondary)
                } else if appState.isBundledModelInstalled(lab.selectedModelID) {
                    Button(lab.isRunning ? "Running…" : "Run all cases") {
                        lab.run(appState: appState)
                    }
                    .disabled(lab.isRunning)
                } else {
                    Button("Download model") {
                        appState.bundledLLMModel = lab.selectedModelID
                        appState.ensureLLMModelExists()
                    }
                }
                Spacer()
                if lab.coldStartMs > 0 {
                    Text("cold \(lab.coldStartMs)ms · median \(lab.medianMs)ms")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }

            if let err = lab.errorText {
                Text(err).font(.caption).foregroundColor(.orange)
            }

            ForEach(lab.results) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text("[\(r.category)] \(r.id) — \(r.latencyMs)ms")
                        .font(.caption.bold())
                    Text("IN:  \(r.input)").font(.caption2).foregroundColor(.secondary)
                    Text("OUT: \(r.output)").font(.caption2)
                }
                .padding(.vertical, 2)
                Divider()
            }
        }
    }
}

@MainActor
final class LLMLabModel: ObservableObject {
    @Published var selectedModelID = "qwen2.5-0.5b-instruct"
    @Published var isRunning = false
    @Published var results: [LLMBenchCaseResult] = []
    @Published var coldStartMs = 0
    @Published var medianMs = 0
    @Published var errorText: String?

    private var runner: LLMBenchRunner?

    func run(appState: AppState) {
        results = []
        errorText = nil
        coldStartMs = 0
        isRunning = true
        let cases = LLMBenchRunner.loadCases()
        guard !cases.isEmpty else {
            errorText = "No bench cases found (Resources/bench/refinement-cases.json)."
            isRunning = false
            return
        }
        let modelPath = appState.bundledModelPath(selectedModelID)
        let runner = LLMBenchRunner()
        self.runner = runner
        runner.run(
            modelID: selectedModelID,
            modelPath: modelPath,
            cases: cases,
            progress: { [weak self] r in self?.results.append(r) },
            completion: { [weak self] result in
                guard let self else { return }
                self.isRunning = false
                switch result {
                case .success(let model):
                    self.coldStartMs = model.coldStartMs
                    self.medianMs = model.medianLatencyMs
                case .failure(let error):
                    self.errorText = error.localizedDescription
                }
                runner.stop()
                self.runner = nil
            }
        )
    }
}
#endif
