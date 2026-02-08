# FollowRelationshipService Integration Guide

This document explains how to integrate the FollowRelationshipService into the Catbird iOS/macOS app.

## Overview

The FollowRelationshipService provides a high-level API for checking and managing follow relationships on Bluesky using the Petrel SDK. It includes:

1. **RelationshipInfo.swift** - Data model and error types
2. **RelationshipCache.swift** - Actor-based in-memory cache with TTL
3. **FollowRelationshipService.swift** - Main service implementation

## File Locations

Move the three Swift files to the Catbird project:

```
Catbird/
└── Catbird/
    └── Core/
        └── Services/
            └── FollowRelationship/
                ├── RelationshipInfo.swift
                ├── RelationshipCache.swift
                └── FollowRelationshipService.swift
```

## Integration Steps

### 1. Add Files to Xcode Project

1. Create the `FollowRelationship` folder in `Catbird/Core/Services/`
2. Add the three Swift files to this folder
3. Ensure they're added to the Catbird target in Xcode

### 2. Initialize the Service

In your app's dependency injection or service container:

```swift
// Example: In your AppServices or similar container
actor AppServices {
    let atProtoClient: ATProtoClient
    let followRelationshipService: FollowRelationshipService
    
    init(atProtoClient: ATProtoClient) {
        self.atProtoClient = atProtoClient
        
        // Initialize with 5-minute cache TTL
        self.followRelationshipService = FollowRelationshipService(
            client: atProtoClient,
            cacheTTL: 300
        )
    }
}
```

### 3. Usage Examples

#### Check if one user follows another

```swift
let userDID = try DID(didString: "did:plc:abc123...")
let targetDID = try DID(didString: "did:plc:xyz789...")

let isFollowing = try await followRelationshipService.isFollowing(
    actor: userDID,
    target: targetDID
)
```

#### Get full relationship info

```swift
let relationship = try await followRelationshipService.getRelationship(
    actor: userDID,
    target: targetDID
)

print("Following: \(relationship.following)")
print("Followed by: \(relationship.followedBy)")
print("Mutual: \(relationship.mutual)")
print("Blocked: \(relationship.blocked)")
```

#### Batch check multiple users

```swift
let targets = [targetDID1, targetDID2, targetDID3]

let followStatuses = try await followRelationshipService.batchCheckFollows(
    actor: userDID,
    targets: targets
)

for (did, isFollowing) in followStatuses {
    print("\(did): \(isFollowing ? "Following" : "Not following")")
}
```

#### Invalidate cache after follow/unfollow

```swift
// After user performs a follow or unfollow action
await followRelationshipService.invalidate(actor: userDID, target: targetDID)

// Or clear entire cache
await followRelationshipService.clearCache()
```

## Architecture Notes

### Thread Safety

All components use Swift's actor model for thread safety:
- `FollowRelationshipService` is an actor
- `RelationshipCache` is an actor
- All public methods are async

### Caching Strategy

- Default TTL: 5 minutes (configurable)
- Automatic cache invalidation on expiry
- Manual invalidation available after mutations
- Efficient batch operations reuse cached data

### Error Handling

The service defines `RelationshipError` enum:
- `.actorNotFound(DID)` - Target actor doesn't exist
- `.networkError(Error)` - Network request failed
- `.invalidResponse` - Unexpected API response
- `.clientNotConfigured` - ATProtoClient not set up

### API Usage

Uses Petrel's `app.bsky.graph.getRelationships` endpoint:
- Namespace: `client.app.bsky.graph.getRelationships()`
- Returns: Array of relationship unions
- Handles both `Relationship` and `NotFoundActor` cases

## Performance Considerations

### Cache Benefits
- Reduces API calls for repeated checks
- Especially useful in feed/list views with multiple users
- Batch operations minimize network round-trips

### Cache Management
```swift
// Periodic cleanup (e.g., on app background)
await followRelationshipService.pruneCache()

// Clear on logout
await followRelationshipService.clearCache()
```

### Batch Operations
Prefer `batchCheckFollows()` over multiple `isFollowing()` calls:
```swift
// ❌ Inefficient - multiple API calls
for target in targets {
    let following = try await service.isFollowing(actor: user, target: target)
}

// ✅ Efficient - single API call
let statuses = try await service.batchCheckFollows(actor: user, targets: targets)
```

## Integration with Catbird Features

### Profile View
```swift
struct ProfileView: View {
    @State private var relationship: RelationshipInfo?
    
    var body: some View {
        VStack {
            // ... profile UI
            
            if let rel = relationship {
                HStack {
                    if rel.following {
                        Badge("Following")
                    }
                    if rel.followedBy {
                        Badge("Follows You")
                    }
                    if rel.mutual {
                        Badge("Mutual")
                    }
                }
            }
        }
        .task {
            relationship = try? await services.followRelationshipService
                .getRelationship(actor: currentUser, target: profileUser)
        }
    }
}
```

### Feed Post Items
```swift
struct PostView: View {
    let post: Post
    @State private var isFollowingAuthor = false
    
    var body: some View {
        VStack {
            // ... post content
            
            if !isFollowingAuthor {
                Button("Follow") {
                    // Follow action
                    await followUser()
                }
            }
        }
        .task {
            isFollowingAuthor = try? await services.followRelationshipService
                .isFollowing(actor: currentUser, target: post.author.did) ?? false
        }
    }
}
```

### User List / Search Results
```swift
// Batch check all visible users
let visibleUserDIDs = users.map(\.did)
let followStatuses = try await services.followRelationshipService
    .batchCheckFollows(actor: currentUser, targets: visibleUserDIDs)

// Update UI with results
for user in users {
    user.isFollowing = followStatuses[user.did] ?? false
}
```

## Testing

### Unit Tests
```swift
final class FollowRelationshipServiceTests: XCTestCase {
    var mockClient: MockATProtoClient!
    var service: FollowRelationshipService!
    
    override func setUp() async throws {
        mockClient = MockATProtoClient()
        service = FollowRelationshipService(client: mockClient, cacheTTL: 60)
    }
    
    func testIsFollowing() async throws {
        // Mock response
        mockClient.mockRelationship = /* ... */
        
        let result = try await service.isFollowing(
            actor: testActorDID,
            target: testTargetDID
        )
        
        XCTAssertTrue(result)
    }
    
    func testCaching() async throws {
        // First call - hits API
        _ = try await service.getRelationship(actor: actorDID, target: targetDID)
        XCTAssertEqual(mockClient.callCount, 1)
        
        // Second call - uses cache
        _ = try await service.getRelationship(actor: actorDID, target: targetDID)
        XCTAssertEqual(mockClient.callCount, 1) // Still 1
    }
}
```

## Dependencies

Required from Petrel SDK:
- `ATProtoClient` - Main client actor
- `DID` - DID identifier type
- `AppBskyGraphGetRelationships` - Generated API types
- `AppBskyGraphDefs.Relationship` - Relationship data type

## Migration Notes

If you have existing relationship checking code:
1. Replace direct API calls with service methods
2. Add cache invalidation after follow/unfollow actions
3. Use batch operations where applicable
4. Handle errors using `RelationshipError` enum

## Future Enhancements

Potential improvements:
- Persistent cache using GRDB
- WebSocket updates for real-time relationship changes
- Relationship change notifications via Combine/AsyncSequence
- Block/mute status integration
- Automatic cache refresh on app foreground
