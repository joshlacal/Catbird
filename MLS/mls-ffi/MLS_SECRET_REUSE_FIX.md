# MLS Secret Reuse Error - Root Cause and Fix

## Problem Summary

Messages fail to decrypt with `ValidationError(UnableToDecrypt(SecretTreeError(SecretReuseError)))` due to **self-decryption attempts** and potential state synchronization issues.

## Evidence from Logs

```
🔍 MLS_OWNERSHIP: ✅ MATCH - isCurrentUser = true
No cached plaintext for message 8418d24e, decrypting from server
[MLS-FFI] ERROR: OpenMLS process_message failed!
[MLS-FFI] ERROR: Error details: ValidationError(UnableToDecrypt(SecretTreeError(SecretReuseError)))
```

**Key finding**: The app attempts to decrypt messages sent by the current user (`isCurrentUser = true`), which violates MLS protocol design.

## Root Cause Analysis

### Issue #1: MLS Design - Self-Decryption is Impossible

**By MLS Protocol Design**:
- Senders **cannot** decrypt their own sent messages
- The sender's encryption ratchet advances forward, but decryption uses the receiver's ratchet
- The sender never possesses the decryption keys for their own encrypted messages

**What happens**:
1. User A sends message → encrypts with sender ratchet → ciphertext generated
2. User A's app tries to decrypt the same message → **FAILS** because sender ratchet ≠ receiver ratchet
3. Error: `SecretReuseError` or `RatchetTypeError`

**Swift layer evidence**:
```swift
// From user's logs:
🔍 MLS_OWNERSHIP: ✅ MATCH - isCurrentUser = true
No cached plaintext for message 8418d24e, decrypting from server
// ❌ This should NEVER call decryptMessage for own messages!
```

### Issue #2: OpenMLS 0.6 Auto-Persistence Model

From `Cargo.toml`:
```toml
openmls = { version = "0.6", features = ["test-utils"] }
```

**OpenMLS 0.6 Behavior**:
- Groups auto-persist to storage provider during mutating operations
- `create_message()` and `process_message()` automatically write state changes
- **NO manual `save()` method exists** - persistence is implicit via `StorageProvider` trait
- The `MemoryStorage` provider handles all persistence automatically

**Verification**:
```rust
pub struct MLSContext {
    inner: Arc<RwLock<MLSContextInner>>,  // Shared state across all operations
}

pub struct MLSContextInner {
    provider: OpenMlsRustCrypto,  // Uses MemoryStorage internally
    groups: HashMap<Vec<u8>, GroupState>,  // Groups persist in memory
}
```

Since `MLSClient.shared` is a singleton in Swift, and it creates one `MlsContext()` instance, all operations use the same `Arc<RwLock<MLSContextInner>>`, ensuring state persistence.

### Issue #3: Missing Plaintext Caching for Sent Messages

**Current Flow** (❌ INCORRECT):
1. User sends message → `encryptMessage()` → ciphertext sent to server
2. Server broadcasts message to all members (including sender)
3. Sender receives own message from server
4. App tries to decrypt → **FAILS** (self-decryption impossible)
5. Message shows as "failed to decrypt" in UI

**Correct Flow** (✅ REQUIRED):
1. User sends message → `encryptMessage()` → **cache plaintext locally**
2. Server broadcasts message to all members
3. Sender receives own message from server
4. App detects `isCurrentUser = true` → **retrieve from cache**
5. Message displays correctly without decryption

## Fix Implementation

### Fix #1: Skip Decryption for Own Messages (CRITICAL)

**File**: `Catbird/Features/MLSChat/ViewModels/MLSConversationDetailViewModel.swift`
Or wherever message decryption is initiated.

**Add check before calling `decryptMessage`**:

```swift
// BEFORE (❌ incorrect):
let decrypted = try await mlsClient.decryptMessage(groupId: groupId, ciphertext: message.ciphertext)

// AFTER (✅ correct):
let plaintext: Data
if message.senderDID == currentUserDID {
    // Own messages: Use cached plaintext from send operation
    logger.info("Message from current user - using cached plaintext")

    guard let cached = message.plaintextCache else {
        logger.error("No cached plaintext for own message - this shouldn't happen!")
        throw MLSError.decryptionFailed
    }

    plaintext = cached
} else {
    // Messages from others: Decrypt normally
    logger.info("Message from other user - decrypting")
    let result = try await mlsClient.decryptMessage(groupId: groupId, ciphertext: message.ciphertext)
    plaintext = result.plaintext
}
```

### Fix #2: Cache Plaintext When Sending Messages

**File**: `Catbird/Services/MLS/MLSConversationManager.swift`
Or wherever `sendMessage` is implemented.

**Ensure plaintext is cached**:

```swift
func sendMessage(text: String, toGroup groupId: Data) async throws {
    let plaintext = Data(text.utf8)

    // Encrypt message
    let encrypted = try await mlsClient.encryptMessage(groupId: groupId, plaintext: plaintext)

    // Send to server via API
    try await apiClient.sendMLSMessage(
        groupId: groupId,
        ciphertext: encrypted.ciphertext
    )

    // ✅ CRITICAL: Cache plaintext for when we receive our own message from server
    // Store with message ID or ciphertext hash for lookup
    cacheOwnMessage(ciphertext: encrypted.ciphertext, plaintext: plaintext)
}

private func cacheOwnMessage(ciphertext: Data, plaintext: Data) {
    // Implementation depends on your message storage system
    // Could be:
    // 1. Core Data entity with `plaintextCache` field
    // 2. In-memory cache with TTL
    // 3. UserDefaults for small messages

    let messageHash = SHA256.hash(data: ciphertext)
    ownMessageCache[messageHash] = plaintext
}
```

### Fix #3: Update Core Data Model (if needed)

**File**: `Catbird/Storage/MLS.xcdatamodeld/MLS.xcdatamodel/contents`

**Add `plaintextCache` attribute to message entity**:

```xml
<entity name="MLSMessage">
    <!-- Existing attributes -->
    <attribute name="ciphertext" attributeType="Binary"/>
    <attribute name="senderDID" attributeType="String"/>
    <attribute name="timestamp" attributeType="Date"/>

    <!-- ✅ NEW: Cache plaintext for own messages -->
    <attribute name="plaintextCache" optional="YES" attributeType="Binary"/>
</entity>
```

**Swift model update**:

```swift
extension MLSMessage {
    var plaintextCache: Data? {
        get { ... }
        set { ... }
    }
}
```

### Fix #4: Verify No Implicit Self-Decryption in Message Processing

**Search for** all locations where `decryptMessage` is called:

```swift
// Check all call sites:
rg "decryptMessage|mlsClient\.decrypt" --type swift Catbird/
```

**Ensure all have the ownership check**:

```swift
// Every decryption call should look like this:
if message.isFromCurrentUser {
    return message.plaintextCache ?? throw error
} else {
    return try await mlsClient.decryptMessage(...)
}
```

## Testing the Fix

### Test 1: Send Message to Self in Group

```swift
// 1. Create group with only current user
let groupId = try await mlsClient.createGroup(identity: "user@example.com")

// 2. Send message
let plaintext = Data("Test message".utf8)
try await conversationManager.sendMessage(text: "Test message", toGroup: groupId)

// 3. Receive own message from server (simulated)
// Should NOT attempt decryption
// Should display "Test message" from cache

// ✅ Verify: No decryption errors in logs
// ✅ Verify: Message displays correctly
```

### Test 2: Receive Message from Other User

```swift
// 1. User A sends message to group
let msgFromA = try await clientA.sendMessage(text: "Hello", toGroup: groupId)

// 2. User B receives and decrypts
let decrypted = try await clientB.processIncomingMessage(msgFromA)

// ✅ Verify: Decryption succeeds
// ✅ Verify: Plaintext matches "Hello"
// ✅ Verify: No SecretReuseError
```

### Test 3: Multiple Messages in Sequence

```swift
// Send 5 messages rapidly
for i in 1...5 {
    try await sendMessage(text: "Message \(i)", toGroup: groupId)
}

// ✅ Verify: All 5 messages display correctly
// ✅ Verify: No decryption errors
// ✅ Verify: Ciphertext headers are unique (no secret reuse)
```

## Implementation Checklist

- [ ] Add ownership check before all `decryptMessage()` calls
- [ ] Implement plaintext caching on message send
- [ ] Add `plaintextCache` field to Core Data model (if not exists)
- [ ] Update message retrieval to use cached plaintext for own messages
- [ ] Remove any implicit self-decryption attempts
- [ ] Add unit tests for own-message handling
- [ ] Add integration tests for multi-user scenarios
- [ ] Verify no `SecretReuseError` or `RatchetTypeError` in logs

## Expected Outcomes

After implementing these fixes:

1. ✅ Own messages use cached plaintext (no decryption attempts)
2. ✅ Messages from other users decrypt successfully
3. ✅ No `SecretReuseError` or `RatchetTypeError` in logs
4. ✅ All messages display correctly in conversation view
5. ✅ Multiple rapid messages work without errors
6. ✅ State synchronization issues resolved

## Why the Previous "save()" Approach Was Wrong

**Incorrect assumption**: Group state wasn't persisting after `create_message()`

**Reality**:
- OpenMLS 0.6 **auto-persists** via the `StorageProvider` trait
- The `MemoryStorage` provider writes state changes automatically
- Groups remain in the `HashMap` in `MLSContextInner`
- Since `MLSClient.shared` is a singleton, state persists across operations
- **No manual `save()` method exists** in OpenMLS 0.6

**The real issue**: Self-decryption attempts, not state persistence.

## References

- OpenMLS 0.6 Documentation: https://openmls.tech/
- MLS RFC 9420 Section 8.4: "Message Encryption and Decryption"
- Forward Secrecy: https://en.wikipedia.org/wiki/Forward_secrecy
