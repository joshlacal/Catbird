# Account Switch Shadow State Bug Fix

## Bug Description

When switching between accounts, post interaction state (likes, reposts, bookmarks) from one account would persist and appear for the newly switched account. This occurred because the `PostShadowManager` singleton retained all shadow state across account switches.

## Root Cause

1. **PostShadowManager is a singleton Actor**: `static let shared = PostShadowManager()`
2. **Shadow state persists in memory**: `private var shadows: [String: PostShadow] = [:]`
3. **Post URIs are account-independent**: URIs reference server objects, not user-specific data
4. **No cleanup during account switch**: The shadow state dictionary was never cleared when switching accounts

### Example Scenario

1. User A logs in and likes Post X (URI: `at://did:plc:abc123/app.bsky.feed.post/xyz`)
2. PostShadowManager stores: `shadows["at://did:plc:abc123/app.bsky.feed.post/xyz"] = { likeUri: "..." }`
3. User switches to Account B
4. User B views Post X (same URI)
5. **BUG**: PostShadowManager still has the shadow state, so User B sees the post as "liked"

## Fix Implementation

### Changes Made

#### 1. PostShadow.swift

Added OSLog import and module-level logger:
```swift
import OSLog
private let logger = Logger(subsystem: "blue.catbird", category: "PostShadowManager")
```

Added `clearAll()` method to PostShadowManager:
```swift
// MARK: - Account Switching

/// Clears all shadow state
/// This should be called when switching accounts to prevent state leakage between accounts
func clearAll() {
    logger.info("Clearing all shadow state (count: \(self.shadows.count))")
    
    // Clear all shadows
    shadows.removeAll()
    
    // Notify all observers with nil to clear their state
    for (uri, observers) in continuations {
        for continuation in observers.values {
            continuation.yield(nil)
        }
    }
    
    // Clear continuations
    continuations.removeAll()
    
    logger.debug("Shadow state cleared successfully")
}
```

#### 2. AppState.swift

Added call to clear shadow state in `refreshAfterAccountSwitch()`:
```swift
// Clear old prefetched data
await prefetchedFeedCache.clear()

// Clear post interaction shadow state to prevent state leakage between accounts
await postShadowManager.clearAll()
```

## Why This Fix Works

1. **Strategic placement**: The `clearAll()` call is positioned right after clearing the prefetched feed cache, ensuring shadow state is cleared before new account data loads
2. **Complete cleanup**: Both the shadows dictionary and observer continuations are cleared
3. **Observer notification**: All observers receive `nil` to update their UI state
4. **Logging**: Debug logs help verify the fix during testing and troubleshooting

## Testing Recommendations

### Manual Test

1. Log in with Account A
2. Like and repost several posts
3. Note the post URIs or content to identify them later
4. Switch to Account B (Settings → Accounts → Switch Account)
5. Navigate to the same posts
6. **Expected**: Posts should NOT show as liked/reposted
7. **Verify logs**: Check Console.app for "Clearing all shadow state" message

### Automated Test (Future)

```swift
@Test("Shadow state clears on account switch")
func testShadowStateClearsOnAccountSwitch() async throws {
    let manager = PostShadowManager.shared
    let testUri = "at://did:plc:test123/app.bsky.feed.post/abc"
    
    // Set shadow state
    await manager.setLiked(postUri: testUri, isLiked: true)
    #expect(await manager.isLiked(postUri: testUri) == true)
    
    // Clear all shadow state (simulating account switch)
    await manager.clearAll()
    
    // Verify shadow state is cleared
    #expect(await manager.isLiked(postUri: testUri) == false)
    #expect(await manager.getShadow(forUri: testUri) == nil)
}
```

## Impact

- **User-facing**: Fixes incorrect UI state showing likes/reposts from other accounts
- **Data integrity**: Prevents confusion about which account performed actions
- **Performance**: Minimal impact - clearAll() runs once per account switch
- **Code quality**: Production-ready, minimal changes, follows existing patterns

## Related Files

- `Catbird/Features/Feed/Models/PostShadow.swift` - PostShadowManager implementation
- `Catbird/Core/State/AppState.swift` - Account switching coordination
- `Catbird/Core/State/AuthManager.swift` - Authentication and account management
- `Catbird/Core/State/StateInvalidationBus.swift` - Event broadcasting system

## Notes

- The fix is minimal and surgical, changing only what's necessary
- Existing PostShadowManager functionality remains unchanged
- The clearAll() method can be reused for logout flows if needed
- Shadow state clearing happens automatically on every account switch
