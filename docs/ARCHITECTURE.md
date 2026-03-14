# Architecture

## Source Tree

```
Sources/
├── App/
│   ├── ScreenRecorderApp.swift    # @main entry + MenuBarExtra
│   ├── AppDelegate.swift          # Lifecycle + global hotkey wiring
│   ├── AppState.swift             # Central state (persisted via UserDefaults)
│   └── RecordingCoordinator.swift # Orchestrates capture, camera, audio, writing
├── AI/
│   ├── AIService.swift            # Protocol + AIRequest + AIHTTPClient + Codable response models
│   ├── OpenAIProvider.swift       # OpenAI protocol implementation (chat/completions)
│   ├── AnthropicProvider.swift    # Anthropic protocol implementation (messages)
│   ├── GeminiProvider.swift       # Google Gemini protocol implementation (generateContent)
│   ├── ProviderConfig.swift       # ProviderType enum + ProviderConfig profile + ProviderPreset
│   ├── AIProviderManager.swift    # Factory + persistence + Keychain management + migration
│   ├── StepGenerator.swift        # Prompt builder + AI caller + response parser
│   ├── WorkflowStep.swift         # GeneratedWorkflow + WorkflowStep models
│   └── WorkflowExporter.swift     # Export workflows to Markdown
├── Capture/
│   ├── ScreenCaptureManager.swift # ScreenCaptureKit wrapper
│   ├── CameraManager.swift        # AVFoundation camera
│   └── VideoWriter.swift          # AVAssetWriter (HEVC/H.264 + camera compositing)
├── Views/
│   ├── ControlBar.swift           # Floating glass control bar
│   ├── CameraOverlay.swift        # Draggable camera preview
│   ├── KeystrokeOverlay.swift     # Keystroke display pills
│   ├── VolumeOverlay.swift        # Mic volume HUD
│   ├── CountdownView.swift        # 3-2-1 countdown animation
│   ├── OverlayWindowManager.swift # Window lifecycle for all overlays
│   ├── SettingsView.swift         # Preferences panel
│   └── AIProviderSettingsView.swift # AI provider profile management UI
├── Input/
│   ├── GlobalHotkeys.swift        # KeyboardShortcuts integration
│   └── KeystrokeMonitor.swift     # CGEvent tap monitor
└── Utilities/
    ├── Permissions.swift          # Permission checking + prompts
    └── StorageManager.swift       # File/directory management
```

## AI Provider Design Patterns

The AI system uses **Strategy + Factory + Protocol** — the standard pattern for multi-provider SDKs:

| Concern | Pattern | Implementation |
|---------|---------|----------------|
| Provider interface | Protocol | `AIService` |
| Provider implementations | Strategy | `OpenAIProvider`, `AnthropicProvider`, `GeminiProvider` |
| Provider selection | Factory | `AIProviderManager.makeService()` |
| Shared HTTP + errors | Adapter | `AIHTTPClient` (retry, error mapping) |
| Response parsing | Typed models | `OpenAIResponse`, `AnthropicResponse`, `GeminiResponse` |
| Runtime config | Profile | `ProviderConfig` (editable name, URL, model, tokens, temp) |

### Request Flow

```
StepGenerator.generate()
    │
    ├── buildPrompt()          → constructs analysis prompt from recording session
    ├── loadKeyFrames()        → extracts up to 10 key frame images
    │
    └── aiService.complete(AIRequest)
            │
            ├── Build provider-specific body (JSON)
            ├── AIHTTPClient.execute()  → shared HTTP with retry on 429
            ├── JSONDecoder.decode()    → typed Codable response model
            └── Return extracted text
```

## Dependencies

| Package | Purpose |
|---------|---------|
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | User-customizable global hotkeys with SwiftUI recorder |

## Output Formats

| Format | Codec | Use Case |
|--------|-------|----------|
| **MOV (HEVC)** | H.265 | Recommended — smallest file size |
| MP4 (H.264) | H.264 | Maximum compatibility |
| MOV (H.264) | H.264 | Apple ecosystem compatibility |
