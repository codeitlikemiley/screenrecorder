import Foundation

/// Google Gemini API client implementing the AIService protocol.
/// Uses the Gemini generateContent REST API.
///
/// Auth: `x-goog-api-key` header.
/// Images: `inlineData` with `mimeType` + base64 `data`.
/// Response: `candidates[].content.parts[].text`.
///
/// Ref: https://ai.google.dev/gemini-api/docs/image-understanding
class GeminiProvider: AIService {
    private let apiKey: String
    private let baseURL: String
    private let defaultModel: String
    private let name: String
    private let maxTokens: Int
    private let temperature: Double

    var providerName: String { name }
    var isConfigured: Bool { !apiKey.isEmpty }

    init(apiKey: String, baseURL: String = "https://generativelanguage.googleapis.com/v1beta",
         defaultModel: String = "gemini-3-flash-preview", name: String = "Google Gemini",
         maxTokens: Int = 8192, temperature: Double = 0.3) {
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

        // Build parts array (Gemini format: text first, then images)
        var parts: [[String: Any]] = [
            ["text": request.prompt]
        ]

        for imageData in request.images {
            let base64 = imageData.base64EncodedString()
            parts.append([
                "inline_data": [
                    "mime_type": "image/png",
                    "data": base64
                ]
            ])
        }

        let body: [String: Any] = [
            "contents": [
                ["parts": parts]
            ],
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": maxTokens
            ]
        ]

        // Gemini uses x-goog-api-key header
        let endpoint = "\(baseURL)/models/\(selectedModel):generateContent"
        guard let url = URL(string: endpoint) else {
            throw AIError.networkError("Invalid URL for model: \(selectedModel)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 120

        // Execute with shared HTTP client
        let data = try await AIHTTPClient.execute(urlRequest, provider: name)

        // Decode typed response
        let response = try JSONDecoder().decode(GeminiResponse.Root.self, from: data)

        // Check for blocked content
        if let blockReason = response.promptFeedback?.blockReason {
            throw AIError.apiError(statusCode: 200, message: "Content blocked: \(blockReason)")
        }

        guard let candidates = response.candidates,
              let firstCandidate = candidates.first else {
            throw AIError.parseError("Failed to parse \(name) response — no candidates")
        }

        let textParts = firstCandidate.content.parts.compactMap(\.text)

        guard !textParts.isEmpty else {
            throw AIError.parseError("No text content in \(name) response")
        }

        // Log usage
        if let usage = response.usageMetadata {
            let promptTokens = usage.promptTokenCount ?? 0
            let completionTokens = usage.candidatesTokenCount ?? 0
            print("  🤖 \(name) usage: \(promptTokens) prompt + \(completionTokens) completion tokens (\(selectedModel))")
        }

        return textParts.joined(separator: "\n")
    }
}
