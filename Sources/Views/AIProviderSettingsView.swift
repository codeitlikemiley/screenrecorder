import SwiftUI

/// Settings sub-view for managing AI providers, API keys, and model selection.
/// Embedded inside the main SettingsView.
struct AIProviderSettingsView: View {
    @ObservedObject var manager: AIProviderManager
    @State private var expandedProviderId: String?
    @State private var showAddMenu = false
    @State private var newKeyLabel = "Default"
    @State private var newKeyValue = ""
    @State private var editingKeyForProvider: String?
    @State private var newModelName = ""
    @State private var editingModelsForProvider: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Master toggle
            Toggle("Enable AI features", isOn: $manager.isAIEnabled)
                .font(.system(size: 13))

            if manager.isAIEnabled {
                // Provider list
                if manager.providers.isEmpty {
                    emptyState
                } else {
                    providerList
                }

                // Add provider button
                addProviderMenu
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No AI providers configured")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Add a provider to enable AI step generation")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Provider List

    private var providerList: some View {
        VStack(spacing: 6) {
            ForEach(manager.providers) { provider in
                providerRow(provider)
            }
        }
    }

    private func providerRow(_ provider: ProviderConfig) -> some View {
        let isActive = manager.activeProviderId == provider.id
        let isExpanded = expandedProviderId == provider.id

        return VStack(spacing: 0) {
            // Compact row
            HStack(spacing: 8) {
                // Active indicator
                Button {
                    manager.setActive(id: provider.id)
                } label: {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isActive ? .green : .gray)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Set as active provider")

                // Provider icon + name
                Image(systemName: provider.providerType.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                Text(provider.displayName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)

                Spacer()

                // Model badge
                Text(provider.selectedModel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)

                // Key count
                if !provider.apiKeys.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 9))
                        Text("\(provider.apiKeys.count)")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text("No key")
                        .font(.system(size: 10))
                        .foregroundStyle(.red.opacity(0.7))
                }

                // Expand/collapse
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedProviderId = isExpanded ? nil : provider.id
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
            )

            // Expanded detail
            if isExpanded {
                providerDetail(provider)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Provider Detail

    private func providerDetail(_ provider: ProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            // Name
            HStack {
                Text("Name")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                TextField("Provider name", text: bindingForName(provider))
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)
            }

            // Base URL (editable for openaiCompatible)
            if provider.providerType == .openaiCompatible {
                HStack {
                    Text("Base URL")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    TextField("https://api.example.com/v1", text: bindingForBaseURL(provider))
                        .font(.system(size: 11, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Model picker
            HStack {
                Text("Model")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)

                if provider.availableModels.isEmpty {
                    TextField("Model name", text: bindingForModel(provider))
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("", selection: bindingForModel(provider)) {
                        ForEach(provider.availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                }

                // Add model button for compatible providers
                if provider.providerType == .openaiCompatible {
                    Button {
                        editingModelsForProvider = provider.id
                        newModelName = ""
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(
                        get: { editingModelsForProvider == provider.id },
                        set: { if !$0 { editingModelsForProvider = nil } }
                    )) {
                        addModelPopover(provider)
                    }
                }
            }

            // API Keys
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("API Keys")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        editingKeyForProvider = provider.id
                        newKeyLabel = "Key \(provider.apiKeys.count + 1)"
                        newKeyValue = ""
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "plus")
                            Text("Add Key")
                        }
                        .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }

                // Key list
                ForEach(Array(provider.apiKeys.enumerated()), id: \.element.id) { index, key in
                    HStack(spacing: 6) {
                        // Active key indicator
                        Image(systemName: index == provider.activeKeyIndex ? "key.fill" : "key")
                            .font(.system(size: 10))
                            .foregroundColor(index == provider.activeKeyIndex ? .green : .gray)

                        Text(key.label)
                            .font(.system(size: 11))
                            .frame(width: 70, alignment: .leading)

                        Text(manager.maskedKey(for: provider, keyIndex: index))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if index != provider.activeKeyIndex {
                            Button("Use") {
                                var updated = provider
                                updated.activeKeyIndex = index
                                manager.updateProvider(updated)
                            }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }

                        Button {
                            manager.removeAPIKey(from: provider.id, keyId: key.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.red.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 60)
                }

                // Add key form (inline)
                if editingKeyForProvider == provider.id {
                    addKeyForm(provider)
                        .padding(.leading, 60)
                }
            }

            // Delete
            HStack {
                Spacer()
                Button(role: .destructive) {
                    manager.removeProvider(id: provider.id)
                    expandedProviderId = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Remove Provider")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: - Add Key Form

    private func addKeyForm(_ provider: ProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Label", text: $newKeyLabel)
                    .font(.system(size: 11))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)

                SecureField("Paste API key", text: $newKeyValue)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                Button("Add") {
                    guard !newKeyValue.isEmpty else { return }
                    manager.addAPIKey(to: provider.id, label: newKeyLabel, key: newKeyValue)
                    editingKeyForProvider = nil
                    newKeyValue = ""
                }
                .controlSize(.small)
                .disabled(newKeyValue.isEmpty)

                Button("Cancel") {
                    editingKeyForProvider = nil
                    newKeyValue = ""
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Add Model Popover

    private func addModelPopover(_ provider: ProviderConfig) -> some View {
        VStack(spacing: 8) {
            Text("Add Model")
                .font(.system(size: 12, weight: .semibold))
            HStack {
                TextField("model-name", text: $newModelName)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Button("Add") {
                    guard !newModelName.isEmpty else { return }
                    var updated = provider
                    updated.availableModels.append(newModelName)
                    manager.updateProvider(updated)
                    newModelName = ""
                    editingModelsForProvider = nil
                }
                .controlSize(.small)
            }
        }
        .padding(12)
    }

    // MARK: - Add Provider Menu

    private var addProviderMenu: some View {
        Menu {
            Section("Native Providers") {
                ForEach(ProviderPreset.builtIn.filter { $0.providerType != .openaiCompatible }) { preset in
                    Button {
                        addFromPreset(preset)
                    } label: {
                        Label(preset.name, systemImage: preset.providerType.icon)
                    }
                }
            }

            Divider()

            Section("OpenAI Compatible") {
                ForEach(ProviderPreset.builtIn.filter { $0.providerType == .openaiCompatible }) { preset in
                    Button {
                        addFromPreset(preset)
                    } label: {
                        Label(preset.name, systemImage: "network")
                    }
                }
            }

            Divider()

            Button {
                let custom = ProviderConfig.custom(name: "Custom Provider", baseURL: "", models: [])
                manager.addProvider(custom)
                expandedProviderId = custom.id
            } label: {
                Label("Custom (OpenAI Compatible)", systemImage: "plus.circle")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                Text("Add Provider")
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Helpers

    private func addFromPreset(_ preset: ProviderPreset) {
        let config = ProviderConfig.from(preset: preset)
        manager.addProvider(config)
        expandedProviderId = config.id
        editingKeyForProvider = config.id
        newKeyLabel = "Default"
        newKeyValue = ""
    }

    // Bindings for editable fields
    private func bindingForName(_ provider: ProviderConfig) -> Binding<String> {
        Binding(
            get: { provider.displayName },
            set: { var p = provider; p.displayName = $0; manager.updateProvider(p) }
        )
    }

    private func bindingForBaseURL(_ provider: ProviderConfig) -> Binding<String> {
        Binding(
            get: { provider.baseURL },
            set: { var p = provider; p.baseURL = $0; manager.updateProvider(p) }
        )
    }

    private func bindingForModel(_ provider: ProviderConfig) -> Binding<String> {
        Binding(
            get: { provider.selectedModel },
            set: { var p = provider; p.selectedModel = $0; manager.updateProvider(p) }
        )
    }
}
