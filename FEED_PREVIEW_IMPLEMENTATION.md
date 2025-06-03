# Feed Preview Implementation Plan

## Overview
Users need to see what content a feed contains before subscribing. This requires implementing live feed previews throughout the discovery experience.

## Core Components

### 1. Feed Preview Data Model
```swift
struct FeedPreview {
    let feed: AppBskyFeedDefs.GeneratorView
    let recentPosts: [AppBskyFeedDefs.FeedViewPost]
    let isLoading: Bool
    let error: String?
}
```

### 2. FeedPreviewService
- Fetches recent posts from a feed without subscribing
- Caches preview data for performance
- Handles rate limiting and errors gracefully

```swift
class FeedPreviewService {
    func fetchPreview(for feedURI: ATProtocolURI) async throws -> [AppBskyFeedDefs.FeedViewPost] {
        // Use getFeed API with limit of 10-15 posts
        // Cache results for 5 minutes
    }
}
```

### 3. UI Components

#### A. Inline Feed Preview (in discovery list)
```swift
struct FeedPreviewRow: View {
    // Shows 3-5 mini post cards horizontally scrollable
    // Tap to expand to full preview
    // Quick subscribe button
}
```

#### B. Full Feed Preview Sheet
```swift
struct FeedPreviewSheet: View {
    // Full-height sheet with:
    // - Feed header with stats
    // - Scrollable list of recent posts (10-20)
    // - Sticky subscribe button at bottom
    // - Pull to refresh
}
```

#### C. Swipeable Feed Cards
```swift
struct FeedDiscoveryCards: View {
    // TikTok-style vertical feed browser
    // Each card shows:
    // - Feed info header
    // - 2-3 sample posts
    // - Swipe up for next feed
    // - Swipe right to subscribe
    // - Swipe left to skip
}
```

## Implementation Phases

### Phase 1: Basic Preview (1-2 days)
- [ ] Create FeedPreviewService
- [ ] Add preview to existing FeedDiscoveryHeaderView
- [ ] Show 3-5 recent post titles/snippets
- [ ] Loading states and error handling

### Phase 2: Rich Preview Sheet (2-3 days)
- [ ] Full preview sheet with actual posts
- [ ] Render posts using existing PostView components
- [ ] Statistics (post frequency, likes, etc.)
- [ ] Subscribe/unsubscribe from preview

### Phase 3: Swipeable Discovery (3-4 days)
- [ ] Card-based feed browser
- [ ] Gesture handling for swipes
- [ ] Animations and transitions
- [ ] Onboarding overlay

### Phase 4: Smart Recommendations (2-3 days)
- [ ] Interest-based feed ranking
- [ ] "Because you follow X" explanations
- [ ] Trending feeds section
- [ ] Personalized feed suggestions

## API Requirements

### Existing APIs to Use
1. `app.bsky.feed.getFeed` - Get posts from a feed
2. `app.bsky.feed.getFeedGenerators` - Get feed metadata
3. `app.bsky.unspecced.getPopularFeedGenerators` - Discover feeds

### New Data Needed
- Feed post frequency/activity level
- Feed subscriber count trends
- Content categories/tags

## UI/UX Considerations

### Preview Quality
- Show diverse content (not just latest posts)
- Include different post types (text, images, links)
- Highlight what makes the feed unique

### Performance
- Lazy load previews as user scrolls
- Prefetch next feed in swipe view
- Cache preview data aggressively
- Show skeletons while loading

### Accessibility
- VoiceOver descriptions for feed content
- Reduce motion option for swipe interface
- High contrast mode support
- Text size scaling

## Mock Implementation

```swift
// In FeedDiscoveryHeaderView
struct FeedDiscoveryHeaderView: View {
    @State private var previewPosts: [AppBskyFeedDefs.FeedViewPost] = []
    @State private var isLoadingPreview = false
    @State private var showFullPreview = false
    
    var body: some View {
        VStack {
            // Existing header content...
            
            // New preview section
            if !previewPosts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent posts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(previewPosts.prefix(5), id: \.post.uri) { post in
                                MiniPostCard(post: post)
                                    .frame(width: 200)
                            }
                        }
                    }
                    
                    Button("See all posts") {
                        showFullPreview = true
                    }
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
                .padding(.vertical, 8)
            }
        }
        .task {
            await loadPreview()
        }
        .sheet(isPresented: $showFullPreview) {
            FeedPreviewSheet(feed: feed, posts: previewPosts)
        }
    }
}
```

## Success Metrics
- Increased feed subscription rate
- Reduced unsubscribe rate within 24 hours
- Higher engagement with discovered feeds
- Positive user feedback on discovery experience

## Technical Debt to Address
- Current AddFeedSheet is too basic
- No preview capability in existing code
- Need to refactor feed discovery architecture
- Performance optimization for preview loading