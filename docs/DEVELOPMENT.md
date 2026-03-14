# Development

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode Command Line Tools
- Swift 5.9+
- Apple Developer certificate (for hardened runtime signing)

## Build & Run

```bash
# Build, sign, and package the .app bundle
./build.sh

# Launch
open .build/ScreenRecorder.app

# Or build and run directly (debug)
swift build && .build/debug/ScreenRecorder
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

## Configuration Storage

| Data | Location |
|------|----------|
| Preferences | `UserDefaults` (standard) |
| AI provider config | `~/Library/Application Support/ScreenRecorder/ai_providers.json` |
| API keys | macOS Keychain |
| Recordings | `~/Movies/ScreenRecorder/` |

## Inspecting AI Config

```bash
cat ~/Library/Application\ Support/ScreenRecorder/ai_providers.json | python3 -m json.tool
```
