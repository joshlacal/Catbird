# NotificationsViewModel Crash Fix

## Problem

The app was crashing with the following exception:
```
-[__NSTaggedDate objectForKey:]: unrecognized selector sent to instance 0x8000000000000000
```

Crash location: `NotificationsViewModel.swift` line 535:
```swift
if let cachedEntry = postCache[uri]
```

## Root Cause Analysis

The crash was caused by a **data race** on the `postCache` dictionary. Here's what was happening:

1. **Concurrent Access**: The `fetchPosts()` async function could be called multiple times concurrently from different notification grouping operations
2. **Unprotected Dictionary**: The `postCache` dictionary was a plain Swift Dictionary without any thread-safety mechanisms
3. **Memory Corruption**: Concurrent reads and writes to the dictionary corrupted its internal structure
4. **Type Confusion**: The corruption caused the runtime to misinterpret memory, leading to a `Date` object being treated as the dictionary itself
5. **Objective-C Bridging**: When Swift tried to subscript the "dictionary" (which was actually a corrupted Date), it bridged to Objective-C and tried to call `objectForKey:` on the Date, causing the crash

### Why This Is Dangerous

Dictionary operations in Swift are **not atomic**. When multiple threads access and modify a dictionary simultaneously:
- Internal hash table structures can become corrupted
- Pointer values can get mixed up
- The runtime can misinterpret what type of object exists at a memory location

## Solution

Refactored the post cache to use a **Swift Actor** for thread-safe access:

### 1. Created PostCacheActor

```swift
private actor PostCacheActor {
  private var cache: [ATProtocolURI: (post: AppBskyFeedDefs.PostView, timestamp: Date)] = [:]
  private let expirationInterval: TimeInterval = 300
  
  func get(_ uri: ATProtocolURI) -> (post: AppBskyFeedDefs.PostView, timestamp: Date)? {
    return cache[uri]
  }
  
  func set(_ uri: ATProtocolURI, post: AppBskyFeedDefs.PostView, timestamp: Date) {
    cache[uri] = (post: post, timestamp: timestamp)
  }
  
  func getCachedPosts(for uris: [ATProtocolURI], now: Date) -> [ATProtocolURI: AppBskyFeedDefs.PostView] {
    // Returns all valid cached posts in one atomic operation
  }
  
  func cleanup(now: Date) {
    // Cleans up expired entries
  }
}
```

### 2. Updated NotificationsViewModel

Changed from:
```swift
private var postCache: [ATProtocolURI: (post: AppBskyFeedDefs.PostView, timestamp: Date)] = [:]
```

To:
```swift
private let postCache = PostCacheActor()
```

### 3. Updated All Cache Access Points

**Before (unsafe):**
```swift
let cachedPosts = uris.reduce(into: [ATProtocolURI: AppBskyFeedDefs.PostView]()) {
  result, uri in
  guard let cachedEntry = postCache[uri],  // ⚠️ Data race!
        now.timeIntervalSince(cachedEntry.timestamp) < cacheExpirationInterval else {
    return
  }
  result[uri] = cachedEntry.post
}
```

**After (thread-safe):**
```swift
let cachedPosts = await postCache.getCachedPosts(for: uris, now: now)
```

**Before (unsafe):**
```swift
postCache[post.uri] = (post: post, timestamp: fetchTime)  // ⚠️ Data race!
```

**After (thread-safe):**
```swift
await postCache.set(post.uri, post: post, timestamp: fetchTime)
```

## Benefits of Actor-Based Solution

1. **Automatic Synchronization**: Swift actors guarantee that only one task can access the actor's state at a time
2. **No Explicit Locks**: The compiler enforces thread-safety through the type system
3. **Async-Friendly**: Works naturally with Swift's async/await concurrency model
4. **Performance**: Actor isolation is efficient and doesn't block threads unnecessarily
5. **Compiler-Enforced**: Any attempt to access cache directly (not through actor methods) would be a compile-time error

## Alternative Solutions Considered

### 1. @MainActor on entire class
- **Pros**: Simple, would prevent data races
- **Cons**: Would force all async operations to run on main thread, blocking UI

### 2. NSLock or DispatchQueue
- **Pros**: Traditional solution, well-understood
- **Cons**: Easy to forget to lock, manual synchronization is error-prone

### 3. Concurrent dictionary implementation
- **Pros**: Could allow parallel reads
- **Cons**: Complex to implement correctly, actors are simpler and safer

## Testing Recommendations

To verify the fix:

1. **Stress Test**: Run notifications view with frequent refreshes
2. **Concurrent Load**: Test with multiple feeds/notifications loading simultaneously
3. **Memory Analysis**: Use Instruments to verify no data races (Thread Sanitizer)
4. **Crash Reports**: Monitor production crash rates for this specific error

## Related Files Changed

- `Catbird/Features/Notifications/ViewModels/NotificationsViewModel.swift`
  - Added `PostCacheActor` (lines 77-105)
  - Updated cache property declaration
  - Modified `fetchPosts()` to use actor methods
  - Modified `cleanupCache()` to be async and use actor

## Swift Concurrency Best Practices

This fix demonstrates important Swift concurrency patterns:

1. **Use Actors for Mutable State**: When you have mutable state accessed from multiple tasks, wrap it in an actor
2. **Avoid Shared Mutable State**: If multiple tasks need access, use synchronization primitives
3. **Batch Operations**: The `getCachedPosts()` method batches multiple reads into one atomic operation
4. **Async All The Way**: Making `cleanupCache()` async allows it to safely call actor methods

## Performance Impact

Minimal to none:
- Actor isolation is very efficient in Swift
- Batch operations reduce actor hops
- Cache hits still avoid network calls
- No main thread blocking

## Conclusion

The crash was a classic **data race** bug that manifested as bizarre type confusion due to memory corruption. Using Swift's actor system provides a clean, compiler-enforced solution that prevents this entire class of concurrency bugs.
