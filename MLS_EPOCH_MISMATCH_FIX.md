# MLS Epoch Mismatch & Persistence Fix

## Problem Summary

The MLS chat UI shows messages inconsistently due to **epoch mismatch** and **timing race conditions** in epoch secret storage.

## Root Cause Analysis

### Issue 1: Epoch Advancement Before Message Decryption

**Flow:**
1. Group created at epoch 0
2. Member added via `addMembers()` - creates commit
3. `mergePendingCommit()` immediately advances group to epoch 1
4. Messages sent at epoch 0 arrive from server
5. Decryption fails: trying to decrypt epoch 0 messages with epoch 1 keys

**Evidence from logs:**
```
[MLS-FFI] merge_pending_commit: Advanced to epoch 1
...
Protocol message epoch: GroupEpoch(1)
Current group epoch: GroupEpoch(1)
ERROR: ValidationError(InvalidSignature)
```

The message is at epoch **0** (from server) but the local group is at epoch **1**, causing signature validation failure.

### Issue 2: Epoch Secret Storage Timing Race

**Flow:**
1. FFI calls `storeEpochSecret()` during group creation
2. Epoch secret storage attempts to save to SQLCipher
3. Conversation doesn't exist in database yet (foreign key constraint)
4. Secret storage silently skips with warning
5. Later decryption attempts fail - no epoch secrets available

**Evidence from logs:**
```
⚠️ [EPOCH-STORAGE] Skipping epoch secret storage - conversation e3032e816b31bc84...
not in database yet (will be created shortly). Epoch: 0
```

### Issue 3: No Backward Epoch Retrieval

The current implementation doesn't retrieve stored epoch secrets when decrypting old messages. Each message tries to use the CURRENT group state, not the epoch-specific state.

## Solution Architecture

### 1. Store Epoch Secrets BEFORE Group Advancement

```swift
// In MLSClient.addMembers - BEFORE mergePendingCommit
let currentEpoch = getCurrentEpoch(groupId)
exportAndStoreEpochSecret(groupId, epoch: currentEpoch)

// Now safe to advance
mergePendingCommit(groupId)
```

### 2. Ensure Conversation Exists Before FFI Callbacks

```swift
// In createGroup - create conversation FIRST
let conversation = try await storage.ensureConversationExists(
    conversationID: convoId,
    groupID: groupId,
    database: database
)

// NOW it's safe to create the group (FFI can store epoch secrets)
let groupId = try await mlsClient.createGroup(...)
```

### 3. Implement Epoch-Aware Decryption

```swift
func processMessage(_ message: MessageView) async throws -> DecryptedMessage {
    let messageEpoch = message.epoch
    let currentEpoch = getCurrentEpoch(groupId)

    if messageEpoch < currentEpoch {
        // Historical message - retrieve old epoch secret
        guard let epochSecret = try await getEpochSecret(groupId, epoch: messageEpoch) else {
            throw MLSError.epochSecretMissing(messageEpoch)
        }

        // Decrypt using historical epoch state
        return try decryptWithEpoch(message, secret: epochSecret)
    } else {
        // Current epoch - use normal decryption
        return try mlsClient.processMessage(groupId, message.ciphertext)
    }
}
```

## Implementation Plan

### Phase 1: Fix Conversation Creation Order ✅
- Create conversation in SQLCipher BEFORE MLS group
- Ensures foreign key constraints are satisfied
- Epoch secrets can be stored immediately

### Phase 2: Export Epoch Secrets Before Advancement 🔄
- Export epoch secret before `mergePendingCommit()`
- Store in SQLCipher for future retrieval
- Prevents loss of decryption capability for old messages

### Phase 3: Implement Backward Decryption ⏳
- Check message epoch vs current group epoch
- Retrieve historical epoch secrets from storage
- Decrypt using epoch-specific state

### Phase 4: Add Epoch Secret Management ⏳
- Cleanup old epoch secrets (keep last N)
- Handle epoch secret expiration
- Monitor epoch secret storage health

## Testing Strategy

1. **Create conversation** → Verify epoch 0 stored before group creation
2. **Send message at epoch 0** → Verify plaintext cached
3. **Add member** → Group advances to epoch 1, epoch 0 secret retained
4. **Fetch messages** → Verify epoch 0 messages decrypt with stored secret
5. **Send new message** → Verify epoch 1 messages decrypt with current state

## Migration Considerations

- Existing conversations at epoch > 0 may have lost epoch 0 secrets
- Consider re-initializing conversations that show persistent decryption failures
- Add health check to detect conversations with missing epoch secrets

## Security Notes

- Epoch secrets are stored in SQLCipher with AES-256-CBC encryption
- Per-user database isolation prevents cross-user secret leakage
- iOS Keychain stores SQLCipher master key
- File protection ensures at-rest encryption

## Files Modified

- `MLSStorage.swift` - Add conversation-first creation
- `MLSConversationManager.swift` - Export epoch secrets before merge
- `MLSClient.swift` - Implement epoch-aware decryption
- `MLSStorage+EpochSecretStorage.swift` - Handle timing race conditions
- `MLSConversationDetailViewModel.swift` - Update message processing flow

## Success Metrics

- ✅ Zero "Skipping epoch secret storage" warnings
- ✅ All messages decrypt successfully on first fetch
- ✅ Messages persist correctly to SQLCipher
- ✅ UI shows consistent message history
- ✅ No InvalidSignature errors in logs
