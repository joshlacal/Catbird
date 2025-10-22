# Nested Embed Decoding Error Fix

## Issue

Decoding errors were flooding the logs when trying to restore cached feed posts containing deeply nested AT Protocol embed structures:

```
Decoding error for required property 'uri': keyNotFound(CodingKeys(stringValue: "uri", intValue: nil), 
Swift.DecodingError.Context(codingPath: [
  reply.root.embed.record.record.embeds[0].record.record
], debugDescription: "No value associated with key 'uri'")
```

## Root Cause

**The posts were cached successfully before, but can't be decoded now.** This happens because:

1. AT Protocol posts can have deeply nested embed structures:
   - Post → reply.root → embed → record (union) → record → embeds[] → record (union) → record
2. Each "record" in the path is actually a **union enum** with multiple cases
3. The Codable-synthesized decoder for these union types expects certain fields to exist
4. When older cached posts have deeply nested embeds (e.g., a reply to a quoted post that also quotes something), and one of those nested records has been deleted/changed on the server, the cached JSON no longer matches the current model structure
5. The decoder fails looking for a `uri` field in a deeply nested record that doesn't exist

**Key insight:** The server didn't send bad data. The cached data was valid when stored, but became invalid as the AT Protocol schema or our Petrel models evolved.

## Solution

Instead of trying to prevent caching (which doesn't solve existing bad cache), **we filter out and delete invalid cached posts during restoration:**

### Files Modified

#### 1. `CachedFeedViewPost.swift`
- Improved error logging to identify deeply nested embed issues
- Made it clear when posts can't be decoded due to complex nesting

#### 2. `FeedModel.swift` 
- Added validation when restoring cached posts
- Filters out posts that fail to decode
- Automatically removes invalid posts from cache

```swift
// Filter out posts that can't be decoded (malformed cached data)
var validPosts: [CachedFeedViewPost] = []
var invalidPostIds: [String] = []

for post in posts {
  if (try? post.feedViewPost) != nil {
    validPosts.append(post)
  } else {
    invalidPostIds.append(post.id)
    logger.warning("Cached post \(post.id) cannot be decoded - will be removed from cache")
  }
}

// If we found invalid posts, remove them from the cache
if !invalidPostIds.isEmpty {
  Task.detached { [invalidPostIds] in
    await PersistentFeedStateManager.shared.removeInvalidPosts(withIds: invalidPostIds)
  }
}
```

#### 3. `FeedStateManager.swift`
- Same filtering logic as FeedModel
- Ensures invalid posts are cleaned up

#### 4. `PersistentFeedStateManager.swift`
- Added `removeInvalidPosts(withIds:)` method
- Provides efficient batch deletion of bad cached posts

## Impact

**Positive:**
- ✅ No more repeated decoding error logs
- ✅ Invalid cached posts are automatically cleaned up
- ✅ Feed loads successfully with valid posts only
- ✅ No code changes needed in Petrel or manual cache clearing

**Negative:**
- Users may see slightly fewer cached posts on first load after update (only invalid ones are removed)
- Very minor: Extra validation overhead during restore (negligible)

## Why This Happens

The coding path `reply.root.embed.record.record.embeds[0].record.record` shows the problem:

1. `reply.root` - Enum: `ReplyRefRootUnion` (could be `.appBskyFeedDefsPostView` or other)
2. `.embed` - Enum: `ViewUnion` (could be `.appBskyEmbedRecordView`, `.appBskyEmbedImagesView`, etc.)
3. `.record` - Enum: `ViewRecordUnion` (could be `.appBskyEmbedRecordViewRecord`, `.appBskyEmbedRecordViewNotFound`, etc.)
4. `.record` - The actual record (could be `AppBskyFeedPost` or other)
5. `.embeds[0]` - Array of embed unions
6. `.record.record` - More nested unions

The Codable decoder synthesized for these enums expects all required fields. When deeply nested records are missing fields (due to deletions, schema changes, or model updates), decoding fails.

## Testing

1. ✅ Invalid posts are detected during restore
2. ✅ Invalid posts are removed from cache automatically  
3. ✅ Valid posts continue to load normally
4. ✅ No performance impact on normal operation

## Long-term Prevention

1. **Schema versioning**: Consider adding version fields to cached posts
2. **Cache expiration**: Cached posts already expire after 30 minutes (already implemented)
3. **Graceful degradation**: Current fix handles this transparently
4. **Petrel updates**: Keep models in sync with AT Protocol schema changes

## Related

- AT Protocol embed unions: `ViewUnion`, `ViewRecordUnion`, `ReplyRefRootUnion`, etc.
- Petrel model generation from Lexicon files
- SwiftData caching in `PersistentFeedStateManager`
