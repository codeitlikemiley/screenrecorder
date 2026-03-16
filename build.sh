#!/bin/bash
set -e

# Load environment variables
if [ -f .env ]; then
    set -a; source .env; set +a
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY in .env}"
TEAM_ID="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID in .env}"
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

# Build CLI and MCP server
echo "🔧 Building CLI (sr) and MCP server (sr-mcp)..."
swift build --product sr 2>&1 | grep -E '(error:|Build)' || true
swift build --product sr-mcp 2>&1 | grep -E '(error:|Build)' || true

# Package .app bundle
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "📦 Packaging .app bundle..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY" "$MACOS_DIR/ScreenRecorder"

# Bundle CLI and MCP inside .app
cp .build/debug/sr "$MACOS_DIR/sr" 2>/dev/null && echo "   ✅ sr bundled" || echo "   ⚠️  sr not found"
cp .build/debug/sr-mcp "$MACOS_DIR/sr-mcp" 2>/dev/null && echo "   ✅ sr-mcp bundled" || echo "   ⚠️  sr-mcp not found"

cp Resources/Info.plist "$CONTENTS_DIR/Info.plist"

# Copy app icon if it exists
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
    echo "🎨 App icon included"
fi

# Copy SPM resource bundles (e.g., KeyboardShortcuts localization)
BUNDLES_DIR=".build/xcode/Build/Products/Debug"
for bundle in "$BUNDLES_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$RESOURCES_DIR/"
        echo "📦 Copied $(basename "$bundle")"
    fi
done

# Sign nested CLI binaries first (no app-specific entitlements)
echo "🔏 Signing with developer certificate (hardened runtime)..."
for cli_bin in "$MACOS_DIR/sr" "$MACOS_DIR/sr-mcp"; do
    if [ -f "$cli_bin" ]; then
        codesign --force --sign "$SIGNING_IDENTITY" \
          --options runtime \
          "$cli_bin" 2>&1
        echo "   ✅ Signed $(basename "$cli_bin")"
    fi
done

# Sign the main .app bundle (with app-specific entitlements, NO --deep)
codesign --force --sign "$SIGNING_IDENTITY" \
  --options runtime \
  --entitlements Resources/ScreenRecorder.entitlements \
  --generate-entitlement-der \
  "$APP_DIR" 2>&1

# Register with macOS execution policy (like Xcode does)
echo "📋 Registering execution policy..."
spctl --add --label "ScreenRecorder" "$APP_DIR" 2>/dev/null || true

# Note: Accessibility permissions are tied to CDHash. If permissions stop working
# after rebuild, the user must re-add the app in System Settings → Accessibility.

# Write license server URL into shared UserDefaults (for GUI app)
# In .env: SR_LICENSE_SERVER=http://localhost:3000
if [ -n "${SR_LICENSE_SERVER:-}" ]; then
    echo "🌐 Setting license server URL: $SR_LICENSE_SERVER"
    defaults write com.codeitlikemiley.screenrecorder.shared license_server_url "$SR_LICENSE_SERVER"
fi

echo ""
echo "✅ Done! Run:  open $APP_DIR"
