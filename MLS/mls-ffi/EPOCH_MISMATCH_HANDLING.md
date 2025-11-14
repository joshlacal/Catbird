# MLS Epoch Mismatch Handling

## Problem

MLS (Messaging Layer Security) implements **forward secrecy** by organizing group state into epochs. Each time a member joins or leaves the group, a new epoch begins and the old epoch's keys are deleted.

This creates a fundamental limitation: **messages from past epochs cannot be decrypted after the group advances to a new epoch**.

### Scenario
1. User is added to group (epoch 0)
2. Message is sent in epoch 0
3. Another member joins, advancing the group to epoch 1
4. User tries to decrypt the epoch 0 message - **FAILS**

The error manifests as:
```
[MLS-FFI] Protocol message epoch: GroupEpoch(0)
[MLS-FFI] Current group epoch: GroupEpoch(1)
[MLS-FFI] ERROR: ValidationError(UnableToDecrypt(AeadError))
```

## Solution

### 1. **Early Detection in Rust FFI Layer** (`api.rs:328-344`)

We now detect epoch mismatches BEFORE attempting decryption:

```rust
let message_epoch = protocol_msg.epoch();
let current_epoch = group.epoch();

// Check for epoch mismatch BEFORE attempting to decrypt
if message_epoch != current_epoch {
    eprintln!("[MLS-FFI] ⚠️ EPOCH MISMATCH DETECTED!");
    eprintln!("[MLS-FFI] Message is from epoch {} but group is at epoch {}",
              message_epoch.as_u64(), current_epoch.as_u64());
    eprintln!("[MLS-FFI] This is expected MLS forward secrecy behavior - old epoch keys are deleted");
    return Err(MLSError::invalid_input(format!(
        "Cannot decrypt message from epoch {} - group is at epoch {} (forward secrecy prevents decrypting old epochs)",
        message_epoch.as_u64(),
        current_epoch.as_u64()
    )));
}
```

### 2. **Graceful Handling in Swift Layer** (`MLSConversationManager.swift:1003-1009`)

The Swift code now distinguishes epoch mismatches from other errors:

```swift
catch {
    // Check if this is an epoch mismatch (forward secrecy preventing old message decryption)
    let errorMessage = error.localizedDescription
    if errorMessage.contains("epoch") && errorMessage.contains("forward secrecy") {
        logger.warning("⏭️ Skipping message \(message.id) from old epoch \(message.epoch) - cannot decrypt due to MLS forward secrecy")
    } else {
        logger.error("❌ Failed to process message \(message.id): \(errorMessage)")
    }
    // Continue processing other messages even if one fails
}
```

## Benefits

1. **Clear error messages**: Users and developers immediately understand why decryption failed
2. **No retries**: We don't waste time retrying messages that will never decrypt
3. **Graceful degradation**: Continue processing other messages instead of failing completely
4. **Proper logging**: Epoch mismatches log as warnings, not errors

## Implications

### For Users
- Some old messages may not be visible if they were sent before you joined the group or after the group advanced epochs
- This is **expected MLS behavior**, not a bug
- Messages sent in the current epoch will always be decryptable

### For Server Integration
Consider implementing one of these strategies:

1. **Server-side plaintext caching**: Store decrypted message plaintext on server
2. **Delayed epoch advancement**: Ensure all clients process all messages before committing member changes
3. **Message placeholders**: Show "Message unavailable (sent in previous epoch)" for failed messages
4. **Read receipts**: Only advance epoch after all members have acknowledged messages

## Testing

The updated code will now log:
```
⏭️ Skipping message 6ac3247b-b615-420e-9fb8-d1fc618d7c4c from old epoch 0 - cannot decrypt due to MLS forward secrecy
```

Instead of the previous confusing error:
```
❌ Failed to process message 6ac3247b-b615-420e-9fb8-d1fc618d7c4c: The operation failed.
```

## Related Issues

- 241 member count bug (caused by corrupted group state from earlier bugs)
- Signer registration fix (prevents "No signer for identity" errors when joining groups)
