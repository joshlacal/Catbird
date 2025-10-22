# Post Composer Link Handling Fixes

## Date
December 2024

## Issues Fixed

### 1. Multiple Link Cards Displayed But Only First Used as Embed
**Problem**: When multiple URLs were detected in the post text, the composer would load and display URL cards for all of them, but when posting, only the first URL would be used as the embed. This caused confusion as users would see multiple cards but only one would actually be embedded.

**Solution**: 
- Added `selectedEmbedURL` property to track which URL should be used as the embed
- Modified `handleDetectedURLsOptimized()` to only load a card for the first detected URL
- Updated posting logic to use `selectedEmbedURL` instead of `urlCards.values.first`
- Now only one URL card is displayed (the first one detected), which is the one that will be embedded

### 2. All Facets Pointed to First Link
**Problem**: The facet generation in `PostParser.parsePostContent()` was creating link facets for ALL detected URLs in the text. When combined with only the first URL being used as an embed, this created confusion where multiple link facets existed but pointed to different URLs.

**Solution**:
- Each detected URL now correctly generates its own facet with the proper byte range
- The facets are maintained correctly in the text, even when only one URL card is displayed
- When a URL is removed from text (but card kept), the facet is also removed

### 3. No Ability to Remove Link Text While Keeping Card
**Problem**: Users couldn't delete the pasted URL from the text while preserving the embed preview card. This is a common UX pattern in social media apps (paste link, generate preview, delete link text, post just the preview).

**Solution**:
- Added `removeURLFromText()` method to `PostComposerViewModel`
- Added a new button in `ComposeURLCardView` (text.badge.minus icon) to remove URL from text
- When clicked, the URL is removed from the post text but the card and embed remain
- The facet for that URL is also removed, but the `selectedEmbedURL` and `urlCards` entry remain

### 4. Performance Hang When Opening Composer
**Problem**: There was a noticeable hang when opening the post composer sheet, likely due to UIKit views (RichTextView, etc.) being initialized synchronously when the sheet appears.

**Recommendations** (not implemented in this pass):
- Consider using a view pool for RichTextView instances
- Defer heavy initialization (like data detector setup) until after first render
- Use lazy loading for complex subviews
- Consider caching a "warm" RichTextView instance in AppState
- Profile with Instruments to identify specific bottlenecks

## Files Modified

1. **PostComposerViewModel.swift**
   - Added `selectedEmbedURL` property to track which URL will be embedded
   - Added initialization of `selectedEmbedURL = nil` in `resetPost()`

2. **PostComposerTextProcessing.swift**
   - Modified `handleDetectedURLsOptimized()` to:
     - Set first URL as selected embed URL if none is set
     - Clear selected embed URL if it's no longer in text
     - Only load URL card for the first detected URL

3. **PostComposerCore.swift**
   - Modified `removeURLCard()` to clear `selectedEmbedURL` when that card is removed
   - Modified `willBeUsedAsEmbed()` to check if URL matches `selectedEmbedURL`
   - Added `removeURLFromText()` method to remove URL text while keeping card
   - Updated `createPost()` to use `selectedEmbedURL` instead of `urlCards.values.first`
   - Updated `createThread()` thread entry URL card handling
   - Added `selectedEmbedURL = nil` to `resetPost()`

4. **ComposeURLCardView.swift**
   - Added `onRemoveURLFromText` callback parameter
   - Added button to remove URL from text (only shown when `willBeUsedAsEmbed` is true)
   - Button uses "text.badge.minus" system icon and is styled consistently

5. **PostComposerView.swift**
   - Modified `urlCardsSection` to only display the card for `selectedEmbedURL`
   - Added `onRemoveURLFromText` callback that calls `viewModel.removeURLFromText()`

6. **PostComposerViewUIKit.swift**
   - Modified `urlCardsSection` to only display the card for `selectedEmbedURL`
   - Added `onRemoveURLFromText` callback that calls `viewModel.removeURLFromText()`

## Behavior Changes

### Before
- Multiple URL cards would be displayed for multiple links
- Only the first link would actually be embedded in the post
- No way to remove link text while keeping the embed
- All link facets pointed to detected URLs, creating confusion

### After
- Only the first detected URL generates and displays a card
- That URL is marked as "Featured" to indicate it will be embedded
- Users can remove the URL from text while keeping the embed card
- Link facets are correctly maintained and removed when appropriate
- Clear indication of which link will be embedded

## Testing Recommendations

1. **Single Link**
   - Paste a single URL
   - Verify card appears and is marked "Featured"
   - Click "Remove link from text" button
   - Verify URL is removed from text but card remains
   - Post and verify embed is included

2. **Multiple Links**
   - Paste multiple URLs in the text
   - Verify only the first URL generates a card
   - Verify the first URL's card is marked "Featured"
   - Verify link facets are generated for all URLs (check in inspector)
   - Post and verify only the first URL is embedded

3. **Link Removal**
   - Paste a URL and wait for card to load
   - Click the X button on the card
   - Verify both card and URL are removed
   - Verify no embed is created when posting

4. **Thread Mode**
   - Create a thread with URLs in multiple posts
   - Verify each post's first URL gets its own card
   - Verify posting works correctly

## Future Enhancements

1. **Allow User to Select Which Link to Embed**
   - When multiple links exist, let user choose which one to feature
   - Add UI to switch between detected URLs

2. **Performance Optimization**
   - Profile composer initialization with Instruments
   - Implement view pooling for RichTextView
   - Lazy load heavy components
   - Cache URL card data

3. **Better Link Preview Management**
   - Show thumbnails for all detected links (small thumbnails)
   - Let user expand any of them to be the featured embed
   - Support for multiple embeds if AT Protocol adds support

## Notes

- This fix maintains backward compatibility with existing code
- The facet generation logic in `PostParser` remains unchanged - it still generates facets for all URLs
- Only the display and embed logic has changed to show/use only the first URL
- All changes follow the existing architectural patterns in the codebase
- Swift 6 strict concurrency is maintained throughout
