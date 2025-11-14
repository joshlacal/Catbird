# MLS Storage Architecture

## Overview

The MLS (Messaging Layer Security) storage layer provides a comprehensive, secure, and efficient data persistence solution for end-to-end encrypted group messaging in Catbird. This architecture leverages Core Data for structured data storage and iOS Keychain for cryptographic material protection.

## Architecture Components

### 1. Core Data Model (`MLS.xcdatamodeld`)

The Core Data schema consists of four primary entities that model the MLS protocol's data requirements:

#### MLSConversation
Represents an MLS group conversation with its metadata and state.

**Attributes:**
- `conversationID` (String, unique): Unique identifier for the conversation
- `groupID` (Binary): MLS group identifier
- `epoch` (Integer 64): Current epoch number
- `createdAt` (Date): Creation timestamp
- `updatedAt` (Date): Last update timestamp
- `lastMessageAt` (Date, optional): Timestamp of last message
- `title` (String, optional): Conversation title
- `isActive` (Boolean): Active status flag
- `welcomeMessage` (Binary, optional): Serialized Welcome message
- `treeHash` (Binary, optional): Current ratchet tree hash
- `memberCount` (Integer 32): Number of active members

**Relationships:**
- `members` → MLSMember (one-to-many, cascade delete)
- `messages` → MLSMessage (one-to-many, cascade delete)
- `keyPackages` → MLSKeyPackage (one-to-many, cascade delete)

#### MLSMessage
Represents encrypted messages within a conversation.

**Attributes:**
- `messageID` (String, unique): Unique message identifier
- `senderID` (String): DID of the sender
- `content` (Binary): Encrypted message content
- `contentType` (String): MIME type or content classification
- `timestamp` (Date): Message creation time
- `epoch` (Integer 64): Epoch when message was sent
- `sequenceNumber` (Integer 64): Sequence number within epoch
- `wireFormat` (Binary, optional): Raw MLS ciphertext
- `authenticatedData` (Binary, optional): Additional authenticated data
- `signature` (Binary, optional): Message signature
- `isDelivered` (Boolean): Delivery status
- `isRead` (Boolean): Read status
- `isSent` (Boolean): Send status
- `sendAttempts` (Integer 16): Number of send attempts
- `error` (String, optional): Error message if failed

**Relationships:**
- `conversation` → MLSConversation (many-to-one)

#### MLSMember
Represents a member of an MLS group.

**Attributes:**
- `memberID` (String, unique): Unique member identifier
- `did` (String): Decentralized identifier
- `handle` (String, optional): Bluesky handle
- `displayName` (String, optional): Display name
- `leafIndex` (Integer 32): Position in ratchet tree
- `credentialData` (Binary, optional): Serialized credential
- `signaturePublicKey` (Binary, optional): Public signature key
- `addedAt` (Date): When member was added
- `updatedAt` (Date): Last update timestamp
- `removedAt` (Date, optional): When member was removed
- `isActive` (Boolean): Active membership status
- `role` (String): Member role (member, admin, moderator)
- `capabilities` (Transformable, [String]): MLS capabilities

**Relationships:**
- `conversation` → MLSConversation (many-to-one)

#### MLSKeyPackage
Represents pre-generated key packages for joining conversations.

**Attributes:**
- `keyPackageID` (String, unique): Unique key package identifier
- `keyPackageData` (Binary): Serialized key package
- `cipherSuite` (Integer 16): MLS cipher suite identifier
- `createdAt` (Date): Creation timestamp
- `expiresAt` (Date, optional): Expiration timestamp
- `isUsed` (Boolean): Usage status
- `usedAt` (Date, optional): When key package was consumed
- `ownerDID` (String): DID of key package owner
- `initKeyHash` (Binary, optional): Hash of init key
- `leafNodeHash` (Binary, optional): Hash of leaf node

**Relationships:**
- `conversation` → MLSConversation (many-to-one, optional)

### 2. Storage Manager (`MLSStorage.swift`)

The `MLSStorage` class provides the primary interface for CRUD operations on MLS data.

#### Key Features:

**Singleton Pattern:**
```swift
MLSStorage.shared
```

**Core Data Stack:**
- Automatic persistent store setup
- Background context support
- Merge policy: property object trump
- Automatic change merging from parent context

**CRUD Operations:**

All entities support:
- Create with validation
- Fetch by ID or criteria
- Update with partial field updates
- Delete with cascade cleanup

**Reactive Updates:**

Uses `NSFetchedResultsController` for reactive data observation:
```swift
storage.setupConversationsFRC(delegate: self)
let conversations = storage.conversations
```

**Batch Operations:**
- Delete all messages for a conversation
- Delete expired key packages
- Efficient bulk operations using batch requests

**Thread Safety:**
- Main actor isolation for view context
- Background context creation for async operations
- Proper context save coordination

#### Usage Examples:

**Creating a Conversation:**
```swift
let conversation = try await storage.createConversation(
    conversationID: "conv-123",
    groupID: groupIDData,
    epoch: 0,
    title: "Team Chat"
)
```

**Sending a Message:**
```swift
let message = try await storage.createMessage(
    messageID: messageID,
    conversationID: conversationID,
    senderID: userDID,
    content: encryptedContent,
    contentType: "text",
    epoch: currentEpoch,
    sequenceNumber: nextSeq
)
```

**Managing Members:**
```swift
let member = try await storage.createMember(
    memberID: memberID,
    conversationID: conversationID,
    did: userDID,
    handle: "user.bsky.social",
    leafIndex: leafIndex
)
```

### 3. Keychain Manager (`MLSKeychainManager.swift`)

The `MLSKeychainManager` provides secure storage for cryptographic materials using iOS Keychain.

#### Security Features:

**Access Control:**
- `kSecAttrAccessibleAfterFirstUnlock`: Group state (persistent)
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: Cryptographic keys (secure)
- Not synchronized to iCloud for maximum security

**Key Types Managed:**

1. **Group State:** Encrypted MLS group state
2. **Private Keys:** Per-epoch private keys
3. **Signature Keys:** Long-term signature keys
4. **Encryption Keys:** Encryption keys per conversation
5. **Epoch Secrets:** Application and exporter secrets
6. **HPKE Private Keys:** For key packages

#### Key Management:

**Epoch-Based Key Storage:**
```swift
// Store private key for specific epoch
try keychainManager.storePrivateKey(
    keyData,
    forConversationID: conversationID,
    epoch: epoch
)

// Retrieve for decryption
let key = try keychainManager.retrievePrivateKey(
    forConversationID: conversationID,
    epoch: epoch
)
```

**Forward Secrecy:**
```swift
// Delete old epoch keys
try keychainManager.deletePrivateKeys(
    forConversationID: conversationID,
    beforeEpoch: currentEpoch
)
```

**Key Archiving:**
```swift
// Archive key for potential recovery
try keychainManager.archiveKey(
    keyData,
    type: "signature",
    conversationID: conversationID,
    epoch: epoch
)
```

## Data Flow

### Message Sending Flow:

1. **Encrypt Message:** Use MLS protocol to encrypt
2. **Store Locally:** Create MLSMessage in Core Data
3. **Store Keys:** Save epoch secrets in Keychain
4. **Update State:** Increment sequence number
5. **Send to Network:** Transmit wireFormat
6. **Update Status:** Mark as sent/delivered

### Message Receiving Flow:

1. **Receive from Network:** Get encrypted message
2. **Retrieve Keys:** Fetch epoch secrets from Keychain
3. **Decrypt:** Use MLS protocol to decrypt
4. **Store Message:** Create MLSMessage with content
5. **Update UI:** Notify via FetchedResultsController

### Group Operations Flow:

1. **Add Member:** 
   - Generate Commit and Welcome
   - Update ratchet tree
   - Store new epoch keys
   - Create MLSMember entity
   - Distribute Welcome message

2. **Remove Member:**
   - Generate Commit
   - Update ratchet tree
   - Rotate epoch keys
   - Mark member as inactive
   - Clean up old keys

## Performance Considerations

### Core Data Optimizations:

1. **Batch Fetching:** Use batch sizes for large result sets
2. **Faulting:** Lazy load relationships when needed
3. **Batch Operations:** Use NSBatchDeleteRequest for bulk deletes
4. **Indexes:** Unique constraints on IDs for fast lookups

### Keychain Optimizations:

1. **Minimize Queries:** Cache frequently used keys in memory
2. **Batch Operations:** Delete multiple keys efficiently
3. **Key Rotation:** Clean up old epoch keys regularly

### Memory Management:

1. **Background Contexts:** Use for bulk operations
2. **Fetch Limits:** Paginate large message lists
3. **Relationship Faulting:** Don't load unnecessary relationships

## Security Considerations

### Data Protection:

1. **Core Data:** File-level encryption via iOS
2. **Keychain:** Hardware-backed security
3. **Memory:** Zero sensitive data after use

### Key Lifecycle:

1. **Generation:** SecRandomCopyBytes for secure random
2. **Storage:** Keychain with device-only access
3. **Usage:** Minimize exposure time
4. **Deletion:** Immediate cleanup after epoch change

### Forward Secrecy:

1. **Epoch Keys:** Delete after epoch advancement
2. **Message Keys:** Single-use, not stored
3. **Archive Keys:** Optional, separate storage

## Testing Strategy

### Unit Tests:

1. **MLSStorageTests:** CRUD operations, relationships, batch operations
2. **MLSKeychainManagerTests:** Key storage, retrieval, deletion

### Integration Tests:

1. End-to-end message flow
2. Group operation sequences
3. Key rotation scenarios

### Performance Tests:

1. Large conversation loading
2. Batch message operations
3. Keychain access latency

## Error Handling

### Storage Errors:

```swift
public enum MLSStorageError: LocalizedError {
    case conversationNotFound(String)
    case memberNotFound(String)
    case messageNotFound(String)
    case keyPackageNotFound(String)
    case saveFailed(Error)
}
```

### Keychain Errors:

```swift
public enum KeychainError: LocalizedError {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case randomGenerationFailed(OSStatus)
    case accessVerificationFailed
}
```

## Maintenance and Monitoring

### Regular Maintenance:

1. **Key Package Cleanup:** Delete expired packages weekly
2. **Old Message Archival:** Archive messages older than 90 days
3. **Epoch Key Cleanup:** Remove keys older than current epoch

### Monitoring:

1. **Storage Size:** Track Core Data store growth
2. **Keychain Items:** Count stored items per conversation
3. **Performance Metrics:** Query times, save times

### Logging:

Uses OSLog with subsystem `com.catbird.mls`:
- Category: `MLSStorage` for Core Data operations
- Category: `MLSKeychainManager` for Keychain operations

## Future Enhancements

### Planned Features:

1. **Cloud Sync:** Optional iCloud sync for public data
2. **Search:** Full-text search on message content
3. **Media Storage:** Efficient media attachment handling
4. **Analytics:** Query optimization based on usage patterns
5. **Backup/Restore:** Secure backup with key escrow

### Scalability:

1. **Sharding:** Split large conversations across stores
2. **Compression:** Compress old message content
3. **Caching:** In-memory cache for hot data

## Integration with MLS Protocol

The storage layer integrates with the MLS FFI layer:

```swift
// After MLS operation
let groupState = mlsGroup.exportState()
try keychainManager.storeGroupState(groupState, forConversationID: conversationID)

// Update Core Data
try storage.updateConversation(conversation, epoch: newEpoch)

// Before MLS operation
let groupState = try keychainManager.retrieveGroupState(forConversationID: conversationID)
let mlsGroup = try MLSGroup.importState(groupState)
```

## Best Practices

### For Developers:

1. **Always use MainActor for UI updates**
2. **Use background contexts for heavy operations**
3. **Clean up old epoch keys after advancement**
4. **Validate data before storage**
5. **Handle errors gracefully**
6. **Log important operations**
7. **Test migration paths thoroughly**

### For Operations:

1. **Monitor storage growth**
2. **Set up key rotation schedules**
3. **Regular backup testing**
4. **Performance profiling in production**

## Conclusion

The MLS storage architecture provides a robust, secure, and performant foundation for end-to-end encrypted group messaging in Catbird. By separating concerns between Core Data (structured data) and Keychain (cryptographic materials), we ensure both efficiency and security while maintaining clean interfaces for the rest of the application.
