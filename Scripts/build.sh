#!/bin/bash
set -euo pipefail

# ── Screen Recorder Build Script ──────────────────────────────────────
# Builds the Swift package and packages it into a proper .app bundle.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="ScreenRecorder"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🎬 Building Screen Recorder..."
echo "──────────────────────────────"

# Step 1: Build the Swift package
echo "📦 Building Swift package (release)..."
cd "$PROJECT_DIR"
swift build -c release 2>&1

# Find the built executable
EXECUTABLE=$(swift build -c release --show-bin-path)/$APP_NAME

if [ ! -f "$EXECUTABLE" ]; then
    echo "❌ Build failed — executable not found at $EXECUTABLE"
    exit 1
fi

echo "✅ Build succeeded"

# Step 2: Create .app bundle structure
echo "📁 Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Step 3: Copy files
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"

# Step 4: Create PkgInfo
echo "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Step 5: Ad-hoc code sign (required for ScreenCaptureKit)
echo "🔏 Code signing..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 || true

echo ""
echo "──────────────────────────────"
echo "✅ Build complete!"
echo "📍 App bundle: $APP_BUNDLE"
echo ""
echo "To run:  open $APP_BUNDLE"
echo ""
echo "⚠️  On first launch, grant these permissions in System Settings:"
echo "   • Screen Recording"
echo "   • Camera"
echo "   • Microphone"
echo "   • Accessibility (for keystroke overlay)"
