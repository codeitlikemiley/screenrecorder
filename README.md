# 🎬 Screen Recorder

A sleek, translucent native macOS screen recording app designed for developers creating tutorials.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **Screen Recording** — Capture your entire display at native retina resolution using ScreenCaptureKit
- **Camera Overlay** — Circular, draggable webcam overlay (defaults to bottom-right corner)
- **Microphone + System Audio** — Record your voice alongside system audio
- **Keystroke Overlay** — Show keyboard shortcuts as beautiful floating pills (toggle with `⌘⇧K`)
- **Global Hotkeys** — Control everything from any app, even when Screen Recorder is in the background
- **HEVC (H.265)** — ~50% smaller files than H.264, saving you storage
- **Translucent Glass UI** — Native macOS vibrancy with frosted glass effects

## Global Hotkeys

| Shortcut | Action |
|----------|--------|
| `⌘⇧R` | Start / Stop recording |
| `⌘⇧K` | Toggle keystroke overlay |
| `⌘⇧C` | Toggle camera overlay |
| `⌘⇧H` | Show / Hide control bar |

## Default Configuration

| Setting | Value |
|---------|-------|
| Video Codec | HEVC (H.265) |
| Container | `.mov` |
| Frame Rate | 30 FPS |
| Resolution | Native retina |
| Camera | Bottom-right, 200px circle |
| Save Location | `~/Movies/ScreenRecorder/` |

## Build & Run

```bash
# Build the .app bundle
./Scripts/build.sh

# Launch
open build/ScreenRecorder.app
```

## First Launch Permissions

On first launch, macOS will prompt you to grant:

1. **Screen Recording** — Required to capture your display
2. **Camera** — Required for webcam overlay
3. **Microphone** — Required for voice recording
4. **Accessibility** — Required for keystroke overlay (System Settings → Privacy & Security → Accessibility)

## Architecture

```
Sources/
├── App/
│   ├── ScreenRecorderApp.swift    # @main entry point + MenuBarExtra
│   ├── AppDelegate.swift          # NSApplication lifecycle + hotkeys
│   ├── AppState.swift             # Central ObservableObject state
│   └── RecordingCoordinator.swift # Orchestrates all recording systems
├── Capture/
│   ├── ScreenCaptureManager.swift # ScreenCaptureKit wrapper
│   ├── CameraManager.swift        # AVFoundation camera
│   └── VideoWriter.swift          # AVAssetWriter (HEVC/H.264)
├── Views/
│   ├── ControlBar.swift           # Floating glass control bar
│   ├── CameraOverlay.swift        # Draggable camera preview
│   ├── KeystrokeOverlay.swift     # Keystroke display pills
│   ├── CountdownView.swift        # 3-2-1 countdown animation
│   └── SettingsView.swift         # Preferences panel
├── Input/
│   ├── GlobalHotkeys.swift        # HotKey package integration
│   └── KeystrokeMonitor.swift     # CGEvent tap monitor
└── Utilities/
    ├── Permissions.swift          # Permission checking helpers
    └── StorageManager.swift       # File/directory management
```

## Output Formats

| Format | Codec | Use Case |
|--------|-------|----------|
| **MOV (HEVC)** | H.265 | Recommended — smallest file size |
| MP4 (H.264) | H.264 | Maximum compatibility |
| MOV (H.264) | H.264 | Apple ecosystem compatibility |

## Dependencies

- [HotKey](https://github.com/soffes/HotKey) — Global hotkey registration

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode Command Line Tools
- Swift 5.9+
