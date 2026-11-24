#!/bin/sh
# Builds "GPTK for Steam.app" next to this script, with GPTK 3 and 4 inside it.
set -e
cd "$(dirname "$0")"
app="GPTK for Steam.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos14 GPTKForSteam.swift -o "$app/Contents/MacOS/GPTKForSteam"
cp Resources/run "$app/Contents/Resources/run"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Apple's GPTK redistributables (non-commercial sharing allowed by Apple's GPTK license) and its license files.
cp -Rc Payload/gptk "$app/Contents/Resources/gptk" 2>/dev/null || ditto Payload/gptk "$app/Contents/Resources/gptk"
# Wine 11 for GPTK 4 (from GameHub; LGPL notice inside).
cp -Rc Payload/wine-11-gptk "$app/Contents/Resources/wine-11-gptk" 2>/dev/null || ditto Payload/wine-11-gptk "$app/Contents/Resources/wine-11-gptk"
# NotProton's Steam Play enabler, its support files and the open-source Steam bridge (GPLv3; licenses inside).
cp -Rc Payload/notproton "$app/Contents/Resources/notproton" 2>/dev/null || ditto Payload/notproton "$app/Contents/Resources/notproton"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GPTK for Steam</string>
  <key>CFBundleDisplayName</key><string>GPTK for Steam</string>
  <key>CFBundleIdentifier</key><string>local.gptk-for-steam</string>
  <key>CFBundleExecutable</key><string>GPTKForSteam</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$app"
echo "built $app ($(du -sh "$app" | cut -f1))"
