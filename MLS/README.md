# MLS (Messaging Layer Security) Integration

This directory contains the MLS encrypted group chat implementation for Catbird.

## Overview

MLS provides end-to-end encrypted group messaging using the IETF MLS protocol (RFC 9420). This implementation uses:
- **Rust crypto library** (OpenMLS) via UniFFI bindings
- **Custom AT Protocol endpoints** (blue.catbird.mls.*)
- **SwiftUI** interface with MVVM architecture

## Directory Structure

```
MLS/
├── mls-ffi/              # Rust FFI crypto implementation
│   ├── src/              # Rust source code
│   ├── Cargo.toml        # Rust dependencies
│   ├── uniffi.toml       # UniFFI configuration
│   └── build.sh          # XCFramework build script
├── Frameworks/           # Pre-built frameworks
│   └── MLSFFIFramework.xcframework/
└── README.md             # This file
```

## Prerequisites

### For Using Pre-built Framework (Recommended)
- Xcode 16+
- iOS 18+ SDK
- No additional tools required

### For Building from Source (Optional)
- Rust 1.70+ (`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`)
- cargo install uniffi-bindgen-swift
- Xcode Command Line Tools

## Xcode Project Integration

### Step 1: Add Files to Xcode Project

1. Open `Catbird.xcodeproj` in Xcode
2. Add the following directories to your project (drag & drop or File > Add Files):

**MLS Services:**
- `Catbird/Services/MLS/` (entire folder)

**MLS UI:**
- `Catbird/Features/MLSChat/` (entire folder)

**MLS Storage:**
- `Catbird/Storage/MLSStorage.swift`
- `Catbird/Storage/MLSStorageIntegration.swift`
- `Catbird/Storage/MLSStorageMigration.swift`
- `Catbird/Storage/MLSKeychainManager.swift`
- `Catbird/Storage/MLS.xcdatamodeld`

**MLS Tests:**
- `CatbirdTests/*MLS*Tests.swift` (all MLS test files)

3. Ensure files are added to appropriate targets:
   - App code → `Catbird` target
   - Tests → `CatbirdTests` target

### Step 2: Link MLSFFIFramework

1. Select Catbird project in Navigator
2. Select `Catbird` target
3. Go to **General** tab
4. Scroll to **Frameworks, Libraries, and Embedded Content**
5. Click **+** button
6. Click **Add Other...** → **Add Files...**
7. Navigate to and select `MLS/Frameworks/MLSFFIFramework.xcframework`
8. Change embed setting to **Embed & Sign**

### Step 3: Configure Framework Search Paths

1. Go to **Build Settings** tab
2. Search for "Framework Search Paths"
3. Add: `$(PROJECT_DIR)/MLS/Frameworks` (recursive)

### Step 4: Configure Petrel Dependency

The Petrel library must be on the `feature/mls-integration` branch for MLS APIs:

1. In **General** → **Frameworks, Libraries, and Embedded Content**
2. Find Petrel package reference
3. Ensure it points to local `../Petrel` with MLS branch checked out
4. Or update Package.swift to reference the correct branch

## Building the FFI Framework (Optional)

If you need to rebuild the Rust FFI framework:

```bash
cd MLS/mls-ffi

# Build XCFramework for all platforms
./build.sh

# Or build manually:
cargo build --release
uniffi-bindgen-swift src/mls.udl --out-dir ./Generated
# ...then create XCFramework manually
```

The script builds for:
- iOS arm64 (device)
- iOS Simulator arm64/x86_64
- macOS arm64/x86_64

Output: `MLS/Frameworks/MLSFFIFramework.xcframework`

## Architecture

### Components

**Swift Layer:**
- `MLSConversationManager` - Main coordinator for MLS operations
- `MLSClient` - UniFFI wrapper for Rust crypto (singleton)
- `MLSAPIClient` - HTTP client for MLS backend server
- `MLSEventStreamManager` - Real-time SSE event handling
- `MLSStorage` - Core Data persistence layer
- `MLSKeychainManager` - Secure key storage

**Rust Layer (mls-ffi):**
- `MLSContext` - MLS group state management
- `api.rs` - Swift-exposed API surface
- `ffi.rs` - UniFFI bridging code
- `types.rs` - FFI type definitions

### Data Flow

```
SwiftUI Views
  ↓
ViewModels
  ↓
MLSConversationManager
  ↓
├─→ MLSClient (Rust FFI) ──→ Crypto Operations
├─→ MLSAPIClient ──→ Backend Server
├─→ MLSStorage ──→ Core Data
└─→ MLSKeychainManager ──→ Keychain
```

## Server Configuration

The MLS backend server is separate from this implementation. Required endpoints:

- `blue.catbird.mls.createConvo`
- `blue.catbird.mls.sendMessage`
- `blue.catbird.mls.getMessages`
- `blue.catbird.mls.addMembers`
- `blue.catbird.mls.leaveConvo`
- `blue.catbird.mls.publishKeyPackage`
- `blue.catbird.mls.getKeyPackages`
- `blue.catbird.mls.getWelcome`
- `blue.catbird.mls.getEpoch`
- `blue.catbird.mls.getCommits`
- `blue.catbird.mls.getConvos`
- `blue.catbird.mls.streamConvoEvents`

Server repository: (separate - already deployed)

## Testing

Run tests via Xcode Test navigator or:

```bash
xcodebuild test \
  -project Catbird.xcodeproj \
  -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Troubleshooting

### Framework Not Found
- Verify `MLSFFIFramework.xcframework` is in `MLS/Frameworks/`
- Check Framework Search Paths include `$(PROJECT_DIR)/MLS/Frameworks`
- Clean build folder (Shift+Cmd+K) and rebuild

### Undefined Symbol Errors
- Ensure framework is set to **Embed & Sign** not just **Do Not Embed**
- Check that all iOS platforms are included in xcframework

### Petrel MLS APIs Missing
- Verify Petrel is on `feature/mls-integration` branch
- Check `Petrel/Sources/Petrel/Generated/BlueCatbirdMls*.swift` files exist
- Rebuild Petrel package if needed

### Rust Build Failures
- Update Rust: `rustup update`
- Install targets: `rustup target add aarch64-apple-ios x86_64-apple-ios aarch64-apple-darwin`
- Install uniffi: `cargo install uniffi-bindgen-swift`

## Security Considerations

- All MLS credentials stored in Keychain
- Group keys never logged or exposed to Swift
- Rust crypto layer uses `zeroize` for memory cleanup
- Backend uses JWT authentication for all MLS endpoints

## Performance

- XCFramework size: ~8MB (includes all platforms)
- Initial key generation: ~200ms
- Message encryption: <10ms
- Supports 1000+ member groups efficiently

## Contributing

When modifying MLS code:
1. Make changes in testing workspace first
2. Test thoroughly
3. Port changes to this integration
4. Update this README if architecture changes

## References

- [IETF MLS RFC 9420](https://datatracker.ietf.org/doc/html/rfc9420)
- [OpenMLS Documentation](https://openmls.tech/)
- [UniFFI Book](https://mozilla.github.io/uniffi-rs/)
- [AT Protocol Specs](https://atproto.com/specs/atp)

## Status

✅ MLS crypto implementation (OpenMLS 0.6)
✅ End-to-end encrypted group chat
✅ Swift FFI bindings (UniFFI)
✅ Real-time message delivery (SSE)
✅ State persistence (Core Data)
✅ Multi-account support
✅ Key package management
✅ Welcome message handling
✅ Epoch synchronization

**Ready for iterative improvement on feature branch**
