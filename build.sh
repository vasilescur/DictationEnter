#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DictationEnter"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Generate app icon if needed
if [ ! -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    echo "Generating app icon..."
    swift "$SCRIPT_DIR/generate_icon.swift"
fi

# Compile
swiftc "$SCRIPT_DIR/$APP_NAME.swift" \
    -o "$SCRIPT_DIR/$APP_NAME" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework ServiceManagement

# Create .app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy files into bundle
cp "$SCRIPT_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/"
cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Ad-hoc sign so Info.plist is bound to the signature
codesign --force --sign - "$APP_BUNDLE"

# Generate DMG background image
DMG_BG="$SCRIPT_DIR/dmg_background.png"
if [ ! -f "$DMG_BG" ]; then
    echo "Generating DMG background..."
    swift "$SCRIPT_DIR/generate_dmg_background.swift" "$DMG_BG"
fi

# Create styled DMG installer
DMG_PATH="$SCRIPT_DIR/$APP_NAME.dmg"
DMG_TEMP="$SCRIPT_DIR/${APP_NAME}_temp.dmg"
DMG_STAGING="$SCRIPT_DIR/dmg_staging"
VOLUME_NAME="Dictation Enter"
rm -rf "$DMG_STAGING" "$DMG_PATH" "$DMG_TEMP"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Create a writable DMG so we can style it
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$DMG_STAGING" -ov -format UDRW "$DMG_TEMP"
rm -rf "$DMG_STAGING"

# Mount the writable DMG
DEVICE=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | head -1 | awk '{print $1}')
MOUNT_DIR="/Volumes/$VOLUME_NAME"
echo "Mounted at: $MOUNT_DIR (device: $DEVICE)"

# Copy background image into DMG (hidden)
mkdir -p "$MOUNT_DIR/.background"
cp "$DMG_BG" "$MOUNT_DIR/.background/background.png"

# Use AppleScript to set DMG window appearance
echo "Styling DMG window..."
osascript <<'APPLESCRIPT'
on run
    tell application "Finder"
        tell disk "Dictation Enter"
            open
            delay 1

            set cw to container window
            set current view of cw to icon view
            set toolbar visible of cw to false
            set statusbar visible of cw to false
            set bounds of cw to {100, 100, 760, 500}

            set vo to icon view options of cw
            set arrangement of vo to not arranged
            set icon size of vo to 96
            set text size of vo to 13

            -- Set background picture
            set background picture of vo to file ".background:background.png"

            -- Position icons
            set position of item "DictationEnter.app" of cw to {165, 200}
            set position of item "Applications" of cw to {495, 200}

            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
APPLESCRIPT

# Make sure writes are flushed
sync
sleep 1

# Unmount
hdiutil detach "$DEVICE"

# Convert to compressed DMG
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$DMG_TEMP"

echo "Built $APP_BUNDLE"
echo "Installer: $DMG_PATH"
echo "Run with: open $APP_BUNDLE"
