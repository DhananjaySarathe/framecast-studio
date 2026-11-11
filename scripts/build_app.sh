#!/bin/zsh
# Builds Framecast.app with SwiftPM and the Command Line Tools (no Xcode), then ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
VERSION=1.1.0
swift build -c "$CONFIG" --product Framecast
swift build -c "$CONFIG" --product fcverify
swift build -c "$CONFIG" --product framecast-mcp
BIN=$(swift build -c "$CONFIG" --show-bin-path)
# FRAMECAST_APP builds somewhere else (test copies), so the app you use isn't replaced while it runs.
APP=${FRAMECAST_APP:-build/Framecast.app}
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Framecast" "$APP/Contents/MacOS/Framecast"
cp "$BIN/framecast-mcp" "$APP/Contents/MacOS/framecast-mcp"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/LiveKitWebRTC.framework" "$APP/Contents/Frameworks/LiveKitWebRTC.framework"
"$BIN/fcverify" icon --out build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
if [ -d Resources/guest ]; then cp -R Resources/guest "$APP/Contents/Resources/guest"; fi
# Creator asset pack (backgrounds, scene plates, frames, annotations). The editable SVG sources stay in the repo.
if [ -d Resources/AssetPacks ]; then
  mkdir -p "$APP/Contents/Resources/AssetPacks"
  rsync -a --exclude editable Resources/AssetPacks/ "$APP/Contents/Resources/AssetPacks/"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Framecast</string>
  <key>CFBundleExecutable</key><string>Framecast</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>app.framecast.studio</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Framecast</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSCameraUsageDescription</key><string>Framecast uses your camera as a source in your layouts.</string>
  <key>NSMicrophoneUsageDescription</key><string>Framecast records and streams audio from your microphone.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Framecast connects to phones and computers on your Wi-Fi that join your show as guests or camera angles.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Framecast captures system and app audio for your recordings and streams.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Framecast captures your displays, windows and apps for layouts, recordings and streams.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Framecast follows your voice on this Mac to suggest scene changes from your rundown. Nothing you say leaves the Mac.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
# Sign with the local self-made identity if present (stable identity, so macOS keeps camera/mic/screen
# permissions across rebuilds); otherwise ad-hoc. See scripts/make_signing_identity.sh.
KC="$PWD/build/signing/framecast-signing.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat build/signing/keychain.pass)" "$KC"
  ID=$(security find-identity -p codesigning "$KC" | awk '/Framecast Local Signing/ {print $2; exit}')
  codesign --force --deep --keychain "$KC" --sign "$ID" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose=1 "$APP"
echo "Built $APP"
