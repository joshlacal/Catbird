# Xcode Integration Instructions for CatbirdMLSCore

## Overview
This guide walks you through adding the CatbirdMLSCore local Swift package to your Xcode project and linking it to both the main Catbird app and the NotificationServiceExtension.

---

## Step 1: Add Local Swift Package to Xcode

1. **Open Catbird.xcodeproj in Xcode**
   - Navigate to `/Users/joshlacalamito/Developer/Catbird+Petrel/Catbird/`
   - Double-click `Catbird.xcodeproj`

2. **Add Package Dependency**
   - In Xcode, select the **Catbird** project in the Project Navigator (top-level blue icon)
   - Select the **Catbird** project (not a target) in the editor area
   - Click the **Package Dependencies** tab
   - Click the **+** button (bottom left)
   - Click **Add Local...** button
   - Navigate to and select: `/Users/joshlacalamito/Developer/Catbird+Petrel/Catbird/CatbirdMLSCore/`
   - Click **Add Package**

3. **Select Targets**
   - A dialog will appear asking which targets should link to CatbirdMLSCore
   - **Check both**:
     - ☑️ `Catbird` (main app)
     - ☑️ `NotificationServiceExtension`
   - Click **Add Package**

---

## Step 2: Link GRDB to Targets

The CatbirdMLSCore package depends on GRDB, which should already be in your project as a Swift Package Manager dependency.

1. **Verify GRDB is Added**
   - In the Project Navigator, look for **Package Dependencies** section
   - You should see `GRDB` listed

2. **Link GRDB to NotificationServiceExtension**
   - Select the **Catbird** project
   - Select the **NotificationServiceExtension** target
   - Go to the **General** tab
   - Scroll to **Frameworks and Libraries**
   - Click **+** button
   - Search for `GRDB`
   - Select `GRDB` from the list
   - Click **Add**
   - Ensure it's set to **"Do Not Embed"** (frameworks from SPM should not be embedded)

---

## Step 3: Add MLSFFIFramework.xcframework to CatbirdMLSCore (Manual)

The generated Swift bindings from UniFFI need the MLSFFIFramework binary.

### Option A: Add as Binary Target in Package.swift (Recommended)

1. **Edit Package.swift**
   - Open `/Users/joshlacalamito/Developer/Catbird+Petrel/Catbird/CatbirdMLSCore/Package.swift`
   - Find the `// TODO: Add MLSFFIFramework` comment
   - Replace with:
   ```swift
   .binaryTarget(
       name: "MLSFFIFramework",
       path: "../../MLSFFIFramework.xcframework"
   )
   ```

2. **Update CatbirdMLSCore Target Dependencies**
   - In the same file, find the `targets` array
   - Add `"MLSFFIFramework"` to the `CatbirdMLSCore` target dependencies:
   ```swift
   .target(
       name: "CatbirdMLSCore",
       dependencies: [
           .product(name: "GRDB", package: "GRDB.swift"),
           "MLSFFIFramework"  // ADD THIS
       ]
   ),
   ```

3. **Reload Package in Xcode**
   - Right-click on `CatbirdMLSCore` in Package Dependencies
   - Select **Update Package**

### Option B: Add Directly to Targets (Alternative)

If Option A doesn't work, manually add the xcframework:

1. **Select Catbird Target**
   - Project Navigator → **Catbird** project → **Catbird** target
   - **General** tab → **Frameworks and Libraries**
   - Click **+** → **Add Other...** → **Add Files...**
   - Navigate to `/Users/joshlacalamito/Developer/Catbird+Petrel/Catbird/MLSFFIFramework.xcframework`
   - Click **Add**
   - Set to **Embed & Sign**

2. **Repeat for NotificationServiceExtension**
   - Same steps but select **NotificationServiceExtension** target
   - Add `MLSFFIFramework.xcframework`
   - Set to **Do Not Embed** (extensions should reference, not embed)

---

## Step 4: Configure Build Settings

### 4.1 Enable App Groups (Already Done)

Both targets should already have App Groups enabled. Verify:

1. **Main App**
   - Select **Catbird** target → **Signing & Capabilities**
   - Verify `App Groups` capability exists
   - Verify `group.blue.catbird.shared` is checked

2. **Extension**
   - Select **NotificationServiceExtension** target → **Signing & Capabilities**
   - Verify `App Groups` capability exists
   - Verify `group.blue.catbird.shared` is checked

### 4.2 Enable Keychain Sharing (Already Done)

Verify keychain access groups:

1. **Main App**
   - **Catbird** target → **Signing & Capabilities**
   - Verify `Keychain Sharing` capability exists
   - Verify `blue.catbird.shared` is in the list

2. **Extension**
   - **NotificationServiceExtension** target → **Signing & Capabilities**
   - Verify `Keychain Sharing` capability exists
   - Verify `blue.catbird.shared` is in the list

---

## Step 5: Clean and Build

1. **Clean Build Folder**
   - In Xcode menu: **Product** → **Clean Build Folder** (⇧⌘K)

2. **Build Main App**
   - Select **Catbird** scheme
   - Build (⌘B)
   - Resolve any import errors by ensuring `import CatbirdMLSCore` is at the top of files

3. **Build Extension**
   - Select **NotificationServiceExtension** scheme
   - Build (⌘B)

4. **Build for Device** (Important!)
   - Select a physical device or "Any iOS Device"
   - Build again to verify arm64 architecture works
   - Extensions must work on real devices for notification testing

---

## Step 6: Verify Integration

### 6.1 Check Imports

Verify these files import `CatbirdMLSCore`:

**Main App**:
- `Catbird/Services/MLS/MLSClient.swift` (line 6: `import CatbirdMLSCore`)

**Extension**:
- `NotificationServiceExtension/NotificationService.swift` (line 4: `import CatbirdMLSCore`)

### 6.2 Check Shared State Access

Both targets should now access:
- Shared MLS database: `group.blue.catbird.shared/mls-state/{userDID}.db`
- Shared Keychain: via `blue.catbird.shared` access group
- Shared MLS contexts: via `MLSCoreContext.shared`

---

## Step 7: Test the Integration

### 7.1 Main App Decryption Test

1. Run the main Catbird app on a simulator or device
2. Open a conversation with MLS encryption
3. Send/receive a test message
4. Check Console logs for:
   ```
   ✅ Decrypted and cached plaintext with proper metadata
   💾 Saved plaintext with epoch: X, sequence: Y
   ```
5. Verify `epoch` and `sequence` are **not 0** (should be real values from FFI)

### 7.2 Extension Decryption Test

**Prerequisites**:
- Physical iOS device (notifications don't work well in simulator)
- Valid APNs push notification certificate configured
- Server setup to send MLS encrypted notifications

**Test Steps**:
1. Install app on physical device
2. Trigger a server-sent MLS encrypted notification
3. Notification should appear with decrypted message text (not "New Encrypted Message")
4. Open the app - message should load instantly (from cache, no re-decryption)
5. Check device Console logs:
   ```
   🔓 Decrypting message abc12345... for did:plc:xyz...
   ✅ Successfully decrypted and cached message
   💾 Saved plaintext with epoch: X, sequence: Y
   ```

### 7.3 Single Decryption Verification

**Goal**: Verify extension decrypts once, app reads from cache

1. Send encrypted notification → Extension decrypts and saves
2. Open app → App should read from database (no decryption)
3. Check logs:
   - Extension logs: `✅ Decrypted and cached plaintext`
   - App logs: `✅ Loaded cached plaintext from database` (no decryption log)

---

## Troubleshooting

### Issue: "Cannot find 'MLSCoreContext' in scope"

**Solution**:
- Ensure `import CatbirdMLSCore` is at the top of the file
- Clean build folder (⇧⌘K)
- Delete DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData`
- Rebuild

### Issue: "No such module 'CatbirdMLSCore'"

**Solution**:
- Verify the package is added: Project → Package Dependencies → `CatbirdMLSCore` should be listed
- Verify target dependencies: Target → General → Frameworks and Libraries → `CatbirdMLSCore` should be there
- Try removing and re-adding the package

### Issue: "Undefined symbol: _swift_FORCE_LOAD_$_MLSFFIFramework"

**Solution**:
- The MLSFFIFramework.xcframework is not properly linked
- Follow Step 3 again carefully
- Ensure the xcframework is in **both** main app and extension targets

### Issue: Extension shows "New Encrypted Message" instead of decrypted text

**Possible Causes**:
1. **Keychain not shared** - Check Step 4.2
2. **App Group not shared** - Check Step 4.1
3. **MLS database doesn't exist** - Main app must create it first
4. **Wrong userDID** - Check notification payload has correct `recipient_did`

**Debug**:
- Connect device to Xcode
- Window → Devices and Simulators → Select device → View Device Logs
- Filter by `blue.catbird.notification-service`
- Look for error messages

### Issue: Epoch and sequence are still 0

**Causes**:
- Rust FFI changes not applied
- Swift bindings not regenerated
- Using old `DecryptResult` struct

**Solution**:
1. Verify Rust changes in `/Users/joshlacalamito/Developer/Catbird+Petrel/MLSFFI/mls-ffi/src/types.rs`
2. Rebuild Rust: `cd mls-ffi && cargo build --release`
3. Regenerate bindings (see `RUST_FFI_CHANGES_NEEDED.md`)
4. Verify generated `MLSFFI.swift` has `epoch` and `sequenceNumber` fields

---

## Next Steps After Integration

1. **Test with multiple users** - Verify per-user context isolation works
2. **Test epoch advancement** - Send many messages, verify epochs increment
3. **Test forward secrecy** - Wait for epoch expiry, verify old messages can't be decrypted
4. **Test multi-device** - Same user on multiple devices, verify all devices decrypt correctly
5. **Profile memory usage** - Extension must stay under ~20 MB
6. **Profile decryption time** - Should be <100ms for extension

---

## Files Modified

**Created**:
- `CatbirdMLSCore/` (entire Swift package)
- `RUST_FFI_CHANGES_NEEDED.md`
- `XCODE_INTEGRATION_INSTRUCTIONS.md` (this file)

**Modified**:
- `MLSFFI/mls-ffi/src/types.rs` (added epoch and sequence_number to DecryptResult)
- `MLSFFI/mls-ffi/src/api.rs` (updated decrypt_message to populate new fields)
- `Catbird/Services/MLS/MLSClient.swift` (delegates to MLSCoreContext)
- `NotificationServiceExtension/NotificationService.swift` (uses MLSCoreContext)

**Deleted**:
- `Catbird/Services/MLS/MLSNotificationDecryptor.swift` (replaced by shared context)
- All files moved to `CatbirdMLSCore/Sources/CatbirdMLSCore/` (originals deleted)

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│  Main Catbird App                                           │
│    ┌──────────────┐                                         │
│    │  MLSClient   │──────────┐                              │
│    │  (high-level)│          │                              │
│    └──────────────┘          │                              │
│                              ▼                              │
│                    ┌──────────────────────┐                 │
│                    │  CatbirdMLSCore      │                 │
│                    │  (Swift Package)     │                 │
│                    │                      │                 │
│                    │  MLSCoreContext──────┼────┐            │
│                    │  (Shared Singleton)  │    │            │
│                    │                      │    │            │
│                    │  - Decryption       │    │            │
│                    │  - Database Save    │    │            │
│                    │  - Proper Metadata  │    │            │
│                    └──────────────────────┘    │            │
│                              ▲                 │            │
└──────────────────────────────┼─────────────────┼────────────┘
                               │                 │
                               │            SQLite DB
                               │         (App Group)
                               │                 │
┌──────────────────────────────┼─────────────────┼────────────┐
│  NotificationServiceExtension│                 │            │
│    ┌──────────────────────┐ │                 │            │
│    │ NotificationService  │─┘                 │            │
│    │ (uses shared context)│                   │            │
│    └──────────────────────┘                   │            │
│                              │                 │            │
│    Extension decrypts once ──────────────────▶│            │
│    Main app reads cached    ◀─────────────────┘            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Key Benefits**:
- ✅ Single decryption path (no double work)
- ✅ Proper epoch and sequence metadata from Rust FFI
- ✅ Shared MLS state between app and extension
- ✅ Clean architecture with Swift package
- ✅ No fake metadata or workarounds

---

## Support

If you encounter issues not covered in this guide:

1. Check Console logs in Xcode (⌘⇧Y)
2. Check device logs (Window → Devices and Simulators → View Device Logs)
3. Verify all file paths are correct
4. Ensure Rust FFI was rebuilt with new fields
5. Verify Swift bindings were regenerated

For Rust FFI issues, refer to `RUST_FFI_CHANGES_NEEDED.md`.
