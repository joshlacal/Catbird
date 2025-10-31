# FFI Swift Bridge Documentation

## Overview

This document describes the Swift wrapper layer (`MLSCrypto.swift`) that bridges the Rust FFI implementation with native Swift code in the Catbird iOS application. The wrapper provides type-safe, async/await-based access to MLS cryptographic operations with comprehensive error handling and memory management.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Swift Layer                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │           MLSCrypto (Actor)                        │  │
│  │  - Thread-safe operations                          │  │
│  │  - Async/await interface                           │  │
│  │  - Swift Error types                               │  │
│  │  - Memory management (defer/deinit)               │  │
│  └─────────────────┬───────────────────────────────────┘  │
└────────────────────┼──────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                    C FFI Layer                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │           mls_ffi.h                                │  │
│  │  - MLSResult struct                                │  │
│  │  - Function declarations                           │  │
│  │  - Memory management functions                     │  │
│  └─────────────────┬───────────────────────────────────┘  │
└────────────────────┼──────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                    Rust Layer                            │
│  ┌───────────────────────────────────────────────────┐  │
│  │           mls-ffi (Rust crate)                     │  │
│  │  - OpenMLS integration                             │  │
│  │  - Cryptographic operations                        │  │
│  │  - Error handling                                  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## Components

### 1. Error Types

#### `MLSCryptoError`

Swift enum that represents all possible errors from MLS operations:

```swift
enum MLSCryptoError: Error, LocalizedError {
    case initializationFailed(String)
    case contextCreationFailed
    case groupCreationFailed(String)
    case addMembersFailed(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case keyPackageCreationFailed(String)
    case welcomeProcessingFailed(String)
    case secretExportFailed(String)
    case invalidGroupId
    case invalidIdentity
    case invalidData
    case memoryAllocationFailed
    case contextNotInitialized
}
```

**Features:**
- Conforms to `Error` and `LocalizedError` protocols
- Includes error messages from Rust layer
- Provides user-friendly error descriptions
- Type-safe error handling in Swift

### 2. Result Types

Domain-specific result types for each operation:

#### `MLSGroupCreationResult`
```swift
struct MLSGroupCreationResult {
    let groupId: Data
}
```

#### `MLSAddMembersResult`
```swift
struct MLSAddMembersResult {
    let commitData: Data
    let welcomeData: Data
}
```

#### `MLSEncryptedMessage`
```swift
struct MLSEncryptedMessage {
    let ciphertext: Data
}
```

#### `MLSDecryptedMessage`
```swift
struct MLSDecryptedMessage {
    let plaintext: Data
}
```

#### `MLSKeyPackage`
```swift
struct MLSKeyPackage {
    let keyPackageData: Data
}
```

#### `MLSWelcomeResult`
```swift
struct MLSWelcomeResult {
    let groupId: Data
}
```

#### `MLSExportedSecret`
```swift
struct MLSExportedSecret {
    let secret: Data
}
```

### 3. MLSCrypto Actor

Thread-safe actor that wraps all MLS operations:

```swift
actor MLSCrypto {
    private var contextId: UInt
    private var isInitialized: Bool
    
    // Methods...
}
```

**Key Features:**
- **Thread Safety**: Uses Swift actor isolation to prevent data races
- **Async/Await**: All operations are async for better performance
- **Memory Management**: Automatic cleanup via `deinit`
- **Context Management**: Maintains FFI context lifecycle

## API Reference

### Initialization

#### `initialize()`
```swift
func initialize() async throws
```

Initialize the MLS context. Must be called before any other operations.

**Throws:**
- `MLSCryptoError.initializationFailed` if context creation fails

**Example:**
```swift
let crypto = MLSCrypto()
try await crypto.initialize()
```

### Group Management

#### `createGroup(identity:)`
```swift
func createGroup(identity: String) async throws -> MLSGroupCreationResult
```

Create a new MLS group.

**Parameters:**
- `identity`: User identity (email, DID, username, etc.)

**Returns:** `MLSGroupCreationResult` containing the group ID

**Throws:**
- `MLSCryptoError.contextNotInitialized`
- `MLSCryptoError.invalidIdentity`
- `MLSCryptoError.groupCreationFailed`

**Example:**
```swift
let result = try await crypto.createGroup(identity: "alice@catbird.blue")
print("Group ID: \(result.groupId.base64EncodedString())")
```

#### `addMembers(groupId:keyPackages:)`
```swift
func addMembers(groupId: Data, keyPackages: Data) async throws -> MLSAddMembersResult
```

Add members to an existing group.

**Parameters:**
- `groupId`: Group identifier
- `keyPackages`: Serialized key packages of members to add

**Returns:** `MLSAddMembersResult` with commit and welcome messages

**Throws:**
- `MLSCryptoError.contextNotInitialized`
- `MLSCryptoError.addMembersFailed`
- `MLSCryptoError.invalidData`

**Example:**
```swift
let bobKeyPkg = try await crypto.createKeyPackage(identity: "bob@catbird.blue")
let result = try await crypto.addMembers(
    groupId: groupId,
    keyPackages: bobKeyPkg.keyPackageData
)
```

### Message Encryption/Decryption

#### `encryptMessage(groupId:plaintext:)`
```swift
func encryptMessage(groupId: Data, plaintext: Data) async throws -> MLSEncryptedMessage
```

Encrypt a message for the group.

**Parameters:**
- `groupId`: Group identifier
- `plaintext`: Message to encrypt

**Returns:** `MLSEncryptedMessage` containing ciphertext

**Throws:**
- `MLSCryptoError.contextNotInitialized`
- `MLSCryptoError.encryptionFailed`

**Example:**
```swift
let message = "Hello, secure world!".data(using: .utf8)!
let encrypted = try await crypto.encryptMessage(
    groupId: groupId,
    plaintext: message
)
```

#### `decryptMessage(groupId:ciphertext:)`
```swift
func decryptMessage(groupId: Data, ciphertext: Data) async throws -> MLSDecryptedMessage
```

Decrypt a message from the group.

**Parameters:**
- `groupId`: Group identifier
- `ciphertext`: Encrypted message

**Returns:** `MLSDecryptedMessage` containing plaintext

**Throws:**
- `MLSCryptoError.contextNotInitialized`
- `MLSCryptoError.decryptionFailed`

**Example:**
```swift
let decrypted = try await crypto.decryptMessage(
    groupId: groupId,
    ciphertext: encrypted.ciphertext
)
let text = String(data: decrypted.plaintext, encoding: .utf8)
```

### Key Package Management

#### `createKeyPackage(identity:)`
```swift
func createKeyPackage(identity: String) async throws -> MLSKeyPackage
```

Create a key package for joining groups.

**Parameters:**
- `identity`: User identity

**Returns:** `MLSKeyPackage` containing serialized key package

**Throws:**
- `MLSCryptoError.contextNotInitialized`
- `MLSCryptoError.invalidIdentity`
- `MLSCryptoError.keyPackageCreationFailed`

**Example:**
```swift
let keyPackage = try await crypto.createKeyPackage(identity: "alice@catbird.blue")
// Send keyPackage.keyPackageData to server or other users
```

#### `processWelcome(welcomeData:identity:)`
```swift
func processWelcome(welcomeData: Data, identity: String) async throws -> MLSWelcomeResult
```

Process a Welcome message to join a group.

**Parameters:**
- `welcomeData`: Serialized Welcome message
- `identity`: User identity

**Returns:** `MLSWelcomeResult` containing group ID

**Throws:**
- `MLSCryptoError.contextNotInitialized`
- `MLSCryptoError.invalidIdentity`
- `MLSCryptoError.welcomeProcessingFailed`

**Example:**
```swift
let result = try await crypto.processWelcome(
    welcomeData: welcomeMessage,
    identity: "bob@catbird.blue"
)
print("Joined group: \(result.groupId.base64EncodedString())")
```

### Secret Export

#### `exportSecret(groupId:label:context:keyLength:)`
```swift
func exportSecret(
    groupId: Data,
    label: String,
    context: Data,
    keyLength: Int
) async throws -> MLSExportedSecret
```

Export a secret from the group's key schedule.

**Parameters:**
- `groupId`: Group identifier
- `label`: Label for the exported secret
- `context`: Context data for secret derivation
- `keyLength`: Desired length of exported secret

**Returns:** `MLSExportedSecret` containing the secret

**Throws:**
- `MLSCryptoError.contextNotInitialized`
- `MLSCryptoError.secretExportFailed`

**Example:**
```swift
let secret = try await crypto.exportSecret(
    groupId: groupId,
    label: "encryption-key",
    context: Data(),
    keyLength: 32
)
// Use secret.secret for additional encryption
```

### Group Information

#### `getEpoch(groupId:)`
```swift
func getEpoch(groupId: Data) async throws -> UInt64
```

Get the current epoch of the group.

**Parameters:**
- `groupId`: Group identifier

**Returns:** Epoch number

**Throws:**
- `MLSCryptoError.contextNotInitialized`
- `MLSCryptoError.invalidGroupId`

**Example:**
```swift
let epoch = try await crypto.getEpoch(groupId: groupId)
print("Current epoch: \(epoch)")
```

## Memory Management

### Automatic Resource Cleanup

The `MLSCrypto` actor automatically manages memory through Swift's reference counting and the `deinit` method:

```swift
deinit {
    if isInitialized && contextId != 0 {
        logger.debug("Cleaning up MLS context \(self.contextId)")
        mls_free_context(contextId)
    }
}
```

### FFI Result Cleanup

All FFI operations use `defer` to ensure proper cleanup:

```swift
let result = mls_create_group(...)
defer { mls_free_result(result) }

guard result.success else {
    let errorMsg = convertErrorMessage(result.error_message)
    throw MLSCryptoError.groupCreationFailed(errorMsg)
}
```

### Safe Memory Access

All data passing between Swift and C uses `withUnsafeBytes` for safe, temporary access:

```swift
return try identityData.withUnsafeBytes { identityBytes in
    let result = mls_create_group(
        contextId,
        identityBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
        UInt(identityData.count)
    )
    // ... process result
}
```

## Thread Safety

### Actor Isolation

The `MLSCrypto` actor provides automatic thread safety:

```swift
actor MLSCrypto {
    private var contextId: UInt = 0
    private var isInitialized = false
    
    // All methods are isolated to the actor's executor
}
```

**Benefits:**
- No manual locking required
- Prevents data races at compile time
- Sequential access to mutable state
- Safe concurrent operations

### Concurrent Operations

Multiple operations can be safely performed concurrently:

```swift
async let group1 = crypto.createGroup(identity: "alice@catbird.blue")
async let group2 = crypto.createGroup(identity: "bob@catbird.blue")

let results = try await [group1, group2]
```

The actor ensures operations are serialized internally while providing async access externally.

## Error Handling

### Converting C Errors to Swift

The wrapper converts C error messages to Swift errors:

```swift
private func convertErrorMessage(_ errorPtr: UnsafeMutablePointer<CChar>?) -> String {
    guard let errorPtr = errorPtr else {
        return "Unknown error"
    }
    
    let errorString = String(cString: errorPtr)
    mls_free_string(errorPtr)
    return errorString
}
```

### Error Handling Best Practices

```swift
do {
    let result = try await crypto.createGroup(identity: "alice@catbird.blue")
    // Success path
} catch MLSCryptoError.contextNotInitialized {
    // Handle not initialized
    try await crypto.initialize()
    // Retry operation
} catch MLSCryptoError.groupCreationFailed(let message) {
    // Handle group creation failure
    logger.error("Failed to create group: \(message)")
} catch {
    // Handle unexpected errors
    logger.error("Unexpected error: \(error)")
}
```

## Usage Examples

### Complete Flow: Create Group, Add Member, Send Message

```swift
// Initialize
let crypto = MLSCrypto()
try await crypto.initialize()

// Alice creates a group
let aliceIdentity = "alice@catbird.blue"
let groupResult = try await crypto.createGroup(identity: aliceIdentity)
let groupId = groupResult.groupId

// Bob creates a key package
let bobIdentity = "bob@catbird.blue"
let bobKeyPackage = try await crypto.createKeyPackage(identity: bobIdentity)

// Alice adds Bob to the group
let addResult = try await crypto.addMembers(
    groupId: groupId,
    keyPackages: bobKeyPackage.keyPackageData
)

// Send addResult.welcomeData to Bob...

// Bob processes the welcome
let bobCrypto = MLSCrypto()
try await bobCrypto.initialize()
let welcomeResult = try await bobCrypto.processWelcome(
    welcomeData: addResult.welcomeData,
    identity: bobIdentity
)

// Alice sends an encrypted message
let message = "Hello Bob!".data(using: .utf8)!
let encrypted = try await crypto.encryptMessage(
    groupId: groupId,
    plaintext: message
)

// Bob receives and decrypts
let decrypted = try await bobCrypto.decryptMessage(
    groupId: welcomeResult.groupId,
    ciphertext: encrypted.ciphertext
)

let text = String(data: decrypted.plaintext, encoding: .utf8)
print("Bob received: \(text!)") // "Hello Bob!"
```

### Export Secret for Additional Encryption

```swift
let crypto = MLSCrypto()
try await crypto.initialize()

let groupResult = try await crypto.createGroup(identity: "alice@catbird.blue")

// Export a secret for encrypting files
let fileEncryptionSecret = try await crypto.exportSecret(
    groupId: groupResult.groupId,
    label: "file-encryption",
    context: "document-v1".data(using: .utf8)!,
    keyLength: 32
)

// Use fileEncryptionSecret.secret with CryptoKit for file encryption
import CryptoKit

let key = SymmetricKey(data: fileEncryptionSecret.secret)
let sealedBox = try AES.GCM.seal(fileData, using: key)
```

### Error Recovery

```swift
func sendMessage(crypto: MLSCrypto, groupId: Data, message: String) async throws {
    do {
        let plaintext = message.data(using: .utf8)!
        let encrypted = try await crypto.encryptMessage(
            groupId: groupId,
            plaintext: plaintext
        )
        
        // Send encrypted.ciphertext to server
        try await sendToServer(encrypted.ciphertext)
        
    } catch MLSCryptoError.encryptionFailed(let error) {
        logger.error("Encryption failed: \(error)")
        
        // Check if group needs update
        let epoch = try await crypto.getEpoch(groupId: groupId)
        logger.info("Current epoch: \(epoch)")
        
        // Request group state update from server
        try await refreshGroupState(groupId: groupId)
        
        // Retry
        try await sendMessage(crypto: crypto, groupId: groupId, message: message)
        
    } catch {
        logger.error("Unexpected error: \(error)")
        throw error
    }
}
```

## Testing

### Unit Tests

The `MLSCryptoTests.swift` file provides comprehensive test coverage:

- **Initialization Tests**: Context creation and lifecycle
- **Group Management Tests**: Create groups, add members
- **Encryption/Decryption Tests**: Message encryption/decryption
- **Key Package Tests**: Key package creation and management
- **Error Handling Tests**: All error paths
- **Memory Management Tests**: Resource cleanup
- **Thread Safety Tests**: Concurrent operations
- **Performance Tests**: Encryption and key generation performance

### Running Tests

```bash
# Run all MLS tests
xcodebuild test -scheme Catbird -destination 'platform=iOS Simulator,name=iPhone 15' \
    -only-testing:CatbirdTests/MLSCryptoTests

# Run specific test
xcodebuild test -scheme Catbird -destination 'platform=iOS Simulator,name=iPhone 15' \
    -only-testing:CatbirdTests/MLSCryptoTests/testEncryptDecryptMessageSuccess
```

### Test Coverage

The test suite covers:
- ✅ All public API methods
- ✅ Error conditions and edge cases
- ✅ Memory management and cleanup
- ✅ Concurrent operations
- ✅ Unicode and special characters
- ✅ Binary data handling
- ✅ Performance benchmarks

## Integration with Catbird

### Service Layer Integration

The `MLSCrypto` wrapper integrates with the existing `MLSAPIClient`:

```swift
final class MLSAPIClient {
    private let crypto: MLSCrypto
    private let apiClient: APIClient
    
    init() {
        self.crypto = MLSCrypto()
        self.apiClient = APIClient()
    }
    
    func createSecureGroup(members: [String]) async throws -> String {
        // Initialize crypto
        try await crypto.initialize()
        
        // Create local MLS group
        let groupResult = try await crypto.createGroup(
            identity: currentUserDid
        )
        
        // Create key packages for members
        var keyPackages = Data()
        for member in members {
            let pkg = try await crypto.createKeyPackage(identity: member)
            keyPackages.append(pkg.keyPackageData)
        }
        
        // Add members locally
        let addResult = try await crypto.addMembers(
            groupId: groupResult.groupId,
            keyPackages: keyPackages
        )
        
        // Sync with server
        try await apiClient.createMLSGroup(
            groupId: groupResult.groupId,
            welcomeData: addResult.welcomeData,
            commitData: addResult.commitData
        )
        
        return groupResult.groupId.base64EncodedString()
    }
}
```

## Performance Considerations

### Async Operations

All operations are async to prevent blocking the main thread:

```swift
// Good: Non-blocking
Task {
    let encrypted = try await crypto.encryptMessage(groupId: groupId, plaintext: data)
    updateUI(with: encrypted)
}

// Bad: Would block if synchronous
// let encrypted = crypto.encryptMessage(...) // Don't do this
```

### Memory Usage

- FFI results are immediately converted to Swift `Data` and freed
- No long-lived C pointers in Swift code
- Actor ensures sequential access to shared state

### Batching Operations

For better performance, batch related operations:

```swift
// Good: Create multiple key packages at once
let keyPackages = try await withThrowingTaskGroup(of: MLSKeyPackage.self) { group in
    for identity in identities {
        group.addTask {
            try await crypto.createKeyPackage(identity: identity)
        }
    }
    
    var results: [MLSKeyPackage] = []
    for try await package in group {
        results.append(package)
    }
    return results
}
```

## Security Considerations

### Key Material Handling

- Secrets are stored in `Data` objects (automatically zeroed on deallocation)
- Use `SecureEnclave` for additional protection if needed
- Export secrets only when necessary

### Error Messages

- Error messages may contain sensitive information
- Don't log error details in production
- Use structured logging with privacy levels

```swift
logger.error("Encryption failed: \(error, privacy: .private)")
```

### Memory Protection

- Swift's automatic memory management prevents use-after-free
- Actor isolation prevents data races
- No manual pointer arithmetic in application code

## Troubleshooting

### Common Issues

#### Context Not Initialized
```swift
// Error: contextNotInitialized
// Solution: Call initialize() before any operations
try await crypto.initialize()
```

#### Invalid Group ID
```swift
// Error: invalidGroupId
// Solution: Ensure group exists and ID is correct
let groups = try await listGroups()
let validGroupId = groups.first?.groupId
```

#### Decryption Failed
```swift
// Error: decryptionFailed
// Solution: Check epoch and group membership
let epoch = try await crypto.getEpoch(groupId: groupId)
// May need to process pending commits
```

## Future Enhancements

### Planned Features

1. **State Persistence**: Save/restore MLS group state
2. **Keychain Integration**: Secure storage of key material
3. **Background Processing**: Handle commits in background
4. **Group State Sync**: Automatic state reconciliation
5. **Analytics**: Performance and usage metrics

### API Stability

The current API is considered **stable** for production use. Future versions will maintain backward compatibility or provide migration paths.

## References

- [OpenMLS Documentation](https://openmls.tech/book/)
- [MLS RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html)
- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [Swift Actors](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID645)

## Support

For issues or questions:
- GitHub Issues: [Catbird MLS Repository]
- Documentation: `/docs/mls/`
- API Client Docs: `MLS_API_CLIENT_README.md`

---

**Version**: 1.0.0  
**Last Updated**: 2025-10-21  
**Maintainer**: Catbird Development Team
