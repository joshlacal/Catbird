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
- **Run single test**: Use Test Navigator (CMD+6), select test and click play button
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

### Build Server
- Uses `xcode-build-server` for LSP support
- Configuration in `buildServer.json`
- Build artifacts in `~/Library/Developer/Xcode/DerivedData/Catbird-*`

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

### Dependency Graph
```
Catbird.app
└── Petrel (AT Protocol Swift library)
    └── Generated AT Protocol models and networking
```

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

## MCP Server Usage for iOS Development

### Available MCP Servers
1. **XcodeBuildMCP** - Primary tool for iOS development
2. **ios-simulator** - Direct simulator control and UI automation
3. **code-sandbox-mcp** - Isolated code execution environment
4. **filesystem** - File system operations
5. **fetch** - Web content fetching
6. **sequential-thinking** - Complex problem solving

### XcodeBuildMCP - Core Development Workflow

#### Project Discovery and Setup
```bash
# Discover Xcode projects in workspace
mcp__XcodeBuildMCP__discover_projs({ workspaceRoot: "/Users/joshlacalamito/Developer/Catbird" })

# List available schemes
mcp__XcodeBuildMCP__list_schems_proj({ projectPath: "/Users/joshlacalamito/Developer/Catbird/Catbird.xcodeproj" })

# List available simulators
mcp__XcodeBuildMCP__list_sims({ enabled: true })
```

#### Build and Run Workflow
```bash
# Clean build
mcp__XcodeBuildMCP__clean_proj({ 
  projectPath: "/Users/joshlacalamito/Developer/Catbird/Catbird.xcodeproj",
  scheme: "Catbird"
})

# Build and run on simulator by name
mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
  projectPath: "/Users/joshlacalamito/Developer/Catbird/Catbird.xcodeproj",
  scheme: "Catbird",
  simulatorName: "iPhone 16",
  configuration: "Debug"
})

# Build and run on specific simulator UUID
mcp__XcodeBuildMCP__build_run_ios_sim_id_proj({
  projectPath: "/Users/joshlacalamito/Developer/Catbird/Catbird.xcodeproj",
  scheme: "Catbird",
  simulatorId: "SIMULATOR_UUID"
})
```

### iOS Simulator Control

#### Basic Operations
```bash
# Boot simulator
mcp__XcodeBuildMCP__boot_sim({ simulatorUuid: "SIMULATOR_UUID" })

# Open Simulator app
mcp__XcodeBuildMCP__open_sim({ enabled: true })

# Install app
mcp__XcodeBuildMCP__install_app_sim({
  simulatorUuid: "SIMULATOR_UUID",
  appPath: "/path/to/Catbird.app"
})

# Launch app
mcp__XcodeBuildMCP__launch_app_sim({
  simulatorUuid: "SIMULATOR_UUID",
  bundleId: "com.example.Catbird"
})
```

#### UI Automation and Testing
```bash
# Get UI hierarchy
mcp__XcodeBuildMCP__describe_all({ simulatorUuid: "UUID" })

# Tap at coordinates
mcp__XcodeBuildMCP__tap({ simulatorUuid: "UUID", x: 200, y: 300 })

# Type text
mcp__XcodeBuildMCP__type_text({ simulatorUuid: "UUID", text: "Hello Bluesky" })

# Swipe
mcp__XcodeBuildMCP__swipe({ 
  simulatorUuid: "UUID",
  x1: 200, y1: 500,
  x2: 200, y2: 200
})

# Take screenshot
mcp__XcodeBuildMCP__screenshot({ simulatorUuid: "UUID" })
```

#### Simulator Configuration
```bash
# Set appearance mode
mcp__XcodeBuildMCP__set_sim_appearance({ 
  simulatorUuid: "UUID",
  mode: "dark"
})

# Set location
mcp__XcodeBuildMCP__set_simulator_location({
  simulatorUuid: "UUID",
  latitude: 37.7749,
  longitude: -122.4194
})

# Set network conditions
mcp__XcodeBuildMCP__set_network_condition({
  simulatorUuid: "UUID",
  profile: "3g"
})
```

### Agentically Iterating on Screens and Views

#### Automated UI Development Workflow
1. **Build and Launch**
   ```bash
   # Build and run the app
   build_run_ios_sim_name_proj(...)
   
   # Wait for app to launch
   # Take initial screenshot
   screenshot({ simulatorUuid: "UUID" })
   ```

2. **Make Code Changes**
   ```bash
   # Edit SwiftUI view
   mcp__filesystem__edit_file({ 
     path: "/path/to/View.swift",
     edits: [...]
   })
   ```

3. **Hot Reload or Rebuild**
   ```bash
   # For SwiftUI previews, rebuild is automatic
   # For full app testing, rebuild:
   build_run_ios_sim_name_proj(...)
   ```

4. **Verify Changes**
   ```bash
   # Screenshot new state
   screenshot({ simulatorUuid: "UUID" })
   
   # Get UI hierarchy to verify elements
   describe_all({ simulatorUuid: "UUID" })
   
   # Test interactions
   tap({ simulatorUuid: "UUID", x: 100, y: 200 })
   ```

#### Example: Iterating on Feed View
```python
# 1. Launch app and navigate to feed
build_run_ios_sim_name_proj(...)
wait(2)

# 2. Take baseline screenshot
screenshot_before = screenshot({ simulatorUuid: "UUID" })

# 3. Modify feed layout
edit_file({
  path: "/Catbird/Features/Feed/Views/FeedView.swift",
  edits: [{
    oldText: "spacing: 8",
    newText: "spacing: 12"
  }]
})

# 4. Rebuild and verify
build_run_ios_sim_name_proj(...)
wait(2)
screenshot_after = screenshot({ simulatorUuid: "UUID" })

# 5. Test scrolling
swipe({ simulatorUuid: "UUID", x1: 200, y1: 500, x2: 200, y2: 100 })

# 6. Verify specific elements
ui_hierarchy = describe_all({ simulatorUuid: "UUID" })
# Check for expected UI elements
```

### Debugging and Logging

#### Capture Logs
```bash
# Start log capture
log_session = mcp__XcodeBuildMCP__start_sim_log_cap({
  simulatorUuid: "UUID",
  bundleId: "com.example.Catbird",
  captureConsole: true
})

# Run test scenario
# ...

# Stop and retrieve logs
logs = mcp__XcodeBuildMCP__stop_sim_log_cap({
  logSessionId: log_session
})
```

### Best Practices for MCP-Driven Development

1. **Always Clean Before Major Changes**
   - Use `clean_proj` before switching branches or major refactors

2. **Use Named Simulators**
   - Prefer `simulatorName: "iPhone 16"` over UUIDs for readability

3. **Batch UI Operations**
   - Group related taps/swipes for efficiency

4. **Screenshot-Driven Development**
   - Take screenshots before/after changes
   - Use for visual regression testing

5. **Parallel Testing**
   - Run multiple simulators for different iOS versions
   - Test dark/light mode simultaneously

## Important Notes

### Token Management and Authentication
- Expired tokens during initialization are handled gracefully
- The app completes initialization even with expired tokens
- Authentication state is separate from initialization state
- See `robust-token-expiry-plan.md` for detailed recovery flow

### Performance Considerations
- Use `FeedTuner` for intelligent thread consolidation
- Image prefetching is handled by `ImageLoadingManager`
- Video assets are managed by `VideoAssetManager` with caching
- Post height calculations are cached in `PostHeightCalculator`

### Security
- All credentials stored in Keychain via `KeychainManager`
- DPoP (Demonstrating Proof of Possession) keys managed separately
- OAuth and legacy auth flows both supported
- Never log sensitive information

### Visual UI Development and Testing Workflow

#### Complete Screenshot-Driven Development Process
The MCP tools provide a powerful way to iteratively develop and test UI changes by taking screenshots at each step to visually verify improvements.

1. **Initial Setup and Baseline**
   ```bash
   # Build and run the app
   mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
     projectPath: "/Users/joshlacalamito/Developer/Catbird/Catbird.xcodeproj",
     scheme: "Catbird",
     simulatorName: "iPhone 16",
     configuration: "Debug"
   })
   
   # Wait for app to fully load
   sleep 8
   
   # Take baseline screenshot
   mcp__XcodeBuildMCP__screenshot({ simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C" })
   ```

2. **Navigate to Target Screen**
   ```bash
   # Example: Open feeds drawer
   mcp__XcodeBuildMCP__swipe({
     simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C",
     x1: 5, y1: 400,
     x2: 300, y2: 400
   })
   
   # Screenshot the current state
   mcp__XcodeBuildMCP__screenshot({ simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C" })
   ```

3. **Make Code Changes**
   ```bash
   # Edit SwiftUI files using Edit tool
   Edit({
     file_path: "/Users/joshlacalamito/Developer/Catbird/Catbird/Features/Feed/Views/FeedsStartPage.swift",
     old_string: "existing code pattern",
     new_string: "improved code pattern"
   })
   ```

4. **Rebuild and Test Changes**
   ```bash
   # Rebuild with changes
   mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
     projectPath: "/Users/joshlacalamito/Developer/Catbird/Catbird.xcodeproj",
     scheme: "Catbird",
     simulatorName: "iPhone 16"
   })
   
   # Wait for build completion
   sleep 8
   
   # Navigate back to target screen if needed
   mcp__XcodeBuildMCP__swipe({
     simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C",
     x1: 5, y1: 400,
     x2: 300, y2: 400
   })
   
   # Screenshot the updated state
   mcp__XcodeBuildMCP__screenshot({ simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C" })
   ```

5. **Test Interactions and Scrolling**
   ```bash
   # Test scrolling behavior
   mcp__XcodeBuildMCP__swipe({
     simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C",
     x1: 250, y1: 600,
     x2: 250, y2: 1100,
     velocity: 2000
   })
   
   # Screenshot scrolled state
   mcp__XcodeBuildMCP__screenshot({ simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C" })
   
   # Test tapping elements
   mcp__XcodeBuildMCP__tap({
     simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C",
     x: 250, y: 350
   })
   ```

#### Real Example: Feeds Start Page Hierarchy Fix
This was used to fix the feeds start page hierarchy by moving the profile section and improving the layout:

```bash
# 1. Take baseline screenshot
mcp__XcodeBuildMCP__screenshot({ simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C" })

# 2. Edit the layout structure
Edit({
  file_path: "/Users/joshlacalamito/Developer/Catbird/Catbird/Features/Feed/Views/FeedsStartPage.swift",
  old_string: "profileButton()\n        .padding(.horizontal, horizontalPadding)\n        .padding(.bottom, 12)",
  new_string: "// Profile moved to scrollable content"
})

# 3. Rebuild and test
mcp__XcodeBuildMCP__build_run_ios_sim_name_proj(...)

# 4. Navigate to feeds
mcp__XcodeBuildMCP__swipe({ x1: 5, y1: 400, x2: 300, y2: 400 })

# 5. Test scrolling to profile
mcp__XcodeBuildMCP__swipe({ x1: 250, y1: 600, x2: 250, y2: 1100, velocity: 2000 })

# 6. Screenshot final result
mcp__XcodeBuildMCP__screenshot({ simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C" })
```

#### Key Simulator UUIDs for Catbird Development
- **iPhone 16**: `9DEB446A-BB21-4E3A-BD6A-D51FBC28617C` (primary development device)
- **iPhone 16 Pro**: `DEEB371A-6A16-4922-8831-BCABBCEB4E41`
- **iPhone 16 Plus**: `C4F81FC1-3AC8-40F1-AA1C-EBC3FFE81B6F`

#### Common Gesture Patterns for Catbird
```bash
# Open feeds drawer (swipe right from left edge)
mcp__XcodeBuildMCP__swipe({
  simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C",
  x1: 5, y1: 400,
  x2: 300, y2: 400
})

# Close feeds drawer (swipe left)
mcp__XcodeBuildMCP__swipe({
  simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C",
  x1: 300, y1: 400,
  x2: 5, y2: 400
})

# Scroll up in feeds list (for profile access)
mcp__XcodeBuildMCP__swipe({
  simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C",
  x1: 250, y1: 600,
  x2: 250, y2: 1100,
  velocity: 2000
})

# Scroll down in timeline
mcp__XcodeBuildMCP__swipe({
  simulatorUuid: "9DEB446A-BB21-4E3A-BD6A-D51FBC28617C",
  x1: 200, y1: 800,
  x2: 200, y2: 300
})
```

### Common Automation Patterns

#### Login Flow Testing
```python
# Launch app
build_run_ios_sim_name_proj(...)

# Tap login button
tap({ simulatorUuid: "UUID", x: 200, y: 600 })

# Enter credentials
type_text({ simulatorUuid: "UUID", text: "username" })
tap({ simulatorUuid: "UUID", x: 200, y: 400 })  # Next field
type_text({ simulatorUuid: "UUID", text: "password" })

# Submit
tap({ simulatorUuid: "UUID", x: 200, y: 500 })
```

#### Feed Scrolling Performance
```python
# Start at top of feed
build_run_ios_sim_name_proj(...)

# Rapid scroll test
for i in range(10):
    swipe({ 
      simulatorUuid: "UUID",
      x1: 200, y1: 600,
      x2: 200, y2: 100,
      velocity: 1000
    })
    wait(0.5)
    screenshot({ simulatorUuid: "UUID" })
```

## Agentic Testing Workflows

### Quick Start: Launch and Test Pattern
```javascript
// 1. Build and launch app
const result = await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
  projectPath: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj",
  scheme: "Catbird",
  simulatorName: "iPhone 16 Pro",  // or "iPhone 16"
  configuration: "Debug"
});

// 2. Wait for app initialization
await Bash({ command: "sleep 8" });  // Initial black screen
await Bash({ command: "sleep 10" }); // Wait for "INITIALIZING..." to complete

// 3. Verify app is ready
const uiState = await mcp__XcodeBuildMCP__describe_all({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});

// 4. Take screenshot for visual verification
await mcp__XcodeBuildMCP__screenshot({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});
```

### Standard Testing Patterns

#### Pattern 1: Edit-Build-Test Cycle
```javascript
// 1. Take baseline screenshot
await mcp__XcodeBuildMCP__screenshot({ simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" });

// 2. Make code change
await Edit({
  file_path: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird/Features/Feed/Views/FeedView.swift",
  old_string: "spacing: 8",
  new_string: "spacing: 12"
});

// 3. Rebuild and launch (app will restart)
await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
  projectPath: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj",
  scheme: "Catbird",
  simulatorName: "iPhone 16 Pro"
});

// 4. Wait for full initialization
await Bash({ command: "sleep 18" });

// 5. Navigate to changed screen (if needed)
await mcp__XcodeBuildMCP__tap({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41", 
  x: 201, y: 430  // Sign In button
});

// 6. Take comparison screenshot
await mcp__XcodeBuildMCP__screenshot({ simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" });
```

#### Pattern 2: Smart Element Selection
```javascript
// Get UI hierarchy
const hierarchy = await mcp__XcodeBuildMCP__describe_all({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});

// Find button by accessibility label
const signInButton = hierarchy[0].children.find(
  el => el.AXLabel === "Sign In" && el.type === "Button"
);

// Calculate center coordinates and tap
if (signInButton) {
  const centerX = signInButton.frame.x + signInButton.frame.width / 2;
  const centerY = signInButton.frame.y + signInButton.frame.height / 2;
  
  await mcp__XcodeBuildMCP__tap({ 
    simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41", 
    x: Math.round(centerX), 
    y: Math.round(centerY) 
  });
}
```

#### Pattern 3: Visual Regression Testing
```javascript
// Function to capture state
async function captureViewState(screenshotName) {
  const screenshot = await mcp__XcodeBuildMCP__screenshot({ 
    simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
  });
  
  // Also capture UI hierarchy for structural comparison
  const hierarchy = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
  });
  
  return { screenshot, hierarchy };
}

// Before changes
const before = await captureViewState("before");

// Make changes and rebuild
await Edit({ /* ... */ });
await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({ /* ... */ });
await Bash({ command: "sleep 18" });

// After changes
const after = await captureViewState("after");

// Compare visually and structurally
```

### Catbird-Specific Navigation Patterns

```javascript
// Open Feeds Drawer (from main timeline)
await mcp__XcodeBuildMCP__swipe({
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41",
  x1: 5, y1: 400,
  x2: 300, y2: 400,
  velocity: 1000
});
await Bash({ command: "sleep 1" });

// Close Feeds Drawer
await mcp__XcodeBuildMCP__swipe({
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41",
  x1: 300, y1: 400,
  x2: 5, y2: 400,
  velocity: 1000
});

// Scroll down in timeline (load more posts)
await mcp__XcodeBuildMCP__swipe({
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41",
  x1: 200, y1: 600,
  x2: 200, y2: 200,
  velocity: 1500
});

// Scroll to bottom of feeds list (to find profile)
await mcp__XcodeBuildMCP__swipe({
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41",
  x1: 250, y1: 600,
  x2: 250, y2: 100,
  velocity: 2000
});
```

### Wait Time Guidelines
- **Initial app launch**: 8 seconds (black screen phase)
- **Initialization completion**: Additional 10 seconds (after "INITIALIZING...")
- **Total from build to ready**: 18 seconds
- **After navigation**: 1-2 seconds
- **Before taking screenshots**: 1 second
- **After keyboard appears**: 0.5 seconds

### Error Recovery Patterns

```javascript
// Pattern 1: App didn't launch properly
try {
  const ui = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
  });
  
  if (!ui || ui.length === 0) {
    // Force quit and relaunch
    await Bash({ command: "xcrun simctl terminate DEEB371A-6A16-4922-8831-BCABBCEB4E41 blue.catbird" });
    await Bash({ command: "sleep 2" });
    await mcp__XcodeBuildMCP__launch_app_sim({
      simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41",
      bundleId: "blue.catbird"
    });
    await Bash({ command: "sleep 18" });
  }
} catch (error) {
  console.log("Recovery needed:", error);
}

// Pattern 2: Build failed - clean and retry
if (buildResult.includes("BUILD FAILED")) {
  await mcp__XcodeBuildMCP__clean_proj({
    projectPath: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj",
    scheme: "Catbird"
  });
  
  // Try build again
  await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({ /* ... */ });
}
```

### Performance Testing Patterns

```javascript
// Feed scrolling performance test
async function testFeedScrollPerformance() {
  const screenshots = [];
  
  for (let i = 0; i < 10; i++) {
    // Rapid scroll
    await mcp__XcodeBuildMCP__swipe({
      simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41",
      x1: 200, y1: 600,
      x2: 200, y2: 100,
      velocity: 2000
    });
    
    // Brief pause to let content load
    await Bash({ command: "sleep 0.5" });
    
    // Capture state
    const screenshot = await mcp__XcodeBuildMCP__screenshot({ 
      simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
    });
    screenshots.push(screenshot);
  }
  
  return screenshots;
}
```

### Complete Test Example: Login Flow

```javascript
// 1. Launch app fresh
await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
  projectPath: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj",
  scheme: "Catbird",
  simulatorName: "iPhone 16 Pro"
});
await Bash({ command: "sleep 18" });

// 2. Verify we're on login screen
const loginScreen = await mcp__XcodeBuildMCP__describe_all({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});

const hasSignIn = loginScreen[0].children.some(el => el.AXLabel === "Sign In");
if (!hasSignIn) {
  throw new Error("Not on login screen");
}

// 3. Tap Sign In button
await mcp__XcodeBuildMCP__tap({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41", 
  x: 201, y: 430 
});
await Bash({ command: "sleep 2" });

// 4. Enter credentials (example - adjust for actual fields)
await mcp__XcodeBuildMCP__type_text({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41", 
  text: "test@example.com" 
});

// 5. Tab to password field
await mcp__XcodeBuildMCP__tap({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41", 
  x: 201, y: 500 
});

await mcp__XcodeBuildMCP__type_text({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41", 
  text: "password123" 
});

// 6. Submit
await mcp__XcodeBuildMCP__tap({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41", 
  x: 201, y: 580 
});

// 7. Wait for login and verify success
await Bash({ command: "sleep 5" });
await mcp__XcodeBuildMCP__screenshot({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});
```

### Expected Performance Baselines
- **Clean build**: 45-90 seconds (depends on package resolution)
- **Incremental build**: 10-20 seconds
- **App initialization**: 18 seconds total (8s black + 10s initializing)
- **Screenshot capture**: <1 second
- **UI hierarchy fetch**: <1 second
- **Swipe gesture**: Immediate
- **Text input**: ~0.1 second per character

### Tips for Efficient Testing
1. **Always use the iPhone 16 Pro** simulator (UUID: DEEB371A-6A16-4922-8831-BCABBCEB4E41) for consistency
2. **Take screenshots liberally** - they're fast and provide visual verification
3. **Use UI hierarchy** to find elements instead of hardcoding coordinates when possible
4. **Batch related tests** to avoid rebuild cycles
5. **Save screenshots with descriptive names** for debugging
6. **Use velocity parameter** on swipes for more realistic gestures

## Advanced Git Worktree Workflow with Autonomous Agents

### Overview
This workflow enables parallel feature development using git worktrees with multiple Claude Code processes and autonomous subagents that can commit and merge changes independently.

### Prerequisites
```bash
# Ensure git worktree support
git --version  # Should be 2.5+

# Create base directory for worktrees
mkdir -p ~/Developer/Catbird-Worktrees
```

### Setting Up Git Worktrees

#### 1. Create Feature Worktrees
```bash
# From main repository
cd /Users/joshlacalamito/Developer/Catbird:Petrel/Catbird

# Create worktree for each feature
git worktree add ~/Developer/Catbird-Worktrees/feature-auth feature/auth-improvements
git worktree add ~/Developer/Catbird-Worktrees/feature-feed feature/feed-optimization
git worktree add ~/Developer/Catbird-Worktrees/feature-ui feature/ui-refresh

# List all worktrees
git worktree list
```

#### 2. Worktree Management Commands
```bash
# Remove a worktree
git worktree remove ~/Developer/Catbird-Worktrees/feature-auth

# Prune stale worktree information
git worktree prune

# Lock/unlock worktree to prevent accidental removal
git worktree lock ~/Developer/Catbird-Worktrees/feature-auth
git worktree unlock ~/Developer/Catbird-Worktrees/feature-auth
```

### Multiple Claude Code Process Architecture

#### Process Structure
```
Main Orchestrator (Claude Code Instance 1)
├── Feature Agent 1 (Auth) → Worktree 1
│   ├── Subagent: API Integration
│   ├── Subagent: UI Updates
│   └── Subagent: Testing
├── Feature Agent 2 (Feed) → Worktree 2
│   ├── Subagent: Performance
│   ├── Subagent: Algorithm
│   └── Subagent: Caching
└── Feature Agent 3 (UI) → Worktree 3
    ├── Subagent: Components
    ├── Subagent: Animations
    └── Subagent: Accessibility
```

### Implementation Pattern

#### 1. Main Orchestrator Setup
```javascript
// Main orchestrator workflow
async function orchestrateParallelDevelopment() {
  // Create todo list for tracking all features
  await TodoWrite({
    todos: [
      { id: "1", content: "Auth improvements feature branch", status: "pending", priority: "high" },
      { id: "2", content: "Feed optimization feature branch", status: "pending", priority: "high" },
      { id: "3", content: "UI refresh feature branch", status: "pending", priority: "medium" },
      { id: "4", content: "Integration testing", status: "pending", priority: "medium" },
      { id: "5", content: "Merge all features to main", status: "pending", priority: "low" }
    ]
  });

  // Launch parallel feature agents
  const features = [
    {
      name: "Auth Improvements",
      worktree: "~/Developer/Catbird-Worktrees/feature-auth",
      branch: "feature/auth-improvements",
      tasks: [
        "Implement OAuth 2.0 flow improvements",
        "Add biometric authentication",
        "Improve token refresh logic"
      ]
    },
    {
      name: "Feed Optimization",
      worktree: "~/Developer/Catbird-Worktrees/feature-feed",
      branch: "feature/feed-optimization",
      tasks: [
        "Optimize FeedTuner algorithm",
        "Implement smart prefetching",
        "Add infinite scroll improvements"
      ]
    },
    {
      name: "UI Refresh",
      worktree: "~/Developer/Catbird-Worktrees/feature-ui",
      branch: "feature/ui-refresh",
      tasks: [
        "Update color scheme for dark mode",
        "Improve animation performance",
        "Add haptic feedback"
      ]
    }
  ];

  // Launch agents in parallel
  const agents = await Promise.all(
    features.map(feature => launchFeatureAgent(feature))
  );

  // Monitor progress
  await monitorAgentProgress(agents);

  // Merge completed features
  await mergeCompletedFeatures(features);
}
```

#### 2. Feature Agent Pattern
```javascript
async function launchFeatureAgent(feature) {
  return await Task({
    description: `${feature.name} Agent`,
    prompt: `
You are a specialized feature development agent working on ${feature.name}.

CONTEXT:
- Working directory: ${feature.worktree}
- Branch: ${feature.branch}
- Tasks: ${feature.tasks.join(', ')}

WORKFLOW:
1. Navigate to your worktree directory
2. Ensure you're on the correct branch
3. Create a todo list for your specific tasks
4. For each task, launch a subagent to handle implementation
5. Review and test each subagent's work
6. Commit changes with descriptive messages
7. Run tests to ensure no regressions
8. Report completion status

SUBAGENT PATTERN:
For complex tasks, launch specialized subagents:
\`\`\`javascript
await Task({
  description: "Implement OAuth Flow",
  prompt: "Implement OAuth 2.0 improvements in AuthManager..."
});
\`\`\`

GIT OPERATIONS:
- Stage and commit after each completed task
- Use conventional commit format: "feat(auth): Add biometric authentication"
- Push to remote after all tasks complete

IMPORTANT:
- Work only in your assigned worktree
- Do not switch branches
- Coordinate through the main orchestrator
- Report any conflicts or blockers immediately
`
  });
}
```

#### 3. Subagent Implementation Pattern
```javascript
// Example subagent for specific task
async function implementBiometricAuth() {
  return await Task({
    description: "Biometric Auth Implementation",
    prompt: `
Implement biometric authentication for Catbird iOS app.

REQUIREMENTS:
1. Add Face ID/Touch ID support to AuthManager
2. Update login flow to offer biometric option
3. Store biometric preference in PreferencesManager
4. Add appropriate entitlements
5. Update UI with biometric login button
6. Handle fallback to password

STEPS:
1. Check current AuthManager implementation
2. Add LocalAuthentication framework
3. Implement biometric authentication methods
4. Update LoginView with biometric option
5. Test on simulator with biometric support
6. Commit changes

Return a summary of:
- Files modified
- Key implementation details
- Any issues encountered
- Test results
`
  });
}
```

### Autonomous Git Operations

#### 1. Smart Commit Pattern
```javascript
async function autonomousCommit(worktree, message) {
  // Navigate to worktree
  await Bash({ 
    command: `cd ${worktree} && pwd`,
    description: "Navigate to worktree"
  });

  // Check status
  const status = await Bash({ 
    command: `cd ${worktree} && git status --porcelain`,
    description: "Check git status"
  });

  if (status.output.trim()) {
    // Stage changes
    await Bash({ 
      command: `cd ${worktree} && git add -A`,
      description: "Stage all changes"
    });

    // Commit with message
    await Bash({ 
      command: `cd ${worktree} && git commit -m "${message}"`,
      description: "Commit changes"
    });

    // Push to remote
    await Bash({ 
      command: `cd ${worktree} && git push origin HEAD`,
      description: "Push to remote"
    });

    return { success: true, message: "Changes committed and pushed" };
  }

  return { success: false, message: "No changes to commit" };
}
```

#### 2. Automated Merge Pattern
```javascript
async function automatedMerge(feature) {
  // Ensure main is up to date
  await Bash({
    command: "cd /Users/joshlacalamito/Developer/Catbird:Petrel/Catbird && git checkout main && git pull",
    description: "Update main branch"
  });

  // Create merge commit
  const mergeResult = await Bash({
    command: `cd /Users/joshlacalamito/Developer/Catbird:Petrel/Catbird && git merge ${feature.branch} --no-ff -m "Merge ${feature.branch}: ${feature.name}"`,
    description: `Merge ${feature.branch}`
  });

  if (mergeResult.output.includes("CONFLICT")) {
    // Handle merge conflicts
    return await handleMergeConflicts(feature);
  }

  // Run tests after merge
  await runPostMergeTests();

  // Push merged changes
  await Bash({
    command: "cd /Users/joshlacalamito/Developer/Catbird:Petrel/Catbird && git push origin main",
    description: "Push merged changes"
  });

  return { success: true, feature: feature.name };
}
```

#### 3. Conflict Resolution Pattern
```javascript
async function handleMergeConflicts(feature) {
  // Launch specialized conflict resolution agent
  return await Task({
    description: "Conflict Resolution",
    prompt: `
Resolve merge conflicts for ${feature.name} branch.

STEPS:
1. Identify conflicted files using git status
2. For each conflict:
   - Analyze both versions
   - Determine correct resolution based on feature intent
   - Apply resolution
3. Test resolved code
4. Complete the merge
5. Document resolution decisions

Use Edit tool to resolve conflicts, ensuring:
- Feature functionality is preserved
- No regressions are introduced
- Code style is consistent

Return summary of:
- Files with conflicts
- Resolution decisions
- Test results
`
  });
}
```

### Monitoring and Coordination

#### 1. Progress Monitoring
```javascript
async function monitorAgentProgress(agents) {
  const checkInterval = 30000; // 30 seconds
  let allComplete = false;

  while (!allComplete) {
    // Check todo list status
    const todos = await TodoRead();
    
    // Update status based on agent reports
    const updatedTodos = await updateTodoStatus(todos, agents);
    await TodoWrite({ todos: updatedTodos });

    // Check if all features are complete
    allComplete = todos.every(todo => 
      todo.status === "completed" || todo.status === "cancelled"
    );

    if (!allComplete) {
      await new Promise(resolve => setTimeout(resolve, checkInterval));
    }
  }
}
```

#### 2. Inter-Agent Communication
```javascript
// Shared state file for agent coordination
const COORDINATION_FILE = "/tmp/catbird-agent-state.json";

async function updateAgentState(agentId, state) {
  const currentState = await readCoordinationState();
  currentState[agentId] = {
    ...state,
    lastUpdate: new Date().toISOString()
  };
  
  await Write({
    file_path: COORDINATION_FILE,
    content: JSON.stringify(currentState, null, 2)
  });
}

async function readCoordinationState() {
  try {
    const content = await Read({ file_path: COORDINATION_FILE });
    return JSON.parse(content);
  } catch {
    return {};
  }
}
```

### Best Practices for Parallel Development

1. **Branch Naming Convention**
   - Feature branches: `feature/description`
   - Bugfix branches: `fix/description`
   - Experimental: `experiment/description`

2. **Commit Message Format**
   ```
   type(scope): Subject line
   
   Body explaining what and why
   
   Refs: #issue-number
   ```

3. **Agent Communication**
   - Use coordination file for state sharing
   - Report progress every significant milestone
   - Flag blockers immediately

4. **Testing Strategy**
   - Each agent runs unit tests after changes
   - Integration tests run before merge
   - UI tests run on merged code

5. **Rollback Strategy**
   ```bash
   # If merge causes issues
   git revert -m 1 <merge-commit-hash>
   git push origin main
   ```

### Example: Complete Feature Development Cycle

```javascript
// Launch parallel feature development
async function developFeaturesInParallel() {
  // 1. Setup worktrees
  await setupWorktrees();
  
  // 2. Launch feature agents
  const agents = await launchAllFeatureAgents();
  
  // 3. Monitor progress with periodic screenshots
  const monitoring = setInterval(async () => {
    await captureProgressScreenshots();
  }, 300000); // Every 5 minutes
  
  // 4. Wait for completion
  await waitForAgentCompletion(agents);
  
  // 5. Run integration tests
  await runIntegrationTests();
  
  // 6. Merge features sequentially
  await mergeAllFeatures();
  
  // 7. Cleanup
  clearInterval(monitoring);
  await cleanupWorktrees();
}

// Run the complete cycle
await developFeaturesInParallel();
```

### Troubleshooting Common Issues

1. **Worktree Conflicts**
   ```bash
   # If worktree is locked
   git worktree unlock <path>
   
   # If worktree is corrupted
   git worktree prune
   rm -rf <worktree-path>
   git worktree add <path> <branch>
   ```

2. **Agent Communication Failures**
   - Check coordination file permissions
   - Ensure file system access for all agents
   - Use fallback communication via git notes

3. **Merge Conflicts**
   - Automated resolution for simple conflicts
   - Escalate complex conflicts to human review
   - Maintain conflict resolution log

4. **Performance Monitoring**
   ```javascript
   // Track agent performance
   const metrics = {
     startTime: Date.now(),
     tasksCompleted: 0,
     commitsCreated: 0,
     testsRun: 0,
     conflictsResolved: 0
   };
   ```

## Local Multi-Agent Orchestrator System (Claude CLI Only)

### Overview
The project includes a fully functional multi-agent orchestrator system that uses only the Claude CLI tool (no API calls) to coordinate multiple development agents working in parallel on different features.

### System Architecture
```
Local Claude Orchestrator (Node.js)
├── Task Queue System (JSON files in shared/tasks/)
├── Agent Coordination (Git worktrees)
├── iOS Simulator Integration (MCP tools)
└── Result Management (shared/results/)
```

### Getting Started

#### 1. System Location
The orchestrator is located at:
```
/claude-agents/
├── orchestrator.js          # Main orchestrator engine
├── shared/
│   ├── tasks/              # JSON task definitions
│   └── results/           # Agent execution results
└── worktrees/             # Isolated agent workspaces
```

#### 2. Starting the Orchestrator
```bash
cd ./claude-agents
node orchestrator.js
```

The orchestrator will:
- ✅ Initialize with 15 iOS simulators
- ✅ Monitor `shared/tasks/` for new JSON task files
- ✅ Create git worktrees for each agent
- ✅ Launch Claude CLI sessions in isolated environments
- ✅ Track results and coordinate multiple agents

#### 3. Creating Tasks
Create JSON files in `shared/tasks/` to trigger agent workflows:

**iOS Feature Workflow Example:**
```json
{
  "id": "feature-navigation-fix",
  "type": "ios-feature-workflow",
  "feature": {
    "name": "Navigation Bar Theme Fix",
    "description": "Fix navigation bar color in dim theme mode",
    "requirements": [
      "Navigation bar should use dim gray (rgb(46, 46, 50)) in dim mode",
      "Colors should update immediately when theme changes",
      "Test in iOS simulator to verify fix works"
    ]
  },
  "priority": 9,
  "simulator": "iPhone 16 Pro"
}
```

**Test Orchestrator System:**
```json
{
  "id": "test-orchestrator-system",
  "type": "test-orchestrator",
  "description": "Test the multi-agent orchestrator system capabilities",
  "priority": 10
}
```

### System Capabilities

#### ✅ Verified Working Features
Based on successful test results:
- **Claude CLI Integration**: Uses only `claude` command (no API calls)
- **iOS Simulator Access**: 15 simulators detected and accessible
- **Git Worktree Support**: Creates isolated development environments  
- **Project Integration**: Full access to Catbird.xcodeproj
- **Task Processing**: JSON-based queue system with duplicate prevention

#### Agent Workflow Process
1. **Task Detection**: Monitors `shared/tasks/` every 2 seconds
2. **Worktree Creation**: Creates isolated git branch for each agent
3. **Agent Launch**: Spawns Claude CLI session with comprehensive instructions
4. **Execution**: Agent works through analysis, implementation, testing phases
5. **Results**: Saves detailed results to `shared/results/`

### iOS-Specific Features

#### Comprehensive iOS Workflow
When processing `ios-feature-workflow` tasks, agents execute:

**Phase 1 - Analysis:**
- Examine current implementation
- Identify root causes of issues
- Document findings

**Phase 2 - Implementation:**
- Fix identified issues
- Ensure proper color values and theme handling
- Verify no regressions in other modes

**Phase 3 - Testing:**
- Build app for iOS simulator
- Test theme switching between light, dark, and dim modes
- Take screenshots showing fixes working
- Test on multiple screens for consistency

**Phase 4 - Documentation:**
- Document changes made
- Explain root cause and solution
- Create summary of testing results

#### Agent Instructions Template
Each agent receives comprehensive instructions including:
```markdown
## Catbird Project Context
This is the Catbird iOS app - a native Bluesky client built with SwiftUI.

Key files you'll likely need:
- Core/State/ThemeManager.swift (theme management)
- Core/UI/ThemeColors.swift (color definitions)
- App/ContentView.swift (main app structure)
- Features/Profile/Views/HomeView.swift (navigation structure)

## iOS Development Guidelines
- Use SwiftUI for UI components
- Follow iOS Human Interface Guidelines
- Implement proper error handling
- Use modern Swift concurrency (async/await)
- Test on iOS simulator to verify fixes
```

### Example: Navigation Bar Theme Fix Success

The orchestrator successfully coordinated a navigation bar theme fix:

**Problem**: Navigation bars showed black instead of dim gray in dim theme mode
**Solution**: Enhanced ThemeManager with proper color values and force update mechanisms
**Result**: ✅ All navigation bars now use correct dim gray (rgb(46, 46, 50))

**Test Results**:
```json
{
  "orchestratorStatus": "working",
  "cliBinaryFound": true,
  "simulatorAccess": true,
  "projectAccess": true,
  "worktreeSupport": true
}
```

### Best Practices

#### 1. Task Design
- Use descriptive IDs and clear requirements
- Specify exact simulators for iOS testing
- Include priority levels for task ordering

#### 2. Agent Coordination
- Each agent works in isolated git worktree
- Results are saved to shared directory
- Duplicate task processing is prevented

#### 3. Development Workflow
- Agents make incremental commits with clear messages
- Screenshots are taken for visual verification
- Comprehensive testing across different themes/modes

### Troubleshooting

#### Common Issues
1. **Duplicate Tasks**: Fixed with processedTasks tracking
2. **Agent Isolation**: Each agent gets unique worktree
3. **CLI Dependencies**: System verifies Claude CLI availability

#### Recovery Patterns
```bash
# Clean up failed worktrees
rm -rf ./claude-agents/worktrees/workflow-*

# Restart orchestrator
cd ./claude-agents && node orchestrator.js
```

### Performance Metrics
- **Task Processing**: ~2 second detection interval
- **Worktree Creation**: <5 seconds per agent
- **iOS Simulator Access**: 15 devices available
- **Build Times**: 45-90 seconds (clean), 10-20 seconds (incremental)

### Future Enhancements
The system is ready for:
- Parallel feature development across multiple worktrees
- Automated merge conflict resolution
- Integration with CI/CD pipelines
- Performance monitoring and metrics collection

This multi-agent system enables autonomous iOS development with proper isolation, testing, and coordination while using only the Claude CLI tool.