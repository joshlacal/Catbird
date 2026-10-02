# MLS Storage

This directory contains the Core Data storage layer and Keychain management for MLS (Messaging Layer Security) in Catbird.

## Components

### Core Data Model
- **MLS.xcdatamodeld/**: Core Data model definition
  - `MLSConversation`: Group conversation entity
  - `MLSMessage`: Encrypted message entity
  - `MLSMember`: Group member entity
  - `MLSKeyPackage`: Pre-generated key package entity

### Swift Files
- **MLSStorage.swift**: Main storage manager with CRUD operations
- **MLSKeychainManager.swift**: Secure keychain storage for cryptographic materials

### Documentation
- **STORAGE_ARCHITECTURE.md**: Comprehensive architecture documentation

## Quick Start

### Creating a Conversation

```swift
let storage = MLSStorage.shared
let conversation = try await storage.createConversation(
    conversationID: conversationID,
    groupID: groupIDData,
    epoch: 0,
    title: "My Group"
)
```

### Storing Cryptographic Keys

```swift
let keychain = MLSKeychainManager.shared
try keychain.storePrivateKey(
    privateKeyData,
    forConversationID: conversationID,
    epoch: currentEpoch
)
```

### Reactive Updates

```swift
storage.setupConversationsFRC(delegate: self)

// Access conversations
let conversations = storage.conversations
```

## Testing

Run tests with:
```bash
xcodebuild test -scheme Catbird -destination 'platform=iOS Simulator,name=iPhone 15'
```

Test files:
- `CatbirdTests/Storage/MLSStorageTests.swift`
- `CatbirdTests/Storage/MLSKeychainManagerTests.swift`

## Security Notes

⚠️ **Important Security Considerations:**

1. **Keychain Access**: All cryptographic keys are stored in iOS Keychain with device-only accessibility
2. **Forward Secrecy**: Old epoch keys should be deleted after epoch advancement
3. **No iCloud Sync**: Cryptographic materials are never synchronized to iCloud
4. **File Protection**: Core Data store uses iOS file-level encryption

## Performance Tips

1. Use background contexts for bulk operations
2. Enable batch faulting for large result sets
3. Clean up old messages and key packages periodically
4. Use NSFetchedResultsController for UI updates

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│             Application Layer               │
├─────────────────────────────────────────────┤
│          MLSStorage (CRUD Ops)              │
├──────────────────┬──────────────────────────┤
│   Core Data      │   MLSKeychainManager     │
│   (Messages,     │   (Keys, Secrets)        │
│   Metadata)      │                          │
├──────────────────┴──────────────────────────┤
│             iOS Persistence                 │
│   (SQLite Store)  │  (Keychain Services)    │
└─────────────────────────────────────────────┘
```

## Entity Relationships

```
MLSConversation
├── messages (1:N) → MLSMessage
├── members (1:N) → MLSMember
└── keyPackages (1:N) → MLSKeyPackage
```

## Key Storage Structure

Keychain keys follow this naming convention:
- Group State: `mls.groupstate.{conversationID}`
- Private Keys: `mls.privatekey.{conversationID}.epoch.{epoch}`
- Signature Keys: `mls.signaturekey.{conversationID}`
- Encryption Keys: `mls.encryptionkey.{conversationID}`
- Epoch Secrets: `mls.epochsecrets.{conversationID}.epoch.{epoch}`
- HPKE Keys: `mls.hpke.privatekey.{keyPackageID}`

## Error Handling

Both storage and keychain operations throw typed errors:

```swift
do {
    try storage.createMessage(...)
} catch MLSStorageError.conversationNotFound(let id) {
    // Handle missing conversation
} catch {
    // Handle other errors
}
```

## Logging

Uses OSLog with subsystem `blue.catbird.mls`:
- `MLSStorage` category for Core Data operations
- `MLSKeychainManager` category for Keychain operations

Enable debug logging:
```bash
log stream --predicate 'subsystem == "blue.catbird.mls"' --level debug
```

## Contributing

When modifying the storage layer:

1. Update the Core Data model version if changing schema
2. Add migration code for schema changes
3. Update tests for new functionality
4. Document security implications
5. Update STORAGE_ARCHITECTURE.md

## License

See main project LICENSE file.
