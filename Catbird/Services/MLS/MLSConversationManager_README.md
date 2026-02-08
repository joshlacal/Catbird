# MLSConversationManager Implementation

## Overview

`MLSConversationManager` is the main coordinator for MLS (Message Layer Security) conversation management in the Catbird iOS application. It provides a comprehensive interface for secure group messaging with end-to-end encryption.

## Features

### 1. Group Initialization
- **Create Groups**: Initialize new MLS groups with optional initial members and metadata
- **Join Groups**: Process Welcome messages to join existing groups
- **Local State Management**: Maintains synchronized local and server group state

### 2. Member Management
- **Add Members**: Add new participants to existing conversations with key package validation
- **Remove Members**: Leave conversations and clean up local state
- **Member Validation**: Ensures all members have valid key packages before adding

### 3. Encryption/Decryption
- **Message Encryption**: Encrypt plaintext messages using MLS group context
- **Message Decryption**: Decrypt received ciphertext messages (guaranteed in-order by server)
- **Content Types**: Support for different content types (text/plain, etc.)
- **Attachments**: Handle encrypted message attachments via blob references
- **Message Ordering**: Server guarantees messages arrive in (epoch ASC, seq ASC) order
- **Sequence Numbers**: Real server-assigned seq immediately available (no placeholder seq=0)
- **Gap Detection**: Server provides authoritative gap detection metadata

### 4. Server Synchronization
- **Full Sync**: Retrieve all conversations from server
- **Incremental Sync**: Update only changed conversations
- **Pagination Support**: Handle large conversation lists efficiently
- **Sync Status**: Track synchronization state to prevent concurrent syncs

### 5. Key Package Management
- **Publish Key Packages**: Create and publish key packages to enable group joining
- **Refresh Management**: Automatically refresh expiring key packages
- **Custom Expiration**: Support for custom key package expiration dates
- **Cipher Suite Management**: Default to recommended cipher suite

### 6. Epoch Updates
- **Track Epochs**: Monitor group epoch changes
- **Handle Updates**: Process server-side epoch updates
- **State Consistency**: Maintain epoch consistency across local and server state

### 7. Observer Pattern
- **State Change Notifications**: Notify observers of all state changes
- **Event Types**: Support for multiple event types (creation, joins, updates, etc.)
- **Flexible Observers**: Add/remove observers dynamically
- **Error Notifications**: Report sync and operation failures

## Architecture

### Dependencies
- `MLSAPIClient`: Server communication for MLS endpoints
- `mls_ffi`: Native MLS cryptographic operations via FFI

### State Management
- **Observable**: Uses Swift's `@Observable` macro for SwiftUI integration
- **Conversations**: Dictionary of active conversations indexed by ID
- **Group States**: MLS-specific group state indexed by group ID
- **Pending Operations**: Queue for retry logic and offline support

### Error Handling
Comprehensive error types covering:
- Authentication errors
- Context initialization failures
- Conversation not found
- Invalid messages/ciphertexts
- Missing key packages
- Server errors
- Sync failures

### Logging
- Structured logging using `OSLog`
- Category: `MLSConversationManager`
- Subsystem: `blue.catbird`
- Log levels: debug, info, warning, error

## Usage Examples

### Initialize Manager
```swift
let apiClient = MLSAPIClient(
    baseURL: URL(string: "https://api.catbird.blue")!,
    userDid: "did:plc:user123",
    authToken: "auth_token"
)

let manager = MLSConversationManager(
    apiClient: apiClient,
    userDid: "did:plc:user123"
)
```

### Create a Group
```swift
let metadata = MLSConvoMetadata(
    name: "My Group",
    description: "A secure group chat",
    avatar: nil
)

let conversation = try await manager.createGroup(
    initialMembers: ["did:plc:friend1", "did:plc:friend2"],
    metadata: metadata
)
```

### Send a Message
```swift
let message = try await manager.sendMessage(
    convoId: conversation.id,
    plaintext: "Hello, secure world!",
    contentType: "text/plain"
)
```

### Decrypt a Message
```swift
let plaintext = try manager.decryptMessage(receivedMessage)
print("Decrypted: \(plaintext)")
```

### Add Observer
```swift
let observer = MLSStateObserver { event in
    switch event {
    case .conversationCreated(let convo):
        print("New conversation: \(convo.id)")
    case .messageSent(let message):
        print("Message sent: \(message.id)")
    case .epochUpdated(let convoId, let epoch):
        print("Epoch updated: \(convoId) -> \(epoch)")
    case .syncCompleted(let count):
        print("Synced \(count) conversations")
    default:
        break
    }
}

manager.addObserver(observer)
```

### Sync with Server
```swift
try await manager.syncWithServer(fullSync: true)
```

### Publish Key Package
```swift
let expiresAt = Date(timeIntervalSinceNow: 30 * 24 * 60 * 60) // 30 days
let keyPackage = try await manager.publishKeyPackage(expiresAt: expiresAt)
```

## Testing

Comprehensive unit tests are provided in `MLSConversationManagerTests.swift`:

### Test Coverage
- ✅ Manager initialization
- ✅ Group creation (success, errors, with members)
- ✅ Join group (invalid welcome, not found)
- ✅ Add members (success, missing key packages, not found)
- ✅ Leave conversation
- ✅ Send messages (success, with attachments, errors)
- ✅ Decrypt messages (success, invalid ciphertext)
- ✅ Server sync (success, pagination, errors, concurrent)
- ✅ Key package management (publish, refresh)
- ✅ Epoch management (get, handle updates)
- ✅ Observer pattern (add, remove, notifications)
- ✅ Error handling (all error types)

### Mock API Client
The test suite includes a comprehensive `MockMLSAPIClient` that:
- Simulates all API responses
- Supports error injection
- Tracks all requests
- Handles pagination
- Simulates network delays

### Running Tests
```bash
# Run all MLS tests
xcodebuild test -scheme Catbird -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:CatbirdTests/MLSConversationManagerTests

# Run specific test
xcodebuild test -scheme Catbird -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:CatbirdTests/MLSConversationManagerTests/testCreateGroupSuccess
```

## Integration Notes

### FFI Integration
The manager uses the MLS FFI library for cryptographic operations:
- `mls_init()`: Initialize MLS context
- `mls_create_group()`: Create local group
- `mls_create_key_package()`: Generate key packages
- `mls_encrypt_message()`: Encrypt messages
- `mls_decrypt_message()`: Decrypt messages
- `mls_process_welcome()`: Process Welcome messages

### Bridging Header Required
Ensure your project has a bridging header that imports `mls_ffi.h`:
```objc
// Catbird-Bridging-Header.h
#import "mls_ffi.h"
```

### Build Settings
Add to your Xcode project:
1. **Header Search Paths**: Path to `mls_ffi.h`
2. **Library Search Paths**: Path to MLS FFI static libraries
3. **Link Binary With Libraries**: Add `libmls_ffi_*.a` files

## Security Considerations

1. **Key Storage**: MLS context is stored in memory only (cleared on deinit)
2. **Authentication**: Requires valid DID and auth token
3. **Key Package Rotation**: Automatic refresh of expiring key packages
4. **Forward Secrecy**: Provided by MLS protocol via epoch updates
5. **Post-Compromise Security**: Achieved through MLS group rekeying

## Performance Considerations

1. **Async Operations**: All network operations are async/await
2. **Pagination**: Large conversation lists are paginated
3. **Lazy Loading**: Groups are loaded on-demand
4. **Efficient Storage**: In-memory state with server sync
5. **Retry Logic**: Automatic retry with exponential backoff (via API client)

## Future Enhancements

Potential improvements:
- [ ] Offline message queue
- [ ] Persistent local storage
- [ ] Background sync
- [ ] Delivery receipts
- [ ] Read receipts
- [ ] Typing indicators
- [ ] Group admin features (remove members)
- [ ] Group metadata updates
- [ ] Key backup/recovery

## Dependencies

- Swift 5.9+
- iOS 17.0+
- OSLog framework
- MLS FFI library
- MLSAPIClient

## License

Same as Catbird project license.

## Authors

Generated as part of the MLS integration for Catbird.
