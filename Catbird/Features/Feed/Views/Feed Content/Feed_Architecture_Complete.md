# Catbird Feed Architecture - Complete Documentation

## Overview

The Catbird feed system is a sophisticated hybrid SwiftUI/UIKit architecture designed to provide native performance with modern reactive data management. Unlike the issues described in the previous documentation, the current implementation successfully combines SwiftUI's declarative data flow with UIKit's performant collection view rendering.

## Architecture Layers

### 1. Data Layer (SwiftUI + Observable)

#### FeedModel (`/Models/FeedModel.swift`)
The core data management layer using Swift 6's `@Observable` macro:

```swift
@Observable
final class FeedModel: StateInvalidationSubscriber {
    // Core properties
    @MainActor var posts: [CachedFeedViewPost] = []
    @MainActor private(set) var isLoading = false
    @MainActor private(set) var cursor: String?
    
    // Key responsibilities:
    // - Manages feed data lifecycle
    // - Handles pagination with cursor-based loading
    // - Applies filters via FeedTuner
    // - Responds to state invalidation events
    // - Caches data for offline/fast loading
}
```

**Key Features:**
- **Single Source of Truth**: One FeedModel instance per feed type via FeedModelContainer
- **Reactive Updates**: Uses @Observable for automatic SwiftUI updates
- **Smart Loading Strategies**: `fullRefresh`, `backgroundRefresh`, `loadIfNeeded`
- **State Invalidation**: Subscribes to app-wide events (post creation, auth changes, etc.)

#### FeedModelContainer (`/Models/FeedModelContainer.swift`)
Singleton that manages FeedModel instances:
- Prevents duplicate models for the same feed
- Reuses existing models when switching feeds
- Ensures consistent data across views

### 2. Network Layer

#### FeedManager (`/Services/FeedManager.swift`)
Simple, focused network layer:

```swift
final class FeedManager {
    func fetchFeed(fetchType: FetchType, cursor: String?) 
        async throws -> ([AppBskyFeedDefs.FeedViewPost], String?)
}
```

**Supported Feed Types:**
- `timeline` - Home timeline
- `list(listUri)` - List-based feeds
- `feed(generatorUri)` - Custom algorithm feeds
- `author(did)` - User profile feeds
- `likes(did)` - User's liked posts

### 3. Post Processing Layer

#### FeedTuner (`/Services/FeedTuner.swift`)
Sophisticated post processing engine that:

```swift
final class FeedTuner {
    func tune(_ rawPosts: [AppBskyFeedDefs.FeedViewPost], 
              filterSettings: FeedTunerSettings) -> [FeedSlice]
}
```

**Processing Pipeline:**
1. **Content Filtering**:
   - Muted/blocked users
   - Language preferences
   - Reply/repost/quote post filters
   - Unfollowed user replies

2. **Thread Consolidation**:
   - Groups related posts into FeedSlice structures
   - Preserves reply context (parent/root posts)
   - Marks incomplete threads
   - Prevents duplicate posts

3. **Slice Structure**:
```swift
struct FeedSlice {
    let items: [FeedSliceItem]  // Thread posts in order
    let isIncompleteThread: Bool
    let rootUri: String
    let reason: FeedViewPostReasonUnion? // Repost info
}
```

### 4. View Layer (SwiftUI)

#### FeedView (`/Views/FeedView.swift`)
Main SwiftUI view that orchestrates the feed:

```swift
struct FeedView: View {
    @State private var feedModel: FeedModel?
    
    var body: some View {
        if let model = feedModel {
            contentView(model: model)
        }
    }
    
    private func contentView(model: FeedModel) -> some View {
        let filteredPosts = model.applyFilters(withSettings: appState.feedFilterSettings)
        
        return NativeFeedContentView(
            posts: filteredPosts,
            appState: appState,
            path: $path,
            loadMoreAction: { await model.loadMore() },
            refreshAction: { await model.loadFeed() },
            feedType: fetch,
            onScrollOffsetChanged: { offset in
                scrollOffset = offset
            }
        )
    }
}
```

**Key Responsibilities:**
- Creates/manages FeedModel via FeedModelContainer
- Applies filters to get display-ready posts
- Passes reactive data to UIKit layer
- Handles loading/error/empty states

### 5. UIKit Display Layer

#### FeedViewController (`/Views/UIKitFeedView.swift`)
Native UICollectionViewController for performance:

```swift
@available(iOS 18.0, *)
final class FeedViewController: UICollectionViewController {
    private var posts: [CachedFeedViewPost] = []
    private let scrollTracker = ScrollPositionTracker()
    
    @MainActor
    func loadPostsDirectly(_ posts: [CachedFeedViewPost]) async {
        await updateDataWithPositionPreservation(posts, insertAt: .replace)
    }
}
```

**Advanced Features:**
- **Scroll Position Preservation**: Maintains position during updates
- **Smart Refresh**: Shows new post indicators without disrupting reading
- **Native Performance**: UICollectionView with compositional layout
- **Prefetching**: Preloads images and data for smooth scrolling

#### Key Components:

1. **ScrollPositionTracker**: Captures and restores scroll position
2. **FeedCompositionalLayout**: Custom layout with position preservation
3. **Cell Types**:
   - `FeedHeaderCell`: Optional feed headers
   - `FeedPostCell`: SwiftUI content in UICollectionViewCell
   - `LoadMoreIndicatorCell`: Pagination indicator

### 6. SwiftUI-UIKit Bridge

#### NativeFeedContentView & NativeFeedViewControllerRepresentable
The bridge between SwiftUI data and UIKit display:

```swift
struct NativeFeedContentView: View {
    let posts: [CachedFeedViewPost]
    
    var body: some View {
        NativeFeedViewControllerRepresentable(
            posts: posts,
            appState: appState,
            fetchType: feedType,
            path: $path,
            loadMoreAction: loadMoreAction,
            refreshAction: refreshAction
        )
    }
}

struct NativeFeedViewControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> FeedViewController {
        let controller = FeedViewController(...)
        Task { @MainActor in
            await controller.loadPostsDirectly(posts)
        }
        return controller
    }
    
    func updateUIViewController(_ uiViewController: FeedViewController, context: Context) {
        Task { @MainActor in
            await uiViewController.loadPostsDirectly(posts)
        }
    }
}
```

## Data Flow Architecture

### Initial Load Flow

```
1. FeedView.onAppear
   ↓
2. FeedModelContainer.getModel(for: fetchType)
   ↓
3. FeedModel.loadFeed()
   ↓
4. FeedManager.fetchFeed() → Network API
   ↓
5. FeedTuner.tune() → Process posts into slices
   ↓
6. FeedModel.posts = processed posts
   ↓
7. FeedView re-renders (Observable)
   ↓
8. NativeFeedContentView passes posts to UIKit
   ↓
9. FeedViewController.loadPostsDirectly()
   ↓
10. UICollectionView displays posts
```

### Update Flow (Pull-to-refresh)

```
1. User pulls to refresh in UICollectionView
   ↓
2. FeedViewController.handlePullToRefresh()
   ↓
3. Captures scroll position
   ↓
4. Calls refreshAction from SwiftUI
   ↓
5. FeedModel.loadFeed(strategy: .fullRefresh)
   ↓
6. New posts processed through FeedTuner
   ↓
7. SwiftUI detects @Observable change
   ↓
8. NativeFeedViewControllerRepresentable.updateUIViewController()
   ↓
9. FeedViewController updates with position preservation
   ↓
10. Shows new posts indicator if needed
```

## Key Design Decisions

### 1. Hybrid Architecture Benefits
- **SwiftUI**: Declarative data management, reactive updates
- **UIKit**: Native scrolling performance, precise control
- **Best of Both**: Modern patterns with proven performance

### 2. FeedTuner Thread Processing
Mirrors Bluesky's React Native implementation:
- Groups posts by root thread URI
- Preserves conversation context
- Prevents duplicate display
- Marks incomplete threads

### 3. Smart Position Preservation
- Captures visible post anchors before updates
- Calculates content height changes
- Restores position after data changes
- Prevents jarring scroll jumps

### 4. Filtering Architecture
Two-stage filtering:
1. **FeedTuner**: Content filtering during processing
2. **FeedModel.applyFilters()**: UI-level filtering

### 5. State Invalidation System
Central event bus for app-wide coordination:
- Post creation immediately appears in timeline
- Authentication changes trigger reloads
- Social graph updates (mute/block) refilter content

## Performance Optimizations

1. **Cached Data Loading**:
   - Shows cached posts immediately
   - Refreshes in background if needed
   - Smooth transition to new data

2. **Prefetching**:
   - Images preloaded via FeedPrefetchingManager
   - Next page prefetched before needed
   - Video assets cached by VideoAssetManager

3. **Debounced Updates**:
   - 150ms debounce on rapid data changes
   - Prevents scroll position thrashing
   - Batches multiple updates

4. **Smart Refresh**:
   - Background refresh doesn't disrupt reading
   - Only replaces data if significant changes
   - Shows indicators for new content

## Navigation Integration

The UIKit layer integrates seamlessly with SwiftUI navigation:
- Collection view supports large title collapse
- Scroll offset reported to SwiftUI for nav bar
- Tab tap scrolls to top via AppState coordination

## Widget Integration

FeedModel updates widget data:
```swift
FeedWidgetDataProvider.shared.updateWidgetData(from: posts, feedType: fetch)
```

## Error Handling

Graceful degradation at each layer:
- Network errors shown in UI
- Cached data used as fallback
- Empty states for no content
- Loading states during operations

## Comparison to Previous Issues

The previous documentation mentioned:
- ❌ "Loading feed..." stuck state
- ❌ Duplicate FeedModel instances
- ❌ Non-reactive data passing

**All these issues are resolved:**
- ✅ Direct data flow from FeedModel to UIKit
- ✅ Single FeedModel instance per feed
- ✅ Reactive updates via @Observable
- ✅ Proper SwiftUI-UIKit integration

## Dead/Unused Code

Some legacy components exist but aren't used:
- `FeedLoadingCoordinator` - Intended for complex loading states
- `FullUIKitNavigationWrapper` - Alternative nav approach
- Various "smart" coordinators - Placeholders for future features

These don't affect the core feed functionality and could be removed in cleanup.

## Summary

The Catbird feed architecture successfully combines:
- Modern Swift 6 patterns (@Observable, actors)
- Proven UIKit performance (UICollectionView)
- Sophisticated post processing (FeedTuner)
- Seamless SwiftUI integration
- Production-ready error handling

The architecture is well-designed for a release-ready application, providing smooth scrolling, instant cached data display, and intelligent thread grouping that matches user expectations from the official Bluesky app.