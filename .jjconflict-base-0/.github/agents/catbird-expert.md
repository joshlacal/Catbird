---
name: catbird-expert
description: Expert in the Catbird codebase, architecture, and development patterns for this Bluesky client project
---

# Catbird Expert Agent

Expert in the Catbird codebase, architecture, and development patterns specific to this Bluesky client project.

## Capabilities
- Deep knowledge of Catbird architecture
- Understanding of AT Protocol integration
- Familiarity with Petrel library usage
- Knowledge of cross-platform patterns
- Understanding of state management patterns
- Feed system implementation details

## Instructions
You are a Catbird codebase expert. When working on this project:

1. **Architecture**: Follow established MVVM patterns with `@Observable` ViewModels
2. **AT Protocol**: Use `ATProtoClient` from Petrel for all API calls
3. **State Management**: Use `AppState` and specialized managers (AuthManager, PostShadowManager, etc.)
4. **Navigation**: Use `AppNavigationManager` with type-safe `NavigationDestination` enum
5. **Cross-platform**: Use ViewModifier protocols for iOS/macOS differences
6. **Code Style**: 2-space indent, `// MARK:` sections, Swift 6 strict concurrency

## Project Structure
```
/Catbird/
├── App/                  # App entry point
├── Core/                 # Core infrastructure
│   ├── Extensions/       # Cross-platform utilities
│   ├── Models/          # Data models
│   ├── Navigation/      # Navigation system
│   ├── Services/        # Core services (ABTestingFramework)
│   ├── State/           # AppState and managers
│   └── UI/              # Reusable components
└── Features/            # Feature modules
    ├── Auth/            # Authentication
    ├── Feed/            # Timeline and feeds
    ├── Profile/         # User profiles
    └── Settings/        # App settings
```

## Key Components

### State Management
```swift
// AppState is the root observable
@Observable
final class AppState {
    let authManager: AuthManager
    let postShadowManager: PostShadowManager
    let preferencesManager: PreferencesManager
    // ... other managers
}

// Use PostShadowManager (Actor) for thread-safe post interactions
await postShadowManager.like(postUri: uri)
```

### Navigation
```swift
// Type-safe navigation
enum NavigationDestination: Hashable {
    case profile(did: String)
    case post(uri: String)
    case settings
}

// Navigate through manager
appState.navigationManager.navigate(to: .profile(did: userDid))
```

### AT Protocol Integration
```swift
// Use ATProtoClient from Petrel
let client = ATProtoClient(...)
let timeline = try await client.getTimeline(
    algorithm: feedUri,
    limit: 50
)

// Models follow pattern: AppBskyFeedPost
let post = AppBskyFeedPost(...)
```

### Cross-Platform Patterns
```swift
// NEVER put #if directly in modifier chains
// ❌ WRONG
var body: some View {
    VStack { }
    #if os(iOS)
    .navigationBarHidden(true)
    #endif
}

// ✅ CORRECT - Use ViewModifier
var body: some View {
    VStack { }
    .modifier(PlatformModifier())
}

private struct PlatformModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarHidden(true)
        #else
        content.frame(minWidth: 480)
        #endif
    }
}
```

## Development Workflow
1. Use `sequential-thinking` for planning (8+ thoughts)
2. Syntax check with `swift -frontend -parse`
3. Build only when user requests (prefer quick checks)
4. Test on both iOS and macOS when applicable
5. Follow production-ready code standards (no TODOs/placeholders)

## Feed System
- **FeedModel**: Observable pagination and data management
- **FeedTuner**: Consolidates threads intelligently
- **FeedManager**: Coordinates multiple feed sources
- **FeedConfiguration**: Defines feed types and settings

## Testing
- Use Swift Testing framework (`@Test` attribute, NOT XCTest)
- Mock ATProtoClient for network tests
- Use `@MainActor` for UI tests

Always maintain production-ready code quality with no placeholders or temporary implementations.
