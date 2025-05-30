# Feed Headers Implementation Plan

## Overview
Implement feed headers for unsubscribed feeds in discovery/exploration contexts to help users understand and subscribe to feeds.

## Requirements

### When to Show Feed Headers
1. **Search Results** - When feeds appear in search
2. **Feeds Start Page** - When browsing available feeds
3. **Feed Links** - When following links to feed generators
4. **Add Feed Sheet** - When exploring feeds to add

### When NOT to Show Feed Headers
- Main timeline/feed view (already subscribed)
- User's own feed list

## Feed Header Components

### Essential Information
```swift
struct FeedHeaderView: View {
    let feed: FeedGeneratorView
    let isSubscribed: Bool
    @State private var showingDescription = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row
            HStack(alignment: .top, spacing: 12) {
                // Feed Avatar
                AsyncImage(url: feed.avatar) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                // Feed Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(feed.displayName)
                        .font(.headline)
                    
                    Text("by @\(feed.creator.handle)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if let likeCount = feed.likeCount {
                        HStack(spacing: 16) {
                            Label("\(likeCount)", systemImage: "heart")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Subscribe Button
                Button(action: { toggleSubscription() }) {
                    Text(isSubscribed ? "Subscribed" : "Subscribe")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(isSubscribed ? .primary : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            isSubscribed ? 
                            Color.gray.opacity(0.2) : 
                            Color.accentColor
                        )
                        .clipShape(Capsule())
                }
            }
            
            // Description (expandable)
            if let description = feed.description {
                VStack(alignment: .leading, spacing: 8) {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(showingDescription ? nil : 2)
                        .animation(.easeInOut, value: showingDescription)
                    
                    if description.count > 100 {
                        Button(action: { showingDescription.toggle() }) {
                            Text(showingDescription ? "Show less" : "Show more")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            
            // Action Row
            HStack(spacing: 20) {
                Button(action: { shareFeed() }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Button(action: { reportFeed() }) {
                    Label("Report", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

## Implementation Locations

### 1. Search Results (RefinedSearchView)
- Add feed headers to feed search results
- Show subscribe button inline
- Compact view for search context

### 2. Feeds Start Page
- Unified feed discovery experience
- Full header with description
- Categories/filters for feeds

### 3. Feed Links Navigation
- When navigating to a feed from external link
- Show header before feed content
- Prominent subscribe action

### 4. Add Feed Sheet
- Enhanced feed browser
- Preview of feed content
- Batch subscribe options

## UI/UX Considerations

### Visual Hierarchy
1. Feed avatar and name most prominent
2. Creator handle secondary
3. Stats (likes, subscribers) tertiary
4. Description expandable to avoid clutter

### Actions
- **Primary**: Subscribe/Unsubscribe
- **Secondary**: Share, Report
- **Contextual**: Preview feed content

### State Management
```swift
// In FeedManager
func getFeedInfo(_ uri: String) async throws -> FeedGeneratorView
func isSubscribed(to uri: String) -> Bool
func toggleSubscription(for uri: String) async throws
```

## Unified Feed Discovery

### FeedsStartPage Improvements
1. **Categories**
   - Popular
   - New
   - By Topic
   - By Language
   
2. **Search & Filter**
   - Search feeds by name
   - Filter by creator
   - Sort options
   
3. **Preview Mode**
   - Show sample posts from feed
   - "Try before subscribe"

## Technical Implementation

### Feed Header Component Usage
```swift
// In search results
ForEach(searchResults.feeds) { feed in
    FeedHeaderView(
        feed: feed,
        isSubscribed: feedManager.isSubscribed(to: feed.uri)
    )
}

// In feed view when not subscribed
if !feedManager.isSubscribed(to: feedURI) {
    FeedHeaderView(
        feed: feedInfo,
        isSubscribed: false
    )
    .padding(.horizontal)
}
```

### Navigation Integration
```swift
// Handle feed navigation
case .feed(let uri):
    FeedView(uri: uri)
        .task {
            // Load feed info for header if needed
            if !feedManager.isSubscribed(to: uri) {
                feedInfo = try? await feedManager.getFeedInfo(uri)
            }
        }
```

## Worktree Assignment

This work should be done in the **feature-feed-improvements** worktree as it's part of the feed enhancement tasks:

```bash
git worktree add ~/Developer/Catbird-Worktrees/feature-feed-improvements -b feature/feed-improvements
```

## Success Metrics

1. Users can easily understand what a feed is about
2. Subscribe action is prominent and accessible
3. Feed discovery is intuitive
4. Consistent header appearance across contexts
5. No headers shown for already-subscribed feeds in main view
