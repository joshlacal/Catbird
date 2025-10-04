# App Attest Debugging Resources

This directory contains tools and documentation for debugging App Attest issues in Catbird.

## 📚 Documentation

### [APP_ATTEST_TESTING_GUIDE.md](./APP_ATTEST_TESTING_GUIDE.md)
**Start here!** Step-by-step guide for testing App Attest:
- Quick start instructions
- Testing scenarios (happy path, error recovery, etc.)
- Using the in-app diagnostic tools
- Common issues and solutions
- Performance benchmarks

### [APP_ATTEST_DEBUG_ANALYSIS.md](./APP_ATTEST_DEBUG_ANALYSIS.md)
Technical deep-dive into the implementation:
- Architecture overview
- Code flow walkthrough
- Known issues and edge cases
- Potential improvements
- Implementation details

## 🛠 Tools

### 1. Debug Script: `debug_app_attest.sh`
Run this first to check your environment:
```bash
./debug_app_attest.sh
```

**What it checks:**
- ✅ Bundle identifier
- ✅ Provisioning profile
- ✅ Entitlements configuration
- ✅ Build settings
- ✅ Available simulators/devices
- ✅ Common issues

### 2. In-App Diagnostics (DEBUG builds)
Built into the app's notification settings:

**Location:** Settings > Notifications > "App Attest Diagnostics"

**Features:**
- Platform detection (Simulator vs Physical Device)
- DCAppAttestService support status
- OS version compatibility
- Bundle ID verification
- Entitlement check
- Real-time key generation testing

**How to use:**
1. Build DEBUG configuration of app
2. Navigate to Settings > Notifications
3. Scroll to bottom "Developer Tools" section
4. Tap "App Attest Diagnostics" to expand
5. Review status indicators
6. Optionally tap "Test Key Generation"

### 3. Code Utility: `AppAttestDebugger.swift`
Swift utility for programmatic checks:

**Location:** `Catbird/Core/Utilities/AppAttestDebugger.swift`

**Usage:**
```swift
// Check environment
let status = AppAttestDebugger.performEnvironmentCheck()
if status.canUseAppAttest {
    print("✅ Ready to use App Attest")
} else {
    print("❌ App Attest not available")
}

// Log detailed diagnostics
AppAttestDebugger.logDiagnostics()

// Get user-friendly message
let message = AppAttestDebugger.getUserFriendlyMessage()

// Test key generation
let result = await AppAttestDebugger.testKeyGeneration()
```

## 🚀 Quick Start

### For First-Time Setup

1. **Run the debug script:**
   ```bash
   ./debug_app_attest.sh
   ```

2. **Review checklist:**
   - [ ] Physical iOS device connected (iOS 14+)
   - [ ] Valid provisioning profile
   - [ ] Entitlements configured
   - [ ] Development team set

3. **Build and test:**
   ```bash
   # Build for physical device
   xcodebuild -scheme Catbird \
       -destination 'platform=iOS,id=YOUR_DEVICE_ID' \
       build
   ```

4. **Open app and check diagnostics:**
   - Settings > Notifications > App Attest Diagnostics
   - All items should show green checkmarks

5. **Enable notifications:**
   - Toggle "Push Notifications" ON
   - Watch Xcode console for log messages
   - Should see "✅ Device token successfully registered"

### For Debugging Issues

1. **Identify the issue:**
   - Check in-app diagnostics first
   - Review Xcode console logs
   - Check Console.app for detailed logs

2. **Common issues:**
   - Running on Simulator → Use physical device
   - Invalid key error → Auto-recovers, wait 5 minutes if circuit breaker triggers
   - Server rejection → Check server logs and configuration

3. **Consult documentation:**
   - See [APP_ATTEST_TESTING_GUIDE.md](./APP_ATTEST_TESTING_GUIDE.md) for specific scenarios
   - See [APP_ATTEST_DEBUG_ANALYSIS.md](./APP_ATTEST_DEBUG_ANALYSIS.md) for technical details

## 📋 Key Concepts

### What is App Attest?
Apple's framework for cryptographically proving:
- Your app is genuine (not tampered with)
- Requests come from a real device
- The app binary matches what you submitted to Apple

### When is it used in Catbird?
- Push notification registration
- Preference updates
- Relationship syncing
- Activity subscriptions

### Requirements
- **iOS 14.0+** or **macOS 11.0+**
- **Physical device** (NOT Simulator)
- **Valid provisioning profile**
- **Proper entitlements**
- **Network connectivity** (to reach Apple's servers)

### Architecture
```
App → Generate Key → Attest Key → Generate Assertion → Server
                    (first time)     (every request)
```

## 🔍 Troubleshooting

### "App Attest not supported"
→ You're on iOS Simulator. Test on a physical device.

### "Invalid key" error
→ App should auto-recover. If not, wait 5 minutes and try again.

### Server returns 401/428
→ Server validation failed. Check server logs for specific error.

### Infinite spinner / hanging
→ Check network connection. Try restarting app.

### Circuit breaker triggered
→ Too many failed attempts. Wait 5 minutes before retrying.

## 📊 Log Messages to Watch For

### ✅ Success
```
✅ App Attest is supported, proceeding with attestation
🔑 Generating new App Attest key...
✅ App Attest key generated: [KEY_ID]
✅ App Attest attestation successful
✅ Device token successfully registered
```

### ⚠️ Expected Warnings
```
⚠️ App Attest not supported (on Simulator - expected)
🔁 Retrying with fresh App Attest assertion
💡 Stored App Attest state is no longer valid (will auto-recover)
```

### ❌ Critical Errors
```
❌ App Attest generateKey failed: [ERROR]
❌ Server rejected App Attest (HTTP 401): [ERROR]
⏸️ Re-attestation circuit breaker triggered
```

## 🎯 Testing Checklist

Before releasing, verify:
- [ ] Works on physical device (not just Simulator)
- [ ] Fresh install scenario
- [ ] Re-enable after disable
- [ ] Multiple preference updates
- [ ] App reinstall recovery
- [ ] Network interruption handling
- [ ] Server rejection handling
- [ ] Push notifications actually delivered

## 📞 Need Help?

1. **Read the guides:**
   - Start with [APP_ATTEST_TESTING_GUIDE.md](./APP_ATTEST_TESTING_GUIDE.md)
   - Consult [APP_ATTEST_DEBUG_ANALYSIS.md](./APP_ATTEST_DEBUG_ANALYSIS.md) for details

2. **Use the tools:**
   - Run `./debug_app_attest.sh`
   - Check in-app diagnostics
   - Review Console.app logs

3. **Check Apple's resources:**
   - [DeviceCheck Documentation](https://developer.apple.com/documentation/devicecheck)
   - [App Attest Guide](https://developer.apple.com/documentation/devicecheck/validating_apps_that_connect_to_your_server)
   - [System Status](https://developer.apple.com/system-status/) - Check if DeviceCheck is down

4. **Common gotchas:**
   - Must use physical device (not Simulator)
   - Requires iOS 14+ or macOS 11+
   - Network connectivity required
   - Server must properly validate attestations

## 📝 Files Modified

This debugging enhancement added/modified:
- ✅ `debug_app_attest.sh` - Diagnostic shell script
- ✅ `APP_ATTEST_TESTING_GUIDE.md` - Testing guide
- ✅ `APP_ATTEST_DEBUG_ANALYSIS.md` - Technical analysis
- ✅ `APP_ATTEST_README.md` - This file
- ✅ `Core/Utilities/AppAttestDebugger.swift` - Debug utility
- ✅ `Features/Settings/Views/NotificationSettingsView.swift` - Added DEBUG diagnostics UI

## 🔒 Security Note

The diagnostic tools are:
- Only included in DEBUG builds
- Never exposed in production
- Safe to use during development
- Do not compromise App Attest security

Test key generation in diagnostics:
- Creates a temporary key
- Does not interfere with production keys
- Used only for validation testing
- Automatically cleaned up by iOS

---

**Last Updated:** January 2025
**Compatible with:** iOS 26.0+, macOS 26.0+
**Xcode Version:** 16.0+
