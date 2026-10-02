# Agent instructions for Catbird (`CLAUDE.md` imports this file).

## Development Principles

- **Production-ready code only**: All code must be complete, release-quality implementations. No placeholders, fallbacks, mock implementations, or "TODO" comments. Never write speculative comments like "in a real implementation".
- **Build freely**: Builds take ~20s — verify compilation with real builds (`xcodebuild` or `XcodeBuildMCP`).
- **Full verification loop**: Build → Run → Inspect UI (`snapshot_ui` / UI tree) → Screenshot → Test.
- **No timeline estimates**: Do not predict duration or completion dates in documentation.
- **No dates in documentation**: Avoid date-based references that become stale immediately.
- **Session notes**: Place temporary fix/debug notes in `docs/session-notes/` (gitignored).
- **Keep root clean**: Never clutter repository root with ad-hoc documentation or fix files.
- **Work continuously**: Execute tasks completely to done without premature stopping.

## Project Overview

Catbird is a production-ready cross-platform Bluesky client built with SwiftUI and Swift 6 patterns, supporting iOS and macOS. Uses Petrel for AT Protocol communication, CatbirdMLSCore for MLS encrypted messaging, and shared components across platforms (~95% code sharing).

### Platform Support
- **iOS 26.0+**: Full-featured mobile client with Liquid Glass design and UIKit feed optimizations (minimum iOS 18.0+ for legacy support).
- **macOS Tahoe 26.0+**: Native macOS client with SwiftUI feed implementation and Liquid Glass (minimum macOS 13.0+ for legacy support).
- **Widgets**: `CatbirdNotificationWidget` and `CatbirdFeedWidget` (shares data via App Groups).

## Build & Test

```bash
# Build for iOS simulator
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Run tests
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

# Single test
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:CatbirdTests/<Suite>/<TestName>

# Quick syntax check
swift -frontend -parse <file.swift>

# Full typecheck with iOS SDK
swiftc -typecheck -sdk $(xcrun --show-sdk-path --sdk iphonesimulator) \
  -target arm64-apple-ios18.0 <file.swift>

# Full typecheck with macOS SDK
swiftc -typecheck -sdk $(xcrun --show-sdk-path --sdk macosx) \
  -target arm64-apple-macos13.0 <file.swift>

# Lint
swiftlint
```

### Testing
- **Frameworks**: Swift Testing (`@Test`) preferred for all new tests; XCTest for legacy suites.
- **Unit tests**: `CatbirdTests/` mirroring module paths.
- **UI tests**: `CatbirdUITests/`.
- **Tooling**: Prefer `XcodeBuildMCP` for builds/tests and `snapshot_ui` / elementRef actions for simulator automation.

## Project Structure

```
Catbird/
├── App/                    # App entry point & lifecycle
├── Core/                   # Core infrastructure
│   ├── Extensions/         # Cross-platform Swift extensions
│   ├── Models/             # Shared data models
│   ├── Navigation/         # AppNavigationManager & navigation handlers
│   ├── Networking/         # URL handling & network utilities
│   ├── Services/           # Core services (KeychainManager, ABTestingFramework)
│   ├── State/              # AppState, AuthManager, PostShadowManager, GraphManager
│   ├── UI/                 # Reusable UI components & Liquid Glass helpers
│   └── Utilities/          # Helper utilities & platform abstractions
├── Features/               # Feature modules
│   ├── Auth/               # Authentication & account switcher
│   ├── Chat/               # MLS encrypted direct messaging
│   ├── Feed/               # Timelines, FeedTuner, FeedModel, prefetching
│   ├── Media/              # Image & video handling (ImageLoadingManager, VideoAssetManager)
│   ├── Migration/          # Account data migration tools
│   ├── Moderation/         # Content moderation & filtering
│   ├── Notifications/      # Push notifications & notification list
│   ├── Profile/            # User profiles & actor details
│   ├── RepositoryBrowser/  # CAR file parsing and browsing (experimental)
│   ├── Search/             # Search functionality & discover
│   └── Settings/           # App settings & preferences
└── Resources/              # Assets, localization, and preview data
```

## Architecture & Key Patterns

### State Management
```
AppState (@Observable)
├── AuthManager (authentication & credentials)
├── PostShadowManager (Actor — thread-safe post interactions)
├── PreferencesManager (user preferences with server sync)
├── GraphManager (social graph cache)
├── NotificationManager (push notifications)
└── ABTestingFramework (A/B testing & feature experiments)
```

### Key Patterns
- **MVVM with `@Observable`**: Use the `@Observable` macro for ViewModels and state objects (NOT `ObservableObject` or Combine).
- **Actors for thread-safe state**: Use `actor` for shared mutable state like `PostShadowManager` (optimistic likes, reposts, replies).
- **Structured concurrency**: `async`/`await` throughout; adhere to Swift 6 strict concurrency.
- **NavigationHandler protocol**: Central `AppNavigationManager` coordinates type-safe destinations (`NavigationDestination`).
- **FeedTuner**: Intelligent thread consolidation and deduplication for timelines.
- **A/B Testing**: `ABTestingFramework` with type-safe `ExperimentConfig` and user bucketing.

### Feed Implementation
- **iOS**: `UICollectionView` via `FeedCollectionViewControllerIntegrated` (touch-optimized, fast scrolling, UIUpdateLink on iOS 18+).
- **macOS**: SwiftUI `List` with `FeedPostRow` components (native macOS scrolling).
- Both platforms share the underlying `FeedModel`, `FeedManager`, and `FeedPrefetchingManager`.

## Code Style

- **Indentation**: 2 spaces (not tabs).
- **Swift 6 Strict Concurrency**: All code must compile cleanly under Swift 6 strict concurrency checks.
- **State**: `@Observable` macro for observable state (avoid `ObservableObject` unless required by external APIs).
- **Actors**: Use actors for shared mutable state.
- **Async/Await**: Native Swift concurrency for all async operations.
- **Closure capture**: Explicit `self` capture semantics required by Swift 6.
- **Logging**: `OSLog` with subsystem `"blue.catbird"` or `"Catbird"` and specific categories. Never log sensitive credentials or tokens.
- **Sectioning**: Use `// MARK: - <Section>` to organize files.

## Cross-Platform Development

### Conditional Compilation
Use ViewModifier protocols or helper properties, **NEVER** inline `#if` inside modifier chains:

```swift
// CORRECT — ViewModifier abstraction
var body: some View {
  VStack {
    // content
  }
  .modifier(PlatformSpecificModifier())
}

private struct PlatformSpecificModifier: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content.navigationBarHidden(true)
    #elseif os(macOS)
    content.frame(minWidth: 480)
    #endif
  }
}

// WRONG — conditional in modifier chain
#if os(iOS)
.navigationBarHidden(true)
#elseif os(macOS)
.frame(minWidth: 480)
#endif
```

### Platform-Specific Values
Compute platform-specific values in helper functions or computed properties:

```swift
private func bottomPadding(for geometry: GeometryProxy) -> CGFloat {
  #if os(iOS)
  max(geometry.safeAreaInsets.bottom, 24)
  #else
  24
  #endif
}
```

### Availability Annotations
Always include both platforms in `@available`:
```swift
@available(iOS 26.0, macOS 26.0, *)
```

### Platform Utilities (`Core/Extensions/`)
- `CrossPlatformImage.swift`: Unified cross-platform image representation (`UIImage` / `NSImage`).
- `CrossPlatformUI.swift`: Shared UI pattern aliases and color bridges.
- `PlatformColors.swift`: Semantic platform color definitions.
- `PlatformDeviceInfo.swift`: Idiom, model, and device capability detection.
- `PlatformHaptics.swift`: Haptic feedback abstraction (no-op on macOS).
- `PlatformScreenInfo.swift`: Screen metrics, scale, and safe area helpers.
- `PlatformSystem.swift`: System integration utilities.

## Liquid Glass (iOS 26 & macOS Tahoe 26)

Liquid Glass is the standard translucent material design system for controls, navigation, and overlays.

### Key APIs
- `.glassEffect()`: Apply regular, clear, or interactive glass to any view (`.glassEffect(.regular.interactive())`).
- `GlassEffectContainer`: Group multiple glass views for batch rendering and optimal performance.
- `.glassEffectUnion(id:namespace:)`: Merge adjacent glass views into a unified fluid glass shape.
- `.glassEffectID(_:in:)`: Morphing transitions between glass elements across state changes.
- **Automatic adoption**: Standard SwiftUI navigation bars, tab bars, sidebars, sheets, and controls adopt Liquid Glass automatically.
- **Custom backgrounds**: Remove legacy `Material.ultraThinMaterial` / `Material.regularMaterial` backgrounds in favor of automatic adoption or `.glassEffect()`.
- **Accessibility**: Always verify layouts with "Reduce Transparency" and "Reduce Motion" enabled.

## Key Components & Subsystems

- **AuthManager & KeychainManager**: Keychain credentials, OAuth PKCE + legacy authentication, DPoP key management, automatic token refresh.
- **FeedModel & FeedManager**: Observable timeline pagination, cursor tracking, `FeedTuner` thread consolidation, and `FeedPrefetchingManager`.
- **PostShadowManager** (Actor): Thread-safe optimistic post state (likes, reposts, thread replies) synced with server.
- **Media Managers**: `ImageLoadingManager` for pipeline prefetching and caching; `VideoAssetManager` for video playback caching.
- **AppNavigationManager**: Central coordinator for stack, tab, and split-view navigation.
- **AT Protocol**: Models generated in `Petrel/Sources/Petrel/Generated/`. All network requests use `ATProtoClient` via async/await.
- **Experimental Features**: CAR file repository browser and account data migration tools managed by `ExperimentalFeaturesCoordinator` (Settings > Advanced > Experimental Features).

## Debugging

- **Network logging**: `ATProtoClient` logs all requests and responses via OSLog.
- **Console filtering**: Filter Console.app / log streams by subsystem `"Catbird"` or category.
- **Performance profiling**: Use Xcode Instruments (Time Profiler, Allocations) to check for retain cycles (`[weak self]`), excessive SwiftUI redraws, and view body evaluation overhead.
