# Rust FFI Changes Required for CatbirdMLSCore

## Overview
To properly support MLS message decryption with correct metadata in both the main app and NotificationServiceExtension, we need to enhance the `DecryptResult` struct to include epoch and sequence number information.

## Required Changes

### 1. Update DecryptResult Struct

**Location**: Your Rust MLS FFI crate (typically `mls-ffi/src/lib.rs` or similar)

**Current Definition** (approximately):
```rust
pub struct DecryptResult {
    pub plaintext: Vec<u8>,
}
```

**Required New Definition**:
```rust
pub struct DecryptResult {
    pub plaintext: Vec<u8>,
    pub epoch: u64,
    pub sequence_number: u64,
}
```

### 2. Update decrypt_message Function

The function that returns `DecryptResult` needs to populate these new fields.

**Example Implementation** (adjust based on your actual OpenMLS integration):
```rust
pub fn decrypt_message(
    &self,
    group_id: Vec<u8>,
    ciphertext: Vec<u8>,
) -> Result<DecryptResult, MlsError> {
    // Your existing decryption logic...
    let processed_message = group.process_message(provider, mls_message)?;

    match processed_message.into_content() {
        ProcessedMessageContent::ApplicationMessage(app_msg) => {
            // Extract metadata from the application message
            let epoch = app_msg.epoch().as_u64();
            let sequence_number = /* extract from app_msg or group state */;

            Ok(DecryptResult {
                plaintext: app_msg.into_bytes(),
                epoch,
                sequence_number,
            })
        }
        _ => Err(MlsError::UnexpectedMessageType),
    }
}
```

**Note**: The exact implementation depends on your OpenMLS version and how you're tracking sequence numbers. You may need to:
- Store sequence numbers in your group state
- Track them separately in the Rust layer
- Derive them from the MLS message structure

### 3. Regenerate Swift Bindings

After making the Rust changes:

```bash
# Build the updated Rust library
cd mls-ffi
cargo build --release

# Regenerate Swift bindings with UniFFI
uniffi-bindgen generate \
    --library target/release/libmls_ffi.dylib \
    --language swift \
    --out-dir ../Catbird/GeneratedFFI

# Copy the updated MLSFFI.swift to your project
cp ../Catbird/GeneratedFFI/MLSFFI.swift ../Catbird/CatbirdMLSCore/Sources/CatbirdMLSCore/FFI/
```

### 4. Verify Generated Swift Code

The generated `MLSFFI.swift` should now include:

```swift
public struct DecryptResult {
    public var plaintext: Data
    public var epoch: UInt64         // ✅ NEW
    public var sequenceNumber: UInt64 // ✅ NEW
}
```

## Testing the Changes

After regenerating bindings:

1. **Compile Test**: Build the Catbird project to ensure the new Swift bindings compile
2. **Functional Test**: Decrypt a test message and verify:
   ```swift
   let result = try context.decryptMessage(groupId: groupId, ciphertext: ciphertext)
   print("Epoch: \(result.epoch)")
   print("Sequence: \(result.sequenceNumber)")
   // Should print actual values, not 0
   ```

## Sequence Number Tracking Options

If OpenMLS doesn't directly expose sequence numbers, consider:

**Option A: Per-Group Counter**
```rust
struct GroupState {
    next_sequence: u64,
    // ... other state
}

// Increment on each message
let sequence = state.next_sequence;
state.next_sequence += 1;
```

**Option B: Derive from Epoch + Local Counter**
```rust
// Use epoch + message index within epoch
let sequence = (epoch << 32) | local_index;
```

**Option C: Hash-based Pseudo-Sequence**
```rust
// Use message hash as pseudo-sequence (for ordering only)
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

let mut hasher = DefaultHasher::new();
plaintext.hash(&mut hasher);
let sequence = hasher.finish();
```

**Recommendation**: Option A (per-group counter) provides true sequential ordering and is most compatible with the database schema.

## Database Schema Compatibility

The Swift side expects:

```swift
try await MLSStorageHelpers.savePlaintext(
    messageID: String,
    plaintext: String,
    embedDataJSON: Data?,
    epoch: Int64,           // Maps to result.epoch
    sequenceNumber: Int64    // Maps to result.sequenceNumber
)
```

Ensure your Rust values map cleanly to `Int64` (Swift's signed 64-bit integer).

## Questions?

If you need help with:
- Finding where `DecryptResult` is defined in your Rust code
- Understanding how to extract epoch from OpenMLS
- Implementing sequence number tracking
- Debugging UniFFI generation issues

Please provide:
1. Your Rust MLS FFI repository structure
2. Which OpenMLS version you're using
3. Any error messages from UniFFI generation

## Next Steps

After completing these changes:
1. Rebuild the Rust library
2. Regenerate Swift bindings
3. Copy updated `MLSFFI.swift` to `CatbirdMLSCore/Sources/CatbirdMLSCore/FFI/`
4. Continue with Swift package implementation (Phase 2)
