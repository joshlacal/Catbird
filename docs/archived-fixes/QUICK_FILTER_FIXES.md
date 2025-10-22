# QuickFilterSheet Fixes - Complete Solution

## Issues Identified

The QuickFilterSheet was experiencing several critical issues:

1. **Filter Detection Problems**: Filters weren't properly detecting post types
   - "Hide Link Posts" only checked embeds, not text facets
   - "Only Media Posts" didn't handle quote posts with media correctly
   
2. **Parent/Root Post Filtering Missing**: Filters didn't check parent and root posts in thread contexts
   - When a reply appeared in the feed, its parent/root posts (embedded in `reply.parent`/`reply.root`) weren't checked
   - These parent/root posts were extracted into slice items without being filtered
   - Users expected entire threads to be hidden if ANY post in the thread matched the filter
   
3. **Slice-Level Filtering Incomplete**: Filters only applied to top-level posts, not individual items within thread slices
   - When FeedTuner created multi-item slices (threads), filters only checked the main post
   - Individual replies/parents within a thread weren't being filtered

4. **Integration Gap**: QuickFilter settings weren't connected to FeedTuner
   - FeedTuner used separate `FeedTunerSettings` 
   - QuickFilterSheet used `FeedFilterSettings`
   - No bridge between the two systems

## Root Cause Analysis

The core problem was that `applyContentFiltering()` only checked `post.post` (the main post in a `FeedViewPost`), but didn't check:
- `post.reply.parent` - The parent post in a reply thread
- `post.reply.root` - The root post of a thread

These parent/root posts would later be extracted by `createSlice()` and added as separate `FeedSliceItem` objects, but they had never been filtered. This meant:
- A reply with a parent that has links would show the parent in the UI
- "Hide Link Posts" would miss threads where parents have links
- "Only Media Posts" would miss threads where only the parent has media

## Fixes Applied

### 1. Enhanced Link Detection (`FeedFilterSettings.swift`)

**Before:**
```swift
case .appBskyEmbedExternalView:
  return false
```

**After:**
```swift
// Check embed for external links
switch embed {
case .appBskyEmbedExternalView:
  return false
case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
  if case .appBskyEmbedExternalView = recordWithMedia.media {
    return false
  }
default:
  break
}

// Also check for links in post text via facets
if let facets = feedPost.facets {
  for facet in facets {
    for feature in facet.features {
      if case .appBskyRichtextFacetLink = feature {
        return false
      }
    }
  }
}
```

### 2. Improved Media Detection (`FeedFilterSettings.swift`)

**Before:**
```swift
case .appBskyEmbedRecordWithMediaView:
  return true
```

**After:**
```swift
case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
  // Quote post with media - check the media part
  switch recordWithMedia.media {
  case .appBskyEmbedImagesView, .appBskyEmbedVideoView:
    return true
  default:
    return false
  }
```

### 3. Integrated QuickFilter Settings into FeedTuner (`FeedTuner.swift`)

**Added to `FeedTunerSettings`:**
```swift
struct FeedTunerSettings {
    // ... existing fields ...
    
    // Quick filter settings from QuickFilterSheet
    let hideLinks: Bool
    let onlyTextPosts: Bool
    let onlyMediaPosts: Bool
}
```

### 4. Added Parent/Root Post Checking in `applyContentFiltering()` (`FeedTuner.swift`)

**Critical Fix - "Hide Link Posts" now checks entire thread:**
```swift
// Quick filter: Hide Link Posts
if settings.hideLinks {
  var hasLink = false
  
  // Helper function to check if a PostView has links
  let checkPostForLinks: (AppBskyFeedDefs.PostView) -> Bool = { postView in
    // Check embeds AND facets for links
    // ... implementation ...
  }
  
  // Check main post
  hasLink = checkPostForLinks(post.post)
  
  // Also check parent and root posts (NEW!)
  if !hasLink, let reply = post.reply {
    if case .appBskyFeedDefsPostView(let parentPost) = reply.parent {
      hasLink = checkPostForLinks(parentPost)
    }
    
    if !hasLink, case .appBskyFeedDefsPostView(let rootPost) = reply.root {
      hasLink = checkPostForLinks(rootPost)
    }
  }
  
  if hasLink {
    // Filter out entire thread if ANY post has links
    continue
  }
}
```

**"Only Text Posts" now checks entire thread:**
```swift
if settings.onlyTextPosts {
  var hasEmbed = false
  
  // Check main post
  if post.post.embed != nil {
    hasEmbed = true
  }
  
  // Also check parent and root posts (NEW!)
  if !hasEmbed, let reply = post.reply {
    if case .appBskyFeedDefsPostView(let parentPost) = reply.parent {
      if parentPost.embed != nil {
        hasEmbed = true
      }
    }
    // ... check root too ...
  }
  
  if hasEmbed {
    // Filter out entire thread if ANY post has embeds
    continue
  }
}
```

**"Only Media Posts" now checks entire thread:**
```swift
if settings.onlyMediaPosts {
  var hasMedia = false
  
  // Helper function to check for media
  let checkPostForMedia: (AppBskyFeedDefs.PostView) -> Bool = { ... }
  
  // Check main, parent, and root posts
  hasMedia = checkPostForMedia(post.post)
  
  if !hasMedia, let reply = post.reply {
    // Check parent and root (NEW!)
    // Show thread if ANY post has media
  }
  
  if !hasMedia {
    // Filter out if NO post in thread has media
    continue
  }
}
```

### 5. Bridged Settings in FeedModel (`FeedModel.swift`)

**Updated `getFilterSettings()` to integrate QuickFilter:**
```swift
private func getFilterSettings() async -> FeedTunerSettings {
  // ... existing code ...
  
  // Get quick filter settings from FeedFilterSettings (these override preferences)
  let hideRepostsQuick = appState.feedFilterSettings.isFilterEnabled(name: "Hide Reposts")
  let hideRepliesQuick = appState.feedFilterSettings.isFilterEnabled(name: "Hide Replies")
  let hideQuotePostsQuick = appState.feedFilterSettings.isFilterEnabled(name: "Hide Quote Posts")
  let hideLinks = appState.feedFilterSettings.isFilterEnabled(name: "Hide Link Posts")
  let onlyTextPosts = appState.feedFilterSettings.isFilterEnabled(name: "Only Text Posts")
  let onlyMediaPosts = appState.feedFilterSettings.isFilterEnabled(name: "Only Media Posts")
  
  return FeedTunerSettings(
    hideReplies: hideRepliesQuick || (feedPref?.hideReplies ?? false),
    hideReposts: hideRepostsQuick || (feedPref?.hideReposts ?? false),
    hideQuotePosts: hideQuotePostsQuick || (feedPref?.hideQuotePosts ?? false),
    // ... other fields ...
    hideLinks: hideLinks,
    onlyTextPosts: onlyTextPosts,
    onlyMediaPosts: onlyMediaPosts
  )
}
```

### 6. Added Slice-Level Item Filtering as Backup (`FeedTuner.swift`)

**New method `filterSliceItems()`:**
- Filters individual items within a thread slice (backup layer)
- Removes entire slice if all items are filtered out
- Creates new slice with remaining items if some are filtered
- Marks slice as incomplete if items were removed
- Checks each item for:
  - Links (embeds + facets)
  - Text-only (no embeds)
  - Media (images/videos in embeds)

**Integration in `tune()` method:**
```swift
for (rootUri, postsInGroup) in rootGroups {
  if let threadSlice = createThreadSlice(from: postsInGroup, rootUri: rootUri) {
    // Apply slice-level filtering to handle individual items within threads
    if let filteredSlice = filterSliceItems(threadSlice, settings: filterSettings) {
      allSlices.append(filteredSlice)
    }
  }
}
```

## How It Works Now

1. **User toggles filter in QuickFilterSheet** → Updates `FeedFilterSettings`
2. **NotificationCenter posts "FeedFiltersChanged"** → Triggers `reapplyFilters()` in `FeedStateManager`
3. **FeedModel's `getFilterSettings()`** → Reads QuickFilter states and creates `FeedTunerSettings`
4. **FeedTuner processes posts with integrated settings:**
   - `applyContentFiltering()` checks main post AND parent/root posts in reply context
   - Entire threads are filtered if ANY post matches the criteria
   - `filterSliceItems()` provides backup filtering for edge cases
5. **Feed UI updates** with filtered content

## Filter Behavior

### "Hide Link Posts"
- Hides entire thread if main post, parent, OR root has links (embeds or text facets)
- Checks all posts in the thread before displaying

### "Only Text Posts"  
- Shows only threads where ALL posts (main, parent, root) have no embeds
- Filters out threads if ANY post has embeds

### "Only Media Posts"
- Shows threads if ANY post (main, parent, root) has media
- Filters out threads if NO posts have images/videos

## Benefits

- ✅ **Accurate post type detection**: Handles embeds, facets, and quote posts correctly
- ✅ **Thread-aware filtering**: Checks parent and root posts in reply contexts
- ✅ **Complete thread filtering**: Filters entire threads, not just individual posts
- ✅ **Double-layer filtering**: applyContentFiltering() + filterSliceItems() for reliability
- ✅ **Unified system**: QuickFilters integrate seamlessly with permanent filters
- ✅ **Override capability**: QuickFilters can temporarily override permanent settings

## Testing

To test the fixes:

1. **Hide Link Posts**:
   - Find a reply where the parent has a link
   - Toggle "Hide Link Posts" → Entire thread should disappear
   - Works for links in embeds OR text

2. **Only Media Posts**:
   - Find a reply where parent has images but reply doesn't
   - Toggle "Only Media Posts" → Thread should still appear
   - Works for quote posts with media

3. **Only Text Posts**:
   - Find a reply where parent has embeds
   - Toggle "Only Text Posts" → Entire thread should disappear
   - Only shows threads where ALL posts are text-only

4. **Thread consistency**:
   - Filters should check ALL posts in thread (main + parent + root)
   - Entire threads filtered, not partial

## Files Modified

- `Catbird/Features/Feed/Models/FeedFilterSettings.swift` - Enhanced filter logic
- `Catbird/Features/Feed/Services/FeedTuner.swift` - Added parent/root checking and slice-level filtering
- `Catbird/Features/Feed/Models/FeedModel.swift` - Integrated QuickFilter settings
- `Catbird/Features/Feed/Views/QuickFilterSheet.swift` - No changes (UI already correct)
