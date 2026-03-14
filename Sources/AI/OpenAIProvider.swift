import Foundation

/// OpenAI API client implementing the AIService protocol.
/// Also serves as the base for all OpenAI-compatible providers (Qwen, DeepSeek, MiniMax, GLM).
class OpenAIProvider: AIService {
    private let apiKey: String
    private let baseURL: String
    private let defaultModel: String
    private let name: String

    var providerName: String { name }

    var isConfigured: Bool { !apiKey.isEmpty }

    init(apiKey: String, baseURL: String = "https://api.openai.com/v1", defaultModel: String = "gpt-4o", name: String = "OpenAI") {
        self.apiKey = apiKey
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.defaultModel = defaultModel
        self.name = name
    }

    // MARK: - AIService

    func complete(prompt: String, images: [Data], model: String?) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIError.notConfigured("\(name) API key not set.")
        }

        let selectedModel = model ?? defaultModel

        // Build messages
        var contentParts: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]

        // Add images as base64 (for multimodal models)
        for imageData in images {
            let base64 = imageData.base64EncodedString()
            contentParts.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/png;base64,\(base64)",
                    "detail": "low"
                ]
            ])
        }

        let body: [String: Any] = [
            "model": selectedModel,
            "messages": [
                [
                    "role": "user",
                    "content": contentParts
                ]
            ],
            "temperature": 0.3,
            "max_tokens": 4096
        ]

        // Build request
        let endpoint = "\(baseURL)/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw AIError.networkError("Invalid URL: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        // Execute request
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 401 {
                throw AIError.notConfigured("Invalid \(name) API key")
            }
            if httpResponse.statusCode == 429 {
                throw AIError.rateLimited
            }
            throw AIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.parseError("Failed to parse \(name) response")
        }

        // Log usage
        if let usage = json["usage"] as? [String: Any],
           let promptTokens = usage["prompt_tokens"] as? Int,
           let completionTokens = usage["completion_tokens"] as? Int {
            print("  🤖 \(name) usage: \(promptTokens) prompt + \(completionTokens) completion tokens (\(selectedModel))")
        }

        return content
    }
}

// MARK: - AI Errors

enum AIError: LocalizedError {
    case notConfigured(String)
    case networkError(String)
    case rateLimited
    case apiError(statusCode: Int, message: String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): return msg
        case .networkError(let msg): return "Network error: \(msg)"
        case .rateLimited: return "Rate limited — please wait a moment and try again"
        case .apiError(let code, let msg): return "API error (\(code)): \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}
