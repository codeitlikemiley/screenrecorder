import Foundation
import Combine
import Security

/// Manages all AI provider configurations, key rotation, and persistence.
/// Replaces AIConfiguration as the single source of truth for AI settings.
@MainActor
class AIProviderManager: ObservableObject {
    static let shared = AIProviderManager()

    // MARK: - Published State

    @Published var providers: [ProviderConfig] = []
    @Published var activeProviderId: String?
    @Published var isAIEnabled: Bool = true

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Paths

    private var configDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VibeTrace", isDirectory: true)
    }

    private var configFile: URL {
        configDirectory.appendingPathComponent("providers.json")
    }

    // MARK: - Init

    private init() {
        loadConfig()
        setupPersistence()
        migrateFromLegacy()
    }

    // MARK: - Active Provider

    /// The currently active provider config.
    var activeProvider: ProviderConfig? {
        guard let id = activeProviderId else {
            return providers.first(where: { $0.isEnabled && $0.hasKeys })
        }
        return providers.first(where: { $0.id == id })
    }

    /// Create an AIService instance for the active provider.
    func makeService() -> AIService? {
        guard let provider = activeProvider else { return nil }
        return makeService(for: provider)
    }

    /// Create an AIService instance for a specific provider.
    func makeService(for provider: ProviderConfig) -> AIService? {
        guard let apiKey = loadAPIKey(for: provider) else { return nil }

        switch provider.providerType {
        case .openai:
            return OpenAIProvider(
                apiKey: apiKey,
                baseURL: provider.baseURL,
                defaultModel: provider.selectedModel,
                name: provider.displayName,
                maxTokens: provider.maxTokens,
                temperature: provider.temperature
            )
        case .anthropic:
            return AnthropicProvider(
                apiKey: apiKey,
                baseURL: provider.baseURL,
                defaultModel: provider.selectedModel,
                name: provider.displayName,
                maxTokens: provider.maxTokens,
                temperature: provider.temperature
            )
        case .gemini:
            return GeminiProvider(
                apiKey: apiKey,
                baseURL: provider.baseURL,
                defaultModel: provider.selectedModel,
                name: provider.displayName,
                maxTokens: provider.maxTokens,
                temperature: provider.temperature
            )
        }
    }

    // MARK: - Provider Management

    func addProvider(_ config: ProviderConfig) {
        providers.append(config)
        if activeProviderId == nil {
            activeProviderId = config.id
        }
        saveConfig()
    }

    func updateProvider(_ config: ProviderConfig) {
        guard let index = providers.firstIndex(where: { $0.id == config.id }) else { return }
        providers[index] = config
        saveConfig()
    }

    func removeProvider(id: String) {
        // Delete all API keys from Keychain
        if let provider = providers.first(where: { $0.id == id }) {
            for key in provider.apiKeys {
                deleteKeyFromKeychain(service: key.keychainService)
            }
        }
        providers.removeAll { $0.id == id }
        if activeProviderId == id {
            activeProviderId = providers.first?.id
        }
        saveConfig()
    }

    func setActive(id: String) {
        activeProviderId = id
        saveConfig()
    }

    // MARK: - API Key Management

    func addAPIKey(to providerId: String, label: String, key: String) {
        guard let index = providers.firstIndex(where: { $0.id == providerId }) else { return }
        let entry = APIKeyEntry(label: label)
        saveKeyToKeychain(key, service: entry.keychainService)
        providers[index].apiKeys.append(entry)
        saveConfig()
    }

    func removeAPIKey(from providerId: String, keyId: String) {
        guard let pIndex = providers.firstIndex(where: { $0.id == providerId }) else { return }
        if let kIndex = providers[pIndex].apiKeys.firstIndex(where: { $0.id == keyId }) {
            let entry = providers[pIndex].apiKeys[kIndex]
            deleteKeyFromKeychain(service: entry.keychainService)
            providers[pIndex].apiKeys.remove(at: kIndex)
            // Adjust active index
            if providers[pIndex].activeKeyIndex >= providers[pIndex].apiKeys.count {
                providers[pIndex].activeKeyIndex = max(0, providers[pIndex].apiKeys.count - 1)
            }
            saveConfig()
        }
    }

    func loadAPIKey(for provider: ProviderConfig) -> String? {
        guard let service = provider.activeKeychainService else { return nil }
        return Self.loadKeyFromKeychain(service: service)
    }

    /// Get the masked version of an API key (e.g., "sk-****7x2a")
    func maskedKey(for provider: ProviderConfig, keyIndex: Int) -> String {
        guard keyIndex < provider.apiKeys.count else { return "—" }
        let service = provider.apiKeys[keyIndex].keychainService
        guard let key = Self.loadKeyFromKeychain(service: service), key.count > 8 else { return "****" }
        let prefix = String(key.prefix(3))
        let suffix = String(key.suffix(4))
        return "\(prefix)****\(suffix)"
    }

    // MARK: - Key Rotation

    /// Rotate to the next API key for a provider after a rate limit error.
    func rotateKey(for providerId: String) -> Bool {
        guard let index = providers.firstIndex(where: { $0.id == providerId }) else { return false }
        let keyCount = providers[index].apiKeys.count
        guard keyCount > 1 else { return false }

        let nextIndex = (providers[index].activeKeyIndex + 1) % keyCount
        providers[index].activeKeyIndex = nextIndex
        saveConfig()

        let keyLabel = providers[index].apiKeys[nextIndex].label
        print("🔄 Rotated to API key: \(keyLabel)")
        return true
    }

    // MARK: - Persistence

    private func loadConfig() {
        guard FileManager.default.fileExists(atPath: configFile.path) else { return }

        do {
            let data = try Data(contentsOf: configFile)

            // Migration: remap old "openaiCompatible" / "anthropicCompatible" provider types
            // and backfill missing profile fields (maxTokens, temperature)
            if var jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               var jsonProviders = jsonObject["providers"] as? [[String: Any]] {
                var migrated = false
                for i in jsonProviders.indices {
                    if let rawType = jsonProviders[i]["providerType"] as? String {
                        if rawType == "openaiCompatible" {
                            jsonProviders[i]["providerType"] = "openai"
                            migrated = true
                        } else if rawType == "anthropicCompatible" {
                            jsonProviders[i]["providerType"] = "anthropic"
                            migrated = true
                        }
                    }
                    // Backfill missing profile fields
                    if jsonProviders[i]["maxTokens"] == nil {
                        jsonProviders[i]["maxTokens"] = 4096
                        migrated = true
                    }
                    if jsonProviders[i]["temperature"] == nil {
                        jsonProviders[i]["temperature"] = 0.3
                        migrated = true
                    }
                }
                if migrated {
                    jsonObject["providers"] = jsonProviders
                    let migratedData = try JSONSerialization.data(withJSONObject: jsonObject)
                    let decoded = try JSONDecoder().decode(PersistedConfig.self, from: migratedData)
                    providers = decoded.providers
                    activeProviderId = decoded.activeProviderId
                    isAIEnabled = decoded.isAIEnabled
                    saveConfig()
                    print("🔄 Migrated provider config to new profile format")
                    return
                }
            }

            let decoded = try JSONDecoder().decode(PersistedConfig.self, from: data)
            providers = decoded.providers
            activeProviderId = decoded.activeProviderId
            isAIEnabled = decoded.isAIEnabled
        } catch {
            print("⚠️ Failed to load AI provider config: \(error)")
        }
    }

    private func saveConfig() {
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

            let config = PersistedConfig(
                providers: providers,
                activeProviderId: activeProviderId,
                isAIEnabled: isAIEnabled
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configFile, options: .atomic)
        } catch {
            print("❌ Failed to save AI provider config: \(error)")
        }
    }

    private func setupPersistence() {
        // Auto-save on changes (debounced)
        $providers
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveConfig() }
            .store(in: &cancellables)

        $activeProviderId
            .dropFirst()
            .sink { [weak self] _ in self?.saveConfig() }
            .store(in: &cancellables)

        $isAIEnabled
            .dropFirst()
            .sink { [weak self] _ in self?.saveConfig() }
            .store(in: &cancellables)
    }

    // MARK: - Legacy Migration

    /// Migrate from old AIConfiguration (single OpenAI key in Keychain)
    private func migrateFromLegacy() {
        guard providers.isEmpty else { return }

        // Check for legacy key
        if let legacyKey = Self.loadKeyFromKeychain(service: "com.screenrecorder.openai-key"), !legacyKey.isEmpty {
            var provider = ProviderConfig.from(preset: ProviderPreset.builtIn.first(where: { $0.id == "openai" })!)
            let entry = APIKeyEntry(label: "Migrated")
            saveKeyToKeychain(legacyKey, service: entry.keychainService)
            provider.apiKeys = [entry]
            provider.selectedModel = UserDefaults.standard.string(forKey: "ai_selectedModel") ?? "gpt-4o-mini"
            providers = [provider]
            activeProviderId = provider.id
            saveConfig()
            print("🔄 Migrated legacy OpenAI config to new provider system")
        }

        // Check for env var
        if providers.isEmpty, let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envKey.isEmpty {
            var provider = ProviderConfig.from(preset: ProviderPreset.builtIn.first(where: { $0.id == "openai" })!)
            let entry = APIKeyEntry(label: "Environment")
            saveKeyToKeychain(envKey, service: entry.keychainService)
            provider.apiKeys = [entry]
            providers = [provider]
            activeProviderId = provider.id
            saveConfig()
            print("🔄 Imported OPENAI_API_KEY from environment")
        }

        // Check for ~/.vibetrace_api_key file
        if providers.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let keyFile = home.appendingPathComponent(".vibetrace_api_key")
            if let fileKey = try? String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !fileKey.isEmpty {
                var provider = ProviderConfig.from(preset: ProviderPreset.builtIn.first(where: { $0.id == "openai" })!)
                let entry = APIKeyEntry(label: "File")
                saveKeyToKeychain(fileKey, service: entry.keychainService)
                provider.apiKeys = [entry]
                providers = [provider]
                activeProviderId = provider.id
                saveConfig()
                print("🔄 Imported API key from ~/.vibetrace_api_key")
            }
        }
    }

    // MARK: - Keychain Helpers

    private func saveKeyToKeychain(_ value: String, service: String) {
        let data = value.data(using: .utf8) ?? Data()
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !value.isEmpty else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func deleteKeyFromKeychain(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func loadKeyFromKeychain(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Persisted Config

private struct PersistedConfig: Codable {
    let providers: [ProviderConfig]
    let activeProviderId: String?
    let isAIEnabled: Bool
}
