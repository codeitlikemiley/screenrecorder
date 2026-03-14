import Foundation

/// Anthropic Claude API client implementing the AIService protocol.
/// Uses the Messages API format which differs from OpenAI's chat completions.
class AnthropicProvider: AIService {
    private let apiKey: String
    private let baseURL: String
    private let defaultModel: String

    var providerName: String { "Anthropic" }
    var isConfigured: Bool { !apiKey.isEmpty }

    init(apiKey: String, baseURL: String = "https://api.anthropic.com/v1", defaultModel: String = "claude-sonnet-4-20250514") {
        self.apiKey = apiKey
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.defaultModel = defaultModel
    }

    // MARK: - AIService

    func complete(prompt: String, images: [Data], model: String?) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIError.notConfigured("Anthropic API key not set.")
        }

        let selectedModel = model ?? defaultModel

        // Build content blocks
        var contentBlocks: [[String: Any]] = []

        // Add images first (Anthropic wants images before text)
        for imageData in images {
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

        // Add text
        contentBlocks.append([
            "type": "text",
            "text": prompt
        ])

        let body: [String: Any] = [
            "model": selectedModel,
            "messages": [
                [
                    "role": "user",
                    "content": contentBlocks
                ]
            ],
            "max_tokens": 4096,
            "temperature": 0.3
        ]

        // Build request — Anthropic uses different auth header
        let endpoint = "\(baseURL)/messages"
        guard let url = URL(string: endpoint) else {
            throw AIError.networkError("Invalid URL: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
                throw AIError.notConfigured("Invalid Anthropic API key")
            }
            if httpResponse.statusCode == 429 {
                throw AIError.rateLimited
            }
            throw AIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Parse Anthropic response format
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AIError.parseError("Failed to parse Anthropic response")
        }

        // Extract text from content blocks
        let textBlocks = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }

        guard !textBlocks.isEmpty else {
            throw AIError.parseError("No text content in Anthropic response")
        }

        // Log usage
        if let usage = json["usage"] as? [String: Any],
           let inputTokens = usage["input_tokens"] as? Int,
           let outputTokens = usage["output_tokens"] as? Int {
            print("  🤖 Anthropic usage: \(inputTokens) input + \(outputTokens) output tokens (\(selectedModel))")
        }

        return textBlocks.joined(separator: "\n")
    }
}
