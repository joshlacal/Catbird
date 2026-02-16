# Catbird iOS Client

## Development Principles

- **Build freely**: Verify code compilation.
- **Full verification loop**: Build -> Run -> describe_ui -> Screenshot -> Test
- **No timeline estimates** in documentation
- **Session notes**: Place temporary docs in `docs/session-notes/` (gitignored)
- **Production-ready code only**: No placeholders, fallbacks, or TODO comments

## Project Overview

Catbird is a cross-platform Bluesky client built with SwiftUI, supporting iOS 18+ and macOS 13+. Uses Petrel for AT Protocol communication and CatbirdMLSCore for MLS encrypted messaging.

### Platform Support
- **iOS 26.0+**: Full featured with Liquid Glass design (minimum iOS 18.0+)
- **macOS Tahoe 26.0+**: Native macOS with SwiftUI feed (minimum macOS 13.0+)
- ~95% code sharing between platforms using conditional compilation

## Build & Test

```bash
# Build for simulator
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Run tests
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

# Quick syntax check
swift -frontend -parse <file.swift>

# Full typecheck with iOS SDK
swiftc -typecheck -sdk $(xcrun --show-sdk-path --sdk iphonesimulator) \
  -target arm64-apple-ios18.0 <file.swift>
```

### Testing
- **Framework**: Swift Testing (`@Test` attribute, NOT XCTest)
- **Unit tests**: `CatbirdTests/` mirroring module paths
- **UI tests**: `CatbirdUITests/`
- SwiftLint: `.swiftlint.yml`

## Architecture

### State Management
```
AppState (@Observable)
├── AuthManager (authentication)
├── PostShadowManager (Actor - thread-safe post interactions)
├── PreferencesManager (user preferences with server sync)
├── GraphManager (social graph cache)
├── NotificationManager (push notifications)
└── ABTestingFramework (experiments)
```

### Key Patterns
- **MVVM** with `@Observable` (NOT ObservableObject/Combine)
- **Actors** for thread-safe state (PostShadowManager)
- **Structured concurrency**: async/await throughout
- **NavigationHandler** protocol for decoupled navigation
- **FeedTuner** for intelligent thread consolidation

### Feed Implementation
- **iOS**: `UICollectionView` via `FeedCollectionViewControllerIntegrated` (touch-optimized)
- **macOS**: SwiftUI `List` with `FeedPostRow` components

## Code Style

- **2-space indentation** (not tabs)
- **Swift 6 strict concurrency** enabled
- **@Observable** macro (NOT ObservableObject)
- **Actors** for thread-safe state
- **async/await** for all async operations
- **OSLog** for logging with subsystem/category
- Be explicit about `self` capture in closures for Swift 6

## Cross-Platform Development

### Conditional Compilation
Use ViewModifier protocols, NOT inline `#if`:

```swift
// CORRECT
.modifier(PlatformSpecificModifier())

// WRONG - conditional in modifier chain
#if os(iOS)
.navigationBarHidden(true)
#endif
```

Always include both platforms in `@available`:
```swift
@available(iOS 26.0, macOS 26.0, *)
```

### Platform Utilities (Core/Extensions/)
- `CrossPlatformImage.swift`, `CrossPlatformUI.swift`
- `PlatformColors.swift`, `PlatformDeviceInfo.swift`
- `PlatformHaptics.swift`, `PlatformScreenInfo.swift`

## Liquid Glass (iOS 26)

Key APIs:
- `.glassEffect()` - apply glass to any view
- `GlassEffectContainer` - group multiple glass elements for performance
- `.glassEffectUnion(id:namespace:)` - combine views into single glass shape
- `.glassEffectID(_:in:)` - morphing transitions
- Standard components (nav bars, tab bars, sheets) adopt automatically
- Test with "Reduce Transparency" and "Reduce Motion" accessibility settings

## Project Structure

```
Catbird/
├── App/           # Entry point
├── Core/          # Infrastructure (Extensions, Models, Navigation, Services, State, UI, Utilities)
├── Features/      # Feature modules (Auth, Chat, Feed, Media, Notifications, Profile, Search, Settings...)
└── Resources/     # Assets and preview data
```

## Key Components

- **AuthManager**: Keychain credentials, OAuth + legacy auth, token refresh
- **FeedModel**: Pagination, FeedTuner thread consolidation, FeedPrefetchingManager
- **PostShadowManager** (Actor): Thread-safe likes/reposts/replies
- **AppNavigationManager**: Central navigation coordinator
- **AT Protocol**: Models in `Petrel/Sources/Petrel/Generated/`, use `ATProtoClient` for API calls

## Debugging

- ATProtoClient logs all requests/responses
- Filter Console.app by subsystem "Catbird"
- Profile with Instruments for retain cycles, excessive redraws
