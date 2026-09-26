import Foundation

// MARK: - AI Request

/// Unified request model for all AI providers.
struct AIRequest {
    let prompt: String
    let images: [Data]
    /// Optional caption sent immediately before each image (same count as `images`),
    /// so the model can tie every picture to what the prompt says about it.
    let imageLabels: [String]
    let model: String?

    init(prompt: String, images: [Data] = [], imageLabels: [String] = [], model: String? = nil) {
        self.prompt = prompt
        self.images = images
        self.imageLabels = imageLabels
        self.model = model
    }

    /// Label for image `index`, if one was provided.
    func label(forImageAt index: Int) -> String? {
        index < imageLabels.count ? imageLabels[index] : nil
    }

    /// MIME type sniffed from the image bytes (providers reject mislabelled data).
    static func mimeType(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return "image/png"
    }
}

// MARK: - AI Service Protocol

/// Protocol abstracting AI provider backends.
/// Implementations target OpenAI, Anthropic, Gemini, or any compatible API.
protocol AIService {
    /// Generate a text completion from a request.
    func complete(_ request: AIRequest) async throws -> String

    /// Check if the service is configured and ready to use.
    var isConfigured: Bool { get }

    /// Human-readable name of the provider.
    var providerName: String { get }
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

// MARK: - Shared HTTP Helper

/// Shared HTTP execution with error handling and retry logic.
/// Eliminates ~15 lines of duplicated boilerplate per provider.
enum AIHTTPClient {
    /// Execute an AI API request with automatic retry on rate-limit (429).
    /// - Parameters:
    ///   - request: The configured URLRequest
    ///   - provider: Provider name for error messages
    ///   - maxRetries: Max retry attempts on 429 (default: 1)
    /// - Returns: Raw response data on success
    static func execute(
        _ request: URLRequest,
        provider: String,
        maxRetries: Int = 1
    ) async throws -> Data {
        var lastError: Error?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                // Exponential backoff: 2s, 4s, ...
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                print("  🔄 \(provider): Retry attempt \(attempt) after rate limit...")
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIError.networkError("Invalid response")
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"

                switch httpResponse.statusCode {
                case 401:
                    throw AIError.notConfigured("Invalid \(provider) API key")
                case 403:
                    throw AIError.notConfigured("\(provider) API key lacks access — \(errorBody)")
                case 429:
                    lastError = AIError.rateLimited
                    continue // retry
                default:
                    throw AIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
                }
            }

            return data
        }

        throw lastError ?? AIError.rateLimited
    }
}

// MARK: - Codable Response Models

/// OpenAI chat/completions response format.
/// Used by: OpenAI, DeepSeek, Qwen, MiniMax (OpenAI mode), Kimi (OpenAI mode), GLM.
enum OpenAIResponse {
    struct Root: Decodable {
        let choices: [Choice]
        let usage: Usage?
    }
    struct Choice: Decodable {
        let message: Message
    }
    struct Message: Decodable {
        let content: String
    }
    struct Usage: Decodable {
        let prompt_tokens: Int
        let completion_tokens: Int
    }
}

/// Anthropic messages response format.
/// Used by: Anthropic, MiniMax (Anthropic mode), Kimi (Anthropic mode).
enum AnthropicResponse {
    struct Root: Decodable {
        let content: [ContentBlock]
        let usage: Usage?
    }
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    struct Usage: Decodable {
        let input_tokens: Int
        let output_tokens: Int
    }
}

/// Google Gemini generateContent response format.
enum GeminiResponse {
    struct Root: Decodable {
        let candidates: [Candidate]?
        let usageMetadata: UsageMetadata?
        let promptFeedback: PromptFeedback?
    }
    struct Candidate: Decodable {
        let content: Content
    }
    struct Content: Decodable {
        let parts: [Part]
    }
    struct Part: Decodable {
        let text: String?
    }
    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
    }
    struct PromptFeedback: Decodable {
        let blockReason: String?
    }
}
