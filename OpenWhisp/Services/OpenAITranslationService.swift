import Foundation

// MARK: - LLM Text Service (OpenAI-compatible)

/// Where chat-completion requests go. Both OpenAI and local servers
/// (llama.cpp `llama-server`, Ollama) speak the same `/v1/chat/completions`
/// shape, so one client serves both — the only differences are the base URL
/// and whether a bearer key is sent.
struct LLMEndpoint {
    /// Base URL up to and including `/v1` (no trailing slash), e.g.
    /// "https://api.openai.com/v1" or "http://localhost:8080/v1".
    var baseURL: String
    /// Bearer key. Empty/absent for most local servers.
    var apiKey: String
    /// Whether a key is required (OpenAI: yes, local: no).
    var requiresKey: Bool

    static let openAI = LLMEndpoint(
        baseURL: "https://api.openai.com/v1",
        apiKey: "",
        requiresKey: true
    )

    var chatCompletionsURL: URL? { URL(string: "\(baseURL)/chat/completions") }
    func modelURL(_ model: String) -> URL? {
        guard let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(baseURL)/models/\(encoded)")
    }
    var modelsURL: URL? { URL(string: "\(baseURL)/models") }
}

final class OpenAITranslationService {
    enum TranslationError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case emptyResponse
        case apiError(String)
        case noTranslation

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "API key is missing."
            case .invalidURL:
                return "The LLM API URL is invalid."
            case .emptyResponse:
                return "The LLM returned an empty response."
            case .apiError(let message):
                return message
            case .noTranslation:
                return "The LLM did not return any text."
            }
        }
    }

    /// Validate connectivity/credentials. For OpenAI this checks a specific
    /// model; for local servers it just confirms the /models endpoint responds.
    func validate(endpoint: LLMEndpoint, model: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let key = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.requiresKey, key.isEmpty {
            completion(.failure(TranslationError.missingAPIKey))
            return
        }
        // For OpenAI, probe the specific model; for local, probe /models (more
        // servers support that than a per-model GET).
        let url = endpoint.requiresKey ? endpoint.modelURL(model) : endpoint.modelsURL
        guard let url else {
            completion(.failure(TranslationError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(TranslationError.emptyResponse))
                return
            }
            if (200..<300).contains(http.statusCode) {
                completion(.success(()))
                return
            }
            completion(.failure(TranslationError.apiError(Self.errorMessage(from: data, fallback: "Validation failed with HTTP \(http.statusCode)."))))
        }.resume()
    }

    /// Backward-compatible OpenAI shim used by older call sites.
    func validate(apiKey: String, model: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var ep = LLMEndpoint.openAI
        ep.apiKey = apiKey
        validate(endpoint: ep, model: model, completion: completion)
    }

    /// Run a chat-completion transform. `customInstruction`, when non-nil,
    /// overrides the mode-derived system prompt (used by voice commands).
    func processFinalText(
        text: String,
        mode: String,
        targetLanguage: String,
        endpoint: LLMEndpoint,
        model: String,
        customInstruction: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let key = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.requiresKey, key.isEmpty {
            completion(.failure(TranslationError.missingAPIKey))
            return
        }
        guard let url = endpoint.chatCompletionsURL else {
            completion(.failure(TranslationError.invalidURL))
            return
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = customInstruction ?? instructionForMode(mode, targetLanguage: targetLanguage)
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only default to an OpenAI model name for the OpenAI endpoint; a local
        // server with an empty model field should receive "" and use its default.
        let modelToSend = resolvedModel.isEmpty && endpoint.requiresKey ? "gpt-4o-mini" : resolvedModel
        let body = ChatCompletionRequest(
            model: modelToSend,
            temperature: 0.0,
            messages: [
                Message(role: "system", content: instruction),
                Message(role: "user", content: trimmedText)
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(TranslationError.emptyResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(TranslationError.apiError(Self.errorMessage(from: data, fallback: "LLM post-processing failed with HTTP \(http.statusCode)."))))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                let processedText = decoded.choices.first?.message.content
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !processedText.isEmpty else {
                    completion(.failure(TranslationError.noTranslation))
                    return
                }
                completion(.success(processedText))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// Backward-compatible OpenAI shim (key-based).
    func processFinalText(
        text: String,
        mode: String,
        targetLanguage: String,
        apiKey: String,
        model: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var ep = LLMEndpoint.openAI
        ep.apiKey = apiKey
        processFinalText(
            text: text,
            mode: mode,
            targetLanguage: targetLanguage,
            endpoint: ep,
            model: model,
            completion: completion
        )
    }

    private func instructionForMode(_ mode: String, targetLanguage: String) -> String {
        switch mode {
        case "rephrase":
            return "Rephrase the user's text to sound natural, clear, and concise. Keep the original language, meaning, names, URLs, code, and formatting. Return only the rewritten text."
        default:
            let target = targetLanguageName(targetLanguage)
            return "Polish the user's locally translated text in \(target). Make it natural and fluent while preserving meaning, tone, punctuation, names, URLs, code, and formatting. Return only the improved text."
        }
    }

    private func targetLanguageName(_ code: String) -> String {
        switch code {
        case "ru": return "Russian"
        case "en": return "English"
        default: return "English"
        }
    }

    private static func errorMessage(from data: Data?, fallback: String) -> String {
        guard let data else { return fallback }
        if let decoded = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            return decoded.error.message
        }
        return String(data: data, encoding: .utf8) ?? fallback
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let temperature: Double
    let messages: [Message]
}

private struct Message: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }
}

private struct OpenAIErrorResponse: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
    }
}
