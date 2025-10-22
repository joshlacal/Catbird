# Mac Catalyst App Sandbox Fix

## Issue
**Error 90296**: App sandbox not enabled for SharedDraftImporter extension in Mac Catalyst builds.

```
App sandbox not enabled. The following executables must include the 
"com.apple.security.app-sandbox" entitlement with a Boolean value of true:
SharedDraftImporter.appex/Contents/MacOS/SharedDraftImporter
```

## Root Cause

When building for **Mac Catalyst** (macOS via UIKit), Apple requires the App Sandbox to be enabled for security. This applies to:
- The main app
- **ALL app extensions** (Share Extensions, Widgets, etc.)

The issue occurred because:
1. Main app (`Catbird.entitlements`) ✅ Had `com.apple.security.app-sandbox = true`
2. FeedWidget (`CatbirdFeedWidget.entitlements`) ✅ Had the entitlement
3. SharedDraftImporter ❌ **Missing** the entitlement
4. NotificationWidget ❌ **Missing** the entitlement

## Why This Matters for Catalyst

- **iOS builds**: App Sandbox is implicit, not explicitly required in entitlements
- **Mac Catalyst builds**: Must explicitly declare `com.apple.security.app-sandbox = true`
- **macOS builds**: Always requires App Sandbox for App Store distribution

The error only appears when:
- Building for Mac Catalyst
- Attempting App Store validation
- Archive/distribution phase (not debug builds)

## Solution

Added `com.apple.security.app-sandbox` entitlement to all extension targets:

### SharedDraftImporter.entitlements
```xml
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.blue.catbird.shared</string>
    </array>
</dict>
```

### CatbirdNotificationWidgetExtension.entitlements
```xml
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.blue.catbird.shared</string>
    </array>
</dict>
```

## Verification

Check all entitlements have sandbox enabled:
```bash
# Main app
plutil -p Catbird/Catbird.entitlements | grep app-sandbox

# Extensions
plutil -p SharedDraftImporter/SharedDraftImporter.entitlements | grep app-sandbox
plutil -p CatbirdNotificationWidgetExtension.entitlements | grep app-sandbox
plutil -p CatbirdFeedWidget/CatbirdFeedWidget.entitlements | grep app-sandbox
```

All should show:
```
"com.apple.security.app-sandbox" => 1
```

## App Sandbox Capabilities

With App Sandbox enabled, you may need to add additional entitlements for:

### File Access
```xml
<!-- Read-only access to user-selected files -->
<key>com.apple.security.files.user-selected.read-only</key>
<true/>

<!-- Read-write access to user-selected files -->
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

### Network Access (if needed)
```xml
<!-- Outgoing network connections -->
<key>com.apple.security.network.client</key>
<true/>

<!-- Incoming network connections -->
<key>com.apple.security.network.server</key>
<true/>
```

### App Groups (already configured)
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.blue.catbird.shared</string>
</array>
```

## Testing

### iOS Build (No Change Required)
```bash
xcodebuild -project Catbird.xcodeproj \
  -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build
```

### Mac Catalyst Build (Should Now Pass)
```bash
xcodebuild -project Catbird.xcodeproj \
  -scheme Catbird \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  build
```

### macOS Build
```bash
xcodebuild -project Catbird.xcodeproj \
  -scheme Catbird \
  -destination 'platform=macOS' \
  build
```

## App Store Validation

Before this fix:
```
❌ Error 90296: App sandbox not enabled for SharedDraftImporter
```

After this fix:
```
✅ All executables have required app-sandbox entitlement
✅ Ready for App Store submission
```

## Related Documentation

- [App Sandbox - Apple Developer](https://developer.apple.com/documentation/security/app_sandbox)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/security/app_sandbox/configuring_the_macos_app_sandbox)
- [Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements)

## Commit

Fixed in commit: `76074ed`
```
fix(catalyst): add app sandbox entitlement to extension targets

- Added app-sandbox entitlement to SharedDraftImporter extension
- Added app-sandbox entitlement to CatbirdNotificationWidget extension
- Required for Mac Catalyst App Store submission
```
