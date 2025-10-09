# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Catbird is a **PRODUCTION-READY** cross-platform client for Bluesky built with SwiftUI and modern Swift 6 patterns, supporting both iOS and macOS. This is a release-ready application where all code must be production-quality with no placeholders, fallbacks, or temporary implementations. It uses the Petrel library for AT Protocol communication.

### Project Components
- **Catbird**: Cross-platform app with SwiftUI interface for Bluesky (iOS and macOS)
- **Petrel**: Swift library providing AT Protocol networking and data models (auto-generated from Lexicon JSON files)
- **CatbirdNotificationWidget**: iOS widget extension for notifications
- **CatbirdFeedWidget**: Feed widget extension (iOS only, in development)

### Platform Support
- **iOS 26.0+**: Full featured mobile client with UIKit optimizations and Liquid Glass design (minimum iOS 18.0+ for legacy support)
- **macOS Tahoe 26.0+**: Native macOS client with SwiftUI-based feed implementation and Liquid Glass (minimum macOS 13.0+ for legacy support)
- **Shared Codebase**: ~95% code sharing between platforms using conditional compilation

### iOS 26 Naming Convention
Apple introduced a major change to OS naming at WWDC 2025, moving from sequential numbering to year-based naming:
- **iOS 26** represents the 2025-2026 release cycle (September 2025 - September 2026)
- What would have been iOS 19 is now iOS 26, reflecting the year it will be current
- This naming convention applies to all Apple platforms: iOS 26, iPadOS 26, macOS Tahoe 26, watchOS 26, tvOS 26, visionOS 26
- Provides consistency across all Apple operating systems and aligns with industry conventions (like automotive model years)

## Build and Development Commands

### Building the App

#### iOS Builds
- **Quick incremental build**: `./quick-build.sh [scheme]`
- **Build for simulator by name**: Use MCP tools with `build_sim` command
- **Build for physical device**: Use MCP tools with `build_device` command
- **Clean build**: Use MCP tools with `clean` command

#### macOS Builds
- **Build for macOS**: Use MCP tools with `build_macos` command
- **Build and run macOS**: Use MCP tools with `build_run_macos` command
- **Get macOS app path**: Use MCP tools with `get_mac_app_path` command
- **Launch macOS app**: Use MCP tools with `launch_mac_app` command

### Testing

#### iOS Testing
- **Run tests on simulator**: Use MCP tools with `test_sim` command
- **Run tests on device**: Use MCP tools with `test_device` command

#### macOS Testing
- **Run tests on macOS**: Use MCP tools with `test_macos` command

#### General Testing
- **Test framework**: Swift Testing (NOT XCTest) - use `@Test` attribute
- **Check Swift syntax errors**: `./swift-check.sh` or `./quick-error-check.sh`

### Petrel Code Generation
- **Generate AT Protocol models**: `cd Petrel && python Generator/main.py`
- Generated files go to `Petrel/Sources/Petrel/Generated/`
- Lexicon definitions in `Petrel/Generator/lexicons/`

### Code Quality Checks
- **Swift syntax check**: `swift -frontend -parse [filename]`
- **Full typecheck with iOS SDK**: `swiftc -typecheck -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk -target arm64-apple-ios18.0 [filename]`
- **Full typecheck with macOS SDK**: `swiftc -typecheck -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos13.0 [filename]`
- **Linting**: SwiftLint configuration in `.swiftlint.yml`

### Headless Task Automation (Copilot CLI)

Run multiple development tasks in parallel or sequence without manual interaction using the GitHub Copilot CLI task runners.

#### Quick Start Examples

**Single Task Execution:**
```bash
# Syntax check with specific approval
./copilot-runner.sh single "syntax-check" \
  "Check all Swift files for syntax errors" \
  "--allow-tool 'shell(swift)'"
```

**Parallel Task Execution (runs simultaneously):**
```bash
# Build for both platforms at once
./copilot-runner.sh parallel \
  "build-ios|Build for iOS simulator|--allow-all-tools" \
  "build-macos|Build for macOS|--allow-all-tools" \
  "lint|Run SwiftLint|--allow-tool 'shell(swiftlint)'"
```

**Sequential Task Execution (runs in order):**
```bash
# CI/CD pipeline - stop on failure
./copilot-runner.py from-file copilot-tasks.example.json \
  --workflow ci-pipeline \
  --sequential \
  --stop-on-failure
```

**Workflow Execution from Config:**
```bash
# Pre-commit checks
./copilot-runner.py from-file copilot-tasks.example.json \
  --workflow pre-commit

# Full multi-platform build
./copilot-runner.py from-file copilot-tasks.example.json \
  --workflow full-build
```

#### Available Tools

- **`copilot-runner.sh`** - Bash version (simple, portable, no dependencies)
- **`copilot-runner.py`** - Python version (advanced features, JSON/YAML support)
- **`copilot-tasks.example.json`** - Example task definitions with workflows

#### Key Features

- **Parallel execution**: Run independent tasks simultaneously for faster completion
- **Sequential execution**: Chain dependent operations in order
- **Headless operation**: Auto-approval with configurable security controls
- **Task definitions**: Reusable JSON/YAML task configurations
- **Result logging**: All outputs saved to `copilot-results/` with timestamps
- **Workflow support**: Pre-defined task sequences (pre-commit, ci-pipeline, full-build)
- **Security controls**: Granular approval flags for safe automation

#### Security & Approval Flags

Control what Copilot can do without manual approval:

```bash
# Safe: Only allow specific commands
--allow-tool 'shell(swift)'        # Allow Swift compiler only
--allow-tool 'shell(git status)'   # Allow read-only git
--deny-tool 'shell(rm)'            # Block dangerous commands

# Moderate: Allow builds but deny destructive operations
--allow-tool 'shell(xcodebuild)' --deny-tool 'shell(rm)' --deny-tool 'write'

# Full automation (⚠️ use in containers/VMs only)
--allow-all-tools
```

#### Common Development Workflows

**Pre-commit Validation:**
```bash
./copilot-runner.py from-file copilot-tasks.example.json \
  --tasks swift-syntax-check swiftlint git-status \
  --sequential
```

**Multi-platform CI Build:**
```bash
./copilot-runner.py from-file copilot-tasks.example.json \
  --workflow ci-pipeline \
  --stop-on-failure \
  --results-dir ./ci-results
```

**Parallel Quality Checks:**
```bash
./copilot-runner.sh parallel \
  "swiftlint|Run SwiftLint|--allow-tool 'shell(swiftlint)'" \
  "todos|Check for TODOs|--allow-tool 'shell(rg)'" \
  "prints|Find print statements|--allow-tool 'shell(rg)'"
```

#### Integration Examples

**Makefile Integration:**
```makefile
.PHONY: copilot-check
copilot-check:
	./copilot-runner.py from-file copilot-tasks.json --workflow pre-commit

.PHONY: copilot-build-all
copilot-build-all:
	./copilot-runner.py from-file copilot-tasks.json --workflow full-build
```

**Git Pre-commit Hook:**
```bash
#!/bin/bash
# .git/hooks/pre-commit
./copilot-runner.sh sequential \
  "syntax|Check Swift syntax|--allow-tool 'shell(swift)'" \
  "lint|Run SwiftLint|--allow-tool 'shell(swiftlint)'" \
  || exit 1
```

**GitHub Actions:**
```yaml
- name: Run Copilot CI Tasks
  run: |
    ./copilot-runner.py from-file copilot-tasks.json \
      --workflow ci-pipeline \
      --sequential \
      --stop-on-failure
```

#### Output & Results

All task execution generates timestamped log files:
- `copilot-results/run_TIMESTAMP.log` - Main execution log
- `copilot-results/task_TASKNAME_TIMESTAMP.log` - Individual task logs

Exit codes:
- `0` - All tasks succeeded
- `1` - One or more tasks failed

#### Full Documentation

See **`COPILOT_RUNNER_README.md`** for:
- Complete task definition format (JSON/YAML)
- Advanced features and options
- Security best practices
- Troubleshooting guide
- More integration examples

## Architecture

### State Management
```
AppState (@Observable)
├── AuthManager (authentication state)
├── PostShadowManager (Actor - thread-safe post interactions)
├── PreferencesManager (user preferences with server sync)
├── GraphManager (social graph cache)
├── NotificationManager (push notifications)
└── ABTestingFramework (A/B testing and experiments)
```

### Key Architectural Patterns
- **MVVM** with @Observable for state management (NOT Combine/ObservableObject)
- **Actors** for thread-safe operations (PostShadowManager)
- **Structured concurrency** with async/await throughout
- **NavigationHandler protocol** for decoupled navigation
- **FeedTuner** for intelligent thread consolidation in feeds
- **A/B Testing** framework for feature experimentation

## Liquid Glass API Integration

### Overview
iOS 26 introduces **Liquid Glass**, a revolutionary design system that combines the optical properties of glass with fluid animations. This translucent material creates a dynamic layer for controls and navigation elements, automatically adapting to content, lighting, and user interactions.

### Core SwiftUI APIs

#### Basic Glass Effects
Apply Liquid Glass to any view using the `.glassEffect()` modifier:

```swift
Text("Hello, World!")
  .font(.title)
  .padding()
  .glassEffect()  // Default: .regular in .capsule shape

// Custom configuration
Text("Custom Glass")
  .padding()
  .glassEffect(.regular.tint(.blue).interactive(), in: .rect(cornerRadius: 16))
```

#### Glass Variants
- **`.regular`**: Standard Liquid Glass appearance
- **`.clear`**: Minimal glass effect for subtle elevation
- **`.identity`**: No effect (useful for conditional application)

#### Interactive Glass
Enable touch/pointer reactions with `.interactive()`:

```swift
Button("Interactive Button") {
  // action
}
.padding()
.glassEffect(.regular.interactive())
```

### Container-Based Rendering

#### GlassEffectContainer
Use `GlassEffectContainer` for optimal performance when applying glass effects to multiple views:

```swift
GlassEffectContainer(spacing: 20) {
  HStack(spacing: 20) {
    ForEach(items, id: \.id) { item in
      ItemView(item)
        .glassEffect()
    }
  }
}
```

#### Glass Effect Unions
Combine multiple views into a single glass shape:

```swift
@Namespace private var glassNamespace

GlassEffectContainer(spacing: 10) {
  HStack(spacing: 10) {
    Button("First") { }
      .glassEffect()
      .glassEffectUnion(id: "buttonGroup", namespace: glassNamespace)
    
    Button("Second") { }
      .glassEffect()
      .glassEffectUnion(id: "buttonGroup", namespace: glassNamespace)
  }
}
```

### Morphing Transitions

#### Glass Effect IDs
Create smooth morphing animations during view transitions:

```swift
@State private var isExpanded = false
@Namespace private var morphNamespace

GlassEffectContainer(spacing: 40) {
  HStack {
    Image(systemName: "pencil")
      .glassEffect()
      .glassEffectID("tool", in: morphNamespace)
    
    if isExpanded {
      Image(systemName: "eraser")
        .glassEffect()
        .glassEffectID("tool2", in: morphNamespace)
        .transition(.glassEffect)
    }
  }
}
```

### Platform-Specific Considerations

#### Automatic Adoption
Standard SwiftUI components automatically adopt Liquid Glass:
- Navigation bars and toolbars
- Tab bars and sidebars
- Sheets and popovers
- Buttons and form controls

#### Custom Components
Apply glass effects judiciously to custom components:
- Limit to functional elements (navigation, controls)
- Avoid overuse - glass should enhance, not distract from content
- Test with accessibility settings (Reduce Transparency/Motion)

### Performance Best Practices

1. **Use containers**: Group related glass elements in `GlassEffectContainer`
2. **Minimize nesting**: Avoid multiple layers of glass effects
3. **Profile regularly**: Test performance across devices
4. **Respect accessibility**: Ensure fallbacks for transparency/motion reduction

### Migration from Custom Blur Effects

#### Remove Custom Backgrounds
**❌ Before (iOS 25 and earlier):**
```swift
.background(Material.ultraThinMaterial)
.presentationBackground(Material.regularMaterial)
```

**✅ After (iOS 26+):**
```swift
// Remove custom backgrounds - system handles automatically
// For custom elements, use .glassEffect() instead
.glassEffect()
```

#### Update Sheet Presentations
**❌ Before:**
```swift
.presentationBackground {
  Rectangle()
    .fill(Material.regularMaterial)
}
```

**✅ After:**
```swift
// Remove - sheets automatically use Liquid Glass
// System handles partial height insets and morphing
```

### Testing with Liquid Glass

- **Accessibility**: Test with "Reduce Transparency" and "Reduce Motion" enabled
- **Performance**: Profile glass-heavy interfaces across device tiers
- **Visual verification**: Test against light/dark content backgrounds
- **Cross-platform**: Verify glass appearance on both iOS and macOS

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
│   ├── Services/          # Core services (includes ABTestingFramework)
│   ├── State/             # State management
│   ├── UI/                # Reusable UI components
│   └── Utilities/         # Helper utilities
├── Features/              # Feature modules
│   ├── Auth/              # Authentication
│   ├── Chat/              # Direct messaging
│   ├── Feed/              # Timeline and feeds
│   ├── Media/             # Video/image handling
│   ├── Migration/         # Data migration tools
│   ├── Moderation/        # Content moderation
│   ├── Notifications/     # Push notifications
│   ├── Profile/           # User profiles
│   ├── RepositoryBrowser/ # CAR file browser (experimental)
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
- **Liquid Glass best practices**:
  - Use `GlassEffectContainer` for grouped glass elements
  - Prefer system glass effects over custom blur materials
  - Apply `.glassEffect()` sparingly to avoid visual overload
  - Test with accessibility settings (Reduce Transparency/Motion)
  - Remove custom `Material` backgrounds in favor of automatic adoption

## Cross-Platform Development

### Platform-Specific Patterns

#### Conditional Compilation
Use `#if os(iOS)`, `#if os(macOS)` for platform-specific code. **NEVER** put conditional compilation directly in modifier chains.

**❌ WRONG - Conditional modifier branching:**
```swift
var body: some View {
    VStack {
        // content
    }
    #if os(iOS)
    .navigationBarHidden(true)
    #elseif os(macOS)
    .frame(minWidth: 480)
    #endif
}
```

**✅ CORRECT - Use ViewModifier protocols:**
```swift
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
```

#### Platform-Specific Values
Use computed properties or functions for platform-specific values.

**✅ CORRECT:**
```swift
private func bottomPadding(for geometry: GeometryProxy) -> CGFloat {
    #if os(iOS)
    max(geometry.safeAreaInsets.bottom, 24)
    #else
    24
    #endif
}
```

#### Availability Annotations
Always include both platforms in `@available` annotations:

**✅ CORRECT:**
```swift
@available(iOS 26.0, macOS 26.0, *)
struct MyView: View {
    // implementation
}
```

### Platform Utilities

The codebase includes cross-platform utility extensions in `Core/Extensions/`:

- **CrossPlatformImage.swift**: Unified image handling across platforms
- **CrossPlatformUI.swift**: Common UI patterns and type aliases
- **PlatformColors.swift**: Platform-specific color definitions
- **PlatformDeviceInfo.swift**: Device and platform detection utilities
- **PlatformHaptics.swift**: Haptic feedback abstraction
- **PlatformScreenInfo.swift**: Screen metrics and capabilities
- **PlatformSystem.swift**: System-level functionality

#### Platform Detection Examples
```swift
// Device type detection
if PlatformDeviceInfo.userInterfaceIdiom == .phone {
    // iPhone-specific code
}

// Screen capabilities
if PlatformScreenInfo.hasDynamicIsland {
    // Handle Dynamic Island
}

// Platform-specific haptics
PlatformHaptics.impact(.medium)
```

### Feed Implementation Differences

#### iOS Implementation
- Uses `UICollectionView` via `FeedCollectionViewControllerIntegrated`
- Optimized for touch interactions and scrolling performance
- Supports advanced features like UIUpdateLink (iOS 18+)

#### macOS Implementation
- Uses SwiftUI `List` with `FeedPostRow` components
- Native macOS scrolling behavior
- Maintains same state management and functionality

**Example from `FeedCollectionViewBridge.swift`:**
```swift
#if os(iOS)
struct FeedCollectionViewWrapper: View {
    var body: some View {
        FeedCollectionViewIntegrated(
            stateManager: stateManager,
            navigationPath: $navigationPath
        )
    }
}
#else
struct FeedCollectionViewWrapper: View {
    var body: some View {
        List {
            ForEach(stateManager.posts, id: \.postKey) { postViewModel in
                FeedPostRow(viewModel: postViewModel, navigationPath: $navigationPath)
            }
        }
        .listStyle(.plain)
    }
}
#endif
```

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
- **FeedPrefetchingManager**: Handles intelligent content prefetching

### Post Interactions
- **PostViewModel**: Handles individual post actions
- **PostShadowManager** (Actor): Thread-safe state for likes/reposts/replies
- All interactions update both local state and server via ATProtoClient

### Navigation
- **AppNavigationManager**: Central navigation coordinator
- **NavigationDestination**: Type-safe navigation targets
- **NavigationHandler** protocol: Decouples navigation from views

### A/B Testing Framework
- **ABTestingFramework**: Manages experiments and feature flags
- Type-safe experiment definitions with `ExperimentConfig`
- User bucketing with consistent assignment
- Performance metrics tracking per experiment
- Integration with analytics for conversion tracking

## Testing Guidelines

### Unit Tests
- Test framework: **Swift Testing** (NOT XCTest)
- Use `@Test` attribute for test functions
- Mock ATProtoClient for network tests
- Use `@MainActor` for UI-related tests
- Test file: `CatbirdTests/CatbirdTests.swift`

### UI Tests
- Test critical user flows (login, post, navigate)
- Use accessibility identifiers for reliable element selection
- Simulator automation via MCP tools

### Testing Commands

#### iOS Testing
```bash
# Run tests on iOS simulator
# Use MCP: test_sim with simulatorName: "iPhone 16 Pro"

# Run tests on physical device
# Use MCP: test_device with deviceId from list_devices
```

#### macOS Testing
```bash
# Run tests on macOS
# Use MCP: test_macos with scheme: "Catbird"
```

#### General Testing
```bash
# Check syntax errors quickly
./swift-check.sh

# Run specific test
# Use Swift Testing filter parameter
```

### iOS 26 Testing Considerations

#### Liquid Glass Testing
- **Accessibility testing**: Enable "Reduce Transparency" and "Reduce Motion" in Settings
- **Visual regression testing**: Compare glass effects across light/dark modes
- **Performance profiling**: Test glass-heavy UIs on older device models
- **Cross-platform consistency**: Verify glass appearance matches between iOS and macOS

#### Build Configuration for iOS 26
```bash
# Build with iOS 26 SDK for full Liquid Glass support
# Use MCP: build_sim with simulatorName: "iPhone 16 Pro"

# Test backward compatibility with iOS 18+ deployment target
# Verify graceful fallback behavior on pre-iOS 26 systems
```

#### Testing Commands for iOS 26 Features
```bash
# Test on iOS 26 simulator with glass effects enabled
# Use MCP: test_sim with simulatorName: "iPhone 16 Pro" scheme: "Catbird"

# Test with accessibility settings enabled
# 1. Enable Settings > Accessibility > Display > Reduce Transparency
# 2. Enable Settings > Accessibility > Motion > Reduce Motion
# 3. Re-run tests to verify fallback behavior

# Profile glass effect performance
# Use Instruments to analyze rendering performance of glass effects
```

## Common Development Tasks

### Adding a New Feature
1. Create feature folder in `/Features`
2. Add Observable ViewModel if needed
3. Implement SwiftUI views with cross-platform support
4. Use proper `@available(iOS 26.0, macOS 26.0, *)` annotations
5. Handle platform differences with ViewModifier protocols
6. Wire up navigation in AppNavigationManager
7. Add unit tests using Swift Testing for both platforms
8. Test on both iOS simulator and macOS
9. Consider A/B test wrapper if experimental

### Cross-Platform Feature Development
When adding features that work across platforms:

1. **Design for both platforms**: Consider iOS mobile patterns and macOS desktop patterns
2. **Use platform utilities**: Leverage `PlatformDeviceInfo`, `PlatformScreenInfo`, etc.
3. **Handle input differences**: Touch vs. mouse interactions
4. **Respect platform conventions**: iOS navigation vs. macOS window management
5. **Test thoroughly**: Verify behavior on both platforms
6. **iOS 26 Liquid Glass considerations**:
   - Glass effects work automatically across iOS 26 and macOS Tahoe 26
   - Use `@available(iOS 26.0, macOS 26.0, *)` for glass-specific features
   - Provide fallback experiences for iOS 18+ and macOS 13+ compatibility
   - Test glass effects with platform-specific accessibility settings

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
- Profile with order files: `./generate_order_file.sh`

## Widget Development
- Widget extensions in `/CatbirdNotificationWidget` and `/CatbirdFeedWidget`
- Shares data via App Groups
- Keep widget timeline updates minimal for battery
- Test on both simulator and device

## Experimental Features
- **Repository Browser**: CAR file parsing and browsing
- **Migration System**: Import/export user data
- Controlled via `ExperimentalFeaturesCoordinator`
- Enable via Settings > Advanced > Experimental Features

## Important Notes

### Release Status
The app should be modified to always be in a production-ready state with all major features implemented and working.

### Security & Performance
- All credentials stored in Keychain via `KeychainManager`
- DPoP (Demonstrating Proof of Possession) keys managed separately
- OAuth and legacy auth flows both supported
- Use `FeedTuner` for intelligent thread consolidation
- Image prefetching is handled by `ImageLoadingManager`
- Video assets are managed by `VideoAssetManager` with caching
- Never log sensitive information

## Coding Principles

### Overarching Development Directive
- **ALWAYS WRITE CODE FOR A PRODUCTION, RELEASE-READY APP**
- **NEVER use placeholder implementations, fallbacks, or temporary code**
- **NEVER write comments like "in a real implementation" or "this would typically"**
- **ALL code must be complete, production-quality implementations**
- **NO "TODO" comments or unfinished features**
- **Every feature must be fully functional from the first implementation**

## Shell Tooling

### General Purpose Tools
- **Finding FILES**: use `fd` (faster than find)
- **Finding TEXT/strings**: use `rg` (ripgrep - faster than grep) 
- **Finding CODE STRUCTURE**: use `ast-grep` (semantic code search)
- **Selecting from multiple results**: pipe to `fzf` (fuzzy finder)
- **Interacting with JSON**: use `jq` (JSON processor)
- **Interacting with YAML/XML**: use `yq` (YAML/XML processor)

### Swift/Xcode Specific Usage

#### Finding Swift Files and Patterns
```bash
# Find all Swift files containing a specific class/struct
fd -e swift | xargs rg "class MyClass|struct MyClass"

# Find ViewModels in Features directory
fd -t f -e swift . Catbird/Features | xargs rg "@Observable.*ViewModel"

# Find all SwiftUI views with specific modifiers
rg "\.navigationTitle|\.toolbar" --type swift

# Find async/await patterns in Swift files
rg "async\s+func|await\s+" --type swift Catbird/

# Find @MainActor usage across the codebase
rg "@MainActor" --type swift | fzf
```

#### Swift Code Structure Analysis
```bash
# Find all function declarations in a Swift file
ast-grep --pattern 'func $_($_) { $$$ }' path/to/file.swift

# Find all @Observable classes
ast-grep --pattern '@Observable class $_ { $$$ }' --lang swift

# Find all NavigationDestination enum cases
ast-grep --pattern 'case $_($_)' Catbird/Core/Navigation/

# Find all SwiftUI View structs
ast-grep --pattern 'struct $_: View { $$$ }' --lang swift
```

#### Xcode Project Files (JSON/PLIST)
```bash
# Analyze project.pbxproj structure
cat Catbird.xcodeproj/project.pbxproj | jq '.objects | keys'

# Find specific build settings
rg "SWIFT_VERSION|IPHONEOS_DEPLOYMENT_TARGET" Catbird.xcodeproj/

# Check Info.plist configurations
yq '.CFBundleIdentifier' Catbird/Resources/Info.plist
```

#### Interactive File/Code Selection
```bash
# Find and open Swift files interactively
fd -e swift Catbird/ | fzf --preview 'head -50 {}'

# Search for functions and open in editor
rg "func " --type swift | fzf | cut -d: -f1 | xargs code

# Find and examine SwiftUI modifiers
rg "\.modifier|\.background|\.foregroundColor" --type swift | fzf
```

#### Performance and Debugging
```bash
# Find potential retain cycles (self usage in closures)
rg "self\." --type swift Catbird/ | fzf

# Find @MainActor violations
rg "@MainActor|await.*MainActor" --type swift

# Find console logging statements
rg "print\(|os_log|Logger" --type swift Catbird/
```

#### AT Protocol Model Investigation
```bash
# Find generated Petrel models
fd -e swift . Petrel/Sources/Petrel/Generated | fzf --preview 'rg "struct|class" {}'

# Search for specific AT Protocol records
rg "AppBsky.*Post|AppBsky.*Profile" --type swift Petrel/

# Find API client usage patterns
rg "ATProtoClient" --type swift Catbird/ | fzf
```

#### Swift Frontend Error Checking
```bash
# Basic syntax check (no dependencies)
swift -frontend -parse filename.swift

# Full typecheck with iOS SDK (shows all compilation errors)
swiftc -typecheck -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk -target arm64-apple-ios18.0 filename.swift

# Batch check multiple files for syntax errors
find Catbird/ -name "*.swift" | head -10 | xargs -I {} swift -frontend -parse {}

# Check specific file with full error context
swiftc -typecheck -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk -target arm64-apple-ios18.0 -I /path/to/modules filename.swift
```

## Build System Configuration

### Incremental Build Optimization
The project is configured for optimal incremental builds using Swift 6.1 and Xcode 16:

**Debug Configuration (Development):**
```
SWIFT_COMPILATION_MODE = Incremental
SWIFT_OPTIMIZATION_LEVEL = -Onone  
ONLY_ACTIVE_ARCH = YES
DEBUG_INFORMATION_FORMAT = dwarf
SWIFT_USE_INTEGRATED_DRIVER = NO  // Better incremental builds
```

**Release Configuration (Production):**
```
SWIFT_COMPILATION_MODE = WholeModule
SWIFT_OPTIMIZATION_LEVEL = -O
ONLY_ACTIVE_ARCH = NO
DEBUG_INFORMATION_FORMAT = dwarf-with-dsym
```

### Build Performance Tips
- **Use incremental builds** for development - they're 4x faster than clean builds
- **Syntax checking**: Use `swift -frontend -parse [filename]` for quick validation
- **Full builds**: Only use when necessary for release or after major changes
- **Network optimization**: Block `developerservices2.apple.com` in `/etc/hosts` to avoid xcodebuild network delays
- **Thread configuration**: Enable "Parallelize Build" with 1.5-2x CPU core count
- **Explicit modules**: Available experimentally with `SWIFT_ENABLE_EXPLICIT_MODULES = YES`

### Git Hooks Integration
The project includes automated quality checks:
- **Pre-commit**: Swift syntax validation, TODO/FIXME warnings, print() statement detection  
- **Commit-msg**: Conventional commit format enforcement
- **Pre-push**: Build verification, secrets scanning, branch protection

### Development Workflow
- **ALWAYS** run syntax checks before committing: `./swift-check.sh`
- **Use incremental builds** for development iteration
- **Full builds** only for release preparation or major refactoring
- **Leverage MCP tools** for iOS simulator/device and macOS builds
- **Test on both platforms** when making UI changes
- **Use platform-specific MCP commands**:
  - iOS: `build_sim`, `test_sim`, `build_device`
  - macOS: `build_macos`, `test_macos`, `build_run_macos`

---

*This document is focused on essential information for effective development. For detailed MCP server usage, simulator automation, and testing patterns, see TESTING_COOKBOOK.md and other documentation files.*
- be sure to think about capture semantics for `self` in Swift 6