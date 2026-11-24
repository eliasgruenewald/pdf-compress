#!/bin/zsh
# Builds "PDF Compress.app" (Apple silicon) and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/PDF Compress.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  main.swift -o "$APP/Contents/MacOS/PDFCompress"
cp Info.plist "$APP/Contents/Info.plist"

# App icon
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
swift icon.swift build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"

rm -rf "/Applications/PDF Compress.app"
cp -R "$APP" /Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/PDF Compress.app"
echo "Installed /Applications/PDF Compress.app"
