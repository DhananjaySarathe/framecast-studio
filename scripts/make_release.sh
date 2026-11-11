#!/bin/zsh
# Builds Framecast for other Macs: one app for Apple silicon and Intel (macOS 14 or later), in a disk image with
# an Applications shortcut, install steps, and the licences. Paths on this Mac are kept out of the binaries.
#   scripts/make_release.sh [out dir]          builds this checkout
#   SRC=<folder> scripts/make_release.sh ...   builds another source tree (the public repo's code, exported)
# Signed with the local "Framecast Local Signing" identity when it exists (see make_signing_identity.sh), so
# macOS keeps people's camera, microphone and screen permissions across updates; otherwise ad hoc. Neither is
# an Apple Developer ID, so on first open people confirm it once in System Settings › Privacy & Security.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$(cd "${SRC:-$HERE}" && pwd)"
cd "$SRC"
VERSION=$(sed -n 's/^VERSION=//p' scripts/build_app.sh)
OUT="${1:-$SRC/build/release}"
mkdir -p "$OUT"
STAGE="$OUT/stage"
APP="$STAGE/Framecast.app"
rm -rf "$STAGE"; mkdir -p "$STAGE"

# 1. The bundle as build_app.sh lays it out (Info.plist, icon, guest page, asset pack, WebRTC framework).
FRAMECAST_APP="$APP" scripts/build_app.sh >/dev/null

# 2. Both architectures with this Mac's folders mapped away, then one universal binary each, stripped of
#    debug symbols (they hold build paths).
MAP=(-Xswiftc -file-prefix-map -Xswiftc "$SRC=/framecast" -Xswiftc -debug-prefix-map -Xswiftc "$SRC=/framecast")
for arch in arm64 x86_64; do
  mkdir -p "$OUT/$arch"
  for product in Framecast framecast-mcp; do
    swift build -c release --triple "$arch-apple-macosx14.0" --product "$product" "${MAP[@]}"
    # Both triples can share one products folder: keep each build before the next one replaces it.
    cp "$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/$product" "$OUT/$arch/$product"
  done
done
for product in Framecast framecast-mcp; do
  lipo -create "$OUT/arm64/$product" "$OUT/x86_64/$product" -output "$APP/Contents/MacOS/$product"
  strip -S -x "$APP/Contents/MacOS/$product"
done

# 3. Sign the whole bundle again.
KC="$HERE/build/signing/framecast-signing.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$HERE/build/signing/keychain.pass")" "$KC"
  ID=$(security find-identity -p codesigning "$KC" | awk '/Framecast Local Signing/ {print $2; exit}')
  codesign --force --deep --keychain "$KC" --sign "$ID" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

# 4. What goes beside the app: install steps, Framecast's licence, and the licences of what it's built with.
cat > "$STAGE/How to install.txt" <<TXT
Framecast $VERSION for Mac
Needs macOS 14 (Sonoma) or later, on an Apple silicon or Intel Mac.

1. Drag Framecast onto the Applications folder in this window.

2. Open your Applications folder and double-click Framecast.
   macOS says it can't verify the app. That's expected: Framecast is free and open source, and it isn't
   signed with a paid Apple developer account.

3. Allow it once:
   - macOS 15 or later: open System Settings › Privacy & Security, scroll down to Security, and click
     "Open Anyway" next to Framecast. Confirm with your password or Touch ID, then click Open.
   - macOS 14: Control-click Framecast in Applications, choose Open, then click Open.
   After that it opens like any other app.

4. Framecast asks for the camera, microphone and screen recording the first time it needs them. After you
   allow Screen Recording, quit and reopen Framecast.

Everything runs on your Mac. Framecast has no account, no sign-up and no tracking.
Source code: https://github.com/DhananjaySarathe/framecast-studio
TXT
cp LICENSE "$STAGE/License.txt"
{
  echo "Framecast is built with these open-source components. Their licences follow."
  for dep in client-sdk-swift swift-collections swift-log swift-protobuf; do
    for kind in LICENSE NOTICE; do
      f=$(find ".build/checkouts/$dep" -maxdepth 1 -name "$kind*" | head -1)
      if [ -n "$f" ]; then echo; echo "==== $dep ($kind) ===="; echo; cat "$f"; fi
    done
  done
  f=$(find .build/artifacts -path "*LiveKitWebRTC.xcframework/LICENSE" | head -1)
  if [ -n "$f" ]; then echo; echo "==== LiveKit WebRTC (webrtc-xcframework) ===="; echo; cat "$f"; fi
} > "$STAGE/Third-party licences.txt"
ln -s /Applications "$STAGE/Applications"

# 5. The disk image.
DMG="$OUT/Framecast-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Framecast $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
