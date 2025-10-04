# App Attest Debugging Analysis

## Overview
This document analyzes the App Attest implementation in Catbird and identifies potential issues and testing strategies.

## Current Implementation

### Architecture
The App Attest flow in Catbird follows this architecture:

```
User enables notifications
  ↓
requestNotificationPermission()
  ↓
registerForRemoteNotifications()
  ↓
handleDeviceToken() - receives APNS token
  ↓
registerDeviceToken()
  ↓
prepareAppAttestPayload()
  ↓
- Check DCAppAttestService.shared.isSupported
- Get or create App Attest key
- Generate attestation (if new key)
- Generate assertion
- Send to server at /devices endpoint
```

### Key Components

1. **NotificationManager.swift** - Main implementation
   - `prepareAppAttestPayload()` - Creates App Attest payload
   - `generateAppAttestKey()` - Generates new key via DCAppAttestService
   - `attestKey()` - Attests the key with Apple
   - `generateAppAttestAssertion()` - Creates assertion for server
   - `attachAppAttestAssertion()` - Attaches to HTTP requests

2. **AppState.swift** - State persistence
   - `appAttestInfo` - Stored key identifier and challenge
   - Persisted to UserDefaults with shared app group

3. **AppAttestState.swift** - Data models
   - `AppAttestInfo` - Key identifier and challenge
   - `AppAttestChallenge` - Server-provided challenge

## Known Issues & Common Problems

### Issue #1: Running on iOS Simulator
**Symptom:** `DCAppAttestService.shared.isSupported` returns `false`

**Why:** App Attest is NOT supported on iOS Simulator. It requires a physical device running iOS 14.0 or later.

**Detection in logs:**
```
⚠️ App Attest not supported by DCAppAttestService.isSupported
🔍 DEBUG: Running on Simulator: YES
❌ DeviceCheck/App Attest not supported on this device/simulator (featureUnsupported)
```

**Solution:** Test on a physical device, not simulator.

---

### Issue #2: Invalid or Stale Key
**Symptom:** `DCError.Code.invalidKey` or `.invalidInput` error

**Why:** 
- Cached key identifier no longer valid
- Key was invalidated by uninstalling/reinstalling app
- Key was deleted from Apple's servers
- Key was generated in different provisioning context

**Detection in logs:**
```
❌ DeviceCheck/App Attest invalid key (error 2)
💡 Stored App Attest state is no longer valid; clearing cached key and retrying
```

**Current handling:** The code DOES handle this:
```swift
private func shouldRetryAppAttest(for error: Error) -> Bool {
    guard let nsError = error as NSError?, nsError.domain == DCError.errorDomain else {
        return false
    }
    if let code = DCError.Code(rawValue: nsError.code) {
        return code == .invalidKey || code == .invalidInput
    }
    return nsError.code == 2 || nsError.code == 3
}
```

When this error occurs, the code should:
1. Detect it via `shouldRetryAppAttest()`
2. Call `clearAppAttestState()`
3. Retry with `forceKeyRotation: true`

---

### Issue #3: Server Rejection (HTTP 401/428)
**Symptom:** Server returns 401 or 428 status code

**Why:**
- Server failed to validate the attestation
- Key mismatch between client and server
- Assertion validation failed
- Challenge expired or mismatched

**Detection in logs:**
```
🔐 Server rejected App Attest (HTTP 401): [error message]
🔑 Server doesn't recognize key - forcing full key rotation and attestation
```

**Current handling:** The code checks for specific server messages:
```swift
let isKeyMismatch = serverError.lowercased().contains("key mismatch")
let requiresReattestation = serverError.lowercased().contains("requires re-attestation")
```

If detected, it triggers re-attestation flow.

---

### Issue #4: Missing or Invalid Entitlements
**Symptom:** Various cryptic errors, or `isSupported` returns false on physical device

**Why:** The entitlements file is missing required keys or has wrong values.

**Required entitlements:**
```xml
<key>com.apple.developer.devicecheck.appattest-environment</key>
<string>development</string>  <!-- or 'production' -->

<key>com.apple.developer.devicecheck.app-attest-opt-in</key>
<array>
    <string>CDhash</string>
</array>

<key>aps-environment</key>
<string>development</string>  <!-- or 'production' -->
```

**Current status:** ✅ All required entitlements are present in `Catbird.entitlements`

---

### Issue #5: Challenge Flow Problems
**Symptom:** Server rejects assertion due to challenge mismatch

**Why:**
- Challenge expired before assertion was generated
- Challenge not properly stored/retrieved
- Race condition in challenge rotation

**Current handling:**
- Server returns `next_challenge` in responses
- Code extracts and stores it via `applyChallengeRotation()`
- Challenge has expiration date with 30-second grace period

---

## Testing Strategy

### Step 1: Verify Environment
```bash
# Run the debug script
./debug_app_attest.sh

# Check:
# ✅ Entitlements are present
# ✅ Bundle ID is set correctly
# ✅ Development team is configured
```

### Step 2: Test on Physical Device
App Attest **ONLY** works on physical devices. You must:

1. Connect an iOS device (iOS 14.0+)
2. Trust the device in Xcode
3. Build and run on the device

```bash
# List available devices
xcrun xctrace list devices

# Build for specific device
xcodebuild -scheme Catbird \
    -destination 'platform=iOS,id=YOUR_DEVICE_ID' \
    build

# Or use Xcode: Product > Destination > [Your Device]
```

### Step 3: Enable Detailed Logging
The code already has extensive logging. To view:

1. **Console.app** (macOS)
   - Open Console.app
   - Connect your iOS device
   - Filter by process "Catbird" or subsystem "blue.catbird"
   - Look for category "Notifications"

2. **Xcode Console**
   - Run app from Xcode
   - View logs in the Xcode console panel

### Step 4: Watch for Key Log Messages

**✅ Success indicators:**
```
✅ App Attest is supported, proceeding with attestation
🔑 Generating new App Attest key...
✅ App Attest key generated: [KEY_ID]
🔐 Attempting to attest key: [KEY_ID]
✅ App Attest attestation successful, size: [X] bytes
✅ Device token successfully registered
```

**❌ Failure indicators:**
```
❌ App Attest generateKey failed: [ERROR]
❌ App Attest attestKey failed: [ERROR]
❌ Server rejected App Attest (HTTP 401/428): [ERROR]
⚠️ App Attest not supported by DCAppAttestService.isSupported
```

### Step 5: Test Re-attestation Flow
To test the re-attestation circuit breaker:

1. Enable notifications (should succeed)
2. Manually clear App Attest state:
   - Delete and reinstall app
   - Or use device settings to reset app data
3. Try to update preferences (should trigger re-attestation)
4. Verify the UI shows re-attestation prompt if needed

---

## Code Flow Walkthrough

### Initial Registration Flow

```swift
// 1. User enables notifications
NotificationSettingsView.enableAllNotifications()
  ↓
// 2. Request permission
NotificationManager.requestNotificationPermission()
  ↓  
// 3. If granted, register for APNS
UIApplication.shared.registerForRemoteNotifications()
  ↓
// 4. System calls AppDelegate/App
application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
  ↓
// 5. Pass to NotificationManager
NotificationManager.handleDeviceToken(deviceToken)
  ↓
// 6. Register with push server
NotificationManager.registerDeviceToken(deviceToken)
  ↓
// 7. Prepare App Attest payload
NotificationManager.prepareAppAttestPayload()
```

### prepareAppAttestPayload() Detailed Flow

```swift
func prepareAppAttestPayload(...) async throws -> AppAttestRequestPayload {
    // 1. Check if App Attest is supported
    guard DCAppAttestService.shared.isSupported else {
        throw NotificationServiceError.appAttestUnsupported
    }
    
    // 2. Get or create App Attest key
    let keyIdentifier: String
    if let existing = await currentAppAttestInfo()?.keyIdentifier,
       !forceKeyRotation {
        // Use existing key
        keyIdentifier = existing
    } else {
        // Generate new key
        keyIdentifier = try await generateAppAttestKey()
    }
    
    // 3. Get challenge from server
    let tokenHex = hexString(from: deviceToken)
    let challenge = try await requestNewChallenge(
        for: did,
        token: tokenHex,
        forceKeyRotation: forceKeyRotation
    )
    
    // 4. Create client data (WebAuthn format)
    let clientData = try makeClientDataBytes(for: challenge)
    
    // 5. Hash: SHA256(clientData + optional body)
    var digestInput = clientData
    if let bindBody {
        digestInput.append(bindBody)
    }
    let clientDataHash = Data(SHA256.hash(data: digestInput))
    
    // 6. Generate attestation (if new key)
    var attestation: String?
    if needsAttestation || forceAttestation {
        let attestationData = try await attestKey(
            keyIdentifier,
            clientDataHash: clientDataHash
        )
        attestation = attestationData.base64EncodedString()
    }
    
    // 7. Generate assertion (always)
    let assertionData = try await generateAppAttestAssertion(
        keyIdentifier,
        clientDataHash: clientDataHash
    )
    let assertion = assertionData.base64EncodedString()
    
    // 8. Return payload
    return AppAttestRequestPayload(
        keyID: keyIdentifier,
        assertion: assertion,
        clientData: clientDataString,
        challenge: challenge.challenge,
        attestation: attestation
    )
}
```

### Error Recovery Flow

```swift
// If generateAppAttestKey() fails with invalidKey:
do {
    keyIdentifier = try await generateAppAttestKey()
} catch {
    if shouldRetryAppAttest(for: error), attempt == 0 {
        // Clear cached state
        await clearAppAttestState()
        
        // Retry with forced key rotation
        return try await prepareAppAttestPayload(
            ...,
            forceKeyRotation: true,
            forceAttestation: true,
            attempt: attempt + 1
        )
    }
    throw error
}
```

---

## Potential Issues in Current Implementation

### Potential Issue #1: Challenge Race Condition
**Location:** `prepareAppAttestPayload()` line ~1299

**Problem:** If a challenge expires between:
1. Fetching it from `currentAppAttestInfo()`
2. Using it to generate assertion

**Current mitigation:** Server challenge has expiration date with 30-second grace period.

**Recommendation:** Consider checking `challenge.isExpired` before using cached challenge.

---

### Potential Issue #2: Concurrent Registration Attempts
**Location:** `registerDeviceToken()` line ~724

**Problem:** Multiple simultaneous calls could create race conditions.

**Current mitigation:** ✅ Already handled via `RegistrationCoordinator` actor:
```swift
guard await registrationCoordinator.begin() else {
    notificationLogger.info("⏳ Registration already in progress; ignoring duplicate request")
    return
}
```

---

### Potential Issue #3: Circuit Breaker May Be Too Restrictive
**Location:** `ReattestationCircuitBreaker` line ~50

**Current settings:**
- Max attempts: 3
- Reset interval: 5 minutes

**Problem:** If user has persistent issue (e.g., server problem), they're locked out for 5 minutes after 3 attempts.

**Recommendation:** Consider:
- User-visible feedback when circuit breaker triggers
- Allow manual reset via "Try Again" button
- Different limits for different operations

---

### Potential Issue #4: No Timeout on Attestation Operations
**Location:** All `DCAppAttestService` calls

**Problem:** Apple's APIs are async callbacks without timeout. If they hang, the registration hangs forever.

**Current mitigation:** None explicitly in code.

**Recommendation:** Add timeout wrapper:
```swift
try await withTimeout(seconds: 30) {
    try await generateAppAttestKey()
}
```

---

## Debugging Checklist

When user reports "App Attest not working":

- [ ] Are they testing on a physical device (not Simulator)?
- [ ] Is the device running iOS 14.0 or later?
- [ ] Does the app have proper entitlements signed with valid provisioning profile?
- [ ] Are they connected to the internet (for challenge request)?
- [ ] Check Console.app logs for specific error messages
- [ ] Has the user tried:
  - [ ] Toggling notifications off/on
  - [ ] Restarting the app
  - [ ] Reinstalling the app
  - [ ] Checking Settings > [App] > Notifications permissions
- [ ] Is the server returning proper challenges?
- [ ] Are server validation errors being logged?

---

## Recommended Testing Script

```bash
#!/bin/bash
# comprehensive_app_attest_test.sh

echo "Testing App Attest Implementation"

# 1. Verify entitlements
echo "1. Checking entitlements..."
plutil -p Catbird/Catbird.entitlements | grep -A 1 "appattest"

# 2. Build for device
echo "2. Building for physical device..."
DEVICE_ID=$(xcrun xctrace list devices | grep "iPhone" | grep -v "Simulator" | head -1 | sed 's/.* (\([^)]*\)).*/\1/')
if [ -z "$DEVICE_ID" ]; then
    echo "❌ No physical device connected"
    exit 1
fi
echo "   Device ID: $DEVICE_ID"

xcodebuild -scheme Catbird \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -configuration Debug \
    build

# 3. Install and run
echo "3. Installing on device..."
# (Xcode handles this automatically on build)

echo "4. Now:"
echo "   a. Open Console.app on Mac"
echo "   b. Connect your device"
echo "   c. Filter by process 'Catbird' and category 'Notifications'"
echo "   d. Launch app and enable notifications"
echo "   e. Watch for App Attest log messages"
```

---

## Summary

The App Attest implementation in Catbird is comprehensive and handles most edge cases correctly:

✅ **Good practices:**
- Extensive logging at each step
- Error recovery with retry logic
- Circuit breaker pattern to prevent infinite loops
- Proper state persistence
- Server challenge rotation
- Detection of key mismatch and re-attestation needs

⚠️ **Areas for improvement:**
- Add explicit timeouts to Apple API calls
- Better user feedback when circuit breaker triggers
- Challenge expiration check before use
- More granular error messages to user

🧪 **Testing requirements:**
- **MUST** test on physical device
- Cannot be fully tested on Simulator
- Need server logs to diagnose server-side validation failures
- Should test re-attestation flow explicitly

The most common issue will be users trying to test on Simulator. The code correctly detects this and logs appropriate warnings.
