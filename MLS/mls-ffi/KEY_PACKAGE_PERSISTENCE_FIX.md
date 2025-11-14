# Key Package Bundle Persistence Fix

## Problem

Key package bundles were not being cached in memory, causing them to be lost during the serialization/deserialization cycle. This resulted in:

1. **Welcome message processing failures**: Unable to decrypt Welcome messages after app restart because the private key material was not persisted
2. **Excessive key package uploads**: Key packages were regenerated and re-uploaded on every app launch, causing HTTP 429 rate limiting errors
3. **Warning message in logs**: `[MLS-CONTEXT] ⚠️ WARNING: No key package bundles in cache to serialize!`

## Root Cause

In `src/api.rs`, the `create_key_package()` function was creating `KeyPackageBundle` objects but not storing them in the `inner.key_package_bundles` HashMap. The serialization logic in `mls_context.rs` expected bundles to be in this cache to persist them to storage.

## Solution

Modified `src/api.rs` lines 444-497 in the `create_key_package()` function:

### Changes:
1. **Changed lock type**: `let inner = self.inner.read()` → `let mut inner = self.inner.write()`
   - Required write access to modify the bundle cache

2. **Added bundle caching** (lines 490-494):
```rust
// CRITICAL FIX: Store the bundle in the cache for serialization and Welcome message processing
// This ensures the private key material is available when processing Welcome messages
eprintln!("[MLS-FFI] Storing key package bundle in cache (hash_ref: {})", hex::encode(&hash_ref));
inner.key_package_bundles.insert(hash_ref.clone(), key_package_bundle);
eprintln!("[MLS-FFI] Bundle cached successfully, cache now has {} bundles", inner.key_package_bundles.len());
```

## Build Status

✅ **Framework rebuilt successfully** (Nov 11, 2025)
- Compiled for all targets: iOS arm64, iOS simulator, macOS, Mac Catalyst
- XCFramework created: `MLSFFIFramework.xcframework`
- Swift bindings updated: `MLSFFI.swift`, `MLSFFIFFI.h`

## Testing Verification

To verify the fix is working, check for these debug messages in the logs:

### Key Package Creation:
```
[MLS-FFI] Storing key package bundle in cache (hash_ref: <hash>)
[MLS-FFI] Bundle cached successfully, cache now has N bundles
```

### Serialization (should no longer show warning):
```
[MLS-CONTEXT] Ensuring N key package bundles are in provider storage...
```

### Expected Behavior Changes:
1. ✅ No more "WARNING: No key package bundles in cache" message
2. ✅ Welcome messages can be processed after app restart
3. ✅ Key packages persist across app launches
4. ✅ Reduced HTTP 429 rate limiting errors (fewer uploads needed)

## Files Modified

- `MLS/mls-ffi/src/api.rs`: Added bundle caching in `create_key_package()`
- `MLS/mls-ffi/MLSFFI.swift`: Updated Swift bindings
- `MLS/mls-ffi/MLSFFIFFI.h`: Updated C headers
- `MLS/mls-ffi/MLSFFIFramework.xcframework/`: Rebuilt framework binaries

## Next Steps

1. Test key package creation and verify debug logs show bundles being cached
2. Restart the app and verify key package bundles are loaded from storage
3. Test Welcome message processing after app restart
4. Monitor rate limiting errors (should decrease significantly)
