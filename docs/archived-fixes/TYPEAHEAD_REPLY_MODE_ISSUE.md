# Typeahead in Reply Mode - Persistent Z-Index/Layering Issue

## Problem Statement

The user mention typeahead (@mention suggestions) appears correctly in normal compose mode but fails to display properly in reply mode. Specifically:

- **Normal Mode**: Typeahead works perfectly - suggestions appear below text editor, fully visible and interactive
- **Reply Mode**: Typeahead outline/border is visible but the rows (user suggestions) are rendering behind the sheet/view content

## Symptoms

1. In reply mode, the typeahead suggestion box outline appears at the correct position
2. The glass effect border and shadow are visible
3. However, the actual content (user rows with avatars, names, handles) is not visible
4. Content appears to be rendered in a layer behind the composer sheet

## Architecture Context

### View Hierarchy

```
PostComposerViewUIKit (presented as sheet)
└── NavigationStack
    └── configured (content)
        └── editorPane (in non-thread mode)
            └── ScrollView
                ├── ReplyingToView (ONLY in reply mode - ~60px height)
                ├── HStack (Avatar + EnhancedRichTextEditor)
                ├── Media/URL/Tags sections
                └── .overlay(alignment: .top) { 
                    └── UserMentionSuggestionView
                }
```

### Key Difference: Reply Mode vs Normal Mode

- **Normal Mode**: ScrollView starts with Avatar + Editor (no ReplyingToView)
- **Reply Mode**: ScrollView has ReplyingToView at top, pushing editor down ~60-80px
- Overlay offset accounts for this: `let offset: CGFloat = viewModel.parentPost != nil ? 280 : 220`

## What We've Tried

### 1. Initial Positioning Fix ✅ (Worked for positioning)
**File**: `PostComposerViewUIKit.swift`

```swift
// Added dynamic offset based on reply mode
let offset: CGFloat = viewModel.parentPost != nil ? 280 : 220
```

**Result**: Fixed positioning, but rows still behind sheet

### 2. Fixed Flickering Issue ✅ (Worked for stability)
**Files**: 
- `PostComposerViewUIKit.swift`
- `PostComposerViewModel.swift`
- `UserMentionSuggestionView.swift`

**Changes**:
- Added `mappedMentionSuggestions` computed property to cache mapping
- Added `.fixedSize(horizontal: false, vertical: true)` to prevent vertical expansion
- Changed `LazyVStack` to `VStack` for better rendering with fixedSize
- Added `.frame(minHeight: 60, maxHeight: 200)` for stable sizing

**Result**: Eliminated flickering, but rows still behind sheet in reply mode

### 3. Z-Index Elevation Attempts ❌ (Failed)
**File**: `PostComposerViewUIKit.swift`

```swift
VStack(spacing: 0) {
  Spacer().frame(height: offset)
  UserMentionSuggestionViewResolver(...)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 16)
    .id("mention-suggestions")
  Spacer()
}
.zIndex(1000)                    // ← Added
.allowsHitTesting(true)          // ← Added
.frame(maxWidth: .infinity, alignment: .top)
```

**Result**: No improvement - rows still behind

### 4. Opaque Background Layers ❌ (Failed)
**File**: `UserMentionSuggestionView.swift`

```swift
VStack(spacing: 0) {
  suggestionList
}
.frame(minHeight: 60, maxHeight: 200)
.background(Color.systemBackground.opacity(1.0))  // ← Explicit opacity
.compositingGroup()                               // ← Force single layer
.glassEffect(.regular, in: .rect(cornerRadius: 12))
```

**Also tried**:
- Double background on ScrollView and inner VStack
- `.background(Color.systemBackground)` on each MentionSuggestionRow
- Changed background order (before vs after glass effect)

**Result**: No improvement - rows still behind in reply mode

### 5. Rendering Layer Fixes ❌ (Failed)
**File**: `UserMentionSuggestionView.swift`

```swift
private var suggestionList: some View {
  ScrollView {
    VStack(spacing: 0) {  // Changed from LazyVStack
      ForEach(suggestions) { suggestion in
        Button {
          onSuggestionSelected(suggestion)
        } label: {
          MentionSuggestionRow(suggestion: suggestion)
        }
        .buttonStyle(.plain)
        // ...
      }
      .background(Color.systemBackground)  // Background on VStack
    }
  }
  .background(Color.systemBackground)      // Background on ScrollView
}
```

**Result**: No improvement

## Current State of Code

### PostComposerViewUIKit.swift - Overlay Structure
```swift
.overlay(alignment: .top) {
  if !viewModel.mentionSuggestions.isEmpty {
    let offset: CGFloat = viewModel.parentPost != nil ? 280 : 220
    
    VStack(spacing: 0) {
      Spacer().frame(height: offset)
      
      UserMentionSuggestionViewResolver(
        suggestions: viewModel.mappedMentionSuggestions,
        onSuggestionSelected: { suggestion in
          viewModel.insertMention(suggestion.profile)
          pendingSelectionRange = NSRange(location: viewModel.postText.count, length: 0)
          activeEditorFocusID = UUID()
        },
        onDismiss: {
          viewModel.mentionSuggestions = []
        }
      )
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16)
      .id("mention-suggestions")
      
      Spacer()
    }
    .zIndex(1000)
    .allowsHitTesting(true)
    .frame(maxWidth: .infinity, alignment: .top)
  }
}
```

### UserMentionSuggestionView.swift - View Structure (iOS 26+)
```swift
var body: some View {
  if !suggestions.isEmpty {
    VStack(spacing: 0) {
      suggestionList
    }
    .frame(minHeight: 60, maxHeight: 200)
    .background(Color.systemBackground.opacity(1.0))
    .compositingGroup()
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
    )
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
  }
}

private var suggestionList: some View {
  ScrollView {
    VStack(spacing: 0) {
      ForEach(suggestions) { suggestion in
        Button {
          onSuggestionSelected(suggestion)
        } label: {
          MentionSuggestionRow(suggestion: suggestion)
        }
        .buttonStyle(.plain)
        
        if suggestion != suggestions.last {
          Divider()
            .padding(.leading, 60)
        }
      }
      .background(Color.systemBackground)
    }
  }
  .background(Color.systemBackground)
}
```

### MentionSuggestionRow Structure
```swift
struct MentionSuggestionRow: View {
  let suggestion: MentionSuggestion
  
  var body: some View {
    HStack(spacing: 12) {
      // Avatar (AsyncImage)
      // User info VStack (displayName, handle)
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color.systemBackground)  // ← Explicit background
    .contentShape(Rectangle())
  }
}
```

## Hypotheses for Why It Fails in Reply Mode

### 1. Sheet Presentation Layer Conflict
- Reply mode may present the composer differently
- NavigationStack in reply context might have different layer priority
- ReplyingToView at top of ScrollView might affect z-indexing

### 2. Glass Effect Rendering Order
- `.glassEffect()` (iOS 26+) may interact poorly with overlay in certain contexts
- Glass effect might be creating a separate render layer in reply mode
- `.compositingGroup()` might not be working as expected with glass effect

### 3. ScrollView + Overlay Interaction
- ScrollView with ReplyingToView might change overlay attachment point
- Overlay alignment `.top` might behave differently with content above it
- Fixed Spacer height approach may cause layer separation

### 4. SwiftUI Rendering Pipeline Difference
- Reply mode sheet might have different rendering pipeline
- NavigationStack behavior differs between new sheet vs presented-over context
- Background/foreground layer priority changes with sheet presentation

## Potential Solutions to Try Next

### Option 1: Move Overlay Outside ScrollView
Instead of `.overlay()` on ScrollView, apply it to parent container:

```swift
VStack {
  ScrollView {
    // content
  }
  
  // Separate overlay positioned absolutely
  if !viewModel.mentionSuggestions.isEmpty {
    GeometryReader { geometry in
      UserMentionSuggestionViewResolver(...)
        .position(x: geometry.size.width / 2, y: calculateY())
    }
  }
}
.coordinateSpace(name: "composer")
```

### Option 2: Use ZStack Instead of Overlay
Replace `.overlay()` with explicit ZStack layering:

```swift
ZStack(alignment: .top) {
  ScrollView {
    // content
  }
  
  if !viewModel.mentionSuggestions.isEmpty {
    VStack {
      Spacer().frame(height: offset)
      UserMentionSuggestionViewResolver(...)
      Spacer()
    }
  }
}
```

### Option 3: Disable Glass Effect in Reply Mode
Test if glass effect is the culprit:

```swift
.background(Color.systemBackground.opacity(1.0))
.compositingGroup()
// Conditionally apply glass effect
.modifier(GlassEffectModifier(isReplyMode: viewModel.parentPost != nil))
```

### Option 4: Use drawingGroup()
Force Metal rendering:

```swift
UserMentionSuggestionViewResolver(...)
  .drawingGroup()  // Forces offscreen rendering
  .zIndex(1000)
```

### Option 5: Present as Separate Popover/Menu
Instead of overlay, use native presentation:

```swift
.popover(isPresented: $showingSuggestions) {
  UserMentionSuggestionViewResolver(...)
    .presentationCompactAdaptation(.popover)
}
```

## Files Modified

1. **PostComposerViewUIKit.swift**
   - Wrap composer scroll views in a  so the mention list renders outside the scroll content
   - Position suggestions with top padding instead of spacer stacks
   - Apply the same layering fix to both single-post and thread composer paths

## Debug Steps to Investigate

1. **Add visual debugging**:
   ```swift
   .border(Color.red, width: 3)  // On each layer
   ```

2. **Test without glass effect**:
   - Remove `.glassEffect()` temporarily
   - See if rows appear

3. **Test with simpler overlay**:
   ```swift
   .overlay(alignment: .top) {
     Text("TEST OVERLAY")
       .background(Color.red)
       .offset(y: 280)
   }
   ```

4. **Check view hierarchy in Xcode debugger**:
   - Use "Debug View Hierarchy" to see actual layer order
   - Check if rows are being rendered at all

5. **Log when view appears**:
   ```swift
   .onAppear {
     print("🔍 UserMentionSuggestionView appeared in reply mode")
   }
   ```

## Related Files

- `/Catbird/Features/Feed/Views/Components/PostComposer/PostComposerViewUIKit.swift`
- `/Catbird/Features/Feed/Views/Components/PostComposer/PostComposerViewModel.swift`
- `/Catbird/Features/Feed/Views/Components/PostComposer/Components/UserMentionSuggestionView.swift`
- `/Catbird/Features/Feed/Views/Components/PostComposer/PostComposerTextProcessing.swift`
- `/Catbird/Features/Feed/Views/Components/PostComposer/Components/ReplyingToView.swift`

## Expected Behavior

In reply mode, when typing "@username", the typeahead should appear below the text editor with:
- Full visibility of all suggestion rows
- Working tap/click interactions
- Proper visual styling (glass effect, shadows, borders)
- Same behavior as normal compose mode

## Actual Behavior

In reply mode:
- Typeahead positioning is correct
- Border/outline is visible
- Glass effect shadow is visible
- But rows (content) are invisible/behind sheet
- Normal mode works perfectly with identical view structure (minus ReplyingToView)


## Resolution

The issue was that the mention view lived inside each scroll view's `.overlay`, which placed it in the same UIKit view hierarchy as the embedded text view used in reply mode. When the sheet composed its layers, the text view always won, so the suggestion rows rendered underneath the sheet.

We now render the composer scroll views normally and draw the suggestion list from a top-level `GeometryReader` + `ZStack` that sits beside the `NavigationStack`. By placing the overlay outside the scroll view/UITextView hierarchy and positioning it with a safe-area-aware padding offset, the rows consistently stay above the composer sheet—reply mode included. The existing `enableGlass` flag remains available, but we only enable the glass effect when not replying.

Key changes:
- Replace the scroll-view `.overlay` with an elevated `UIViewRepresentable` host that renders the SwiftUI list at a higher z-position
- Use the shared overlay host for both single-post and thread composers so the placement logic stays consistent
- Keep tap handling via `.allowsHitTesting(true)` while letting the host manage visibility and animation

