# Height Validation System Usage Example

This document shows how to use the new height validation system to test PostHeightCalculator accuracy.

## How to Enable

1. Open Catbird
2. Go to Settings → Debug Settings (only visible in DEBUG builds)
3. Enable "Enable Height Validation"
4. Optionally enable "Show Visual Indicators" to see red overlays on posts with calculation errors

## What It Does

The system compares PostHeightCalculator estimates with actual rendered cell heights:

```swift
// PostHeightCalculator estimates this height:
let estimatedHeight = PostHeightCalculator.estimatedHeight(for: post)

// UICollectionView renders the cell at this height:
let actualHeight = cell.bounds.height

// System calculates the difference:
let percentageError = (actualHeight - estimatedHeight) / actualHeight * 100
```

## Validation Report

After scrolling through posts, generate a report to see:

- **Overall accuracy percentage**
- **Average error in points and percentage**
- **Breakdown by content type** (text-only, images, videos, embeds)
- **Recent significant errors** (>10% or >20pt difference)
- **Recommendations** for improving accuracy

Example report:
```
# PostHeightCalculator Validation Report

## Overall Statistics
- Total validations: 150
- Accuracy: 87.3%
- Average error: 2.1pt (3.2%)
- Average absolute error: 8.7pt
- Significant errors: 19/150 (12.7%)

## Error Analysis by Content Type
- Posts with images: 45 posts, avg error: 12.4%
- Posts with videos: 12 posts, avg error: 18.7%
- Posts with embeds: 23 posts, avg error: 15.1%
- Text-only posts: 70 posts, avg error: 2.8%

## Recommendations
⚠️ Image height calculations may need adjustment.
📸 Video height calculations may need adjustment.
```

## Visual Indicators

When "Show Visual Indicators" is enabled, posts with significant height calculation errors will show a red overlay border, making it easy to spot problematic cases while browsing.

## Performance Impact

- Validation has minimal performance impact when disabled
- When enabled, adds ~0.1ms per cell configuration
- Data is stored in memory with a 1000-entry limit
- No network requests or disk I/O during validation

## Technical Details

The system hooks into the collection view cell configuration process:

1. **Cell Configuration**: After `FeedPostRow` is configured in `UIHostingConfiguration`
2. **Layout Completion**: Waits for the cell to complete layout (`bounds.height > 0`)
3. **Height Measurement**: Captures `cell.bounds.height` as the actual height
4. **Validation**: Calls `HeightValidationManager.validateHeight()` to compare with estimate
5. **Storage**: Results stored in memory for later analysis

## Data Export

Validation results can be exported as JSON for external analysis:

```json
[
  {
    "postId": "at://did:example/app.bsky.feed.post/123",
    "estimatedHeight": 120.5,
    "actualHeight": 134.2,
    "difference": 13.7,
    "percentageError": 10.2,
    "timestamp": "2025-01-14T...",
    "feedType": "timeline",
    "hasImages": true,
    "hasVideos": false,
    "hasExternalEmbed": false,
    "hasRecordEmbed": false,
    "textLength": 89
  }
]
```

## Use Cases

### 1. Debugging Scroll Issues
If users report jumpy scrolling, enable validation to identify posts with large height estimation errors that could cause content to jump during scroll position preservation.

### 2. Performance Optimization
Accurate height estimation improves:
- Collection view performance (fewer layout passes)
- Scroll position preservation accuracy  
- Memory usage (better cell recycling)

### 3. Content Type Analysis
Identify which types of content (images, videos, threads) have the most estimation errors, helping prioritize improvements to PostHeightCalculator.

### 4. Regression Testing
Use validation data as a baseline to ensure PostHeightCalculator changes don't introduce new estimation errors.