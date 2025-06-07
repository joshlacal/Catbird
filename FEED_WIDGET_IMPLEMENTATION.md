# Catbird Feed Widget Implementation

## Overview
The Catbird Feed Widget displays recent Bluesky posts directly on the user's home screen. Users can configure which feed to display and customize the appearance.

## Features
- **Feed Selection**: Choose between Timeline, Discover, What's Hot, or Custom feeds
- **Multiple Widget Sizes**: Supports small, medium, large, and extra large widgets
- **Post Display**: Shows author, text, engagement stats, and image indicators
- **Configuration Options**:
  - Feed type selection
  - Number of posts to display (1-10)
  - Show/hide image indicators
- **Data Sharing**: Syncs with main app via App Groups

## Implementation Details

### New Files Created
1. **CatbirdFeedWidget/FeedWidgetModels.swift** - Shared data models for widget posts
2. **Catbird/Features/Feed/Services/FeedWidgetDataProvider.swift** - Service to manage widget data

### Modified Files
1. **CatbirdFeedWidget/AppIntent.swift** - Updated with feed selection configuration
2. **CatbirdFeedWidget/CatbirdFeedWidget.swift** - Complete widget implementation
3. **Catbird/Features/Feed/Models/FeedModel.swift** - Integrated widget data updates
4. **CatbirdFeedWidget/CatbirdFeedWidget.entitlements** - Added app group entitlement

### Widget Sizes and Layouts
- **Small**: Shows single post with compact stats
- **Medium**: Shows featured post with header
- **Large**: Shows up to 3 posts with dividers
- **Extra Large**: Shows all posts with scrolling

### Data Flow
1. Main app loads feed data via FeedModel
2. FeedWidgetDataProvider converts posts to widget format
3. Data saved to shared UserDefaults (group.blue.catbird.shared)
4. Widget loads data and displays posts
5. Widget refreshes every 15 minutes

### Deep Linking
Tapping the widget opens the app to the corresponding feed:
- URL format: `blue.catbird://feed/{feedType}`

## Usage Instructions

### For Users
1. Long press on home screen and tap "+"
2. Search for "Catbird" 
3. Select "Bluesky Feed" widget
4. Choose widget size
5. Add to home screen
6. Long press widget and select "Edit Widget" to configure:
   - Feed Type (Timeline, Discover, What's Hot, Custom)
   - Number of Posts (1-10)
   - Show Images toggle

### For Developers
To update widget data from the app:
```swift
// In any feed loading context
FeedWidgetDataProvider.shared.updateWidgetData(from: posts, feedType: fetchType)

// To clear widget data
FeedWidgetDataProvider.shared.clearWidgetData()
```

## Testing
1. Build and run the main Catbird app
2. Load some feed data by browsing feeds
3. Add widget to home screen
4. Verify posts appear in widget
5. Test different widget sizes
6. Test configuration options
7. Test deep linking by tapping widget

## Notes
- Widget data persists between app launches
- Placeholder data shown when no real data available
- Widget updates automatically when app loads new feed data
- Performance optimized by limiting to 10 most recent posts