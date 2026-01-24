#!/bin/bash

# Build script for SeaSync macOS app
# Creates a proper .app bundle that can be placed in /Applications
# Signed with Blaris ApS Developer ID

set -e

APP_NAME="SeaSync"
BUNDLE_ID="com.blaris.seasync"
VERSION="1.0.0"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"
SIGNING_IDENTITY="Developer ID Application: Blaris ApS (433NDKVD38)"

echo "🔨 Building $APP_NAME..."

# Build release version
swift build -c release

echo "📦 Creating app bundle..."

# Remove old bundle if exists
rm -rf "$APP_BUNDLE"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy resource bundle if it exists
if [ -d "$BUILD_DIR/${APP_NAME}_SeaSync.bundle" ]; then
    cp -R "$BUILD_DIR/${APP_NAME}_SeaSync.bundle" "$APP_BUNDLE/Contents/Resources/"
fi

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "📝 Signing app bundle with $SIGNING_IDENTITY..."

# Sign the app bundle with entitlements for file access
codesign --force --deep --sign "$SIGNING_IDENTITY" \
    --entitlements "SeaSync.entitlements" \
    --options runtime \
    "$APP_BUNDLE"

# Verify the signature
echo "🔍 Verifying signature..."
codesign -vvv --deep --strict "$APP_BUNDLE"

echo "✅ App bundle created and signed: $APP_BUNDLE"
echo ""
echo "To install, run:"
echo "  cp -R $APP_BUNDLE /Applications/"
echo ""
echo "To open:"
echo "  open /Applications/$APP_BUNDLE"
echo ""
echo "To add to Login Items (auto-start on login):"
echo "  Open System Settings → General → Login Items → Add SeaSync"
echo ""
echo "To verify Gatekeeper acceptance:"
echo "  spctl --assess --verbose $APP_BUNDLE"
