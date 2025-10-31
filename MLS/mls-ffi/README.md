# MLS FFI - Foreign Function Interface for OpenMLS

A C-compatible FFI layer for OpenMLS, designed for iOS integration.

## Features

- ✅ Full OpenMLS functionality exposed via C API
- ✅ Thread-safe context management
- ✅ Comprehensive error handling
- ✅ Memory-safe FFI layer
- ✅ iOS-optimized builds (ARM64 + Simulator)
- ✅ XCFramework support
- ✅ Extensive test coverage
- ✅ Swift and Objective-C examples

## Quick Start

### Build

```bash
# Basic build
./build_ios.sh

# Build with tests
./build_ios.sh --test

# Build universal binaries and XCFramework
./build_ios.sh --release --universal
```

### Test

```bash
cargo test
```

### Integration

See [FFI_INTEGRATION_GUIDE.md](./FFI_INTEGRATION_GUIDE.md) for detailed integration instructions.

## API Overview

### Initialization

```c
usize context_id = mls_init();
// Use context_id for all operations
mls_free_context(context_id);
```

### Group Operations

```c
// Create group
MLSResult group_result = mls_create_group(context_id, identity, identity_len);

// Add members
MLSResult add_result = mls_add_members(context_id, group_id, group_id_len, 
                                        key_packages, kp_len);

// Get epoch
uint64_t epoch = mls_get_epoch(context_id, group_id, group_id_len);
```

### Messaging

```c
// Encrypt
MLSResult cipher = mls_encrypt_message(context_id, group_id, gid_len,
                                        plaintext, pt_len);

// Decrypt
MLSResult plain = mls_decrypt_message(context_id, group_id, gid_len,
                                       ciphertext, ct_len);
```

### Key Management

```c
// Create key package
MLSResult kp = mls_create_key_package(context_id, identity, id_len);

// Process welcome
MLSResult welcome = mls_process_welcome(context_id, welcome_bytes, w_len,
                                         identity, id_len);

// Export secret
MLSResult secret = mls_export_secret(context_id, group_id, gid_len,
                                      "app-secret", context, ctx_len, 32);
```

## Architecture

```
┌─────────────────────┐
│   iOS Application   │
│  (Swift/Obj-C)      │
└──────────┬──────────┘
           │
           ├─ Bridging Header
           │
┌──────────▼──────────┐
│    C FFI Layer      │
│    (ffi.rs)         │
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│   Context Manager   │
│  (mls_context.rs)   │
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│     OpenMLS         │
│  (Rust Library)     │
└─────────────────────┘
```

## Directory Structure

```
mls-ffi/
├── src/
│   ├── lib.rs           # Module exports
│   ├── ffi.rs           # C-compatible functions
│   ├── mls_context.rs   # State management
│   ├── error.rs         # Error types
│   └── tests.rs         # Rust tests
├── build.rs             # Build script (cbindgen)
├── cbindgen.toml        # cbindgen configuration
├── build_ios.sh         # iOS build script
├── include/             # Generated C headers
│   └── mls_ffi.h
├── build/               # Build artifacts
│   ├── libmls_ffi.a.*   # Per-target libraries
│   └── mls_ffi.xcframework/
├── Cargo.toml           # Rust dependencies
└── FFI_INTEGRATION_GUIDE.md
```

## Dependencies

- `openmls` - MLS protocol implementation
- `openmls_rust_crypto` - Cryptographic provider
- `openmls_basic_credential` - Basic credential support
- `serde` / `serde_json` - Serialization
- `tls_codec` - TLS encoding/decoding
- `thiserror` - Error handling
- `cbindgen` - C header generation

## Memory Management

All memory allocated by Rust must be freed by calling the appropriate free functions:

- `mls_free_result()` - Free MLSResult
- `mls_free_context()` - Free context
- `mls_free_string()` - Free error strings

## Thread Safety

- Each context is thread-safe via internal Mutex
- Multiple contexts can be used concurrently
- Context IDs are unique and thread-safe

## Error Handling

All operations return `MLSResult`:

```c
typedef struct {
    bool success;
    char* error_message;  // NULL on success
    uint8_t* data;        // NULL on failure
    size_t data_len;
} MLSResult;
```

Always check `success` before accessing `data`.

## Platform Support

- ✅ iOS Device (aarch64-apple-ios)
- ✅ iOS Simulator Intel (x86_64-apple-ios)
- ✅ iOS Simulator ARM (aarch64-apple-ios-sim)
- ⚠️ macOS (untested but should work)
- ❌ Android (not yet supported)

## Performance

- Minimal overhead over native Rust
- Zero-copy where possible
- Efficient context management
- Optimized for mobile platforms

## Security Notes

- No persistence by default (in-memory only)
- Clear sensitive data with `mls_free_*` functions
- Use secure storage for production
- Validate all inputs from untrusted sources

## Testing

```bash
# Unit tests
cargo test

# Integration tests
cargo test --test '*'

# With logging
RUST_LOG=debug cargo test

# Specific test
cargo test test_encrypt_decrypt_message
```

## Troubleshooting

**Build errors:**
```bash
# Update Rust
rustup update

# Clean build
cargo clean && cargo build
```

**Missing targets:**
```bash
rustup target add aarch64-apple-ios
rustup target add x86_64-apple-ios
rustup target add aarch64-apple-ios-sim
```

**cbindgen not found:**
```bash
cargo install cbindgen
```

## Contributing

1. Follow Rust style guidelines (rustfmt)
2. Add tests for new functionality
3. Update FFI_INTEGRATION_GUIDE.md
4. Ensure all tests pass

## License

MIT License - See ../LICENSE

## Resources

- [OpenMLS Documentation](https://openmls.tech/)
- [FFI Integration Guide](./FFI_INTEGRATION_GUIDE.md)
- [Rust FFI Book](https://doc.rust-lang.org/nomicon/ffi.html)
- [Swift Interoperability](https://developer.apple.com/documentation/swift/imported_c_and_objective-c_apis)
