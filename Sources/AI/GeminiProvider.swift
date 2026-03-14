import Foundation

/// Google Gemini API client implementing the AIService protocol.
/// Uses the Gemini generateContent REST API.
///
/// Auth: `x-goog-api-key` header (NOT bearer token, NOT URL parameter).
/// Images: `inlineData` with `mimeType` + base64 `data`.
/// Response: `candidates[].content.parts[].text`.
///
/// Ref: https://ai.google.dev/gemini-api/docs/image-understanding
class GeminiProvider: AIService {
    private let apiKey: String
    private let baseURL: String
    private let defaultModel: String

    var providerName: String { "Google Gemini" }
    var isConfigured: Bool { !apiKey.isEmpty }

    init(apiKey: String, baseURL: String = "https://generativelanguage.googleapis.com/v1beta", defaultModel: String = "gemini-3-flash-preview") {
        self.apiKey = apiKey
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.defaultModel = defaultModel
    }

    // MARK: - AIService

    func complete(prompt: String, images: [Data], model: String?) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIError.notConfigured("Google Gemini API key not set.")
        }

        let selectedModel = model ?? defaultModel

        // Build parts array (Gemini format)
        var parts: [[String: Any]] = []

        // Add text prompt first
        parts.append(["text": prompt])

        // Add images as inline data (Gemini supports: PNG, JPEG, WEBP, HEIC, HEIF)
        for imageData in images {
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
                [
                    "parts": parts
                ]
            ],
            "generationConfig": [
                "temperature": 0.3,
                "maxOutputTokens": 8192
            ]
        ]

        // Gemini uses x-goog-api-key header for authentication
        let endpoint = "\(baseURL)/models/\(selectedModel):generateContent"
        guard let url = URL(string: endpoint) else {
            throw AIError.networkError("Invalid URL for model: \(selectedModel)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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
            if httpResponse.statusCode == 400 && (errorBody.contains("API_KEY") || errorBody.contains("API key")) {
                throw AIError.notConfigured("Invalid Google Gemini API key")
            }
            if httpResponse.statusCode == 403 {
                throw AIError.notConfigured("Google Gemini API key doesn't have access to model: \(selectedModel)")
            }
            if httpResponse.statusCode == 429 {
                throw AIError.rateLimited
            }
            throw AIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Parse Gemini response format
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let responseParts = content["parts"] as? [[String: Any]] else {
            // Check for blocked content
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let promptFeedback = json["promptFeedback"] as? [String: Any],
               let blockReason = promptFeedback["blockReason"] as? String {
                throw AIError.apiError(statusCode: 200, message: "Content blocked: \(blockReason)")
            }
            throw AIError.parseError("Failed to parse Gemini response")
        }

        // Extract text from parts
        let textParts = responseParts.compactMap { $0["text"] as? String }

        guard !textParts.isEmpty else {
            throw AIError.parseError("No text content in Gemini response")
        }

        // Log usage
        if let usageMetadata = json["usageMetadata"] as? [String: Any] {
            let promptTokens = usageMetadata["promptTokenCount"] as? Int ?? 0
            let completionTokens = usageMetadata["candidatesTokenCount"] as? Int ?? 0
            print("  🤖 Gemini usage: \(promptTokens) prompt + \(completionTokens) completion tokens (\(selectedModel))")
        }

        return textParts.joined(separator: "\n")
    }
}
