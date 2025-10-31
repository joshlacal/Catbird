# MLS FFI Layer

Rust FFI (Foreign Function Interface) library providing C-compatible bindings for MLS (Messaging Layer Security) operations. Designed for integration with iOS applications.

## Features

- ✅ **Thread-Safe**: All operations use proper synchronization
- ✅ **Memory-Safe**: Correct memory management with explicit cleanup functions
- ✅ **Error Handling**: Comprehensive error reporting via FFI-safe result types
- ✅ **C-Compatible**: Generated C headers for easy integration
- ✅ **Multi-Platform**: Supports iOS devices and simulators (ARM64 and x86_64)
- ✅ **Well-Tested**: Comprehensive test suite included

## Architecture

```
┌─────────────────────────────────────┐
│         iOS Application             │
│     (Swift/Objective-C)             │
└──────────────┬──────────────────────┘
               │ C FFI
┌──────────────▼──────────────────────┐
│      mls_ffi (This Library)         │
│  - C-Compatible Functions           │
│  - Memory Management                │
│  - Error Handling                   │
└──────────────┬──────────────────────┘
               │ Rust API
┌──────────────▼──────────────────────┐
│         OpenMLS                     │
│  - MLS Protocol Implementation      │
│  - Cryptographic Operations         │
└─────────────────────────────────────┘
```

## Quick Start

### Prerequisites

```bash
# Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Add iOS targets
rustup target add aarch64-apple-ios
rustup target add x86_64-apple-ios
rustup target add aarch64-apple-ios-sim
```

### Build

```bash
# Build for all iOS platforms
./build_all.sh

# Or build manually for a specific target
cargo build --release --target aarch64-apple-ios

# Run tests
cargo test
```

### Output

After building, you'll find:
- Static libraries: `build/ios/libmls_ffi_*.a`
- C header: `build/ios/mls_ffi.h`

## API Reference

### Initialization

#### `mls_init`

```c
uintptr_t mls_init(void);
```

Initialize an MLS context. Returns a context handle for subsequent operations.

**Returns:** Context ID (non-zero on success, 0 on failure)

**Example:**
```c
uintptr_t context_id = mls_init();
if (context_id == 0) {
    fprintf(stderr, "Failed to initialize MLS\n");
    return -1;
}
```

#### `mls_free_context`

```c
void mls_free_context(uintptr_t context_id);
```

Free an MLS context and all associated resources.

### Group Management

#### `mls_create_group`

```c
struct MLSResult mls_create_group(
    uintptr_t context_id,
    const uint8_t *identity_bytes,
    uintptr_t identity_len
);
```

Create a new MLS group.

**Parameters:**
- `context_id`: MLS context handle
- `identity_bytes`: User identity (e.g., email, username)
- `identity_len`: Length of identity bytes

**Returns:** `MLSResult` containing group ID

**Example:**
```c
const char *identity = "alice@example.com";
struct MLSResult result = mls_create_group(
    context_id,
    (uint8_t*)identity,
    strlen(identity)
);

if (result.success) {
    // Use result.data and result.data_len
    printf("Group created with ID length: %zu\n", result.data_len);
    mls_free_result(result);
} else {
    fprintf(stderr, "Error: %s\n", result.error_message);
    mls_free_result(result);
}
```

#### `mls_add_members`

```c
struct MLSResult mls_add_members(
    uintptr_t context_id,
    const uint8_t *group_id,
    uintptr_t group_id_len,
    const uint8_t *key_packages_bytes,
    uintptr_t key_packages_len
);
```

Add members to an existing group.

**Returns:** `MLSResult` containing commit and welcome messages (JSON format)

### Messaging

#### `mls_encrypt_message`

```c
struct MLSResult mls_encrypt_message(
    uintptr_t context_id,
    const uint8_t *group_id,
    uintptr_t group_id_len,
    const uint8_t *plaintext,
    uintptr_t plaintext_len
);
```

Encrypt a message for the group.

#### `mls_decrypt_message`

```c
struct MLSResult mls_decrypt_message(
    uintptr_t context_id,
    const uint8_t *group_id,
    uintptr_t group_id_len,
    const uint8_t *ciphertext,
    uintptr_t ciphertext_len
);
```

Decrypt a message from the group.

### Key Management

#### `mls_create_key_package`

```c
struct MLSResult mls_create_key_package(
    uintptr_t context_id,
    const uint8_t *identity_bytes,
    uintptr_t identity_len
);
```

Create a key package for joining groups.

#### `mls_process_welcome`

```c
struct MLSResult mls_process_welcome(
    uintptr_t context_id,
    const uint8_t *welcome_bytes,
    uintptr_t welcome_len,
    const uint8_t *identity_bytes,
    uintptr_t identity_len
);
```

Process a Welcome message to join a group.

### Utilities

#### `mls_export_secret`

```c
struct MLSResult mls_export_secret(
    uintptr_t context_id,
    const uint8_t *group_id,
    uintptr_t group_id_len,
    const char *label,
    const uint8_t *context_bytes,
    uintptr_t context_len,
    uintptr_t key_length
);
```

Export a secret from the group's key schedule for custom cryptographic operations.

#### `mls_get_epoch`

```c
uint64_t mls_get_epoch(
    uintptr_t context_id,
    const uint8_t *group_id,
    uintptr_t group_id_len
);
```

Get the current epoch number of the group.

### Memory Management

#### `mls_free_result`

```c
void mls_free_result(struct MLSResult result);
```

Free a result object. **Must** be called for every `MLSResult` returned by API functions.

#### `mls_free_string`

```c
void mls_free_string(char *s);
```

Free an error message string.

## Error Handling

All functions that return `MLSResult` follow this pattern:

```c
struct MLSResult result = mls_some_function(...);

if (result.success) {
    // Use result.data (uint8_t*) and result.data_len
    // ... process data ...
    mls_free_result(result);  // MUST free!
} else {
    // result.error_message contains error description
    fprintf(stderr, "Error: %s\n", result.error_message);
    mls_free_result(result);  // MUST free even on error!
}
```

## Integration with iOS

### Xcode Project Setup

1. Add the static library to your project:
   - Drag `libmls_ffi_*.a` into your Xcode project
   - Add to "Link Binary With Libraries" in Build Phases

2. Add the header file:
   - Copy `mls_ffi.h` to your project
   - Add to your bridging header (for Swift) or import in Objective-C

3. Configure build settings:
   - Set "Library Search Paths" to include the directory with `.a` files
   - Set "Header Search Paths" to include the directory with `.h` files

### Swift Integration

Create a Swift wrapper:

```swift
import Foundation

class MLSWrapper {
    private var contextId: UInt = 0
    
    init() {
        contextId = mls_init()
        guard contextId != 0 else {
            fatalError("Failed to initialize MLS context")
        }
    }
    
    deinit {
        mls_free_context(contextId)
    }
    
    func createGroup(identity: String) throws -> Data {
        let identityData = identity.data(using: .utf8)!
        let result = identityData.withUnsafeBytes { identityPtr in
            mls_create_group(
                contextId,
                identityPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt(identityData.count)
            )
        }
        
        defer { mls_free_result(result) }
        
        guard result.success else {
            let errorMsg = String(cString: result.error_message)
            throw NSError(domain: "MLSError", code: -1, 
                         userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        return Data(bytes: result.data, count: result.data_len)
    }
}
```

## Development

### Project Structure

```
mls-ffi/
├── src/
│   ├── lib.rs           # Library entry point
│   ├── ffi.rs           # FFI function implementations
│   ├── error.rs         # Error types and handling
│   ├── mls_context.rs   # Context management
│   └── tests.rs         # Rust tests
├── include/
│   └── mls_ffi.h        # Generated C header
├── build/               # Build outputs
├── Cargo.toml           # Rust dependencies
├── cbindgen.toml        # C header generation config
├── build.rs             # Build script
├── build_all.sh         # Multi-platform build script
└── FFI_INTEGRATION_GUIDE.md  # Detailed integration guide
```

### Running Tests

```bash
# Run all tests
cargo test

# Run with output
cargo test -- --nocapture

# Run specific test
cargo test test_mls_init
```

### Debugging

Enable logging by setting environment variable:

```bash
RUST_LOG=debug cargo test
```

## Dependencies

- `openmls` (0.5): MLS protocol implementation
- `openmls_rust_crypto` (0.2): Cryptographic backend
- `openmls_basic_credential` (0.2): Credential management
- `serde` + `serde_json`: Serialization
- `hex`: Binary encoding
- `thiserror`: Error handling

## Current Status

### ✅ Implemented

- Context initialization and management
- Group creation (basic)
- Key package creation (basic)
- Memory management
- Error handling
- Thread safety
- Test suite
- C header generation
- Build scripts

### 🚧 To Be Completed

The following functions require full OpenMLS integration:

- `mls_add_members`: Add members to groups with proper commit/welcome generation
- `mls_encrypt_message`: Message encryption using group keys
- `mls_decrypt_message`: Message decryption and validation
- `mls_process_welcome`: Process Welcome messages to join groups
- Full credential and key management
- Persistent state management

These are currently implemented as placeholders that return appropriate errors. The FFI structure is complete and ready for the full OpenMLS integration.

## Security Considerations

- **Memory Safety**: All memory is managed through Rust's ownership system
- **Thread Safety**: Global state is protected by mutexes
- **Input Validation**: All inputs are validated before processing
- **Error Propagation**: Errors are properly propagated to callers
- **No Panics**: FFI boundary never panics (returns errors instead)

## Performance

- Context operations: O(1)
- Group lookups: O(1) hash map access
- Memory overhead: Minimal - contexts stored in Arc<Mutex<>>
- Thread contention: Minimized through per-context locking

## Troubleshooting

### Build Errors

**Error: Target not installed**
```bash
rustup target add aarch64-apple-ios
```

**Error: cbindgen not found**
```bash
cargo install cbindgen
```

### Runtime Errors

**Context ID is 0**
- Check that `mls_init()` succeeded
- Verify no thread safety issues

**Null pointer errors**
- Ensure all pointers passed to FFI are valid
- Check data lengths match actual buffer sizes

## Contributing

When adding new functions:

1. Add Rust implementation in `src/ffi.rs`
2. Add comprehensive error handling
3. Add tests in `src/tests.rs`
4. Rebuild to regenerate C header: `cargo build`
5. Update this README
6. Update `FFI_INTEGRATION_GUIDE.md`

## License

See LICENSE file in project root.

## Support

For issues and questions, see the main project documentation or open an issue on GitHub.
