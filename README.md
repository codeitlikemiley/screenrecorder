# Screen Recorder

A native macOS screen recorder designed for developers. Record your screen, camera, and microphone with global hotkeys — then let AI generate step-by-step workflow documentation from your recordings.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
[![Release](https://github.com/codeitlikemiley/screenrecorder/actions/workflows/release.yml/badge.svg)](https://github.com/codeitlikemiley/screenrecorder/actions/workflows/release.yml)

## Features

- **Screen Recording** — Native retina resolution via ScreenCaptureKit
- **Camera Overlay** — Circular, draggable webcam preview composited into the recording
- **Microphone + System Audio** — Voice and system audio with adjustable mic volume
- **Keystroke Overlay** — Floating key display with coalescing and repeat counts
- **Noise Suppression** — macOS Voice Isolation for clean audio
- **Global Hotkeys** — Fully customizable, works from any app
- **HEVC (H.265)** — ~50% smaller files than H.264
- **AI Step Generation** — Analyze recordings with OpenAI, Anthropic, Gemini, or any compatible API
- **Recording Library** — Browse, re-process, and manage all past recordings
- **Menu Bar App** — Lives in the menu bar, no dock icon

## Install

### Download (Recommended)

1. Download the latest DMG from [**Releases**](https://github.com/codeitlikemiley/screenrecorder/releases/latest):

   ```bash
   # Or grab it directly via curl
   curl -LO https://github.com/codeitlikemiley/screenrecorder/releases/download/v1.0.0/ScreenRecorder-1.0.0.dmg
   ```

2. Open the `.dmg` and drag **Screen Recorder** to your **Applications** folder.

3. Launch from Applications. On first launch, macOS may show a Gatekeeper warning since the app is signed but not distributed via the App Store:

   ```bash
   # Remove the quarantine flag to allow the app to open
   xattr -d com.apple.quarantine /Applications/Screen\ Recorder.app
   ```

4. Grant **Screen Recording**, **Accessibility**, and **Microphone** permissions when prompted.

### Build from Source

```bash
git clone https://github.com/codeitlikemiley/screenrecorder.git
cd screenrecorder
./build.sh
open .build/ScreenRecorder.app
```

> Requires macOS 14+ and Xcode Command Line Tools. See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for details.

## Global Hotkeys

All hotkeys are customizable in **Settings → Shortcuts**.

### Recording & Capture

| Default Shortcut | Action |
|------------------|--------|
| `⌘⇧4` | Start / Stop recording |
| `⌘⇧S` | Start / Stop recording (alt) |
| `⌘⇧3` | Annotation screenshot (save to file) |
| `⌘⇧⌥3` | Annotation screenshot (alt) |
| `⌘⇧C` | Toggle camera |
| `⌘⇧M` | Toggle microphone |
| `⌘⇧K` | Toggle keystroke overlay |
| `⌘⇧H` | Show / Hide control bar |
| `⌘⇧F` | Open recordings folder |
| `⌘,` | Open settings |

### Annotation (Doodle Mode)

| Default Shortcut | Action |
|------------------|--------|
| `⌘⇧D` | Toggle annotation mode |
| `⌘⇧X` | Clear annotations |
| `⌘1` | Pen tool |
| `⌘2` | Line tool |
| `⌘3` | Arrow tool |
| `⌘4` | Rectangle tool |
| `⌘5` | Ellipse tool |

> ⚠️ **macOS Screenshot Conflict:**
> `⌘⇧3` and `⌘⇧4` conflict with macOS default screenshot shortcuts. Each has an alt fallback (`⌘⇧S` and `⌘⇧⌥3`) that works without changes. For the best experience, disable the macOS defaults:
>
> **System Settings → Keyboard → Keyboard Shortcuts → Screenshots** → uncheck `⌘⇧3`, `⌘⇧4`, and `⌘⇧5`.
>
> All shortcuts are customizable in the app's **Settings → Shortcuts**.

## AI Step Generation

After recording, the app analyzes your session and generates step-by-step workflow documentation using AI.

**Setup:** Go to **Settings** (`⌘,`) → **AI Providers** → **Add Provider** and pick a preset:

| Protocol | Presets |
|----------|---------|
| **OpenAI** | OpenAI, DeepSeek, Qwen, Groq, Kimi, GLM, MiniMax |
| **Anthropic** | Anthropic, MiniMax, Kimi, GLM |
| **Gemini** | Google Gemini |

Each provider is a fully editable **profile** — configure the base URL, model, max tokens, temperature, and API keys. You can add multiple profiles and switch between them at any time.

Want to use a **local model**? Add a Custom Provider pointing to Ollama, LM Studio, or any OpenAI/Anthropic-compatible endpoint.

> See [docs/AI_PROVIDERS.md](docs/AI_PROVIDERS.md) for the full provider list, custom endpoint setup, and configuration guide.

### Generated Artifacts

Each recording produces a set of files in your recordings directory (`~/Movies/ScreenRecorder/` by default):

```
Recording_2026-03-15_04-30-00.mov          # Screen recording (HEVC)
Recording_2026-03-15_04-30-00_session.json  # Session metadata (duration, events, keystrokes)
Recording_2026-03-15_04-30-00_workflow.json # AI-generated step-by-step workflow
Recording_2026-03-15_04-30-00_frames/       # Extracted key frames (PNG)
```

| File | Description |
|------|-------------|
| `_session.json` | Recording metadata — date, duration, input events, processing state |
| `_workflow.json` | AI-generated workflow with titled steps, descriptions, and frame references |
| `_frames/` | Key frames extracted from the video, used as context for AI analysis |

## Session Viewer

After a recording is processed, the **Session Viewer** opens automatically. You can also reopen any past session from the Recording Library.

The viewer is a split-pane interface:

- **Steps Panel** (left) — AI-generated step-by-step workflow with numbered steps, action types, and descriptions
- **Screenshot Preview** (right) — Key frame for the selected step, synced to your selection
- **AI Prompt Tab** — View or copy the raw prompt used for AI analysis

### Editing Steps

Steps are fully editable inside the viewer:

- **Edit** title and description inline
- **Reorder** steps via drag-and-drop
- **Delete** steps you don't need

### Exporting

Click **Export** in the title bar to copy or save the workflow:

| Format | Description |
|--------|-------------|
| **Markdown Steps** | Full document with steps, screenshots, and metadata |
| **AI Agent Prompt** | Ready-to-paste prompt for Cursor, Copilot, Codex, etc. |
| **GitHub Issue** | Issue body with task checklist and context |
| **JSON Workflow** | Machine-readable workflow for automation |

Export to clipboard or save to file — all formats are supported.

## Recording Library

Access all past recordings from the menu bar via **📚 Recording Library**.

- **Browse** — View all recordings with thumbnails, dates, duration, and status badges (`Steps Generated`, `Unprocessed`, `Processing`, `Failed`)
- **Open** — Double-click or hit the eye icon to load the session in the Session Viewer
- **Re-process** — Re-run AI analysis with a different provider or updated settings (reuses existing frames, skips re-extraction)
- **Delete** — Remove a recording and all its associated artifacts (video, session, workflow, frames) with confirmation
- **Reveal in Finder** — Jump to the recording file in Finder

## Documentation

| Doc | Description |
|-----|-------------|
| [AI Providers](docs/AI_PROVIDERS.md) | Full AI provider setup, presets, custom endpoints |
| [Architecture](docs/ARCHITECTURE.md) | Source tree, design patterns, request flow |
| [Development](docs/DEVELOPMENT.md) | Build, permissions, config storage |
| [Release](docs/RELEASE.md) | Signing, notarization, DMG creation |
| [Contributing](docs/CONTRIBUTING.md) | How to contribute, PR guidelines |

## License

[MIT](LICENSE)
