# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Catbird is a native iOS client for Bluesky built with SwiftUI and modern Swift 6 patterns. It uses the Petrel library for AT Protocol communication.

### Project Components
- **Catbird**: Main iOS app with SwiftUI interface for Bluesky
- **Petrel**: Swift library providing AT Protocol networking and data models (auto-generated from Lexicon JSON files)
- **CatbirdNotificationWidget**: iOS widget extension for notifications

## Build and Development Commands

### Xcode Build and Run
- **Build and run**: Open `Catbird.xcodeproj` in Xcode 16+ and run the `Catbird` scheme (iOS 18+ required)
- **Run all tests**: CMD+U in Xcode or Product → Test
- **Clean build**: CMD+Shift+K
- **Build for device**: Select physical device from scheme selector and run

### SwiftLint
- **Lint check**: `swiftlint` from project root
- **Auto-fix**: `swiftlint --fix`
- Configuration in `.swiftlint.yml`

### Petrel Code Generation
- **Generate AT Protocol models**: `cd Petrel && python Generator/main.py`
- Generated files go to `Petrel/Sources/Petrel/Generated/`
- Lexicon definitions in `Petrel/Generator/lexicons/`

## Architecture

### State Management
```
AppState (@Observable)
├── AuthManager (authentication state)
├── PostShadowManager (Actor - thread-safe post interactions)
├── PreferencesManager (user preferences with server sync)
├── GraphManager (social graph cache)
└── NotificationManager (push notifications)
```

### Key Architectural Patterns
- **MVVM** with @Observable for state management (NOT Combine/ObservableObject)
- **Actors** for thread-safe operations (PostShadowManager)
- **Structured concurrency** with async/await throughout
- **NavigationHandler protocol** for decoupled navigation
- **FeedTuner** for intelligent thread consolidation in feeds

## Code Organization

### Project Structure
```
/Catbird/
├── App/                    # App entry point
├── Core/                   # Core infrastructure
│   ├── Extensions/         # Swift extensions
│   ├── Models/            # Data models
│   ├── Navigation/        # Navigation system
│   ├── Networking/        # URL handling
│   ├── State/             # State management
│   ├── UI/                # Reusable UI components
│   └── Utilities/         # Helper utilities
├── Features/              # Feature modules
│   ├── Auth/              # Authentication
│   ├── Chat/              # Direct messaging
│   ├── Feed/              # Timeline and feeds
│   ├── Media/             # Video/image handling
│   ├── Moderation/        # Content moderation
│   ├── Notifications/     # Push notifications
│   ├── Profile/           # User profiles
│   ├── Search/            # Search functionality
│   └── Settings/          # App settings
└── Resources/             # Assets and preview data
```

### Code Style Requirements
- **Swift 6 strict concurrency** enabled
- **@Observable** macro for state objects (NOT ObservableObject)
- **Actors** for thread-safe state management
- **async/await** for all asynchronous operations
- **OSLog** for logging with appropriate subsystem/category
- **2 spaces** indentation (not tabs)
- **MARK:** comments to organize code sections
- **AppNavigationManager** for all navigation

## Key Components

### Authentication Flow
1. `AuthManager` checks for stored credentials on app launch
2. Attempts token refresh via `ATProtoClient`
3. Shows login view if no valid credentials
4. Supports both legacy (username/password) and OAuth flows
5. Credentials stored securely in Keychain

### Feed System
- **FeedModel**: Observable model managing pagination and data
- **FeedTuner**: Consolidates related posts into thread views
- **FeedManager**: Coordinates multiple feed sources
- **FeedConfiguration**: Defines feed types and settings

### Post Interactions
- **PostViewModel**: Handles individual post actions
- **PostShadowManager** (Actor): Thread-safe state for likes/reposts/replies
- All interactions update both local state and server via ATProtoClient

### Navigation
- **AppNavigationManager**: Central navigation coordinator
- **NavigationDestination**: Type-safe navigation targets
- **NavigationHandler** protocol: Decouples navigation from views

## Testing Guidelines

### Unit Tests
- Test ViewModels and business logic
- Mock ATProtoClient for network tests
- Use `@MainActor` for UI-related tests

### UI Tests
- Test critical user flows (login, post, navigate)
- Use accessibility identifiers for reliable element selection

## Common Development Tasks

### Adding a New Feature
1. Create feature folder in `/Features`
2. Add Observable ViewModel if needed
3. Implement SwiftUI views
4. Wire up navigation in AppNavigationManager
5. Add unit tests

### Working with AT Protocol
- AT Protocol models are in `Petrel/Sources/Petrel/Generated/`
- Use `ATProtoClient` for all API calls
- Models follow pattern: `AppBskyFeedPost` for `app.bsky.feed.post`
- All API calls are async/await

### Debugging Network Requests
- ATProtoClient logs all requests/responses
- Check Console.app for OSLog output
- Filter by subsystem "Catbird"

### Performance Optimization
- Use Instruments to profile
- Check for retain cycles in closures
- Verify @Observable dependencies are minimal
- Use task cancellation for async operations

## Widget Development
- Widget extension in `/CatbirdNotificationWidget`
- Shares data via App Groups
- Keep widget timeline updates minimal for battery

## iOS Simulator Testing

### Key Simulator UUIDs for Catbird Development
- **iPhone 16**: `9DEB446A-BB21-4E3A-BD6A-D51FBC28617C` (primary development device)
- **iPhone 16 Pro**: `DEEB371A-6A16-4922-8831-BCABBCEB4E41`
- **iPhone 16 Plus**: `C4F81FC1-3AC8-40F1-AA1C-EBC3FFE81B6F`

### Common Gesture Patterns for Catbird
```bash
# Open feeds drawer (swipe right from left edge)
mcp__XcodeBuildMCP__swipe({
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41",
  x1: 5, y1: 400, x2: 300, y2: 400
})

# Scroll down in timeline
mcp__XcodeBuildMCP__swipe({
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41",
  x1: 200, y1: 600, x2: 200, y2: 200
})
```

### Standard Testing Pattern
```javascript
// 1. Build and launch app
await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
  projectPath: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj",
  scheme: "Catbird",
  simulatorName: "iPhone 16 Pro"
});

// 2. Wait for full initialization (18 seconds total)
await Bash({ command: "sleep 18" });

// 3. Take screenshot and test
await mcp__XcodeBuildMCP__screenshot({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});
```

## Multi-Agent Orchestrator System

### Local Development Orchestration
The project includes a multi-agent orchestrator at `/claude-agents/`:

```bash
# Start orchestrator
cd ./claude-agents && node orchestrator.js

# Create task
echo '{"id": "feature-fix", "type": "ios-feature-workflow", "priority": 9}' > shared/tasks/my-task.json
```

**Capabilities:**
- ✅ 15 iOS simulators accessible
- ✅ Git worktree isolation per agent
- ✅ Claude CLI integration (no API calls)
- ✅ Automated build, test, and screenshot workflows

## Important Notes

### Release Status: MAJOR PROGRESS - 4 of 7 Critical Issues Resolved
**Current Priority**: 3 remaining issues before release readiness.

**✅ Recently Resolved (commits 5e3be1c, 3ee8636):**
1. **Emoji picker** - ✅ Working with responsive design and search
2. **Chat error alerts** - ✅ Fixed recurring "Chat Error cancelled" loop
3. **Tab bar translucency** - ✅ Consistent appearance across all screens
4. **Notifications header** - ✅ Proper scroll compacting behavior

**🔴 Remaining Critical Issues:**
5. **Font accessibility** - Core system working, advanced options incomplete
6. **Content settings** - Toggles still don't affect app behavior
7. **Biometric auth UI** - Backend complete but no settings interface

**What's Working:**
- ✅ Authentication system (OAuth, biometric backend, error handling)
- ✅ Feed performance (thread consolidation, smooth scrolling)
- ✅ Chat functionality (real-time delivery, emoji picker, reactions)
- ✅ Theme system (light/dark/dim switching)
- ✅ Font system (style/size selection with Dynamic Type)
- ✅ Error handling (proper chat error management)

**Implementation Guide**: See `RELEASE_IMPLEMENTATION_GUIDE.md` for detailed fix requirements.

### Release Readiness Criteria
Before any release, ensure:
✅ All emoji and chat functionality works correctly
✅ Visual consistency across all screens and themes
✅ Font accessibility settings fully implemented
✅ All user-facing settings actually affect app behavior
✅ No recurring error alerts or crashes in normal usage

### Security & Performance
- All credentials stored in Keychain via `KeychainManager`
- DPoP (Demonstrating Proof of Possession) keys managed separately
- OAuth and legacy auth flows both supported
- Use `FeedTuner` for intelligent thread consolidation
- Image prefetching is handled by `ImageLoadingManager`
- Video assets are managed by `VideoAssetManager` with caching
- Never log sensitive information

---

*This document is focused on essential information for effective development. For detailed MCP server usage, worktree workflows, and testing patterns, see the full documentation in project files.*