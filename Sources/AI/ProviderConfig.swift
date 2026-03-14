import Foundation

// MARK: - Provider Type

/// The type of AI provider backend.
enum ProviderType: String, Codable, CaseIterable, Identifiable {
    case openai
    case anthropic
    case gemini
    case openaiCompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openaiCompatible: return "OpenAI Compatible"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openaiCompatible: return ""
        }
    }

    var defaultModels: [String] {
        switch self {
        case .openai:
            return ["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini", "o4-mini"]
        case .anthropic:
            return ["claude-sonnet-4-20250514", "claude-haiku-3.5-20241022", "claude-opus-4-20250514"]
        case .gemini:
            return ["gemini-3-flash-preview", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite-preview", "gemini-2.5-flash", "gemini-2.5-pro"]
        case .openaiCompatible:
            return []
        }
    }

    var icon: String {
        switch self {
        case .openai: return "brain.head.profile"
        case .anthropic: return "sparkles"
        case .gemini: return "diamond"
        case .openaiCompatible: return "network"
        }
    }
}

// MARK: - Provider Preset

/// Quick-add presets for OpenAI-compatible providers.
struct ProviderPreset: Identifiable {
    let id: String
    let name: String
    let baseURL: String
    let models: [String]
    let providerType: ProviderType

    static let builtIn: [ProviderPreset] = [
        // Native providers
        ProviderPreset(
            id: "openai", name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            models: ProviderType.openai.defaultModels,
            providerType: .openai
        ),
        ProviderPreset(
            id: "anthropic", name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            models: ProviderType.anthropic.defaultModels,
            providerType: .anthropic
        ),
        ProviderPreset(
            id: "gemini", name: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            models: ProviderType.gemini.defaultModels,
            providerType: .gemini
        ),
        // OpenAI-compatible presets
        ProviderPreset(
            id: "qwen", name: "Alibaba Qwen",
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            models: ["qwen3.5-plus", "qwen3-max", "qwen3-coder-plus", "qwen3-coder-next"],
            providerType: .openaiCompatible
        ),
        ProviderPreset(
            id: "deepseek", name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            models: ["deepseek-chat", "deepseek-reasoner"],
            providerType: .openaiCompatible
        ),
        ProviderPreset(
            id: "minimax", name: "MiniMax",
            baseURL: "https://api.minimax.chat/v1",
            models: ["MiniMax-M2.5"],
            providerType: .openaiCompatible
        ),
        ProviderPreset(
            id: "glm", name: "GLM / Zhipu",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            models: ["glm-5", "glm-4-plus"],
            providerType: .openaiCompatible
        ),
    ]
}

// MARK: - API Key Entry

/// A single API key entry with a label and Keychain reference.
struct APIKeyEntry: Codable, Identifiable {
    let id: String
    var label: String

    /// Keychain service name for this key
    var keychainService: String

    init(label: String = "Default") {
        self.id = UUID().uuidString
        self.label = label
        self.keychainService = "com.vibetrace.apikey.\(id)"
    }
}

// MARK: - Provider Config

/// Configuration for a single AI provider instance.
struct ProviderConfig: Codable, Identifiable {
    let id: String
    var providerType: ProviderType
    var displayName: String
    var baseURL: String
    var apiKeys: [APIKeyEntry]
    var activeKeyIndex: Int
    var selectedModel: String
    var availableModels: [String]
    var isEnabled: Bool

    /// Create a new provider from a preset.
    static func from(preset: ProviderPreset) -> ProviderConfig {
        ProviderConfig(
            id: UUID().uuidString,
            providerType: preset.providerType,
            displayName: preset.name,
            baseURL: preset.baseURL,
            apiKeys: [],
            activeKeyIndex: 0,
            selectedModel: preset.models.first ?? "",
            availableModels: preset.models,
            isEnabled: true
        )
    }

    /// Create a custom OpenAI-compatible provider.
    static func custom(name: String, baseURL: String, models: [String]) -> ProviderConfig {
        ProviderConfig(
            id: UUID().uuidString,
            providerType: .openaiCompatible,
            displayName: name,
            baseURL: baseURL,
            apiKeys: [],
            activeKeyIndex: 0,
            selectedModel: models.first ?? "",
            availableModels: models,
            isEnabled: true
        )
    }

    /// The active API key's Keychain service, if available.
    var activeKeychainService: String? {
        guard activeKeyIndex >= 0 && activeKeyIndex < apiKeys.count else { return nil }
        return apiKeys[activeKeyIndex].keychainService
    }

    /// Whether this provider has at least one configured API key.
    var hasKeys: Bool {
        !apiKeys.isEmpty
    }
}
