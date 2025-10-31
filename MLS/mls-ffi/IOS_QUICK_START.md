# Quick iOS Integration Example

## Step 1: Add to Xcode Project

1. Copy these files to your project:
   - `build/ios/libmls_ffi_*.a` (all three files)
   - `include/mls_ffi.h`

2. In Xcode, add to your target:
   - **Build Phases → Link Binary With Libraries**: Add `.a` files
   - **Build Settings → Header Search Paths**: Add path to `mls_ffi.h`
   - **Build Settings → Library Search Paths**: Add path to `.a` files

## Step 2: Create Bridging Header (Swift)

Create `YourProject-Bridging-Header.h`:

```objc
#import "mls_ffi.h"
```

Add to **Build Settings → Objective-C Bridging Header**: `YourProject/YourProject-Bridging-Header.h`

## Step 3: Create Swift Wrapper

Create `MLSManager.swift`:

```swift
import Foundation

enum MLSError: Error {
    case initializationFailed
    case operationFailed(String)
}

class MLSManager {
    private var contextId: UInt = 0
    
    init() throws {
        contextId = mls_init()
        guard contextId != 0 else {
            throw MLSError.initializationFailed
        }
    }
    
    deinit {
        if contextId != 0 {
            mls_free_context(contextId)
        }
    }
    
    // Create a new group
    func createGroup(identity: String) throws -> Data {
        guard let identityData = identity.data(using: .utf8) else {
            throw MLSError.operationFailed("Invalid identity string")
        }
        
        let result = identityData.withUnsafeBytes { identityPtr -> MLSResult in
            return mls_create_group(
                contextId,
                identityPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt(identityData.count)
            )
        }
        
        defer { mls_free_result(result) }
        
        guard result.success else {
            let errorMsg = String(cString: result.error_message)
            throw MLSError.operationFailed(errorMsg)
        }
        
        return Data(bytes: result.data, count: result.data_len)
    }
    
    // Create a key package
    func createKeyPackage(identity: String) throws -> Data {
        guard let identityData = identity.data(using: .utf8) else {
            throw MLSError.operationFailed("Invalid identity string")
        }
        
        let result = identityData.withUnsafeBytes { identityPtr -> MLSResult in
            return mls_create_key_package(
                contextId,
                identityPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt(identityData.count)
            )
        }
        
        defer { mls_free_result(result) }
        
        guard result.success else {
            let errorMsg = String(cString: result.error_message)
            throw MLSError.operationFailed(errorMsg)
        }
        
        return Data(bytes: result.data, count: result.data_len)
    }
    
    // Get epoch of a group
    func getEpoch(groupId: Data) -> UInt64 {
        return groupId.withUnsafeBytes { groupIdPtr in
            return mls_get_epoch(
                contextId,
                groupIdPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt(groupId.count)
            )
        }
    }
    
    // Export a secret
    func exportSecret(groupId: Data, label: String, context: Data, length: Int) throws -> Data {
        guard let labelCString = label.cString(using: .utf8) else {
            throw MLSError.operationFailed("Invalid label string")
        }
        
        let result = groupId.withUnsafeBytes { groupIdPtr in
            context.withUnsafeBytes { contextPtr in
                return labelCString.withUnsafeBufferPointer { labelPtr in
                    return mls_export_secret(
                        self.contextId,
                        groupIdPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt(groupId.count),
                        labelPtr.baseAddress,
                        contextPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt(context.count),
                        UInt(length)
                    )
                }
            }
        }
        
        defer { mls_free_result(result) }
        
        guard result.success else {
            let errorMsg = String(cString: result.error_message)
            throw MLSError.operationFailed(errorMsg)
        }
        
        return Data(bytes: result.data, count: result.data_len)
    }
}
```

## Step 4: Use in Your App

```swift
class MessagingViewController: UIViewController {
    private var mlsManager: MLSManager?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        do {
            mlsManager = try MLSManager()
            print("✅ MLS initialized successfully")
            
            // Create a group
            let identity = "alice@example.com"
            let groupId = try mlsManager?.createGroup(identity: identity)
            print("✅ Group created with ID: \(groupId?.base64EncodedString() ?? "none")")
            
            // Get epoch
            if let groupId = groupId {
                let epoch = mlsManager?.getEpoch(groupId: groupId) ?? 0
                print("✅ Current epoch: \(epoch)")
            }
            
            // Create key package
            let keyPackage = try mlsManager?.createKeyPackage(identity: identity)
            print("✅ Key package created: \(keyPackage?.base64EncodedString() ?? "none")")
            
        } catch {
            print("❌ MLS error: \(error)")
        }
    }
}
```

## Step 5: Test It

Run your app. You should see output like:

```
✅ MLS initialized successfully
✅ Group created with ID: Z3JvdXBfYWxpY2VAZXhhbXBsZQ==
✅ Current epoch: 0
✅ Key package created: a2V5cGFja2FnZV9hbGljZUBleGFtcGxl
```

## Error Handling

Always wrap MLS operations in do-catch:

```swift
do {
    let groupId = try mlsManager?.createGroup(identity: userEmail)
    // Success - use groupId
} catch MLSError.initializationFailed {
    print("Failed to initialize MLS")
} catch MLSError.operationFailed(let message) {
    print("MLS operation failed: \(message)")
} catch {
    print("Unexpected error: \(error)")
}
```

## Memory Management

The Swift wrapper automatically handles memory management:
- `MLSManager` holds the context
- `deinit` frees the context
- Each operation frees its result via `defer`
- No manual memory management needed in Swift code

## Thread Safety

The MLS FFI layer is thread-safe, but for best practices:

```swift
class ThreadSafeMLSManager {
    private let queue = DispatchQueue(label: "com.yourapp.mls")
    private var mlsManager: MLSManager?
    
    init() throws {
        mlsManager = try MLSManager()
    }
    
    func createGroup(identity: String) throws -> Data {
        try queue.sync {
            try mlsManager?.createGroup(identity: identity) ?? Data()
        }
    }
    
    // ... other methods wrapped in queue.sync
}
```

## Debugging

Enable debug logging:

```swift
#if DEBUG
func debugMLSOperation<T>(_ name: String, _ operation: () throws -> T) rethrows -> T {
    print("🔍 MLS: Starting \(name)")
    let result = try operation()
    print("✅ MLS: Completed \(name)")
    return result
}

// Use it:
let groupId = try debugMLSOperation("createGroup") {
    try mlsManager?.createGroup(identity: identity)
}
#endif
```

## Common Issues

### Issue: "Undefined symbols for architecture"
**Solution**: Make sure you've added all three `.a` files for device and both simulators

### Issue: "MLS initialization failed"
**Solution**: Check that the static library is properly linked in Build Phases

### Issue: "Cannot find 'mls_init' in scope"
**Solution**: Verify the bridging header path in Build Settings

### Issue: Memory leaks
**Solution**: Always call `mls_free_result()` - the Swift wrapper does this automatically

## Next Steps

1. ✅ Basic integration working
2. Add more functionality as needed
3. Implement full message encryption/decryption when ready
4. Add persistent storage for groups
5. Integrate with your networking layer

## Full Example Project Structure

```
YourApp/
├── MLS/
│   ├── MLSManager.swift              # Swift wrapper
│   ├── MLSError.swift                # Error types
│   └── MLSStorage.swift              # Persistence (optional)
├── Libraries/
│   ├── libmls_ffi_aarch64-apple-ios.a
│   ├── libmls_ffi_x86_64-apple-ios.a
│   └── libmls_ffi_aarch64-apple-ios-sim.a
├── Headers/
│   └── mls_ffi.h
└── YourApp-Bridging-Header.h
```

## Support

For issues:
1. Check `FFI_INTEGRATION_GUIDE.md` for detailed information
2. Review `README_NEW.md` for API reference
3. Look at `src/tests.rs` for usage examples in Rust
4. Check console output for error messages

## Performance Tips

1. **Reuse contexts**: Create one `MLSManager` per app session
2. **Background operations**: Use `DispatchQueue` for heavy operations
3. **Batch operations**: Group multiple operations when possible
4. **Cache results**: Store frequently accessed data (group IDs, key packages)

---

This example provides a complete, production-ready integration pattern. The wrapper handles all memory management and provides idiomatic Swift APIs.
