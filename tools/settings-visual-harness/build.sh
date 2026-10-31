#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUTPUT=${1:?Pass an absolute artifact directory outside iCloud}
TOKEN_SOURCE=${2:-"$ROOT/Catbird/Core/UI/DesignTokens.swift"}
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
APP="$OUTPUT/SettingsTypographyHarness.app"
mkdir -p "$APP"
xcrun swiftc -j 2 -parse-as-library -swift-version 5 -sdk "$SDK" \
  -target arm64-apple-ios18.0-simulator -module-name SettingsTypographyHarness \
  "$TOKEN_SOURCE" \
  "$ROOT/Catbird/Core/State/FontManager.swift" \
  "$ROOT/Catbird/Core/Extensions/Typography.swift" \
  "$ROOT/tools/settings-visual-harness/FixtureSupport.swift" \
  "$ROOT/tools/settings-visual-harness/TypographyHarness.swift" \
  -o "$APP/SettingsTypographyHarness"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>blue.catbird.fixture.typography</string>
<key>CFBundleExecutable</key><string>SettingsTypographyHarness</string>
<key>CFBundleName</key><string>Typography Fixture</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>MinimumOSVersion</key><string>18.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
shasum -a 256 "$TOKEN_SOURCE" "$ROOT/Catbird/Core/State/FontManager.swift" \
  "$ROOT/Catbird/Core/Extensions/Typography.swift" \
  "$ROOT/tools/settings-visual-harness/FixtureSupport.swift" \
  "$ROOT/tools/settings-visual-harness/TypographyHarness.swift" \
  "$APP/SettingsTypographyHarness" > "$OUTPUT/source-and-binary.sha256"
xcrun swiftc --version > "$OUTPUT/compiler.txt"
