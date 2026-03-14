# AI Providers

## Supported Protocols

The app supports **3 API protocols** with 12+ built-in presets:

| Protocol | Built-in Presets | Compatible Services |
|----------|-----------------|---------------------|
| **OpenAI** | OpenAI, DeepSeek, Qwen, Groq, Kimi, GLM, MiniMax | Any `/chat/completions` API |
| **Anthropic** | Anthropic, MiniMax, Kimi, GLM (via opencode.ai) | Any `/messages` API |
| **Gemini** | Google Gemini | Google `generateContent` API |

Every provider is a fully editable **profile** — configure name, base URL, model, max tokens, and temperature.

## Setup

### Option 1: Settings UI (Recommended)

1. Open app → **Settings** (`⌘,`) → **AI Providers**
2. Enable **"Enable AI features"**
3. Click **"Add Provider"** → pick a preset (e.g., OpenAI)
4. Paste your API key → click "Add"
5. Click the circle indicator to set it as active

### Option 2: Environment Variable

```bash
export OPENAI_API_KEY="sk-..."
```

Auto-imported on first launch.

### Option 3: Key File

```bash
echo "sk-..." > ~/.vibetrace_api_key
```

## Custom Provider (Any Compatible API)

Use this to connect to Ollama, LM Studio, vLLM, or any OpenAI/Anthropic-compatible endpoint.

1. **Settings → AI Providers → Add Provider → Custom Provider**
2. Pick protocol (OpenAI / Anthropic / Gemini)
3. Configure:
   - **Base URL** — e.g., `http://localhost:11434/v1` for Ollama
   - **Model** — type or add model names manually
   - **Max Tokens** — default output token limit
   - **Temperature** — 0.0 (deterministic) to 2.0 (creative)
4. Add API key (for local servers, use any string like `ollama`)

## Profile Fields

Every provider exposes the same editable fields:

| Field | Description | Example |
|-------|-------------|---------|
| **Name** | Display name in the UI | "My DeepSeek" |
| **Base URL** | API endpoint root | `https://api.deepseek.com/v1` |
| **Model** | Model identifier | `deepseek-chat` |
| **Max Tokens** | Maximum output tokens | `4096` |
| **Temperature** | Sampling temperature (0.0–2.0) | `0.3` |
| **API Keys** | Multiple keys with rotation | Stored in Keychain |

## Built-in Presets

Presets pre-fill the profile for known providers. You can still edit everything after adding.

### OpenAI Protocol
| Preset | Base URL | Default Model |
|--------|----------|---------------|
| OpenAI | `https://api.openai.com/v1` | `gpt-4o` |
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` |
| Qwen | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus` |
| Groq | `https://api.groq.com/openai/v1` | `llama-3.3-70b-versatile` |
| Kimi (OpenAI) | `https://api.moonshot.cn/v1` | `moonshot-v1-8k` |
| GLM (OpenAI) | `https://open.bigmodel.cn/api/paas/v4` | `glm-4-flash` |
| MiniMax (OpenAI) | `https://api.minimax.chat/v1` | `MiniMax-Text-01` |

### Anthropic Protocol
| Preset | Base URL | Default Model |
|--------|----------|---------------|
| Anthropic | `https://api.anthropic.com/v1` | `claude-sonnet-4-20250514` |
| MiniMax (Anthropic) | `https://opencode.ai/zen/go/v1` | `minimax-m2.5` |
| Kimi (Anthropic) | `https://opencode.ai/zen/go/v1` | `kimi-k2.5` |
| GLM (Anthropic) | `https://opencode.ai/zen/go/v1` | `glm-5` |

### Gemini Protocol
| Preset | Base URL | Default Model |
|--------|----------|---------------|
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta` | `gemini-3-flash-preview` |

## Testing

See the [Testing Walkthrough](../docs/TESTING.md) for step-by-step testing instructions.
