# Post Composer Link Handling Bug Fix

## Date
December 2024

## Bug Report

### What Didn't Work

The previous implementation in `POST_COMPOSER_LINK_FIXES.md` had **two critical bugs** that prevented the "Remove link from text" feature from working correctly.

### Problem 1: URL Cards Cleared on Text Update

When a user clicked "Remove link from text" to delete the URL from the post text while keeping the embed card, the following sequence would occur:

1. `removeURLFromText(for: url)` is called
2. The URL is removed from `postText`
3. `updatePostContent()` is called to regenerate facets
4. `handleDetectedURLsOptimized()` is called with the new (URL-free) text
5. Since the URL is no longer detected in the text, lines 239-243 of `PostComposerTextProcessing.swift` would execute:
   ```swift
   // If the selected embed URL is no longer in the detected URLs, clear it
   if let selectedURL = selectedEmbedURL, !urls.contains(selectedURL) {
       selectedEmbedURL = nil
       logger.debug("RT: Cleared selected embed URL as it's no longer in text")
   }
   ```
6. Additionally, lines 245-247 would remove the URL card entirely:
   ```swift
   // Remove cards for URLs no longer in text
   let urlsSet = Set(urls)
   urlCards = urlCards.filter { urlsSet.contains($0.key) }
   ```

**Result**: Both the `selectedEmbedURL` and the card itself were cleared, making the embed disappear entirely when the user tried to remove just the text!

### Problem 2: State Not Persisted in ThreadEntry

Even if we fixed Problem 1, there was a second critical issue: `selectedEmbedURL` and `urlsKeptForEmbed` were not being saved to `ThreadEntry`. This meant:

1. When switching between thread entries, the state would be lost
2. When loading entry state via `loadEntryState()`, it would call `clearComposerState()` (line 646) which sets `urlCards = [:]`, wiping out all cards
3. The `updatePostContent()` call at line 681 would then clear everything again since the text didn't contain the URL

**Result**: Even with the `urlsKeptForEmbed` tracking, the state would be lost during any thread entry switching or state restoration!

## The Solution

### New State Variables

Added new properties to track URLs that should be kept as embeds:

**In PostComposerViewModel.swift:**
```swift
/// URLs that should be kept as embeds even when removed from text
/// This allows users to paste a URL, generate preview, then delete the URL text
var urlsKeptForEmbed: Set<String> = []
```

**In ThreadEntry and CodableThreadEntry:**
```swift
var selectedEmbedURL: String?
var urlsKeptForEmbed: Set<String> = []
```

### Changes Made

#### 1. PostComposerViewModel.swift
- Added `urlsKeptForEmbed` property to track URLs that should persist as embeds

#### 2. PostComposerModels.swift
- Added `selectedEmbedURL` and `urlsKeptForEmbed` to `ThreadEntry` struct
- Added `selectedEmbedURL` and `urlsKeptForEmbed` to `CodableThreadEntry` struct
- Updated `init(from:parentPost:quotedPost:)` to copy these fields
- Updated `toThreadEntry()` to restore these fields

#### 3. PostComposerCore.swift

**In `resetPost()`:**
```swift
urlsKeptForEmbed.removeAll()
```

**In `removeURLCard(for:)`:**
```swift
urlsKeptForEmbed.remove(url)  // Clear from kept set when card is explicitly removed
```

**In `removeURLFromText(for:)`:**
```swift
// Mark this URL as one to keep for embedding even when not in text
urlsKeptForEmbed.insert(url)
logger.debug("Marked URL as kept for embed: \(url)")
```

**In `updateCurrentThreadEntry()`:**
```swift
threadEntries[currentThreadIndex].selectedEmbedURL = selectedEmbedURL
threadEntries[currentThreadIndex].urlsKeptForEmbed = urlsKeptForEmbed
```

**In `loadEntryState()`:**
```swift
selectedEmbedURL = entry.selectedEmbedURL
urlsKeptForEmbed = entry.urlsKeptForEmbed
```

**In `exitThreadMode()` when restoring first entry:**
```swift
selectedEmbedURL = firstEntry.selectedEmbedURL
urlsKeptForEmbed = firstEntry.urlsKeptForEmbed
```

#### 4. PostComposerTextProcessing.swift

**In `handleDetectedURLsOptimized(_:)`:**

Changed the logic to respect the `urlsKeptForEmbed` set:

```swift
// If the selected embed URL is no longer in the detected URLs,
// only clear it if it's not in the kept-for-embed set
if let selectedURL = selectedEmbedURL, !urls.contains(selectedURL) {
    if !urlsKeptForEmbed.contains(selectedURL) {
        selectedEmbedURL = nil
        logger.debug("RT: Cleared selected embed URL as it's no longer in text")
    } else {
        logger.debug("RT: Kept selected embed URL even though it's not in text (user removed text but kept card)")
    }
}

// Remove cards for URLs no longer in text, EXCEPT those marked to keep for embedding
let urlsSet = Set(urls)
urlCards = urlCards.filter { urlsSet.contains($0.key) || urlsKeptForEmbed.contains($0.key) }
```

#### 5. LinkStatePersistence.swift

**In `updateCurrentThreadEntryWithLinkState()`:**
```swift
threadEntries[currentThreadIndex].selectedEmbedURL = selectedEmbedURL
threadEntries[currentThreadIndex].urlsKeptForEmbed = urlsKeptForEmbed
```

**In `loadEntryStateWithLinkPreservation()`:**
```swift
selectedEmbedURL = entry.selectedEmbedURL
urlsKeptForEmbed = entry.urlsKeptForEmbed
```

## How It Works Now

### User Flow

1. User pastes a URL (e.g., `https://example.com`)
2. System detects URL and loads card
3. Card is displayed with "Featured" badge
4. User clicks "Remove link from text" button
5. **NEW**: URL is added to `urlsKeptForEmbed` set
6. URL text is removed from `postText`
7. `updatePostContent()` is called
8. `handleDetectedURLsOptimized()` sees URL is not in text
9. **NEW**: But checks `urlsKeptForEmbed` and keeps `selectedEmbedURL` and card intact
10. **NEW**: State is persisted when saving thread entry
11. **NEW**: State is restored when loading thread entry
12. Post is created with embed but without URL text

### Thread Entry Switching

When switching between thread entries (or loading/saving state):
- `updateCurrentThreadEntry()` saves `selectedEmbedURL` and `urlsKeptForEmbed` to current entry
- `loadEntryState()` restores `selectedEmbedURL` and `urlsKeptForEmbed` from entry
- Even after `clearComposerState()` and `updatePostContent()`, the kept URLs remain intact

### Cleanup Flow

When the user explicitly removes the card (X button):
- `removeURLCard()` clears the URL from `urlsKeptForEmbed`
- Clears `selectedEmbedURL` if it matches
- Removes the card from `urlCards`

When the user creates a new post:
- `resetPost()` clears `urlsKeptForEmbed`
- All URL state is reset

## Testing

### Test Scenario 1: Remove URL Text, Keep Card
1. Open composer
2. Paste a URL: `https://example.com`
3. Wait for card to load
4. Click "Remove link from text" button (text.badge.minus icon)
5. **Expected**: URL text disappears, card remains with "Featured" badge
6. Post the message
7. **Expected**: Post is created with embed but no URL text

### Test Scenario 2: Remove URL Text, Switch Thread Entries
1. Enable thread mode
2. In first entry, paste a URL and remove text (keeping card)
3. Switch to second thread entry
4. Switch back to first entry
5. **Expected**: Card still visible with "Featured" badge
6. Post the thread
7. **Expected**: First post has embed without URL text

### Test Scenario 3: Remove Card Entirely
1. Open composer
2. Paste a URL: `https://example.com`
3. Wait for card to load
4. Click the X button on the card
5. **Expected**: Both URL text and card disappear
6. Post the message
7. **Expected**: Post is created without any embed

### Test Scenario 4: Multiple Posts
1. Open composer
2. Paste URL and remove text, keeping card
3. Post successfully
4. Open composer again for new post
5. **Expected**: Clean state, no lingering URL cards from previous post

## Summary

The fix introduces a two-part solution:

1. **Runtime tracking with `urlsKeptForEmbed`**: A set that acts as a whitelist preventing automatic cleanup of intentionally kept URLs
2. **State persistence in ThreadEntry**: Ensures `selectedEmbedURL` and `urlsKeptForEmbed` survive thread entry switching, state restoration, and composer lifecycle

This distinguishes between:
- **Automatic cleanup**: URLs removed from text by user editing (should clear card)
- **Intentional persistence**: URLs explicitly marked to keep as embed (should keep card)

The state is now properly persisted across all composer state changes, ensuring the feature works reliably.

## Files Modified

1. `PostComposerViewModel.swift` - Added `urlsKeptForEmbed` property
2. `PostComposerModels.swift` - Added fields to `ThreadEntry` and `CodableThreadEntry`
3. `PostComposerCore.swift` - Updated state management functions to save/restore URL embed state
4. `PostComposerTextProcessing.swift` - Updated `handleDetectedURLsOptimized()` to respect kept URLs
5. `LinkStatePersistence.swift` - Updated thread entry persistence functions

All changes maintain Swift 6 strict concurrency and follow existing architectural patterns.
