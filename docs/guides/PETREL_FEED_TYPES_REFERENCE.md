# Petrel Feed Interaction Types - Reference

## 📦 Available Types in Petrel

This document confirms all required types are available in Petrel for implementing feed interaction tracking.

## ✅ Core Types

### AppBskyFeedSendInteractions
**Location**: `../Petrel/Sources/Petrel/Generated/AppBskyFeedSendInteractions.swift`

```swift
public struct AppBskyFeedSendInteractions { 
    public static let typeIdentifier = "app.bsky.feed.sendInteractions"
    
    // Input for the API call
    public struct Input: ATProtocolCodable {
        public let interactions: [AppBskyFeedDefs.Interaction]
        
        public init(interactions: [AppBskyFeedDefs.Interaction]) {
            self.interactions = interactions
        }
    }
    
    // Output (empty - no response data)
    public struct Output: ATProtocolCodable {
        public init() { }
    }
}
```

### ATProtoClient Extension
**Location**: Same file as above

```swift
extension ATProtoClient.App.Bsky.Feed {
    /// Send information about interactions with feed items back to the 
    /// feed generator that served them.
    public func sendInteractions(
        input: AppBskyFeedSendInteractions.Input
    ) async throws -> (responseCode: Int, data: AppBskyFeedSendInteractions.Output?) {
        let endpoint = "app.bsky.feed.sendInteractions"
        // ... implementation details
    }
}
```

### AppBskyFeedDefs.Interaction
**Location**: `../Petrel/Sources/Petrel/Generated/AppBskyFeedDefs.swift` (line 3686)

```swift
public struct Interaction: ATProtocolCodable, ATProtocolValue {
    public static let typeIdentifier = "app.bsky.feed.defs#interaction"
    
    /// The URI of the post being interacted with
    public let item: ATProtocolURI?
    
    /// The type of interaction (e.g., "app.bsky.feed.defs#interactionLike")
    public let event: String?
    
    /// Feed-specific context (optional metadata)
    public let feedContext: String?
    
    /// Request ID for correlation (optional)
    public let reqId: String?
    
    // Standard initializer
    public init(
        item: ATProtocolURI?,
        event: String?,
        feedContext: String?,
        reqId: String?
    ) {
        self.item = item
        self.event = event
        self.feedContext = feedContext
        self.reqId = reqId
    }
}
```

## 🎯 Supported Interaction Events

Based on Bluesky PR #9094, these event types are valid:

### Explicit User Actions
```swift
"app.bsky.feed.defs#requestLess"    // User clicked "show less like this"
"app.bsky.feed.defs#requestMore"    // User clicked "show more like this"
```

### Inferrable Interactions (Public Data)
```swift
"app.bsky.feed.defs#interactionLike"    // User liked the post
"app.bsky.feed.defs#interactionQuote"   // User quoted the post
"app.bsky.feed.defs#interactionReply"   // User replied to the post
"app.bsky.feed.defs#interactionRepost"  // User reposted the post
"app.bsky.feed.defs#interactionSeen"    // User viewed the post
```

## 💡 Usage Examples

### Creating a Like Interaction
```swift
let interaction = AppBskyFeedDefs.Interaction(
    item: try ATProtocolURI(uriString: "at://did:plc:abc.../app.bsky.feed.post/xyz123"),
    event: "app.bsky.feed.defs#interactionLike",
    feedContext: nil,  // Optional: can include feed metadata
    reqId: nil         // Optional: can include request correlation ID
)
```

### Sending Interactions to Feed Generator
```swift
let interactions = [
    AppBskyFeedDefs.Interaction(
        item: postURI1,
        event: "app.bsky.feed.defs#interactionLike",
        feedContext: nil,
        reqId: nil
    ),
    AppBskyFeedDefs.Interaction(
        item: postURI2,
        event: "app.bsky.feed.defs#interactionRepost",
        feedContext: nil,
        reqId: nil
    )
]

let input = AppBskyFeedSendInteractions.Input(interactions: interactions)

// Set proxy header for feed generator
await client.setHeader(name: "atproto-proxy", value: "\(feedGeneratorDID)#bsky_fg")

// Send the interactions
let (responseCode, _) = try await client.app.bsky.feed.sendInteractions(input: input)

// IMPORTANT: Remove the header after the request
await client.removeHeader(name: "atproto-proxy")

if responseCode == 200 {
    print("Successfully sent \(interactions.count) interactions")
}
```

## 🔧 Helper Types

### ATProtocolURI
Used for post URIs:
```swift
// From string
let uri = try ATProtocolURI(uriString: "at://did:plc:abc.../app.bsky.feed.post/xyz")

// Access components
uri.recordKey  // "xyz"
uri.uriString() // Full URI string
```

### CID (Content Identifier)
Used for post content addressing:
```swift
// CID is part of post references
let postRef = ComAtprotoRepoStrongRef(
    uri: postURI,
    cid: postCID
)
```

## ✅ Type Availability Checklist

- [x] `AppBskyFeedSendInteractions` struct ✅
- [x] `AppBskyFeedSendInteractions.Input` ✅
- [x] `AppBskyFeedSendInteractions.Output` ✅
- [x] `AppBskyFeedDefs.Interaction` ✅
- [x] `ATProtoClient.app.bsky.feed.sendInteractions()` method ✅
- [x] `ATProtocolURI` for post references ✅
- [x] `ATProtocolCodable` conformance ✅

## 🎨 Integration Pattern

### Current Catbird Usage (in FeedFeedbackManager)
```swift
// Creating interaction
let interaction = AppBskyFeedDefs.Interaction(
    item: try? ATProtocolURI(uriString: postURIString),
    event: eventType,  // e.g., "app.bsky.feed.defs#interactionLike"
    feedContext: feedContext,
    reqId: reqId
)

// Batching interactions
let input = AppBskyFeedSendInteractions.Input(
    interactions: batchedInteractions
)

// Sending with proxy header
await client.setHeader(name: "atproto-proxy", value: "\(feedDID)#bsky_fg")
let (responseCode, _) = try await client.app.bsky.feed.sendInteractions(input: input)
await client.removeHeader(name: "atproto-proxy")
```

This pattern is already implemented in `FeedFeedbackManager.flushInteractions()`.

## 📚 AT Protocol Specification

### Lexicon ID
- **Namespace**: `app.bsky.feed`
- **Name**: `sendInteractions`
- **Full ID**: `app.bsky.feed.sendInteractions`

### Request
- **Method**: POST
- **Endpoint**: `/xrpc/app.bsky.feed.sendInteractions`
- **Content-Type**: `application/json`
- **Body**: `{ "interactions": [...] }`

### Response
- **Success**: 200 OK
- **Body**: `{}` (empty object)
- **Errors**: Standard AT Protocol error responses

### Special Headers
- **atproto-proxy**: `{feedGeneratorDID}#bsky_fg`
  - Required for routing request to correct feed generator
  - Must be removed after request to prevent header pollution

## 🔍 Type Verification Commands

### Check if types exist in Petrel:
```bash
# Find Interaction type
rg "struct Interaction.*ATProtocol" ../Petrel/Sources/Petrel/Generated/

# Find sendInteractions method
rg "func sendInteractions" ../Petrel/Sources/Petrel/Generated/

# Check all interaction event types
rg "app\.bsky\.feed\.defs#interaction" ../Petrel/
```

### Verify Codable conformance:
```bash
# Check if Interaction conforms to ATProtocolCodable
rg "struct Interaction.*ATProtocolCodable" ../Petrel/Sources/Petrel/Generated/AppBskyFeedDefs.swift
```

## ✅ Conclusion

**All required types are available in Petrel!** 

No Petrel changes needed - just need to use the existing types in Catbird's implementation.

**Status**: Ready for implementation ✅

---

**Document Created**: 2025-01-11  
**Petrel Version**: Current (as of project analysis)  
**Verification**: All types confirmed present ✅
