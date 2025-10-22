# Post Composer Phase 1: Critical URL Handling Fixes

## Date
December 2024

## Overview

This document outlines immediate fixes for the most critical URL handling issues identified in `POST_COMPOSER_URL_BEHAVIOR_ANALYSIS.md`. These fixes address phantom link highlighting and facet contamination without requiring major architectural changes.

---

## Fix 1: Clear Manual Link Facets When Removing URL Text

### Problem
When user clicks "Remove link from text" button:
1. URL text is removed from post
2. `manualLinkFacets` still contains link facets with now-invalid byte ranges
3. These stale facets are merged into display facets
4. New text inherits link styling (blue color)
5. User sees blue text even when typing normal content

### Root Cause
- `manualLinkFacets` is populated by RichTextView's UIKit link detection
- It persists across text changes
- When URL is removed, byte ranges become invalid but facets remain
- These are merged into display facets in `performUpdatePostContent()`

### Solution

**File**: `PostComposerCore.swift`

**In `removeURLFromText(for:)` function**, add facet clearing:

```swift
func removeURLFromText(for url: String) {
    guard let urlToRemove = detectedURLs.first(where: { $0 == url }) else { 
        logger.debug("Cannot remove URL from text - not found in detectedURLs: \(url)")
        return 
    }
    
    // Mark this URL as one to keep for embedding even when not in text
    urlsKeptForEmbed.insert(url)
    logger.debug("Marked URL as kept for embed: \(url)")
    
    // Find and remove the URL from the text
    if let range = postText.range(of: urlToRemove) {
        isUpdatingText = true
        postText.removeSubrange(range)
        // Clean up any extra whitespace
        postText = postText.replacingOccurrences(of: "  ", with: " ")
        postText = postText.trimmingCharacters(in: .whitespacesAndNewlines)
        isUpdatingText = false
        
        // CRITICAL FIX: Clear manual link facets that reference this URL
        // This prevents phantom link styling from appearing on new text
        let urlString = url
        manualLinkFacets.removeAll { facet in
            // Check if this facet contains a link to the removed URL
            facet.features.contains { feature in
                if case .appBskyRichtextFacetLink(let link) = feature {
                    return link.uri.uriString() == urlString
                }
                return false
            }
        }
        logger.debug("Cleared manual link facets for URL: \(url)")
        
        // Update content to regenerate facets without this URL
        updatePostContent()
        
        logger.debug("Removed URL from text but kept card for embedding: \(url)")
    }
}
```

### Testing
1. Paste URL: `https://example.com`
2. Wait for card to load
3. Click "Remove link from text" button
4. Observe URL text is removed
5. Start typing new text
6. **Expected**: New text is normal color (not blue)
7. Post and verify no link facets for new text

---

## Fix 2: Reset Typing Attributes in RichTextView

### Problem
UITextView's `typingAttributes` property preserves the last character's attributes. When a URL is removed, the typing attributes still contain link styling, causing new text to be styled as links.

### Root Cause
- UITextView behavior: typing attributes = attributes at cursor position
- After URL removal, cursor is where URL was
- That position had link attributes
- New text inherits those attributes

### Solution

**File**: `PostComposerCore.swift`

**Add helper method to reset typing attributes**:

```swift
// MARK: - RichTextView Reference Management

/// Reference to the active RichTextView for direct manipulation
weak var activeRichTextView: RichTextView?

/// Reset typing attributes to prevent link styling inheritance
private func resetTypingAttributes() {
    #if os(iOS)
    guard let richTextView = activeRichTextView else { return }
    
    // Reset to default text attributes
    richTextView.typingAttributes = [
        .font: UIFont.preferredFont(forTextStyle: .body),
        .foregroundColor: UIColor.label
    ]
    
    logger.debug("Reset typing attributes to default")
    #endif
}
```

**Update `removeURLFromText(for:)` to call this**:

```swift
func removeURLFromText(for url: String) {
    guard let urlToRemove = detectedURLs.first(where: { $0 == url }) else { 
        logger.debug("Cannot remove URL from text - not found in detectedURLs: \(url)")
        return 
    }
    
    // Mark this URL as one to keep for embedding even when not in text
    urlsKeptForEmbed.insert(url)
    logger.debug("Marked URL as kept for embed: \(url)")
    
    // Find and remove the URL from the text
    if let range = postText.range(of: urlToRemove) {
        isUpdatingText = true
        postText.removeSubrange(range)
        postText = postText.replacingOccurrences(of: "  ", with: " ")
        postText = postText.trimmingCharacters(in: .whitespacesAndNewlines)
        isUpdatingText = false
        
        // Clear manual link facets for this URL
        let urlString = url
        manualLinkFacets.removeAll { facet in
            facet.features.contains { feature in
                if case .appBskyRichtextFacetLink(let link) = feature {
                    return link.uri.uriString() == urlString
                }
                return false
            }
        }
        logger.debug("Cleared manual link facets for URL: \(url)")
        
        // Update content to regenerate facets without this URL
        updatePostContent()
        
        // CRITICAL FIX: Reset typing attributes to prevent blue text
        resetTypingAttributes()
        
        logger.debug("Removed URL from text but kept card for embedding: \(url)")
    }
}
```

**Wire up the reference in PostComposerViewUIKit.swift**:

Find the `RichTextEditorView` or wherever `RichTextView` is instantiated and add:

```swift
// Inside makeUIView or similar
let richTextView = RichTextView()
// ... existing setup ...

// Store reference in view model for direct access
viewModel.activeRichTextView = richTextView
```

### Testing
1. Paste URL with text before it: `Hello https://example.com world`
2. Click "Remove link from text" button  
3. Text becomes: `Hello  world`
4. Place cursor at the end
5. Type: ` test`
6. **Expected**: "test" is normal color, not blue

---

## Fix 3: Consider Disabling UITextView Data Detectors (Optional)

### Problem
`RichTextView` has `dataDetectorTypes = .all`, which enables automatic link detection by UIKit. This interferes with our manual facet management and creates conflicts.

### Solution

**File**: `RichTextEditor.swift`

**In `setupView()` method**:

```swift
private func setupView() {
    allowsEditingTextAttributes = true
    isEditable = true
    isSelectable = true
    
    textContainer.lineFragmentPadding = 0
    textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    
    // DISABLE automatic data detection - we handle all formatting manually
    // This prevents UIKit from interfering with our custom facet system
    dataDetectorTypes = []  // Changed from .all
}
```

### Tradeoffs

**Pros**:
- Eliminates UIKit interference with manual facets
- Complete control over link detection and styling
- Consistent behavior across all text inputs
- Prevents automatic link attribute creation

**Cons**:
- Lose automatic phone number detection (minor - not critical for social posts)
- Lose automatic address detection (minor - not critical for social posts)
- Must ensure PostParser catches all URLs correctly
- Slightly less "iOS native" feel

### Recommendation
**IMPLEMENT THIS** - The benefits far outweigh the costs. Social media posts rarely need phone/address detection, and URL detection is already handled by PostParser.

### Testing
1. Paste URL: `https://example.com`
2. **Expected**: URL is styled via our facet system, not UIKit
3. Paste phone number: `555-1234`
4. **Expected**: Phone number remains plain text (acceptable)
5. Edit text around URL
6. **Expected**: No unexpected link styling or attribute inheritance

---

## Fix 4: Clear Manual Facets on Manual Text Deletion

### Problem
When user manually deletes URL text (not via button), the card disappears but manual link facets may persist.

### Solution

**File**: `PostComposerTextProcessing.swift`

**In `handleDetectedURLsOptimized(_:)` function**, add facet cleanup:

```swift
private func handleDetectedURLsOptimized(_ urls: [String]) {
    logger.debug("RT: handleDetectedURLsOptimized count=\(urls.count)")
    
    // Track which URLs were removed
    let previousURLs = Set(detectedURLs)
    let currentURLs = Set(urls)
    let removedURLs = previousURLs.subtracting(currentURLs)
    
    // Update detected URLs immediately
    detectedURLs = urls
    
    // Set the first URL as the selected embed URL if none is set and we have URLs
    if selectedEmbedURL == nil && !urls.isEmpty {
        selectedEmbedURL = urls.first
        logger.debug("RT: Set first URL as selected embed: \(urls.first ?? "none")")
    }
    
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
    
    // NEW: Clear manual link facets for URLs that were removed from text
    // This prevents phantom facets when user manually deletes URLs
    if !removedURLs.isEmpty {
        manualLinkFacets.removeAll { facet in
            facet.features.contains { feature in
                if case .appBskyRichtextFacetLink(let link) = feature {
                    return removedURLs.contains(link.uri.uriString())
                }
                return false
            }
        }
        logger.debug("RT: Cleared manual link facets for removed URLs: \(removedURLs)")
        
        // Reset typing attributes if we removed facets
        #if os(iOS)
        if let richTextView = activeRichTextView {
            richTextView.typingAttributes = [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label
            ]
        }
        #endif
    }
    
    // Remove cards for URLs no longer in text, EXCEPT those marked to keep for embedding
    let urlsSet = Set(urls)
    urlCards = urlCards.filter { urlsSet.contains($0.key) || urlsKeptForEmbed.contains($0.key) }
    
    // Only load card for the first detected URL (which will be the embed)
    if let firstURL = urls.first, urlCards[firstURL] == nil {
        if let optimizer = performanceOptimizer {
            optimizer.debounceURLDetection(urls: [firstURL]) { urlsToProcess in
                Task {
                    await self.loadURLCardsOptimized(urlsToProcess)
                }
            }
        } else {
            Task {
                await loadURLCard(for: firstURL)
            }
        }
    }
}
```

### Testing
1. Paste URL: `Hello https://example.com world`
2. Manually select and delete the URL
3. Card disappears (expected)
4. Type new text: `test`
5. **Expected**: "test" is normal color, not blue
6. Post and verify no phantom link facets

---

## Implementation Checklist

- [ ] Add `activeRichTextView` weak reference to `PostComposerViewModel`
- [ ] Add `resetTypingAttributes()` helper method to `PostComposerCore`
- [ ] Update `removeURLFromText()` to clear manual link facets
- [ ] Update `removeURLFromText()` to reset typing attributes
- [ ] Wire up `activeRichTextView` reference in `PostComposerViewUIKit`
- [ ] Update `handleDetectedURLsOptimized()` to track removed URLs
- [ ] Update `handleDetectedURLsOptimized()` to clear facets for removed URLs
- [ ] Update `handleDetectedURLsOptimized()` to reset typing attributes
- [ ] Change `dataDetectorTypes = []` in `RichTextEditor.swift`
- [ ] Test all scenarios on iOS simulator
- [ ] Test all scenarios on macOS
- [ ] Test in thread mode
- [ ] Test with multiple URLs
- [ ] Verify no performance regression
- [ ] Update unit tests if needed

---

## Risk Assessment

### Low Risk Changes
- ✅ Clearing `manualLinkFacets` - only affects display, not data
- ✅ Resetting typing attributes - only affects UI, reversible
- ✅ Tracking removed URLs - pure computation, no side effects

### Medium Risk Changes
- ⚠️ Disabling `dataDetectorTypes` - changes core text view behavior
  - Mitigation: Thoroughly test URL detection still works
  - Rollback: Easy, just change back to `.all`

### Testing Focus
- URL detection accuracy (ensure PostParser catches all valid URLs)
- Manual vs button deletion behavior consistency
- Thread mode state preservation
- Performance with rapid text changes

---

## Success Criteria

After implementing these fixes:

1. ✅ No blue/highlighted text appears after removing URL
2. ✅ New typed text has normal styling
3. ✅ No phantom link facets in posted content
4. ✅ URL cards behave predictably and consistently
5. ✅ No performance degradation
6. ✅ Thread mode works correctly
7. ✅ Both iOS and macOS work identically

---

## Next Steps

1. Implement fixes in order (1 → 2 → 3 → 4)
2. Test each fix individually before moving to next
3. Run full regression test suite
4. Get code review from another developer
5. Deploy to TestFlight for beta testing
6. Monitor crash reports and user feedback
7. Document any additional edge cases discovered
8. Plan Phase 2 architectural improvements based on learnings

---

## Notes

- These are **critical fixes** that should be implemented ASAP
- They are low-risk and high-impact
- No breaking changes to existing functionality
- Foundation for Phase 2 architectural improvements
- All changes follow Swift 6 concurrency patterns
- Maintain existing code style and patterns
