import Foundation

// MARK: - Provider Type (API Protocol)

/// The API protocol used to communicate with the AI provider.
/// This is NOT the vendor — it's the wire format. MiniMax can be `.openai` or `.anthropic`.
enum ProviderType: String, Codable, CaseIterable, Identifiable {
    case openai      // OpenAI chat/completions format (Bearer auth)
    case anthropic   // Anthropic messages format (x-api-key auth)
    case gemini      // Google Gemini generateContent format (x-goog-api-key auth)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI Protocol"
        case .anthropic: return "Anthropic Protocol"
        case .gemini: return "Gemini Protocol"
        }
    }

    var icon: String {
        switch self {
        case .openai: return "brain.head.profile"
        case .anthropic: return "sparkles"
        case .gemini: return "diamond"
        }
    }
}

// MARK: - Provider Preset

/// Quick-start templates that pre-fill a profile. Users can edit everything after.
struct ProviderPreset: Identifiable {
    let id: String
    let name: String
    let baseURL: String
    let models: [String]
    let providerType: ProviderType
    let defaultMaxTokens: Int
    let defaultTemperature: Double

    init(id: String, name: String, baseURL: String, models: [String], providerType: ProviderType,
         maxTokens: Int = 4096, temperature: Double = 0.3) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.providerType = providerType
        self.defaultMaxTokens = maxTokens
        self.defaultTemperature = temperature
    }

    static let builtIn: [ProviderPreset] = [
        // ── OpenAI Protocol ─────────────────────────────────────────
        ProviderPreset(
            id: "openai", name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini", "o4-mini"],
            providerType: .openai
        ),
        ProviderPreset(
            id: "qwen", name: "Alibaba Qwen",
            baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            models: ["qwen3.5-plus", "qwen3-max", "qwen3-coder-plus", "qwen3-coder-next"],
            providerType: .openai
        ),
        ProviderPreset(
            id: "deepseek", name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            models: ["deepseek-chat", "deepseek-reasoner"],
            providerType: .openai
        ),
        ProviderPreset(
            id: "minimax-openai", name: "MiniMax",
            baseURL: "https://api.minimax.chat/v1",
            models: ["MiniMax-M2.5", "MiniMax-M2.5-highspeed"],
            providerType: .openai
        ),
        ProviderPreset(
            id: "moonshot-openai", name: "Moonshot AI (Kimi)",
            baseURL: "https://api.moonshot.ai/v1",
            models: ["kimi-k2.5", "kimi-k2-0905-preview", "kimi-k2-thinking"],
            providerType: .openai
        ),
        ProviderPreset(
            id: "glm", name: "GLM / Zhipu",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            models: ["glm-5", "glm-4-plus"],
            providerType: .openai
        ),
        // ── Anthropic Protocol ──────────────────────────────────────
        ProviderPreset(
            id: "anthropic", name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            models: ["claude-sonnet-4-20250514", "claude-haiku-3.5-20241022", "claude-opus-4-20250514"],
            providerType: .anthropic
        ),
        ProviderPreset(
            id: "minimax-anthropic", name: "MiniMax",
            baseURL: "https://api.minimax.io/anthropic",
            models: ["MiniMax-M2.5", "MiniMax-M2.5-highspeed"],
            providerType: .anthropic
        ),
        ProviderPreset(
            id: "moonshot-anthropic", name: "Moonshot AI (Kimi)",
            baseURL: "https://api.moonshot.ai/anthropic",
            models: ["kimi-k2.5", "kimi-k2-0905-preview", "kimi-k2-thinking"],
            providerType: .anthropic
        ),
        // ── Gemini Protocol ─────────────────────────────────────────
        ProviderPreset(
            id: "gemini", name: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            models: ["gemini-3-flash-preview", "gemini-3.1-pro-preview", "gemini-3.1-flash-lite-preview", "gemini-2.5-flash", "gemini-2.5-pro"],
            providerType: .gemini, maxTokens: 8192
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

// MARK: - Provider Config (Profile)

/// A fully user-configurable AI provider profile.
/// Presets pre-fill these values; the user can change everything.
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
    var maxTokens: Int
    var temperature: Double

    /// Create a profile from a preset (user can edit everything after).
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
            isEnabled: true,
            maxTokens: preset.defaultMaxTokens,
            temperature: preset.defaultTemperature
        )
    }

    /// Create a blank profile for a given API protocol.
    static func blank(type: ProviderType) -> ProviderConfig {
        ProviderConfig(
            id: UUID().uuidString,
            providerType: type,
            displayName: "Custom Provider",
            baseURL: "",
            apiKeys: [],
            activeKeyIndex: 0,
            selectedModel: "",
            availableModels: [],
            isEnabled: true,
            maxTokens: 4096,
            temperature: 0.3
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
