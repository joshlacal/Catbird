# Scroll Position Preservation Fixes

## Issues Identified from Logs

1. **UIUpdateLink Timeouts**: `⏰ UIUpdateLink timeout, applying fallback`
   - UIUpdateLink was timing out after 50ms, causing fallback to less precise method
   - Solution: Increased timeout to 100ms and improved fallback synchronization

2. **Large Offset Changes**: `⚠️ Large unexpected scroll offset change: 241.333333px`
   - Anchor calculations were sometimes inaccurate due to poor height estimation
   - Solution: Use average height from multiple visible items for better accuracy

3. **Redundant Operations**: Multiple gap loading operations triggering simultaneously
   - Background refresh was called multiple times causing interference
   - Solution: Added debouncing and better condition checks

4. **Poor Error Recovery**: Recovery logic was too aggressive
   - Was interfering with legitimate offset changes during anchor restoration
   - Solution: More targeted recovery only for extreme position loss cases

## Key Improvements Made

### 1. Enhanced Anchor Capture (`captureMostReliableAnchor`)
- Analyzes visibility scores of all items in viewport
- Prioritizes items with >50% visibility  
- Chooses anchors closer to viewport center
- Prevents using partially visible items as anchors

### 2. Reliable Synchronized Restoration
- Replaced unreliable UIUpdateLink approach with CATransaction-based synchronization
- Uses completion blocks to ensure proper timing
- Applies pixel-perfect alignment with display scale correction
- Enhanced fallback mechanism with better error handling

### 3. Improved Offset Calculations
- Uses average height from multiple visible items (not just one)
- Better bounds checking with actual vs estimated content size
- More accurate viewport-relative positioning
- Enhanced debugging logs for troubleshooting

### 4. Smart Update Debouncing  
- Prevents rapid consecutive updates (100ms minimum interval)
- Always allows user-initiated refreshes through
- Reduces interference from background gap loading

### 5. Targeted Error Recovery
- Only recovers from extreme position loss (>500px jumps)
- Doesn't interfere with legitimate anchor restoration
- Better logging to identify root causes

## Expected Results

✅ **Eliminated UIUpdateLink timeouts** - More reliable synchronization method
✅ **Consistent scroll restoration** - Better anchor selection and calculations  
✅ **Reduced "jank"** - Fewer correction attempts and smoother transitions
✅ **Better debugging** - Enhanced logging for troubleshooting issues
✅ **Prevented redundant operations** - Smart debouncing and condition checks

## Testing Recommendations

1. **Pull-to-refresh from various positions**
   - Top of feed (should show large title after refresh if no new content)
   - Middle of feed (should maintain exact position)
   - During active scrolling

2. **Load more scenarios**
   - While scrolled down in middle of feed
   - Rapid scroll to bottom triggering multiple loads

3. **Background refresh scenarios**  
   - App backgrounded/foregrounded during refresh
   - Network delays during refresh operations

4. **Edge cases**
   - Very small feeds (< 5 items)
   - Mixed content heights (images, text-only, etc.)
   - Rapid feed switching

The improvements focus on the root timing and calculation issues while providing better error recovery and debugging capabilities.