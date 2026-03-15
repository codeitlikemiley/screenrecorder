#!/bin/bash
set -e

# ─── Load .env ──────────────────────────────────────────────
if [ -f .env ]; then
    set -a; source .env; set +a
fi

# ─── Configuration ──────────────────────────────────────────
APPLE_ID="${APPLE_ID:?Set APPLE_ID in .env}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID in .env}"
APP_PASSWORD="${APP_PASSWORD:?Set APP_PASSWORD in .env}"
SIGNING_IDENTITY="${RELEASE_SIGNING_IDENTITY:?Set RELEASE_SIGNING_IDENTITY in .env}"
VERSION="${APP_VERSION:?Set APP_VERSION in .env}"

BUNDLE_ID="com.codeitlikemiley.screenrecorder"
APP_NAME="ScreenRecorder"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
APP_DIR=".build/release/${APP_NAME}.app"
ARCHIVE_PATH=".build/${APP_NAME}.xcarchive"

# Stamp version into Info.plist before building
sed -i '' "s|<key>CFBundleShortVersionString</key>|<key>CFBundleShortVersionString</key>|" Resources/Info.plist
sed -i '' "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>${VERSION}</string>|;}" Resources/Info.plist
sed -i '' "/<key>CFBundleVersion<\/key>/{n;s|<string>.*</string>|<string>${VERSION}</string>|;}" Resources/Info.plist

echo "🚀 Building ${APP_NAME} v${VERSION} for release..."
echo "   Bundle ID: ${BUNDLE_ID}"
echo "   Signing:   ${SIGNING_IDENTITY}"
echo ""

# ─── Step 1: Clean Build ────────────────────────────────────
echo "🔨 Step 1/7: Building release binary..."
pkill -f "${APP_NAME}" 2>/dev/null || true

xcodebuild -scheme "${APP_NAME}" -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode-release \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
  CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
  CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--options=runtime" \
  build 2>&1 | grep -E '(error:|warning:|BUILD|Signing)' || true

BINARY=".build/xcode-release/Build/Products/Release/${APP_NAME}"
if [ ! -f "$BINARY" ]; then
    echo "❌ Release build failed"
    exit 1
fi
echo "   ✅ App build succeeded"

echo "🔧 Building CLI (sr) and MCP server (sr-mcp)..."
swift build -c release --product sr
swift build -c release --product sr-mcp
echo "   ✅ CLI and MCP built"

# ─── Step 2: Package .app ───────────────────────────────────
echo "🎁 Step 2/7: Packaging .app bundle..."
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BINARY}" "${MACOS_DIR}/${APP_NAME}"
cp Resources/Info.plist "${CONTENTS_DIR}/Info.plist"

# App icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
fi

# SPM resource bundles
BUNDLES_DIR=".build/xcode-release/Build/Products/Release"
for bundle in "${BUNDLES_DIR}"/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "${RESOURCES_DIR}/"
    fi
done
echo "   ✅ App packaged"

# ─── Step 3: Code Sign ─────────────────────────────────────
echo "🔏 Step 3/7: Signing with Developer ID (hardened runtime)..."
codesign --force --sign "${SIGNING_IDENTITY}" \
  --options runtime \
  --entitlements Resources/ScreenRecorder.entitlements \
  --deep \
  --timestamp \
  --generate-entitlement-der \
  "${APP_DIR}" 2>&1

# Verify signature
codesign --verify --verbose=2 "${APP_DIR}" 2>&1
echo "   ✅ Signed and verified"

# ─── Step 4: Notarize ──────────────────────────────────────
echo "📤 Step 4/7: Submitting for notarization..."
ZIP_PATH=".build/${APP_NAME}-notarize.zip"
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

xcrun notarytool submit "${ZIP_PATH}" \
  --apple-id "${APPLE_ID}" \
  --team-id "${APPLE_TEAM_ID}" \
  --password "${APP_PASSWORD}" \
  --wait

echo "   ✅ Notarization approved"

# ─── Step 5: Staple ────────────────────────────────────────
echo "📎 Step 5/7: Stapling notarization ticket..."
xcrun stapler staple "${APP_DIR}"
echo "   ✅ Ticket stapled"

# ─── Step 6: Create DMG ────────────────────────────────────
echo "💿 Step 6/7: Creating DMG..."
rm -f ".build/${DMG_NAME}"

# Stage the app in a clean temp directory
DMG_STAGING=".build/dmg-staging"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_DIR}" "${DMG_STAGING}/"

# Check if create-dmg is available
if command -v create-dmg &>/dev/null; then
    create-dmg \
      --volname "Screen Recorder" \
      --window-pos 200 120 \
      --window-size 600 400 \
      --icon-size 100 \
      --icon "${APP_NAME}.app" 150 190 \
      --app-drop-link 450 190 \
      --no-internet-enable \
      ".build/${DMG_NAME}" \
      "${DMG_STAGING}" || true
else
    # Fallback: create DMG with Applications symlink manually
    ln -sf /Applications "${DMG_STAGING}/Applications"
    hdiutil create -volname "Screen Recorder" \
      -srcfolder "${DMG_STAGING}" \
      -ov -format UDZO \
      ".build/${DMG_NAME}"
fi
rm -rf "${DMG_STAGING}"
echo "   ✅ DMG created"

# ─── Step 7: Git Tag & Push ─────────────────────────────────
echo "🏷️  Step 7/7: Tagging v${VERSION} and pushing..."

git add Resources/Info.plist
git diff --cached --quiet || git commit -m "release: v${VERSION}"
git tag -f "v${VERSION}"
git push --force origin "v${VERSION}" 2>/dev/null && echo "   ✅ Tag v${VERSION} pushed (GitHub Action triggered)" || echo "   ⚠️  No remote found — tag created locally only"

# ─── Done ──────────────────────────────────────────────────
rm -f "${ZIP_PATH}"
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅ ${APP_NAME} v${VERSION} is ready for distribution!"
echo ""
echo "  📦 App:  ${APP_DIR}"
echo "  💿 DMG:  .build/${DMG_NAME}"
echo "  🔧 CLI:  .build/release/sr"
echo "  🔌 MCP:  .build/release/sr-mcp"
echo "  🏷️  Tag:  v${VERSION}"
echo "═══════════════════════════════════════════════════════"
