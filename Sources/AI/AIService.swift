import Foundation

/// Protocol abstracting AI provider backends.
/// Implementations can target OpenAI, Anthropic, local Ollama, or Apple Intelligence.
protocol AIService {
    /// Generate a text completion from a prompt.
    /// Supports both text-only and multimodal (text + images) inputs.
    func complete(prompt: String, images: [Data], model: String?) async throws -> String

    /// Check if the service is configured and ready to use
    var isConfigured: Bool { get }

    /// Human-readable name of the provider
    var providerName: String { get }
}

extension AIService {
    /// Convenience: text-only completion
    func complete(prompt: String, model: String? = nil) async throws -> String {
        try await complete(prompt: prompt, images: [], model: model)
    }
}

/// Fallback service when no provider is configured. Always throws.
class DummyAIService: AIService {
    var providerName: String { "Not Configured" }
    var isConfigured: Bool { false }
    func complete(prompt: String, images: [Data], model: String?) async throws -> String {
        throw AIError.notConfigured("No AI provider configured. Add one in Settings → AI Providers.")
    }
}
