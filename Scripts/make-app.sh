#!/bin/bash
# Build and package InkSweep.app into ./build.
#
# Usage: ./Scripts/make-app.sh [open]
#
# VERSION and BUILD override the plist version (default 0.1.0 / 1):
#   VERSION=0.2.0 BUILD=17 ./Scripts/make-app.sh
#
# Signing: uses SIGN_IDENTITY if set, otherwise the first "Developer ID
# Application" certificate in your keychain, otherwise an ad-hoc signature.
# RELEASE=1 additionally asks Apple's timestamp server for a secure timestamp
# (required for notarization) — the same pipeline as InkBar/InkStats.

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="release"
APP="build/InkSweep.app"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
    SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi
# Notarization needs a secure timestamp; local builds skip the network call.
TIMESTAMP=--timestamp=none
[[ "${RELEASE:-}" == 1 ]] && TIMESTAMP=--timestamp

echo "building ($CONFIG)…"
swift build -c "$CONFIG"

echo "packaging $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/InkSweepApp" "$APP/Contents/MacOS/InkSweep"
# The CLI rides along for Smart Care's daily background scan (LaunchAgent).
# Sign it before it goes inside the bundle, so notarization sees a signed helper.
codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" ".build/$CONFIG/inksweep"
cp ".build/$CONFIG/inksweep" "$APP/Contents/Resources/inksweep"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>InkSweep</string>
    <key>CFBundleDisplayName</key>      <string>InkSweep</string>
    <key>CFBundleIdentifier</key>       <string>com.amosw.inksweep</string>
    <key>CFBundleExecutable</key>       <string>InkSweep</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>          <string>$BUILD</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>NSAccentColorName</key>        <string>AccentColor</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>NSSupportsSuddenTermination</key>    <false/>
</dict>
</plist>
EOF

# Icon: generate on demand, then convert to icns.
if [[ ! -f Scripts/AppIcon.icns ]]; then
  echo "generating icon…"
  swift Scripts/icongen.swift Scripts/icon-1024.png
  ICONSET=Scripts/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s     Scripts/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
    sips -z $((s*2)) $((s*2)) Scripts/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  sips -z 1024 1024 Scripts/icon-1024.png --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o Scripts/AppIcon.icns
  rm -rf "$ICONSET" Scripts/icon-1024.png
fi
cp Scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Vermilion accent (InkKit's red, light and dark): focus rings, pop-ups,
# selection and every native control speak the family colour.
xcrun actool Scripts/Assets.xcassets --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --output-partial-info-plist /dev/null >/dev/null

echo "signing ($SIGN_IDENTITY)…"
codesign --force --options runtime "$TIMESTAMP" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo
echo "OK: $APP  ($VERSION build $BUILD)"
echo "First run:  open $APP"
echo "Full Disk Access: add InkSweep in System Settings → Privacy & Security →"
echo "Full Disk Access, then use the in-app link (enables Trash + Safari data)."
