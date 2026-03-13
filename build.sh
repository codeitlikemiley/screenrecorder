#!/bin/bash
set -e

SIGNING_IDENTITY="Apple Development: Uriah Galang (SLT9H2M79A)"
TEAM_ID="5KZ8MD34QW"
APP_DIR=".build/ScreenRecorder.app"

# Kill existing instance to prevent -600 error on relaunch
pkill -f "ScreenRecorder" 2>/dev/null || true

# Build using Xcode's build system (handles signing + execution policy registration)
echo "🔨 Building with xcodebuild..."
xcodebuild -scheme ScreenRecorder -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  build 2>&1 | grep -E '(error:|warning:|BUILD|Signing)' || true

# Check build succeeded
BINARY=".build/xcode/Build/Products/Debug/ScreenRecorder"
if [ ! -f "$BINARY" ]; then
    echo "❌ Build failed"
    exit 1
fi

# Package .app bundle
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "📦 Packaging .app bundle..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY" "$MACOS_DIR/ScreenRecorder"
cp Resources/Info.plist "$CONTENTS_DIR/Info.plist"

# Copy app icon if it exists
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
    echo "🎨 App icon included"
fi

# Sign the .app bundle with hardened runtime + entitlements
echo "🔏 Signing with developer certificate (hardened runtime)..."
codesign --force --sign "$SIGNING_IDENTITY" \
  --options runtime \
  --entitlements Resources/ScreenRecorder.entitlements \
  --deep \
  --generate-entitlement-der \
  "$APP_DIR" 2>&1

# Register with macOS execution policy (like Xcode does)
echo "📋 Registering execution policy..."
spctl --add --label "ScreenRecorder" "$APP_DIR" 2>/dev/null || true

# Reset stale Accessibility permission (CDHash changes on each rebuild)
# This clears the old entry so the new binary gets a fresh permission grant
echo "🔑 Resetting Accessibility permission for fresh CDHash..."
tccutil reset Accessibility com.screenrecorder.app 2>/dev/null || true

echo ""
echo "✅ Done! Run:  open $APP_DIR"
