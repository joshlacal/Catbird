# MLS API Client - Quick Reference

## Initialization

```swift
let client = MLSAPIClient(
    baseURL: URL(string: "https://api.catbird.blue")!,
    userDid: "did:plc:user123",
    authToken: "your_token"
)
```

## Authentication

```swift
// Set credentials
client.updateAuthentication(did: "did:plc:user", token: "token")

// Clear credentials
client.clearAuthentication()
```

## API Calls

### Conversations

```swift
// Get all conversations
let (convos, cursor) = try await client.getConversations()

// Create conversation
let response = try await client.createConversation(
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
    initialMembers: ["did:plc:friend1"]
)

// Leave conversation
let response = try await client.leaveConversation(convoId: "convo123")
```

### Members

```swift
// Add members
let response = try await client.addMembers(
    convoId: "convo123",
    members: ["did:plc:user1", "did:plc:user2"]
)
```

### Messages

```swift
// Get messages
let (messages, cursor) = try await client.getMessages(convoId: "convo123")

// Send message
let message = try await client.sendMessage(
    convoId: "convo123",
    ciphertext: "base64encrypted=="
)
```

### Key Packages

```swift
// Publish key package
let keyPackage = try await client.publishKeyPackage(
    keyPackage: "base64keypackage==",
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"
)

// Get key packages
let (keyPackages, missing) = try await client.getKeyPackages(
    dids: ["did:plc:user1", "did:plc:user2"]
)
```

### Blobs

```swift
// Upload file
let blobRef = try await client.uploadBlob(
    data: fileData,
    mimeType: "image/jpeg"
)
```

## Error Handling

```swift
do {
    let result = try await client.getConversations()
} catch MLSAPIError.noAuthentication {
    // Handle authentication error
} catch MLSAPIError.httpError(let status, let message) {
    // Handle HTTP error
} catch {
    // Handle other errors
}
```

## Cipher Suites

- `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` (recommended)
- `MLS_128_DHKEMP256_AES128GCM_SHA256_P256`
- `MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519`
- `MLS_256_DHKEMX448_AES256GCM_SHA512_Ed448`
- `MLS_256_DHKEMP521_AES256GCM_SHA512_P521`
- `MLS_256_DHKEMX448_CHACHA20POLY1305_SHA512_Ed448`

## Limits

- **Conversations**: 100 per page
- **Messages**: 100 per page
- **Initial Members**: 100 max
- **Add Members**: 50 per request
- **DIDs for Key Packages**: 100 per request
- **Blob Size**: 50MB max
- **Attachments**: 10 per message
- **Key Package Size**: 64KB max
- **Ciphertext**: 1MB max

## Common Patterns

### Pagination

```swift
var allConvos: [MLSConvoView] = []
var cursor: String? = nil

repeat {
    let (convos, nextCursor) = try await client.getConversations(cursor: cursor)
    allConvos.append(contentsOf: convos)
    cursor = nextCursor
} while cursor != nil
```

### With Metadata

```swift
let metadata = MLSConvoMetadata(
    name: "Group Name",
    description: "Description",
    avatar: avatarBlobRef
)

let response = try await client.createConversation(
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
    metadata: metadata
)
```

### With Attachments

```swift
let attachments = [
    MLSBlobRef(cid: "bafytest", mimeType: "image/jpeg", size: 50000, ref: nil)
]

let message = try await client.sendMessage(
    convoId: "convo123",
    ciphertext: "encrypted==",
    attachments: attachments
)
```

## Testing

```swift
import XCTest
@testable import Catbird

final class MyMLSTests: XCTestCase {
    var client: MLSAPIClient!
    
    override func setUp() {
        client = MLSAPIClient(
            baseURL: URL(string: "https://test.example.com")!,
            maxRetries: 1
        )
    }
    
    func testExample() async throws {
        // Your test code
    }
}
```

## Files Location

- Implementation: `/Catbird/Services/MLS/MLSAPIClient.swift`
- Tests: `/CatbirdTests/Services/MLS/MLSAPIClientTests.swift`
- Documentation: `/Catbird/Services/MLS/MLS_API_CLIENT_README.md`

## See Also

- Full documentation: `MLS_API_CLIENT_README.md`
- Lexicon definitions: `/mls/lexicon/blue.catbird.mls.*.json`
- Test examples: `MLSAPIClientTests.swift`
