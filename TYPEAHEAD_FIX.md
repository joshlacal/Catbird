# @Handle Typeahead Fix for Reply Mode

## Problem
The @handle typeahead view was not showing up when typing mentions in reply mode. Two issues were identified:

1. **Cursor position not tracked**: The mention detection logic looked for the last `@` in the entire text, not considering where the cursor actually was. In reply mode, if there was already an `@mention` earlier in the text, typing a new `@` wouldn't trigger suggestions.

2. **Z-index/layering issue**: The typeahead view was positioned inside the `ScrollView`, causing it to appear behind other content and potentially scroll away.

## Solution

### Part 1: Cursor-Aware Mention Detection

**Changes to `EnhancedRichTextEditor.swift`:**
- Updated `onTextChanged` callback signature from `(NSAttributedString) -> Void` to `(NSAttributedString, Int) -> Void`
- Modified `textViewDidChange` to capture and pass `textView.selectedRange.location` (cursor position)
- Consolidated duplicate `cursorPosition` declarations into a single variable

**Changes to `PostComposerViewModel.swift`:**
- Added `var cursorPosition: Int = 0` to track current cursor position

**Changes to `PostComposerTextProcessing.swift`:**
- Updated `updateFromAttributedText` to accept `cursorPosition` parameter and store it
- Rewrote `getCurrentTypingMention()` to use cursor position for detection:
  - Only searches for `@` before the cursor
  - Validates `@` is at start of text or preceded by whitespace
  - Extracts mention text from `@` to cursor position
  - Ensures mention text contains no whitespace

**Changes to `PostComposerViewUIKit.swift`:**
- Updated both `onTextChanged` callbacks (single mode and thread mode) to pass cursor position

### Part 2: Fix Typeahead Visibility (Z-Index)

**Problem:** The typeahead was inside the `ScrollView` content, making it scroll with the content and appear behind other UI elements.

**Solution:** Moved typeahead to an `.overlay()` on the `ScrollView`:

```swift
ScrollView {
  // ... content ...
}
.overlay(alignment: .top) {
  if !viewModel.mentionSuggestions.isEmpty {
    VStack {
      Spacer().frame(height: 220) // Position below text editor
      UserMentionSuggestionViewResolver(...)
      Spacer()
    }
  }
}
```

**Applied to both:**
- `editorPane` (single post mode)
- `threadComposerStack` (thread mode)

## Files Modified

1. **EnhancedRichTextEditor.swift** - Cursor position tracking and callback signature
2. **PostComposerViewModel.swift** - Cursor position storage
3. **PostComposerTextProcessing.swift** - Cursor-aware mention detection
4. **PostComposerViewUIKit.swift** - Callbacks updated, typeahead moved to overlay

## Result

The typeahead now:
- ✅ Detects `@` mentions at the cursor position (works in reply mode)
- ✅ Appears on top of all content (not behind or scrolled away)
- ✅ Works in both single and thread composer modes
- ✅ Properly positions below the text editor
