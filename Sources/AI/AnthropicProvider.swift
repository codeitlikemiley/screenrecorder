import Foundation

/// Anthropic API client implementing the AIService protocol.
/// Uses the Messages API format. Also serves as the base for all
/// Anthropic-protocol providers (MiniMax, Kimi, GLM via opencode.ai).
class AnthropicProvider: AIService {
    private let apiKey: String
    private let baseURL: String
    private let defaultModel: String
    private let name: String
    private let maxTokens: Int
    private let temperature: Double

    var providerName: String { name }
    var isConfigured: Bool { !apiKey.isEmpty }

    init(apiKey: String, baseURL: String = "https://api.anthropic.com/v1", defaultModel: String = "claude-sonnet-4-20250514",
         name: String = "Anthropic", maxTokens: Int = 4096, temperature: Double = 0.3) {
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

        // Build content blocks (Anthropic wants images before text)
        var contentBlocks: [[String: Any]] = []

        for imageData in request.images {
            let base64 = imageData.base64EncodedString()
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": base64
                ]
            ])
        }

        contentBlocks.append([
            "type": "text",
            "text": request.prompt
        ])

        let body: [String: Any] = [
            "model": selectedModel,
            "messages": [
                ["role": "user", "content": contentBlocks]
            ],
            "max_tokens": maxTokens,
            "temperature": temperature
        ]

        // Build request — Anthropic uses x-api-key header
        let endpoint = "\(baseURL)/messages"
        guard let url = URL(string: endpoint) else {
            throw AIError.networkError("Invalid URL: \(endpoint)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120

        // Execute with shared HTTP client
        let data = try await AIHTTPClient.execute(urlRequest, provider: name)

        // Decode typed response
        let response = try JSONDecoder().decode(AnthropicResponse.Root.self, from: data)

        let textBlocks = response.content.compactMap { $0.type == "text" ? $0.text : nil }

        guard !textBlocks.isEmpty else {
            throw AIError.parseError("No text content in \(name) response")
        }

        // Log usage
        if let usage = response.usage {
            print("  🤖 \(name) usage: \(usage.input_tokens) input + \(usage.output_tokens) output tokens (\(selectedModel))")
        }

        return textBlocks.joined(separator: "\n")
    }
}
