# 🍌 Nano Banana — Screen Recorder

A native macOS screen recorder designed for developers. Record your screen, camera, and microphone with global hotkeys — built to eventually generate visual artifacts for AI-assisted debugging.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **Screen Recording** — Native retina resolution via ScreenCaptureKit
- **Camera Overlay** — Circular, draggable webcam preview (composited into the recording)
- **Microphone + System Audio** — Voice + system audio with adjustable mic volume (0–10 scale)
- **Keystroke Overlay** — Floating key display with coalescing and repeat counts
- **Noise Suppression** — macOS Voice Isolation for clean audio in noisy environments
- **Global Hotkeys** — Control everything from any app, even in the background
- **HEVC (H.265)** — ~50% smaller files than H.264
- **Persistent Settings** — All preferences saved via UserDefaults across restarts
- **Menu Bar App** — Lives in the menu bar, no dock icon

## Global Hotkeys

| Shortcut | Action |
|----------|--------|
| `⌘⇧S` | Start / Stop recording |
| `⌘⇧C` | Toggle camera (enable/disable or show/hide during recording) |
| `⌘⇧M` | Toggle microphone (enable/disable or mute/unmute during recording) |
| `⌘⇧K` | Toggle keystroke overlay |
| `⌘⇧H` | Show / Hide control bar |
| `⌘⇧+` | Increase mic volume |
| `⌘⇧-` | Decrease mic volume |
| `⌘⇧0` | Reset mic volume to default |
| `⌘⇧F` | Open recordings folder |
| `⌘,` | Open settings |

## Default Configuration

| Setting | Default |
|---------|---------|
| Video Codec | HEVC (H.265) |
| Container | `.mov` |
| Frame Rate | 30 FPS |
| Resolution | Native retina |
| Camera | Off (bottom-right, 200px circle when enabled) |
| Microphone | Off (volume 5/10 when enabled) |
| Keystroke Overlay | Off |
| Save Location | `~/Movies/ScreenRecorder/` |

## Build & Run

```bash
# Build, sign, and package the .app bundle
./build.sh

# Launch
open .build/ScreenRecorder.app
```

## App Icon

Generate or update the app icon from any source image:

```bash
# Generate all macOS icon sizes + .icns from a single image
./generate_icons.sh /path/to/your/icon.png

# Rebuild with the new icon
./build.sh
```

The script uses `sips` + `iconutil` (built-in macOS tools, no dependencies) and produces all 10 required sizes (16px–1024px including @2x variants).

## First Launch Permissions

On first launch, macOS will prompt you to grant:

1. **Screen Recording** — Required to capture your display
2. **Camera** — Required for webcam overlay (optional)
3. **Microphone** — Required for voice recording (optional)
4. **Accessibility** — Required for keystroke overlay (System Settings → Privacy & Security → Accessibility)

## Architecture

```
Sources/
├── App/
│   ├── ScreenRecorderApp.swift    # @main entry + MenuBarExtra
│   ├── AppDelegate.swift          # Lifecycle + global hotkey wiring
│   ├── AppState.swift             # Central state (persisted via UserDefaults)
│   └── RecordingCoordinator.swift # Orchestrates capture, camera, audio, writing
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
│   └── SettingsView.swift         # Preferences panel
├── Input/
│   ├── GlobalHotkeys.swift        # HotKey package integration
│   └── KeystrokeMonitor.swift     # CGEvent tap monitor
└── Utilities/
    ├── Permissions.swift          # Permission checking + prompts
    └── StorageManager.swift       # File/directory management
```

## Output Formats

| Format | Codec | Use Case |
|--------|-------|----------|
| **MOV (HEVC)** | H.265 | Recommended — smallest file size |
| MP4 (H.264) | H.264 | Maximum compatibility |
| MOV (H.264) | H.264 | Apple ecosystem compatibility |

## Dependencies

- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — User-customizable global keyboard shortcuts with built-in SwiftUI recorder, auto-persistence, and conflict detection

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode Command Line Tools
- Swift 5.9+
- Apple Developer certificate (for hardened runtime signing)
