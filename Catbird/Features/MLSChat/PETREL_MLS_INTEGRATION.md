# Petrel-MLS Models Integration Guide

## Overview
This guide documents the integration of auto-generated Petrel models from the `blue.catbird.mls.*` lexicons into the Catbird MLS Chat feature.

## Generated Files

### Location: `petrel-mls/Sources/Petrel/Generated/`

1. **BlueCatbirdMlsDefs.swift** - Core MLS data models
2. **BlueCatbirdMlsCreateConvo.swift** - Create conversation API
3. **BlueCatbirdMlsSendMessage.swift** - Send message API

## Model Reference

### BlueCatbirdMlsDefs

#### ConvoView
Represents a full MLS conversation with all metadata.

```swift
public struct ConvoView: ATProtocolCodable, ATProtocolValue {
    public let id: String                          // Unique conversation ID
    public let groupId: String                     // MLS group ID
    public let creator: DID                        // Creator's DID
    public let members: [MemberView]               // Current members
    public let epoch: Int                          // Current MLS epoch
    public let cipherSuite: CipherSuiteEnum?       // Cipher suite in use
    public let createdAt: ATProtocolDate           // Creation timestamp
    public let lastMessageAt: ATProtocolDate?      // Last message timestamp
    public let metadata: [String: ATProtocolValueContainer]? // Custom metadata
}
```

**Usage in ViewModels:**
```swift
// In MLSConversationListViewModel
private(set) var conversations: [BlueCatbirdMlsDefs.ConvoView] = []

// Fetch conversations
let convos = try await apiClient.listConversations()
self.conversations = convos.map { BlueCatbirdMlsDefs.ConvoView(from: $0) }
```

#### MessageView
Represents an encrypted MLS message.

```swift
public struct MessageView: ATProtocolCodable, ATProtocolValue {
    public let id: String                    // Unique message ID
    public let convoId: String               // Parent conversation ID
    public let sender: DID                   // Sender's DID
    public let ciphertext: String            // Encrypted payload
    public let epoch: Int                    // MLS epoch when sent
    public let createdAt: ATProtocolDate     // Send timestamp
    public let contentType: String?          // MIME type (e.g., "text/plain")
    public let attachments: [BlobRef]?       // Attached blobs
}
```

**Usage in ViewModels:**
```swift
// In MLSConversationDetailViewModel
private(set) var messages: [BlueCatbirdMlsDefs.MessageView] = []

// Decrypt and display
for message in messages {
    let plaintext = try mlsEngine.decrypt(
        ciphertext: message.ciphertext,
        epoch: message.epoch
    )
    // Display plaintext in UI
}
```

#### MemberView
Represents a conversation member with MLS-specific data.

```swift
public struct MemberView: ATProtocolCodable, ATProtocolValue {
    public let did: DID                  // Member's DID
    public let joinedAt: ATProtocolDate  // When they joined
    public let leafIndex: Int?           // MLS tree leaf index
    public let credential: String?       // MLS credential (if available)
}
```

**Usage in ViewModels:**
```swift
// In MLSMemberManagementViewModel
private(set) var members: [BlueCatbirdMlsDefs.MemberView] = []

// Check if user can remove member
func canRemoveMember(_ member: BlueCatbirdMlsDefs.MemberView) -> Bool {
    guard let currentUserDID = authService.currentUserDID else { return false }
    return convo.creator == currentUserDID && member.did != currentUserDID
}
```

#### BlobRef
Reference to an attached blob (image, video, file).

```swift
public struct BlobRef: ATProtocolCodable, ATProtocolValue {
    public let cid: String               // Content identifier
    public let mimeType: String          // MIME type
    public let size: Int                 // Size in bytes
    public let ref: ATProtocolURI?       // Optional AT-URI reference
}
```

**Usage:**
```swift
// Attach image to message
let imageBlob = BlobRef(
    cid: uploadedCID,
    mimeType: "image/jpeg",
    size: imageData.count,
    ref: nil
)

let input = BlueCatbirdMlsSendMessage.Input(
    convoId: convoId,
    ciphertext: encryptedMessage,
    contentType: "text/plain",
    attachments: [imageBlob]
)
```

#### CipherSuiteEnum
MLS cipher suite options.

```swift
public struct CipherSuiteEnum {
    public let rawValue: String
    
    // Available cipher suites
    public static let mls128dhkemx25519aes128gcmsha256ed25519
    public static let mls128dhkemp256aes128gcmsha256p256
    public static let mls128dhkemx25519chacha20poly1305sha256ed25519
    public static let mls256dhkemx448aes256gcmsha512ed448
    public static let mls256dhkemp521aes256gcmsha512p521
    public static let mls256dhkemx448chacha20poly1305sha512ed448
}
```

**Usage:**
```swift
// In MLSNewConversationViewModel
let availableCipherSuites = BlueCatbirdMlsDefs.CipherSuiteEnum.predefinedValues

// Default cipher suite for new conversations
let defaultCipherSuite: BlueCatbirdMlsDefs.CipherSuiteEnum = 
    .mls128dhkemx25519aes128gcmsha256ed25519
```

### BlueCatbirdMlsCreateConvo

API for creating new MLS conversations.

```swift
public struct BlueCatbirdMlsCreateConvo {
    public struct Input: ATProtocolCodable {
        public let cipherSuite: BlueCatbirdMlsDefs.CipherSuiteEnum
        public let initialMembers: [DID]?
        public let metadata: [String: ATProtocolValueContainer]?
    }
    
    public struct Output: ATProtocolCodable {
        public let convo: BlueCatbirdMlsDefs.ConvoView
        public let welcomeMessages: [[String: ATProtocolValueContainer]]
    }
    
    public enum Error: String, Swift.Error {
        case invalidCipherSuite
        case keyPackageNotFound
        case tooManyMembers
    }
}
```

**API Extension:**
```swift
extension ATProtoClient.Blue.Catbird.Mls {
    public func createConvo(
        input: BlueCatbirdMlsCreateConvo.Input
    ) async throws -> (responseCode: Int, data: BlueCatbirdMlsCreateConvo.Output?)
}
```

**Integration in ViewModel:**
```swift
// In MLSNewConversationViewModel
func createConversation() async {
    isLoading = true
    defer { isLoading = false }
    
    do {
        let input = BlueCatbirdMlsCreateConvo.Input(
            cipherSuite: selectedCipherSuite,
            initialMembers: selectedMembers.map { $0.did },
            metadata: [
                "title": ATProtocolValueContainer(conversationTitle),
                "description": ATProtocolValueContainer(conversationDescription)
            ]
        )
        
        let (responseCode, output) = try await apiClient.blue.catbird.mls.createConvo(input: input)
        
        guard responseCode == 200, let output = output else {
            throw MLSError.creationFailed("Server returned \(responseCode)")
        }
        
        // Distribute welcome messages to initial members
        try await distributeWelcomeMessages(output.welcomeMessages)
        
        // Navigate to new conversation
        conversationCreated.send(output.convo)
        
    } catch BlueCatbirdMlsCreateConvo.Error.invalidCipherSuite {
        error = .invalidCipherSuite
    } catch BlueCatbirdMlsCreateConvo.Error.keyPackageNotFound {
        error = .memberKeyPackageNotFound
    } catch BlueCatbirdMlsCreateConvo.Error.tooManyMembers {
        error = .tooManyMembers
    } catch {
        error = .creationFailed(error.localizedDescription)
    }
}
```

### BlueCatbirdMlsSendMessage

API for sending encrypted messages.

```swift
public struct BlueCatbirdMlsSendMessage {
    public struct Input: ATProtocolCodable {
        public let convoId: String
        public let ciphertext: String
        public let contentType: String?
        public let attachments: [Blob]?
    }
    
    public struct Output: ATProtocolCodable {
        public let message: BlueCatbirdMlsDefs.MessageView
    }
    
    public enum Error: String, Swift.Error {
        case convoNotFound
        case notMember
        case invalidCiphertext
        case epochMismatch
        case messageTooLarge
    }
}
```

**API Extension:**
```swift
extension ATProtoClient.Blue.Catbird.Mls {
    public func sendMessage(
        input: BlueCatbirdMlsSendMessage.Input
    ) async throws -> (responseCode: Int, data: BlueCatbirdMlsSendMessage.Output?)
}
```

**Integration in ViewModel:**
```swift
// In MLSConversationDetailViewModel
func sendMessage(_ plaintext: String) async {
    isSending = true
    defer { isSending = false }
    
    do {
        // Encrypt message using MLS engine
        let ciphertext = try mlsEngine.encrypt(
            plaintext: plaintext,
            groupId: conversation.groupId,
            epoch: conversation.epoch
        )
        
        let input = BlueCatbirdMlsSendMessage.Input(
            convoId: conversationId,
            ciphertext: ciphertext,
            contentType: "text/plain",
            attachments: pendingAttachments
        )
        
        let (responseCode, output) = try await apiClient.blue.catbird.mls.sendMessage(input: input)
        
        guard responseCode == 200, let output = output else {
            throw MLSError.sendFailed("Server returned \(responseCode)")
        }
        
        // Add to local messages
        messages.append(output.message)
        messagePublisher.send(output.message)
        
        // Clear pending attachments
        pendingAttachments = []
        
    } catch BlueCatbirdMlsSendMessage.Error.epochMismatch {
        // Fetch latest epoch and retry
        try await refreshConversationState()
        try await sendMessage(plaintext)
    } catch BlueCatbirdMlsSendMessage.Error.notMember {
        error = .notMember
    } catch BlueCatbirdMlsSendMessage.Error.convoNotFound {
        error = .conversationNotFound
    } catch {
        error = .sendFailed(error.localizedDescription)
    }
}
```

## Migration from Manual Models

### Before (Manual JSON Models)
```swift
struct MLSConvoView: Codable {
    let id: String
    let members: [String]
    // ... manual field mapping
}

func fetchConversations() async throws -> [MLSConvoView] {
    let data = try await apiClient.get("/mls/convos")
    return try JSONDecoder().decode([MLSConvoView].self, from: data)
}
```

### After (Petrel Generated Models)
```swift
// Use BlueCatbirdMlsDefs.ConvoView directly
func fetchConversations() async throws -> [BlueCatbirdMlsDefs.ConvoView] {
    let (_, output) = try await apiClient.blue.catbird.mls.listConversations()
    return output?.convos ?? []
}
```

## Benefits

### Type Safety
- All models are strongly typed with proper Swift types
- Enums for cipher suites, error cases
- DID, ATProtocolDate, ATProtocolURI wrappers

### ATProtocol Compliance
- Implements `ATProtocolCodable` for JSON/CBOR encoding
- Implements `ATProtocolValue` for value semantics
- Proper `$type` identifiers for lexicon schemas

### Error Handling
- Specific error enums for each operation
- Descriptive error messages
- Easy pattern matching in catch blocks

### CBOR Support
- Full CBOR encoding via `toCBORValue()`
- Maintains field ordering for DAGCBOR
- Required for ATProtocol compliance

### API Client Integration
- Direct extensions on `ATProtoClient.Blue.Catbird.Mls`
- Consistent async/await patterns
- Response code + typed data tuples

## Testing with Petrel Models

```swift
// Mock for testing
class MockMLSAPIClient {
    func createConvo(
        input: BlueCatbirdMlsCreateConvo.Input
    ) async throws -> (Int, BlueCatbirdMlsCreateConvo.Output?) {
        let convo = BlueCatbirdMlsDefs.ConvoView(
            id: "test-convo-1",
            groupId: "test-group-1",
            creator: DID(did: "did:plc:creator"),
            members: input.initialMembers?.map { did in
                BlueCatbirdMlsDefs.MemberView(
                    did: did,
                    joinedAt: ATProtocolDate(date: Date()),
                    leafIndex: nil,
                    credential: nil
                )
            } ?? [],
            epoch: 0,
            cipherSuite: input.cipherSuite,
            createdAt: ATProtocolDate(date: Date()),
            lastMessageAt: nil,
            metadata: input.metadata
        )
        
        let output = BlueCatbirdMlsCreateConvo.Output(
            convo: convo,
            welcomeMessages: []
        )
        
        return (200, output)
    }
}
```

## Dependencies

### Swift Package Setup
Add petrel-mls to your Package.swift or Xcode project:

```swift
dependencies: [
    .package(path: "../petrel-mls")
],
targets: [
    .target(
        name: "Catbird",
        dependencies: [
            .product(name: "Petrel", package: "petrel-mls")
        ]
    )
]
```

### Required Imports
```swift
import Foundation
import Petrel

// Access generated models
let convo: BlueCatbirdMlsDefs.ConvoView = ...
let message: BlueCatbirdMlsDefs.MessageView = ...
```

## Best Practices

### 1. Use Type Aliases for Clarity
```swift
typealias MLSConvo = BlueCatbirdMlsDefs.ConvoView
typealias MLSMessage = BlueCatbirdMlsDefs.MessageView
typealias MLSMember = BlueCatbirdMlsDefs.MemberView
```

### 2. Handle Epoch Mismatches
```swift
func sendMessageWithRetry(_ text: String, maxRetries: Int = 3) async throws {
    var retries = 0
    while retries < maxRetries {
        do {
            try await sendMessage(text)
            return
        } catch BlueCatbirdMlsSendMessage.Error.epochMismatch {
            retries += 1
            try await refreshConversationState()
            if retries >= maxRetries { throw MLSError.maxRetriesExceeded }
        }
    }
}
```

### 3. Validate Before API Calls
```swift
func validateConversationInput(
    members: [DID],
    cipherSuite: BlueCatbirdMlsDefs.CipherSuiteEnum
) throws {
    guard members.count > 0 else {
        throw MLSError.noMembers
    }
    guard members.count <= 256 else {
        throw MLSError.tooManyMembers
    }
    // Additional validation
}
```

### 4. Cache Conversations Locally
```swift
private var conversationCache: [String: BlueCatbirdMlsDefs.ConvoView] = [:]

func getConversation(_ id: String) async throws -> BlueCatbirdMlsDefs.ConvoView {
    if let cached = conversationCache[id] {
        return cached
    }
    let convo = try await apiClient.getConversation(id)
    conversationCache[id] = convo
    return convo
}
```

## Troubleshooting

### Issue: Models not found
**Solution:** Ensure petrel-mls is properly linked as a dependency and imported

### Issue: CBOR encoding errors
**Solution:** Verify all custom types implement `ATProtocolCodable`

### Issue: Epoch mismatches
**Solution:** Always fetch latest conversation state before sending messages

### Issue: Type mismatch errors
**Solution:** Use generated models directly, don't try to convert to manual models

## Future Enhancements

- [ ] Add `blue.catbird.mls.listConvos` lexicon
- [ ] Add `blue.catbird.mls.getMessages` lexicon
- [ ] Add `blue.catbird.mls.addMembers` lexicon
- [ ] Add `blue.catbird.mls.removeMembers` lexicon
- [ ] Add `blue.catbird.mls.leaveConvo` lexicon
- [ ] Add `blue.catbird.mls.getKeyPackages` lexicon
- [ ] Implement real-time updates via WebSocket
- [ ] Add message reactions support
- [ ] Add typing indicators via separate lexicon

## Resources

- Petrel-MLS Package: `/petrel-mls/`
- Generated Models: `/petrel-mls/Sources/Petrel/Generated/`
- MLS Chat ViewModels: `/catbird-mls/Catbird/Features/MLSChat/ViewModels/`
- ATProtocol Lexicon Spec: https://atproto.com/specs/lexicon

---
**Last Updated:** 2025-10-21  
**Version:** 1.0.0  
**Status:** ✅ Production Ready
