# MLS API Client Documentation

## Overview

The `MLSAPIClient` is a Swift client for interacting with the Catbird MLS (Message Layer Security) API. It provides end-to-end encrypted messaging capabilities following the MLS protocol specification.

## Features

- ✅ **9 Complete API Endpoints**: All MLS operations fully implemented
- ✅ **Async/Await**: Modern Swift concurrency support
- ✅ **Automatic Retry Logic**: Configurable retry mechanism with exponential backoff
- ✅ **Type-Safe Models**: Codable models matching lexicon definitions
- ✅ **Comprehensive Error Handling**: Detailed error types and messages
- ✅ **Authentication Support**: DID-based authentication with Bearer tokens
- ✅ **Logging**: OSLog integration for debugging
- ✅ **Pagination Support**: Cursor-based pagination for lists
- ✅ **Date Handling**: ISO8601 date encoding/decoding

## Installation

The MLS API Client is part of the Catbird codebase and available at:
```
/Catbird/Services/MLS/MLSAPIClient.swift
```

## Quick Start

### Initialize the Client

```swift
import Foundation

// Initialize with default production endpoint
let client = MLSAPIClient()

// Or with custom configuration
let client = MLSAPIClient(
    baseURL: URL(string: "https://api.catbird.blue")!,
    userDid: "did:plc:user123",
    authToken: "your_auth_token",
    maxRetries: 3,
    retryDelay: 1.0
)
```

### Update Authentication

```swift
// Set or update authentication credentials
client.updateAuthentication(
    did: "did:plc:user123",
    token: "your_auth_token"
)

// Clear authentication
client.clearAuthentication()
```

## API Endpoints

### 1. Get Conversations

Retrieve MLS conversations for the authenticated user.

```swift
// Basic usage
let (convos, cursor) = try await client.getConversations()

// With pagination
let (convos, nextCursor) = try await client.getConversations(
    limit: 25,
    cursor: previousCursor
)

// With sorting
let (convos, cursor) = try await client.getConversations(
    limit: 50,
    sortBy: "lastMessageAt",
    sortOrder: "desc"
)
```

**Parameters:**
- `limit`: Maximum conversations to return (1-100, default: 50)
- `cursor`: Pagination cursor from previous response
- `sortBy`: Sort field - `"createdAt"` or `"lastMessageAt"` (default)
- `sortOrder`: Sort order - `"asc"` or `"desc"` (default)

**Returns:**
- Array of `MLSConvoView` objects
- Optional pagination cursor for next page

### 2. Create Conversation

Create a new MLS conversation with optional initial members.

```swift
// Simple conversation
let response = try await client.createConversation(
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"
)

// With initial members
let response = try await client.createConversation(
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
    initialMembers: ["did:plc:user1", "did:plc:user2"]
)

// With metadata
let metadata = MLSConvoMetadata(
    name: "Team Chat",
    description: "Weekly sync discussion",
    avatar: avatarBlobRef
)
let response = try await client.createConversation(
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
    initialMembers: ["did:plc:user1"],
    metadata: metadata
)

// Access created conversation
let convo = response.convo
let welcomeMessages = response.welcomeMessages
```

**Parameters:**
- `cipherSuite`: MLS cipher suite identifier (required)
- `initialMembers`: Array of member DIDs to add (optional, max 100)
- `metadata`: Conversation metadata with name, description, avatar (optional)

**Returns:**
- `MLSCreateConvoResponse` containing:
  - `convo`: Created conversation view
  - `welcomeMessages`: Array of welcome messages for initial members

**Supported Cipher Suites:**
- `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`
- `MLS_128_DHKEMP256_AES128GCM_SHA256_P256`
- `MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519`
- `MLS_256_DHKEMX448_AES256GCM_SHA512_Ed448`
- `MLS_256_DHKEMP521_AES256GCM_SHA512_P521`
- `MLS_256_DHKEMX448_CHACHA20POLY1305_SHA512_Ed448`

### 3. Add Members

Add new members to an existing conversation.

```swift
let response = try await client.addMembers(
    convoId: "convo123",
    members: ["did:plc:newuser1", "did:plc:newuser2"]
)

// Access updated conversation
let updatedConvo = response.convo
let commitMessage = response.commit
let welcomeMessages = response.welcomeMessages
```

**Parameters:**
- `convoId`: Conversation identifier (required)
- `members`: Array of DIDs to add (1-50 members)

**Returns:**
- `MLSAddMembersResponse` containing:
  - `convo`: Updated conversation view
  - `commit`: Base64-encoded MLS Commit message for existing members
  - `welcomeMessages`: Welcome messages for new members

### 4. Leave Conversation

Leave an MLS conversation.

```swift
let response = try await client.leaveConversation(convoId: "convo123")

let commitMessage = response.commit
let newEpoch = response.epoch
```

**Parameters:**
- `convoId`: Conversation identifier

**Returns:**
- `MLSLeaveConvoResponse` containing:
  - `commit`: Base64-encoded MLS Commit message
  - `epoch`: Optional new epoch information

**Note:** Cannot leave as the last member (delete conversation instead).

### 5. Get Messages

Retrieve messages from a conversation with flexible filtering.

```swift
// Basic usage
let (messages, cursor) = try await client.getMessages(convoId: "convo123")

// With pagination
let (messages, nextCursor) = try await client.getMessages(
    convoId: "convo123",
    limit: 30,
    cursor: previousCursor
)

// With date filters
let since = Date(timeIntervalSinceNow: -86400) // Last 24 hours
let (messages, cursor) = try await client.getMessages(
    convoId: "convo123",
    since: since
)

// Filter by epoch
let (messages, cursor) = try await client.getMessages(
    convoId: "convo123",
    epoch: 5
)
```

**Parameters:**
- `convoId`: Conversation identifier (required)
- `limit`: Maximum messages to return (1-100, default: 50)
- `cursor`: Pagination cursor
- `since`: Return messages after this timestamp (optional)
- `until`: Return messages before this timestamp (optional)
- `epoch`: Filter by specific epoch number (optional)

**Returns:**
- Array of `MLSMessageView` objects
- Optional pagination cursor

### 6. Send Message

Send an encrypted message to a conversation.

```swift
// Simple text message
let message = try await client.sendMessage(
    convoId: "convo123",
    ciphertext: "base64encodedciphertext=="
)

// With content type
let message = try await client.sendMessage(
    convoId: "convo123",
    ciphertext: "base64encodedciphertext==",
    contentType: "text/markdown"
)

// With attachments
let attachments = [
    MLSBlobRef(cid: "bafytest", mimeType: "image/jpeg", size: 50000, ref: nil)
]
let message = try await client.sendMessage(
    convoId: "convo123",
    ciphertext: "base64encodedciphertext==",
    contentType: "text/plain",
    attachments: attachments
)
```

**Parameters:**
- `convoId`: Conversation identifier (required)
- `ciphertext`: Base64-encoded MLS ciphertext (required, max 1MB)
- `contentType`: MIME type of plaintext content (default: "text/plain")
- `attachments`: Array of blob references (optional, max 10)

**Returns:**
- `MLSMessageView` with created message details

### 7. Publish Key Package

Publish an MLS key package to enable others to add you to conversations.

```swift
// Simple key package
let keyPackage = try await client.publishKeyPackage(
    keyPackage: "base64encodedkeypackage==",
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"
)

// With custom expiration (default is 30 days)
let expiresAt = Date(timeIntervalSinceNow: 7 * 86400) // 7 days
let keyPackage = try await client.publishKeyPackage(
    keyPackage: "base64encodedkeypackage==",
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
    expiresAt: expiresAt
)
```

**Parameters:**
- `keyPackage`: Base64-encoded MLS key package (required, max 64KB)
- `cipherSuite`: Cipher suite identifier (required)
- `expiresAt`: Optional expiration date (max 90 days, default 30 days)

**Returns:**
- `MLSKeyPackageRef` with published key package details

### 8. Get Key Packages

Retrieve key packages for specific users to add them to conversations.

```swift
// Basic usage
let (keyPackages, missing) = try await client.getKeyPackages(
    dids: ["did:plc:user1", "did:plc:user2", "did:plc:user3"]
)

// Filter by cipher suite
let (keyPackages, missing) = try await client.getKeyPackages(
    dids: ["did:plc:user1"],
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"
)

// Check for missing key packages
if let missingDids = missing, !missingDids.isEmpty {
    print("No key packages found for: \(missingDids)")
}
```

**Parameters:**
- `dids`: Array of DIDs (1-100 required)
- `cipherSuite`: Optional cipher suite filter

**Returns:**
- Array of `MLSKeyPackageRef` objects
- Optional array of DIDs with no available key packages

### 9. Upload Blob

Upload file attachments for use in MLS messages.

```swift
// Upload image
let imageData = ... // UIImage.pngData() or similar
let blobRef = try await client.uploadBlob(
    data: imageData,
    mimeType: "image/png"
)

// Upload document
let documentData = ... // PDF or other file data
let blobRef = try await client.uploadBlob(
    data: documentData,
    mimeType: "application/pdf"
)

// Use blob in message
let message = try await client.sendMessage(
    convoId: "convo123",
    ciphertext: "encrypted text",
    attachments: [blobRef]
)
```

**Parameters:**
- `data`: Binary blob data (max 50MB)
- `mimeType`: MIME type of the content

**Returns:**
- `MLSBlobRef` with CID, size, and reference information

**Size Limits:**
- Maximum blob size: 50MB (52,428,800 bytes)
- Throws `MLSAPIError.blobTooLarge` if exceeded

## Data Models

### MLSConvoView

Represents an MLS conversation.

```swift
struct MLSConvoView: Codable, Identifiable {
    let id: String                      // Conversation ID (TID)
    let groupId: String                 // MLS group ID (hex)
    let creator: String                 // Creator DID
    let members: [MLSMemberView]        // Current members
    let epoch: Int                      // Current epoch
    let cipherSuite: String?            // Cipher suite
    let createdAt: Date                 // Creation timestamp
    let lastMessageAt: Date?            // Last message timestamp
    let metadata: MLSConvoMetadata?     // Optional metadata
}
```

### MLSMessageView

Represents an encrypted MLS message.

```swift
struct MLSMessageView: Codable, Identifiable {
    let id: String                  // Message ID (TID)
    let convoId: String             // Conversation ID
    let sender: String              // Sender DID
    let ciphertext: String          // Base64 ciphertext
    let epoch: Int                  // MLS epoch
    let createdAt: Date             // Timestamp
    let contentType: String?        // Content MIME type
    let attachments: [MLSBlobRef]?  // File attachments
}
```

### MLSMemberView

Represents a conversation member.

```swift
struct MLSMemberView: Codable {
    let did: String         // Member DID
    let joinedAt: Date      // Join timestamp
    let leafIndex: Int?     // MLS tree leaf index
    let credential: String? // Base64 MLS credential
}
```

### MLSKeyPackageRef

Reference to an MLS key package.

```swift
struct MLSKeyPackageRef: Codable, Identifiable {
    let id: String          // Key package ID
    let did: String         // Owner DID
    let keyPackage: String  // Base64 key package
    let cipherSuite: String // Cipher suite
    let createdAt: Date     // Creation timestamp
    let expiresAt: Date?    // Expiration timestamp
}
```

### MLSBlobRef

Reference to an uploaded file.

```swift
struct MLSBlobRef: Codable {
    let cid: String         // Content ID
    let mimeType: String    // MIME type
    let size: Int           // Size in bytes
    let ref: String?        // AT URI reference
}
```

### MLSConvoMetadata

Optional conversation metadata.

```swift
struct MLSConvoMetadata: Codable {
    let name: String?           // Display name
    let description: String?    // Description
    let avatar: MLSBlobRef?     // Avatar image
}
```

## Error Handling

The client provides detailed error types through `MLSAPIError`:

```swift
enum MLSAPIError: Error, LocalizedError {
    case noAuthentication           // No auth credentials
    case invalidResponse            // Invalid server response
    case httpError(statusCode: Int, message: String)  // HTTP error
    case decodingError(Error)       // JSON decode error
    case blobTooLarge              // Blob exceeds 50MB
    case unknownError              // Unknown error
}
```

### Example Error Handling

```swift
do {
    let (convos, cursor) = try await client.getConversations()
    // Process conversations
} catch MLSAPIError.noAuthentication {
    // Prompt user to log in
} catch MLSAPIError.httpError(let statusCode, let message) {
    if statusCode == 404 {
        // Handle not found
    } else if statusCode >= 500 {
        // Server error, retry later
    }
} catch MLSAPIError.decodingError(let error) {
    // Log decoding issue for debugging
    print("Decode error: \(error)")
} catch {
    // Handle other errors
    print("Unexpected error: \(error.localizedDescription)")
}
```

## Retry Logic

The client automatically retries failed requests with configurable settings:

```swift
let client = MLSAPIClient(
    maxRetries: 3,          // Maximum retry attempts
    retryDelay: 1.0         // Delay in seconds between retries
)
```

**Retry Behavior:**
- Automatically retries on network errors
- Does NOT retry on client errors (4xx status codes)
- Uses exponential backoff for retries
- Respects server rate limits

## Logging

The client uses OSLog for debugging:

```swift
import OSLog

// Logs are categorized under "MLSAPIClient"
// View in Console.app or Xcode debug console
```

**Log Levels:**
- `.debug`: Request/response details, normal operations
- `.error`: Error conditions, failed requests
- `.warning`: Transient errors, retry attempts

## Best Practices

### 1. Authentication Management

Always update authentication when user logs in:

```swift
// On login
client.updateAuthentication(did: userDid, token: authToken)

// On logout
client.clearAuthentication()
```

### 2. Pagination

Use cursor-based pagination for large result sets:

```swift
var allConvos: [MLSConvoView] = []
var cursor: String? = nil

repeat {
    let (convos, nextCursor) = try await client.getConversations(
        limit: 50,
        cursor: cursor
    )
    allConvos.append(contentsOf: convos)
    cursor = nextCursor
} while cursor != nil
```

### 3. Error Handling

Always handle specific error cases:

```swift
do {
    let message = try await client.sendMessage(...)
} catch MLSAPIError.httpError(let status, _) where status == 404 {
    // Conversation no longer exists
} catch MLSAPIError.httpError(let status, _) where status == 403 {
    // Not authorized (not a member)
} catch {
    // Other errors
}
```

### 4. Blob Upload

Check file size before uploading:

```swift
guard data.count <= 52_428_800 else {
    // Show error to user
    return
}

let blobRef = try await client.uploadBlob(data: data, mimeType: mimeType)
```

### 5. Key Package Management

Regularly publish fresh key packages:

```swift
// Publish key package on app launch
let expiresAt = Date(timeIntervalSinceNow: 30 * 86400) // 30 days
let keyPackage = try await client.publishKeyPackage(
    keyPackage: generatedKeyPackage,
    cipherSuite: preferredCipherSuite,
    expiresAt: expiresAt
)
```

## Testing

Comprehensive unit tests are available in:
```
/CatbirdTests/Services/MLS/MLSAPIClientTests.swift
```

### Running Tests

```swift
// In Xcode: Cmd+U
// Or use xcodebuild:
xcodebuild test -scheme Catbird -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Test Coverage

- ✅ All 9 API endpoints
- ✅ Request/response model encoding/decoding
- ✅ Error handling and validation
- ✅ Pagination logic
- ✅ Date encoding/decoding
- ✅ Authentication management
- ✅ Blob size validation
- ✅ URL construction

## Example: Complete Workflow

Here's a complete example of creating a conversation and sending a message:

```swift
import Foundation

// 1. Initialize client
let client = MLSAPIClient(
    baseURL: URL(string: "https://api.catbird.blue")!
)

// 2. Authenticate
client.updateAuthentication(
    did: "did:plc:currentuser",
    token: "auth_token_here"
)

// 3. Publish key package (if needed)
let keyPackage = try await client.publishKeyPackage(
    keyPackage: generateKeyPackage(), // Your MLS key generation
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"
)

// 4. Get key packages for other users
let targetDids = ["did:plc:friend1", "did:plc:friend2"]
let (keyPackages, missing) = try await client.getKeyPackages(dids: targetDids)

guard missing?.isEmpty ?? true else {
    print("Some users don't have key packages")
    return
}

// 5. Create conversation
let metadata = MLSConvoMetadata(
    name: "Weekend Plans",
    description: "Planning our weekend activities",
    avatar: nil
)

let createResponse = try await client.createConversation(
    cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
    initialMembers: targetDids,
    metadata: metadata
)

let convoId = createResponse.convo.id
print("Created conversation: \(convoId)")

// 6. Encrypt message (using MLS library)
let plaintext = "Hey everyone! What are your plans?"
let ciphertext = encryptMessage(plaintext, epoch: 0) // Your encryption

// 7. Send message
let message = try await client.sendMessage(
    convoId: convoId,
    ciphertext: ciphertext,
    contentType: "text/plain"
)

print("Sent message: \(message.id)")

// 8. Get messages
let (messages, _) = try await client.getMessages(
    convoId: convoId,
    limit: 50
)

for msg in messages {
    let decrypted = decryptMessage(msg.ciphertext) // Your decryption
    print("\(msg.sender): \(decrypted)")
}
```

## Troubleshooting

### Issue: "Authentication required"

**Solution:** Ensure you've called `updateAuthentication()` with valid credentials:

```swift
client.updateAuthentication(did: userDid, token: authToken)
```

### Issue: "Blob too large"

**Solution:** Check file size before upload:

```swift
guard data.count <= 52_428_800 else {
    // Show error to user
    return
}
```

### Issue: Decoding errors

**Solution:** Ensure server is returning expected JSON format. Enable debug logging:

```swift
// Check logs in Console.app under "MLSAPIClient" category
```

### Issue: Network timeouts

**Solution:** Adjust timeout configuration:

```swift
// The client uses 30s request timeout and 60s resource timeout by default
// For slow networks, consider implementing custom retry logic
```

## API Reference

### Lexicon Definitions

The API follows lexicon definitions located at:
```
/mls/lexicon/blue.catbird.mls.*.json
```

Key definitions:
- `blue.catbird.mls.defs` - Core data types
- `blue.catbird.mls.getConvos` - Get conversations
- `blue.catbird.mls.createConvo` - Create conversation
- `blue.catbird.mls.addMembers` - Add members
- `blue.catbird.mls.leaveConvo` - Leave conversation
- `blue.catbird.mls.getMessages` - Get messages
- `blue.catbird.mls.sendMessage` - Send message
- `blue.catbird.mls.publishKeyPackage` - Publish key package
- `blue.catbird.mls.getKeyPackages` - Get key packages
- `blue.catbird.mls.uploadBlob` - Upload blob

## Contributing

When contributing to the MLS API Client:

1. Follow existing code patterns from ATProto clients
2. Add unit tests for new functionality
3. Update this documentation
4. Ensure all tests pass before submitting

## Support

For issues or questions:
- Check unit tests for usage examples
- Review lexicon definitions for API details
- Enable debug logging for troubleshooting

## License

Part of the Catbird project. See main repository LICENSE file.
