# Label Visibility System Fix

## Problem Summary

The label system had several issues:

1. **No explanatory text**: Labels showed raw identifiers like "nsfw" instead of friendly names like "Adult Content"
2. **No visibility indication**: Warnings didn't explain what content was being filtered
3. **Incorrect visibility values**: Using "Show" instead of AT Protocol's "ignore"
4. **Missing preference integration**: Label preferences weren't properly mapped to AT Protocol values

## Solution

### 1. Friendly Label Names

Added `friendlyLabelName()` helper function that maps label identifiers to human-readable names:

```swift
func friendlyLabelName(_ labelKey: String) -> String {
    switch labelKey.lowercased() {
    case "nsfw", "porn": return "Adult Content"
    case "sexual": return "Sexual Content"
    case "suggestive": return "Sexually Suggestive"
    case "graphic", "gore": return "Graphic Content"
    // ... etc
    }
}
```

### 2. Updated ContentLabelBadge

Badges now display friendly names instead of raw values:

- Before: `Text(label.val)` → "nsfw"
- After: `Text(displayName)` → "Adult Content"

### 3. Warning Text Enhancement

The blur overlay now shows:

- **Title**: Specific label name (e.g., "Adult Content") or "Sensitive Content" for multiple labels
- **Description**: "May contain [list of labels]" with friendly names
- **Example**: "May contain adult content, violence, and graphic content"

Implemented with:
- `warningTitle`: Single label friendly name or generic title
- `warningLabels`: Comma-separated list of all label friendly names

### 4. Fixed ContentVisibility Enum

Updated to match AT Protocol specification:

```swift
enum ContentVisibility: String, Codable {
    case show = "ignore"  // AT Protocol uses "ignore"
    case warn = "warn"
    case hide = "hide"
    
    // Added conversion helpers
    init(fromPreference value: String)
    var preferenceValue: String
    var displayName: String  // For UI
}
```

### 5. Updated ContentFilterManager

All preference conversions now use proper AT Protocol values:

```swift
// Before
ContentVisibility(rawValue: pref.visibility) ?? .warn

// After
ContentVisibility(fromPreference: pref.visibility)
```

And when saving:

```swift
// Before
visibility: visibility.rawValue  // "Show" → invalid

// After
visibility: visibility.preferenceValue  // "ignore" → correct
```

### 6. Removed Redundant Label Display

Fixed double-display issue in PostView where labels appeared twice:
- ContentLabelManager already shows badges for `.show` visibility
- Removed duplicate ContentLabelView in normalPostContent

## Label Visibility Levels

### Hide (`"hide"`)
- Post is **completely filtered** out by FeedTuner
- Does not appear in feed at all
- No placeholder shown

### Warn (`"warn"`)
- Post appears in feed
- Content is **blurred** with overlay
- Overlay shows:
  - Friendly label names in title and description
  - "Show Content" button to reveal
- After revealing: badges shown at top, "Hide" button in corner

### Show (`"ignore"`)
- Post appears normally
- **Badge displayed** at top with friendly label name
- Content fully visible
- Example: Red badge showing "Adult Content"

## AT Protocol Preference Format

Preferences are stored as:

```swift
ContentLabelPreference(
    labelerDid: DID?,  // Optional: specific labeler or nil for global
    label: "nsfw",     // Label identifier
    visibility: "ignore" | "warn" | "hide"  // AT Protocol values
)
```

## User Experience Flow

### Setting Preferences

1. User goes to Settings → Content Filtering
2. Sees friendly names: "Adult Content", "Graphic Content", etc.
3. Selects visibility with icons:
   - 👁 Show (green)
   - ⚠️ Warn (orange)
   - 🚫 Hide (red)
4. Preferences saved with correct AT Protocol values

### Viewing Content

#### With "Show" Setting
- Post appears normally
- Badge at top: "Adult Content" (red background)
- All content visible

#### With "Warn" Setting
- Post appears with blur
- Title: "Adult Content" or "Sensitive Content"
- Description: "May contain adult content and violence"
- Button: "Show Content"
- After clicking: badges at top, content visible

#### With "Hide" Setting
- Post not shown in feed
- Filtered out at FeedTuner level
- No placeholder or indication

## Files Modified

1. **ContentLabelView.swift**
   - Added `friendlyLabelName()` helper
   - Updated `ContentLabelBadge` to show friendly names
   - Enhanced warning overlay with specific label info
   - Updated `ContentVisibility` enum with AT Protocol values

2. **ContentFilterModels.swift**
   - Updated `ContentFilterManager` preference conversion
   - Added `fromPreference` initializer
   - Added `preferenceValue` property
   - Updated `createPreferenceForLabel` to use correct values

3. **PostView.swift**
   - Removed redundant `ContentLabelView` display
   - ContentLabelManager now handles all label display

## Testing Checklist

- [ ] Badges show friendly names (e.g., "Adult Content" not "nsfw")
- [ ] Warning overlays explain what content is hidden
- [ ] "Show" preference displays badge without blur
- [ ] "Warn" preference shows blur with explanation
- [ ] "Hide" preference filters post from feed completely
- [ ] Preferences save with correct AT Protocol values
- [ ] Per-labeler preferences work correctly
- [ ] Multiple labels display correctly (comma-separated)

## Next Steps

1. Test with real labeled content from Bluesky
2. Verify preference sync across devices
3. Test with custom labelers
4. Ensure FeedTuner properly filters "hide" posts
5. Verify all label types have friendly names
