#!/bin/bash
# generate_icons.sh — Convert a source image to all required macOS app icon sizes
# Usage: ./generate_icons.sh <source_image.png>
#
# This script:
# 1. Creates an .iconset folder with all required macOS icon sizes
# 2. Generates an .icns file using iconutil
# 3. Copies the .icns to Resources/ for the app bundle
#
# Requires: sips (built into macOS), iconutil (built into macOS)
# Source image should be at least 1024x1024 pixels.

set -e

SOURCE="${1:?Usage: ./generate_icons.sh <source_image.png>}"

if [ ! -f "$SOURCE" ]; then
    echo "❌ File not found: $SOURCE"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICONSET_DIR="$SCRIPT_DIR/Resources/AppIcon.iconset"
RESOURCES_DIR="$SCRIPT_DIR/Resources"
ICNS_FILE="$RESOURCES_DIR/AppIcon.icns"

echo "🎨 Generating macOS app icons from: $SOURCE"

# Clean and create iconset directory
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# macOS required icon sizes
# Format: filename  pixel_size
declare -a SIZES=(
    "icon_16x16.png 16"
    "icon_16x16@2x.png 32"
    "icon_32x32.png 32"
    "icon_32x32@2x.png 64"
    "icon_128x128.png 128"
    "icon_128x128@2x.png 256"
    "icon_256x256.png 256"
    "icon_256x256@2x.png 512"
    "icon_512x512.png 512"
    "icon_512x512@2x.png 1024"
)

for entry in "${SIZES[@]}"; do
    FILENAME=$(echo "$entry" | awk '{print $1}')
    SIZE=$(echo "$entry" | awk '{print $2}')
    echo "  📐 ${FILENAME} (${SIZE}x${SIZE})"
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET_DIR/$FILENAME" > /dev/null 2>&1
done

# Generate .icns from iconset
echo "📦 Creating AppIcon.icns..."
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_FILE"

# Clean up iconset (optional — keep for reference)
rm -rf "$ICONSET_DIR"

# Also save the original 1024x1024 as a reference
cp "$SOURCE" "$RESOURCES_DIR/AppIcon-1024.png"

echo ""
echo "✅ Icons generated!"
echo "   📁 $ICNS_FILE"
echo "   📁 $RESOURCES_DIR/AppIcon-1024.png"
echo ""
echo "🔨 Run './build.sh' to rebuild with the new icon."
