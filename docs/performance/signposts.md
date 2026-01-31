# Performance Signposts

This document describes the signpost instrumentation available in Catbird for profiling with Instruments.

## Overview

We use two signpost systems:
1. **MetricKitSignposts** — For production metrics (MetricKit daily reports)
2. **PerformanceSignposts** — For development profiling (visible in Instruments)

## Available Signposts

### Feed Operations

| Signpost | Category | Description |
|----------|----------|-------------|
| `FeedLoad` | Feed | Feed fetch start/end with post count |
| `Scroll` | Feed | Scroll session tracking |
| `ScrollFrame` | Feed | Per-frame FPS events |

### Cell Configuration

| Signpost | Category | Description |
|----------|----------|-------------|
| `CellConfig` | Cell | UICollectionView cell configuration time |

### Image Loading

| Signpost | Category | Description |
|----------|----------|-------------|
| `ImageLoad` | Image | Image load with cache hit/miss and bytes |
| `CacheHit` | Image | Instant event for cache hits |
| `CacheMiss` | Image | Instant event for cache misses |

### Navigation

| Signpost | Category | Description |
|----------|----------|-------------|
| `Navigation` | Navigation | Push/pop timing |
| `TabSwitch` | Navigation | Tab change events |

### MLS Operations

| Signpost | Category | Description |
|----------|----------|-------------|
| `MLSOperation` | MLS | Generic MLS operation |
| `MLSDecrypt` | MLS | Message decryption with count |
| `MLSEncrypt` | MLS | Message encryption |

### Network

| Signpost | Category | Description |
|----------|----------|-------------|
| `NetworkRequest` | Network | API request with method, endpoint, status |

### Threads

| Signpost | Category | Description |
|----------|----------|-------------|
| `ThreadLoad` | Thread | Thread view load with reply count |

## Viewing in Instruments

1. Build and run the app
2. Open Instruments and attach to the running app
3. Use the **Time Profiler** or **os_signpost** instrument
4. Look for `blue.catbird.performance` subsystem

### Categories

- `blue.catbird.performance.Feed`
- `blue.catbird.performance.Cell`
- `blue.catbird.performance.Image`
- `blue.catbird.performance.Navigation`
- `blue.catbird.performance.MLS`
- `blue.catbird.performance.Network`
- `blue.catbird.performance.Thread`

## Usage Examples

```swift
// Track feed loading
let id = PerformanceSignposts.beginFeedLoad(feedName: "Following")
let posts = try await fetchFeed()
PerformanceSignposts.endFeedLoad(id: id, postCount: posts.count, success: true)

// Track cell configuration (inline)
PerformanceSignposts.trackCellConfiguration(postId: post.id) {
  configureCell(cell, with: post)
}

// Track navigation
let navId = PerformanceSignposts.beginNavigation(destination: "ProfileView")
// ... navigation happens ...
PerformanceSignposts.endNavigation(id: navId)

// Single event (not an interval)
PerformanceSignposts.tabSwitch(from: "Feed", to: "Search")
```

## Files

- `Catbird/Core/Telemetry/PerformanceSignposts.swift` — Development signposts (os_signpost)
- `Catbird/Core/Telemetry/MetricKitSignposts.swift` — Production signposts (MetricKit)
