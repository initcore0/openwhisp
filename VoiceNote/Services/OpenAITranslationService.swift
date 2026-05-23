import Foundation

// MARK: - OpenAI Text Service

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
                return "OpenAI API key is missing."
            case .invalidURL:
                return "OpenAI API URL is invalid."
            case .emptyResponse:
                return "OpenAI returned an empty response."
            case .apiError(let message):
                return message
            case .noTranslation:
                return "OpenAI did not return text."
            }
        }
    }
    
    func validate(apiKey: String, model: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            completion(.failure(TranslationError.missingAPIKey))
            return
        }
        guard let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.openai.com/v1/models/\(encodedModel)") else {
            completion(.failure(TranslationError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        
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
            
            completion(.failure(TranslationError.apiError(Self.errorMessage(from: data, fallback: "OpenAI validation failed with HTTP \(http.statusCode)."))))
        }.resume()
    }
    
    func processFinalText(
        text: String,
        mode: String,
        targetLanguage: String,
        apiKey: String,
        model: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            completion(.failure(TranslationError.missingAPIKey))
            return
        }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(.failure(TranslationError.invalidURL))
            return
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = instructionForMode(mode, targetLanguage: targetLanguage)
        let body = ChatCompletionRequest(
            model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-4o-mini" : model,
            temperature: 0.0,
            messages: [
                Message(
                    role: "system",
                    content: instruction
                ),
                Message(role: "user", content: trimmedText)
            ]
        )
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
                completion(.failure(TranslationError.apiError(Self.errorMessage(from: data, fallback: "OpenAI post-processing failed with HTTP \(http.statusCode)."))))
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

    func translate(
        text: String,
        targetLanguage: String,
        apiKey: String,
        model: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        processFinalText(
            text: text,
            mode: "improveTranslation",
            targetLanguage: targetLanguage,
            apiKey: apiKey,
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
