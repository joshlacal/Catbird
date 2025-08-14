# iOS 18+ Enhanced Feed State Restoration System

This document describes the enhanced state restoration system implemented to fix feed state suspension issues in Catbird. The system provides seamless integration between SwiftUI's @Observable pattern and UIKit state restoration.

## Architecture Overview

### Core Components

1. **FeedStateStore** - Enhanced with proper ScenePhase integration
2. **FeedStateManager** - Coordinated lifecycle management with scene phases
3. **FeedCollectionViewControllerIntegrated** - UIKit controller with unified state restoration
4. **iOS18StateRestorationCoordinator** - Coordinates state restoration between SwiftUI and UIKit
5. **EnhancedFeedPersistenceManager** - Intelligent caching and persistence

## Key Features

### 1. Unified Lifecycle Management

- **SwiftUI Scene Phase**: Primary lifecycle coordination through `@Environment(\.scenePhase)`
- **UIKit Notifications**: Secondary support for granular timing control
- **Coordinated Transitions**: Prevents conflicts between SwiftUI and UIKit lifecycle events

### 2. Intelligent Refresh Logic

```swift
// Background duration-based refresh strategy
if backgroundDuration > 1800 { // 30 minutes - full refresh
    await performSmartRefreshForAllFeeds()
} else if backgroundDuration > 600 { // 10 minutes - content check
    await checkForNewContentNonDisruptive()
} else { // < 10 minutes - preserve state
    await restoreExistingStateWithoutRefresh()
}
```

### 3. Enhanced Persistence

- **Memory Cache**: Immediate state restoration
- **Disk Persistence**: Survives app termination
- **Smart Expiration**: Age-based cache invalidation
- **Metadata Tracking**: User agent and timestamp tracking

### 4. Scroll Position Preservation

- **Pixel-Perfect Restoration**: Maintains exact scroll position
- **Viewport-Relative Positioning**: Accounts for safe area changes
- **Fallback Strategies**: Graceful degradation for missing anchors

## Implementation Details

### Scene Phase Integration

```swift
// FeedView.swift
.onChange(of: scenePhase) { oldPhase, newPhase in
    Task { @MainActor in
        await feedStateStore.handleScenePhaseChange(newPhase)
    }
}
```

### UIKit Controller Registration

```swift
// Automatic registration with coordinator
if #available(iOS 18.0, *) {
    let identifier = "feed_controller_\(stateManager.currentFeedType.identifier)"
    iOS18StateRestorationCoordinator.shared.registerController(self, identifier: identifier)
}
```

### State Restoration Flow

1. **App Enters Background**:
   - Scene phase → `.background`
   - Save all feed states with metadata
   - Capture precise scroll positions
   - Cancel ongoing network operations

2. **App Returns to Foreground**:
   - Scene phase → `.active`
   - Calculate background duration
   - Apply intelligent refresh logic
   - Restore scroll positions

3. **Temporary Inactive States**:
   - Scene phase → `.inactive`
   - Proactive state saving
   - Prepare for potential backgrounding
   - No network interruption

## Usage

### Basic Integration

Apply the restoration support modifier to feed views:

```swift
FeedWithNewPostsIndicator(
    stateManager: stateManager,
    navigationPath: $path
)
.modifier(iOS18StateRestorationSupport(feedType: fetch))
```

### Advanced Configuration

```swift
// Enable coordinated restoration for custom views
.coordinatedStateRestoration(enabled: true)
```

## Performance Optimizations

### 1. Batch Operations

- Parallel state saving for multiple feeds
- Asynchronous disk persistence
- Non-blocking cache operations

### 2. Intelligent Caching

- Memory cache for immediate restoration
- Disk cache for app termination recovery
- Automatic cleanup of expired entries

### 3. Network Optimization

- Prevents unnecessary refreshes for short backgrounds
- Smart content checking for medium durations
- Full refresh only for extended backgrounds

## Debugging

### Enable Detailed Logging

The system provides comprehensive logging for debugging:

- **Scene Phase Transitions**: `🎭 Scene phase coordination`
- **State Persistence**: `💾 Enhanced save completed`
- **Restoration Events**: `🔄 Starting coordinated restoration`
- **UIKit Coordination**: `📱 UIKit: App entering background`

### Cache Statistics

```swift
let stats = EnhancedFeedPersistenceManager.shared.getCacheStatistics()
print("Memory entries: \(stats.memoryEntries), Average age: \(stats.averageAge)s")
```

## Testing

### State Restoration Testing

1. **Background/Foreground Cycle**:
   - Open feed and scroll to specific position
   - Background app (Home button)
   - Return to app
   - Verify exact position restoration

2. **Extended Background**:
   - Leave app in background for 15+ minutes
   - Return to app
   - Verify intelligent refresh behavior

3. **App Termination**:
   - Force quit app
   - Relaunch app
   - Verify state restoration from disk cache

## Migration from Legacy System

The enhanced system is backward compatible and automatically migrates existing persisted positions:

```swift
// Automatic migration on first run
FeedScrollPositionMigrator.migrateIfNeeded()
```

## Troubleshooting

### Common Issues

1. **Double Restoration**: Ensure only scene phase handlers trigger restoration
2. **Stale Cache**: Check cache expiration times and cleanup intervals
3. **Memory Leaks**: Verify weak references in controller registration

### Performance Monitoring

Monitor restoration performance using Instruments:
- **Time Profiler**: Measure restoration timing
- **Allocations**: Check for memory leaks
- **Energy Log**: Monitor background activity

## Future Enhancements

- **Machine Learning**: Predict optimal refresh timing based on user behavior
- **Network Awareness**: Adapt refresh strategy based on connection quality
- **Multi-Window Support**: Extend coordination to multiple scenes
- **Widget Integration**: Coordinate with widget timeline updates

## Compatibility

- **iOS 18.0+**: Full feature support with enhanced coordination
- **iOS 16.0+**: Basic state restoration with UIKit notifications
- **iOS 15.0+**: Legacy fallback with limited restoration capabilities