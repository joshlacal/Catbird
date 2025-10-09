# Post Composer URL Behavior Analysis & Proposed Solutions

## Date
December 2024

## Executive Summary

The post composer has complex, intertwined URL handling logic that creates unexpected user experiences. This document analyzes the current behavior, identifies core problems, and proposes architectural solutions for a cleaner, more predictable system.

---

## Current Behavior Analysis

### What Happens Now

#### Scenario 1: Manual Text Deletion
1. User pastes URL: `https://example.com`
2. URL card loads and displays with "Featured" badge
3. User manually selects and deletes the URL text
4. **Result**: URL card disappears immediately
5. **Issue**: This is inconsistent with the "Remove link from text" button behavior

#### Scenario 2: Using "Remove Link from Text" Button
1. User pastes URL: `https://example.com`
2. URL card loads and displays with "Featured" badge
3. User clicks "Remove link from text" button on card
4. URL text is removed from post
5. URL card remains with "Featured" badge
6. User starts typing new text
7. **Issue**: New text appears highlighted blue (link color) even though no URL is present
8. **Issue**: Phantom link facets are created for non-URL text

#### Scenario 3: Multiple URLs
1. User pastes multiple URLs in text
2. Only first URL generates a card (correct)
3. All URLs in text generate link facets (correct)
4. All URLs remain blue/highlighted (correct)
5. Only first URL will be used as embed (correct)
6. **Issue**: No visual indication of which URLs will be clickable vs which will be embed

---

## Root Cause Analysis

### Problem 1: Reactive vs. Sticky URL Card Management

**Current Architecture**: Reactive
- URL cards are regenerated on every text change
- `handleDetectedURLsOptimized()` runs on every `updatePostContent()` call
- Cards are filtered based on `detectedURLs` array + `urlsKeptForEmbed` set
- This creates a fragile system where cards can disappear unexpectedly

**Desired Architecture**: Sticky
- URL cards should be created once and persist until explicitly removed
- User actions (manual deletion, button clicks) should be distinct operations
- Text editing should not automatically remove cards
- Cards should only disappear when:
  - User clicks X button on card
  - User posts/cancels composer
  - User explicitly removes URL from original location

### Problem 2: Facet Contamination After URL Text Removal

**Current Flow**:
```
removeURLFromText(for: url)
  → Remove URL from postText
  → updatePostContent()
    → PostParser.parsePostContent(postText) 
      → Returns facets for current text (no URL facets since URL removed)
    → Merge manualLinkFacets (may contain stale link facets)
    → updateAttributedText(displayFacets)
      → Creates NSAttributedString with blue highlighting
```

**The Issue**:
- `manualLinkFacets` contains link facets created by RichTextView/UIKit
- These facets have byte ranges that may no longer be valid after URL removal
- When merged, they apply link styling to wrong parts of text
- New typing inherits the link attribute from UITextView's typing attributes

**Why It Happens**:
1. RichTextView has `dataDetectorTypes = .all` (line in RichTextEditor.swift)
2. UIKit automatically detects and styles URLs with link attributes
3. These link attributes are extracted into `manualLinkFacets`
4. When URL text is removed but `manualLinkFacets` isn't cleared, stale facets persist
5. UITextView's typing attributes preserve the last character's attributes (iOS behavior)

### Problem 3: No Clear Separation of URL States

The system doesn't distinguish between:
- **URLs in text that should generate facets** (clickable links)
- **URLs that should generate embed cards** (rich previews)
- **URLs kept for embed but removed from text** (preview only, no facet)

Current state management:
- `detectedURLs: [String]` - URLs found by parser in current text
- `urlCards: [String: URLCardResponse]` - Loaded card data
- `selectedEmbedURL: String?` - Which URL will be used as embed
- `urlsKeptForEmbed: Set<String>` - URLs to keep even when not in text
- `manualLinkFacets: [AppBskyRichtextFacet]` - Legacy inline links

This is too many overlapping state variables tracking similar things.

### Problem 4: UITextView Data Detectors Interference

**RichTextView Setup**:
```swift
dataDetectorTypes = .all
```

This enables automatic link detection and styling by UIKit, which:
- Overrides custom text styling
- Creates its own link attributes
- Interferes with manual facet management
- Cannot be precisely controlled

When combined with manual facet management, this creates conflicts.

---

## Proposed Solutions

### Solution 1: Implement Sticky URL Card Lifecycle

**New Architecture**:

```swift
// New state model
struct URLEmbedState {
    let url: String
    let card: URLCardResponse
    let wasRemovedFromText: Bool  // User explicitly removed text
    let createdAt: Date           // For ordering
}

var urlEmbedStates: [String: URLEmbedState] = [:]  // Replaces urlCards
```

**Behavior Changes**:

1. **Card Creation**: 
   - When URL is detected, create `URLEmbedState` with `wasRemovedFromText = false`
   - Card persists regardless of subsequent text changes

2. **Manual Text Deletion**:
   - Detect when user manually deletes URL text (not via button)
   - Mark `wasRemovedFromText = true` 
   - Keep card visible but with different badge ("Text removed" or similar)
   - Or: Remove card entirely (more predictable)

3. **Button-Based Text Removal**:
   - User clicks "Remove link from text" button
   - Mark `wasRemovedFromText = true`
   - Keep card visible with "Featured" badge
   - Clear facets for this URL to prevent highlighting

4. **Explicit Card Removal**:
   - User clicks X button on card
   - Remove from `urlEmbedStates` completely
   - If URL still in text, it remains as plain text (no facet, no card)

### Solution 2: Clear Facets When Removing URL Text

**Implementation**:

```swift
func removeURLFromText(for url: String) {
    guard let urlToRemove = detectedURLs.first(where: { $0 == url }) else { 
        logger.debug("Cannot remove URL from text - not found")
        return 
    }
    
    // Mark URL as kept for embed
    urlsKeptForEmbed.insert(url)
    
    // Find and remove URL from text
    if let range = postText.range(of: urlToRemove) {
        isUpdatingText = true
        postText.removeSubrange(range)
        postText = postText.replacingOccurrences(of: "  ", with: " ")
        postText = postText.trimmingCharacters(in: .whitespacesAndNewlines)
        isUpdatingText = false
        
        // CRITICAL: Clear manual link facets to prevent phantom highlighting
        manualLinkFacets.removeAll { facet in
            // Remove facets that reference this URL
            facet.features.contains { feature in
                if case .appBskyRichtextFacetLink(let link) = feature {
                    return link.uri.uriString() == url
                }
                return false
            }
        }
        
        // Update content to regenerate clean facets
        updatePostContent()
        
        // CRITICAL: Reset typing attributes in UITextView to prevent blue text
        if let richTextView = getRichTextViewReference() {
            richTextView.typingAttributes = [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label
            ]
        }
        
        logger.debug("Removed URL from text and cleared associated facets: \(url)")
    }
}
```

### Solution 3: Disable UITextView Data Detectors

**Rationale**: 
- We're manually managing all link detection via `PostParser`
- UIKit's automatic detection interferes with our custom facet system
- Better to have one source of truth

**Implementation**:

```swift
// In RichTextView.setupView()
private func setupView() {
    allowsEditingTextAttributes = true
    isEditable = true
    isSelectable = true
    
    textContainer.lineFragmentPadding = 0
    textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    
    // DISABLE automatic data detection - we handle links manually
    dataDetectorTypes = []  // Changed from .all
}
```

**Tradeoffs**:
- ✅ Pro: Complete control over link detection and styling
- ✅ Pro: No interference with manual facets
- ✅ Pro: Consistent behavior across all text inputs
- ⚠️ Con: Must ensure PostParser catches all URLs correctly
- ⚠️ Con: Lose automatic phone number/address detection (acceptable for social media)

### Solution 4: Separate URL Facets from Embed State

**New Conceptual Model**:

```
Text Content Layer:
  ├─ Plain text (postText)
  ├─ Detected URLs (for facet generation)
  └─ Facets (for styling/linking)

Embed Layer (independent):
  ├─ URL cards (rich previews)
  ├─ Selected embed URL (which card to use)
  └─ Kept URLs (persist after text removal)
```

**Rules**:
1. **Facets are only for URLs currently in text**
   - If URL is removed from text, remove its facet
   - Exception: Manual inline links created via toolbar (if implemented)

2. **Embeds persist independently**
   - Once card is loaded, it stays until explicitly removed
   - User action determines card lifecycle, not text parsing

3. **Clear state transitions**
   - URL detected → Load card + Create facet
   - User removes text → Remove facet, mark card as "text removed"
   - User removes card → Delete card, URL becomes plain text if still present

### Solution 5: Unified State Management

**Replace**:
```swift
var detectedURLs: [String] = []
var urlCards: [String: URLCardResponse] = [:]
var selectedEmbedURL: String?
var urlsKeptForEmbed: Set<String> = []
```

**With**:
```swift
struct URLState {
    enum Status {
        case inText           // URL is in post text, has facet
        case keptForEmbed     // URL removed from text but kept for embed
        case removed          // URL removed entirely
    }
    
    let url: String
    var status: Status
    var card: URLCardResponse?
    var isSelectedForEmbed: Bool
    let detectedAt: Date
}

var urlStates: [String: URLState] = [:]
```

**Benefits**:
- Single source of truth for URL state
- Clear lifecycle management
- Easy to reason about state transitions
- Eliminates overlapping/contradictory state

---

## Implementation Priority

### Phase 1: Critical Fixes (Immediate)
1. ✅ **Clear manualLinkFacets when removing URL text**
   - Fixes phantom blue highlighting
   - Prevents facet contamination
   - Low risk, high impact

2. ✅ **Reset typing attributes in UITextView**
   - Prevents new text from inheriting link color
   - Simple fix, immediate user-visible improvement

3. **Consider disabling data detectors**
   - Evaluate impact on URL detection
   - Test thoroughly before deployment

### Phase 2: Architectural Improvements (Next Sprint)
1. **Implement sticky URL card lifecycle**
   - Cards persist until explicit removal
   - Clearer user mental model
   - Reduces complexity in text processing

2. **Separate facet generation from embed management**
   - Independent state tracking
   - More predictable behavior
   - Foundation for future features

### Phase 3: Unified State Management (Future)
1. **Replace multiple URL state variables with URLState**
   - Cleaner architecture
   - Easier to maintain
   - Better testing story

---

## Testing Requirements

### Test Cases for Phase 1

**TC1: Remove URL via button, then type**
- Paste URL → Click "Remove link from text" → Type new text
- Expected: New text is black, not blue
- Expected: No link facets for new text

**TC2: Manual text deletion behavior**
- Paste URL → Manually delete URL text
- Expected: Card disappears (current) OR stays with different badge (future)
- Expected: No phantom facets remain

**TC3: Multiple URLs handling**
- Paste 3 URLs → First gets card → All are blue
- Remove first URL via button
- Expected: First URL's card stays, facet removed
- Expected: Other URLs still blue with facets

**TC4: Thread entry switching**
- Create thread → Paste URL in entry 1 → Remove text via button
- Switch to entry 2 → Switch back to entry 1
- Expected: Card still visible, no blue text

### Test Cases for Phase 2

**TC5: Sticky card persistence**
- Paste URL → Card loads → Edit text before/after URL
- Expected: Card remains visible throughout editing

**TC6: Card removal doesn't affect text**
- Paste URL → Card loads → Click X on card
- Expected: URL text remains in post (no longer blue)
- Expected: URL will not be embedded

**TC7: Manual vs button deletion distinction**
- Test both paths have appropriate behavior
- Expected: Clear, consistent user feedback

---

## Questions for Parallel Agents

### Architecture Review
1. Is the proposed `URLState` model too complex, or appropriately detailed?
2. Should manual text deletion keep the card or remove it?
3. Is disabling `dataDetectorTypes` safe, or are there edge cases we'd miss?

### User Experience
4. What should the card badge say when URL text is removed?
   - "Featured" (current)
   - "Link preview" (clearer)
   - No badge (simpler)
   - "Text removed" (explicit)

5. Should there be a way to restore URL text after removal?
   - Undo button on card?
   - Tap card to re-insert URL?

### Technical Implementation
6. How should we handle race conditions between:
   - URL card loading (async)
   - Text updates (sync)
   - User actions (unpredictable timing)

7. Should `urlStates` be an Actor for thread safety?

8. How do we migrate existing drafts with old state structure?

### Edge Cases
9. What happens if user pastes same URL twice in different positions?
10. How do we handle URL shorteners that expand to same final URL?
11. Should editing a URL (changing a character) be treated as remove + add?

### Performance
12. Is creating/destroying URL cards on every text change a performance issue?
13. Should we debounce URL detection more aggressively?
14. Does the RichTextView need a display link for smoother updates?

---

## Related Files

### Core URL Handling
- `PostComposerViewModel.swift` - Main state management
- `PostComposerTextProcessing.swift` - Text parsing and URL detection
- `PostComposerCore.swift` - URL card lifecycle methods
- `PostParser.swift` - URL detection via NSDataDetector

### UI Components
- `RichTextEditor.swift` - UITextView with data detectors
- `ComposeURLCardView.swift` - URL card display
- `PostComposerView.swift` - SwiftUI integration
- `PostComposerViewUIKit.swift` - UIKit integration

### State Persistence
- `PostComposerModels.swift` - ThreadEntry and state structures
- `LinkStatePersistence.swift` - Thread entry state management

---

## Recommended Next Steps

1. **Review this document** with team/agents for feedback
2. **Implement Phase 1 critical fixes** (manualLinkFacets clearing)
3. **Test thoroughly** across iOS/macOS, thread/single post modes
4. **Gather user feedback** on card persistence behavior
5. **Design Phase 2** architecture in detail before implementation
6. **Create migration plan** for Phase 3 state management refactor

---

## Notes

- This is a complex system with many interaction points
- Any changes should be made incrementally with comprehensive testing
- User experience should be prioritized over architectural purity
- Consider A/B testing different behaviors before full rollout
- Document all behavior changes in user-facing release notes

## Appendix: Current State Variables

```swift
// PostComposerViewModel.swift
var detectedURLs: [String] = []                    // URLs in current text
var urlCards: [String: URLCardResponse] = [:]      // Loaded card data
var selectedEmbedURL: String?                       // URL for embed
var urlsKeptForEmbed: Set<String> = []             // URLs to keep when not in text
var manualLinkFacets: [AppBskyRichtextFacet] = []  // UIKit-created link facets
var isLoadingURLCard: Bool = false                  // Loading state
```

This overlapping state creates cognitive overhead and bugs.
