# MLSConversationManager Quick Reference

## Quick Start

```swift
// 1. Initialize
let manager = MLSConversationManager(
    apiClient: apiClient,
    userDid: "did:plc:youruser"
)

// 2. Create a group
let convo = try await manager.createGroup(
    initialMembers: ["did:plc:friend1"],
    metadata: MLSConvoMetadata(name: "Friends", description: nil, avatar: nil)
)

// 3. Send a message
let message = try await manager.sendMessage(
    convoId: convo.id,
    plaintext: "Hello!"
)

// 4. Decrypt a message
let plaintext = try manager.decryptMessage(receivedMessage)
```

## API Reference

### Group Management

| Method | Purpose | Returns |
|--------|---------|---------|
| `createGroup(initialMembers:metadata:)` | Create new MLS group | `MLSConvoView` |
| `joinGroup(welcomeMessage:)` | Join existing group | `MLSConvoView` |
| `leaveConversation(convoId:)` | Leave a group | `Void` |

### Member Management

| Method | Purpose | Returns |
|--------|---------|---------|
| `addMembers(convoId:memberDids:)` | Add members to group | `Void` |

### Messaging

| Method | Purpose | Returns |
|--------|---------|---------|
| `sendMessage(convoId:plaintext:contentType:attachments:)` | Send encrypted message | `MLSMessageView` |
| `decryptMessage(_:)` | Decrypt received message | `String` |

### Synchronization

| Method | Purpose | Returns |
|--------|---------|---------|
| `syncWithServer(fullSync:)` | Sync conversations | `Void` |

### Key Management

| Method | Purpose | Returns |
|--------|---------|---------|
| `publishKeyPackage(expiresAt:)` | Publish new key package | `MLSKeyPackageRef` |
| `refreshKeyPackagesIfNeeded()` | Refresh expiring packages | `Void` |

### Epoch Management

| Method | Purpose | Returns |
|--------|---------|---------|
| `getEpoch(convoId:)` | Get current epoch | `Int` |
| `handleEpochUpdate(convoId:newEpoch:)` | Handle epoch change | `Void` |

### Observers

| Method | Purpose | Returns |
|--------|---------|---------|
| `addObserver(_:)` | Add state observer | `Void` |
| `removeObserver(_:)` | Remove state observer | `Void` |

## State Events

| Event | When Triggered | Data |
|-------|----------------|------|
| `.conversationCreated(convo)` | New group created | `MLSConvoView` |
| `.conversationJoined(convo)` | Joined existing group | `MLSConvoView` |
| `.conversationLeft(id)` | Left a group | `String` |
| `.membersAdded(convoId, dids)` | Members added | `String, [String]` |
| `.messageSent(message)` | Message sent | `MLSMessageView` |
| `.epochUpdated(convoId, epoch)` | Epoch changed | `String, Int` |
| `.syncCompleted(count)` | Sync finished | `Int` |
| `.syncFailed(error)` | Sync failed | `Error` |

## Error Types

| Error | Description |
|-------|-------------|
| `.noAuthentication` | User not authenticated |
| `.contextNotInitialized` | MLS context failed to initialize |
| `.conversationNotFound` | Conversation ID doesn't exist |
| `.groupStateNotFound` | Group state missing |
| `.invalidWelcomeMessage` | Welcome message malformed |
| `.invalidIdentity` | User identity invalid |
| `.invalidGroupId` | Group ID malformed |
| `.invalidMessage` | Message format invalid |
| `.invalidCiphertext` | Ciphertext malformed |
| `.decodingFailed` | Failed to decode message |
| `.missingKeyPackages(dids)` | Key packages not available |
| `.mlsError(message)` | MLS operation failed |
| `.serverError(error)` | Server API error |
| `.syncFailed(error)` | Sync operation failed |

## Properties

| Property | Type | Description |
|----------|------|-------------|
| `conversations` | `[String: MLSConvoView]` | Active conversations (read-only) |
| `isSyncing` | `Bool` | Current sync status (read-only) |
| `defaultCipherSuite` | `String` | Default cipher suite (read-only) |
| `keyPackageRefreshInterval` | `TimeInterval` | Key package refresh interval (read-only) |

## Common Patterns

### Setup Observer
```swift
let observer = MLSStateObserver { event in
    switch event {
    case .conversationCreated(let convo):
        print("Created: \(convo.id)")
    case .messageSent(let message):
        print("Sent: \(message.id)")
    case .epochUpdated(let convoId, let epoch):
        print("Epoch: \(convoId) -> \(epoch)")
    default:
        break
    }
}
manager.addObserver(observer)
```

### Handle Errors
```swift
do {
    try await manager.addMembers(
        convoId: conversationId,
        memberDids: newMembers
    )
} catch MLSConversationError.missingKeyPackages(let dids) {
    print("Missing key packages for: \(dids)")
} catch MLSConversationError.conversationNotFound {
    print("Conversation not found")
} catch {
    print("Unknown error: \(error)")
}
```

### Send Message with Attachment
```swift
// Upload blob first
let blobData = imageData
let blob = try await apiClient.uploadBlob(
    data: blobData,
    mimeType: "image/png"
)

// Send message with attachment
let message = try await manager.sendMessage(
    convoId: conversationId,
    plaintext: "Check this out!",
    contentType: "text/plain",
    attachments: [blob]
)
```

### Periodic Key Package Refresh
```swift
Task {
    while true {
        try await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 hour
        try? await manager.refreshKeyPackagesIfNeeded()
    }
}
```

### Background Sync
```swift
Task {
    while true {
        try? await manager.syncWithServer(fullSync: false)
        try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
    }
}
```

## Best Practices

1. **Initialize once**: Create a single manager instance and share it
2. **Error handling**: Always wrap async calls in do-catch
3. **Observer cleanup**: Remove observers when views are dismissed
4. **Key packages**: Refresh regularly to ensure joinability
5. **Sync regularly**: Poll for updates or use push notifications
6. **Offline support**: Queue messages when offline (future feature)
7. **Epoch tracking**: Monitor epoch updates for security auditing

## Thread Safety

- All public methods are thread-safe
- Internal state is protected
- Async/await ensures proper concurrency
- Observable updates are thread-safe

## Performance Tips

1. Use pagination for large conversation lists
2. Decrypt messages on-demand, not in advance
3. Cache decrypted messages in memory
4. Batch member additions when possible
5. Use incremental sync instead of full sync
6. Implement message pagination

## Debugging

Enable detailed logging:
```swift
// In your app's logging configuration
let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationManager")
logger.debug("Current conversations: \(manager.conversations.count)")
```

Check state:
```swift
print("Conversations: \(manager.conversations.keys)")
print("Is syncing: \(manager.isSyncing)")
```

## Testing

Run tests:
```bash
xcodebuild test -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:CatbirdTests/MLSConversationManagerTests
```

Mock the manager in your tests:
```swift
let mockAPIClient = MockMLSAPIClient()
let testManager = MLSConversationManager(
    apiClient: mockAPIClient,
    userDid: "did:plc:testuser"
)
```

## Integration Checklist

- [ ] Add MLS FFI library to project
- [ ] Create bridging header with `mls_ffi.h`
- [ ] Configure build settings (header/library paths)
- [ ] Initialize manager with authenticated API client
- [ ] Add state observers for UI updates
- [ ] Implement message list with decryption
- [ ] Add error handling UI
- [ ] Test with multiple users
- [ ] Verify epoch updates work correctly
- [ ] Test offline/online transitions

## Related Files

- `MLSAPIClient.swift` - Server API communication
- `MLSConversationManagerTests.swift` - Unit tests
- `MLSConversationManager_README.md` - Detailed documentation
- `mls_ffi.h` - FFI interface definition

## Support

For issues or questions:
1. Check the README for detailed documentation
2. Review test cases for usage examples
3. Enable debug logging for troubleshooting
4. Consult MLS FFI documentation for crypto operations
