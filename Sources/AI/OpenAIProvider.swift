import Foundation

/// OpenAI API client implementing the AIService protocol.
/// Also serves as the base for all OpenAI-protocol providers (Qwen, DeepSeek, MiniMax, Kimi, GLM).
class OpenAIProvider: AIService {
    private let apiKey: String
    private let baseURL: String
    private let defaultModel: String
    private let name: String
    private let maxTokens: Int
    private let temperature: Double

    var providerName: String { name }
    var isConfigured: Bool { !apiKey.isEmpty }

    init(apiKey: String, baseURL: String = "https://api.openai.com/v1", defaultModel: String = "gpt-4o",
         name: String = "OpenAI", maxTokens: Int = 4096, temperature: Double = 0.3) {
        self.apiKey = apiKey
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.defaultModel = defaultModel
        self.name = name
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    // MARK: - AIService

    func complete(_ request: AIRequest) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIError.notConfigured("\(name) API key not set.")
        }

        let selectedModel = request.model ?? defaultModel

        // Build content parts
        var contentParts: [[String: Any]] = [
            ["type": "text", "text": request.prompt]
        ]

        for imageData in request.images {
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
                ["role": "user", "content": contentParts]
            ],
            "temperature": temperature,
            "max_tokens": maxTokens
        ]

        // Build request
        let endpoint = "\(baseURL)/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw AIError.networkError("Invalid URL: \(endpoint)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120

        // Execute with shared HTTP client (handles retries + error mapping)
        let data = try await AIHTTPClient.execute(urlRequest, provider: name)

        // Decode typed response
        let response = try JSONDecoder().decode(OpenAIResponse.Root.self, from: data)

        guard let content = response.choices.first?.message.content else {
            throw AIError.parseError("Failed to parse \(name) response — no choices")
        }

        // Log usage
        if let usage = response.usage {
            print("  🤖 \(name) usage: \(usage.prompt_tokens) prompt + \(usage.completion_tokens) completion tokens (\(selectedModel))")
        }

        return content
    }
}
