#!/bin/bash

# Debug script for App Attest issues
# This script helps identify common App Attest problems

echo "=================================="
echo "App Attest Debugging Tool"
echo "=================================="
echo ""

# Check if we're in the right directory
if [ ! -f "Catbird.xcodeproj/project.pbxproj" ]; then
    echo "❌ Error: Run this script from the Catbird project root directory"
    exit 1
fi

echo "1️⃣ Checking Bundle Identifier..."
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw Catbird/Resources/Info.plist 2>/dev/null)
if [ -z "$BUNDLE_ID" ]; then
    echo "   ⚠️  Could not find bundle identifier in Info.plist"
else
    echo "   ✅ Bundle ID: $BUNDLE_ID"
fi
echo ""

echo "2️⃣ Checking for Provisioning Profile..."
if [ -d "Catbird.app" ]; then
    if [ -f "Catbird.app/embedded.mobileprovision" ]; then
        echo "   ✅ Found embedded.mobileprovision"
        security cms -D -i Catbird.app/embedded.mobileprovision 2>/dev/null | grep -A 2 "application-identifier" | head -5
    else
        echo "   ⚠️  No embedded.mobileprovision found (may be App Store build)"
    fi
else
    echo "   ℹ️  App bundle not found - build the app first to check"
fi
echo ""

echo "3️⃣ Checking Entitlements..."
if [ -f "Catbird/Catbird.entitlements" ]; then
    echo "   ✅ Found Catbird.entitlements"
    
    # Check for App Attest related entitlements
    if grep -q "com.apple.developer.devicecheck.appattest-environment" Catbird/Catbird.entitlements; then
        ENV=$(plutil -extract "com.apple.developer.devicecheck.appattest-environment" raw Catbird/Catbird.entitlements 2>/dev/null)
        echo "   📱 App Attest Environment: $ENV"
    else
        echo "   ⚠️  No App Attest environment entitlement found"
    fi
    
    # Check for push notifications entitlement
    if grep -q "aps-environment" Catbird/Catbird.entitlements; then
        APNS_ENV=$(plutil -extract "aps-environment" raw Catbird/Catbird.entitlements 2>/dev/null)
        echo "   📱 APNS Environment: $APNS_ENV"
    else
        echo "   ⚠️  No APNS environment entitlement found"
    fi
else
    echo "   ❌ Catbird.entitlements file not found"
fi
echo ""

echo "4️⃣ Checking Build Settings..."
# Check if we can find the xcodeproj settings
DEVELOPMENT_TEAM=$(grep -A 1 "DevelopmentTeam" Catbird.xcodeproj/project.pbxproj | grep "=" | head -1 | sed 's/.*= //;s/;//' | tr -d ' ')
if [ ! -z "$DEVELOPMENT_TEAM" ]; then
    echo "   ✅ Development Team: $DEVELOPMENT_TEAM"
else
    echo "   ⚠️  Could not determine development team"
fi
echo ""

echo "5️⃣ Checking Xcode Version..."
xcodebuild -version
echo ""

echo "6️⃣ Checking Available Simulators..."
echo "   iOS Simulators with DeviceCheck support:"
xcrun simctl list devices available | grep "iPhone" | grep -v "SE" | head -3
echo ""

echo "7️⃣ Common App Attest Issues to Check:"
echo "   ❓ Is DCAppAttestService.shared.isSupported returning false?"
echo "      → This is EXPECTED on iOS Simulator"
echo "      → Only physical devices (iOS 14+) support App Attest"
echo ""
echo "   ❓ Getting 'featureUnsupported' error?"
echo "      → You're running on Simulator - use a physical device"
echo "      → Or device is iOS < 14.0"
echo ""
echo "   ❓ Getting 'invalidKey' or 'invalidInput' error?"
echo "      → Cached App Attest key is stale/invalid"
echo "      → App should automatically clear state and regenerate"
echo "      → Check UserDefaults or Keychain for cached keys"
echo ""
echo "   ❓ Getting HTTP 401/428 from server?"
echo "      → Server rejected the attestation/assertion"
echo "      → Check server logs for specific validation failure"
echo "      → May need 'key mismatch' or 're-attestation' flow"
echo ""
echo "   ❓ App Attest entitlement missing?"
echo "      → Add to Catbird.entitlements:"
echo "        <key>com.apple.developer.devicecheck.appattest-environment</key>"
echo "        <string>development</string>  <!-- or 'production' -->"
echo ""

echo "8️⃣ Testing Steps:"
echo "   1. Build and run on a PHYSICAL iOS device (not Simulator)"
echo "   2. Enable notifications in app"
echo "   3. Check Console.app logs filtered by 'Catbird'"
echo "   4. Look for App Attest related log messages:"
echo "      - '✅ App Attest is supported'"
echo "      - '🔑 Generating new App Attest key'"
echo "      - '🔐 Attempting to attest key'"
echo "      - '❌ App Attest ... failed'"
echo ""

echo "9️⃣ Recommended Testing Command:"
echo "   # Build and run on physical device"
echo "   xcodebuild -scheme Catbird -destination 'platform=iOS,id=YOUR_DEVICE_ID' build"
echo ""
echo "   # List connected devices to get ID:"
echo "   xcrun xctrace list devices"
echo ""

echo "=================================="
echo "Debug script complete!"
echo "=================================="
