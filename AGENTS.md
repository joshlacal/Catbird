# AGENTS.md

This guide provides prescriptive, production-focused instructions for AI agents (GitHub Copilot, Aider, Cursor, etc.) working in this repository. **All workflows leverage MCP (Model Context Protocol) servers for intelligent automation.**

## Critical Development Principles

### Efficiency & Workflow
- **NO timeline estimates**: Don't predict how long things will take - timelines are consistently inaccurate
- **NO dates in documentation**: Avoid date-based references that become stale immediately
- **BUILD FREELY**: Builds take ~20 seconds on M4 Max - just do it
- **Verify with real builds**: Use XcodeBuildMCP for actual compilation, not just syntax checks
- **Full verification loop**: Build → Run → describe_ui → Screenshot → Test
- **Use MCP servers extensively**: Always verify against Apple docs via MCP, use xcodebuild-mcp, leverage all available MCP tools
- **Work continuously**: No artificial session boundaries - complete tasks fully without stopping prematurely
- **Maximize parallelism**: Use parallel tool calls aggressively for all independent operations
- **Parallel agents**: Consider using `parallel-agents.py` for truly independent concurrent tasks

### Documentation Management
- **Session notes directory**: Place temporary fix documentation in `docs/session-notes/` (gitignored, auto-cleaned)
- **Keep root clean**: Never clutter main directory with ad-hoc fix documentation files
- **Permanent docs only**: Only commit documentation with lasting value to repository root
- **Clear old fixes**: Session notes should be reviewed and either promoted to permanent docs or deleted

### Context Management
- **No context anxiety**: Don't underestimate capacity - you can accomplish more in a session than you think
- **Rolling context**: Application maintains context automatically across work - don't artificially limit scope
- **Work depth over breadth**: Complete tasks thoroughly rather than stopping prematurely due to perceived limits
- **Trust your capabilities**: The system handles context management - focus on completing work

### Communication Style
- **Minimal explanations**: Execute efficiently without verbose preambles or postambles
- **Skip confirmations**: Don't repeatedly ask for permission on straightforward, low-risk tasks
- **Direct action**: Prefer immediate execution over prolonged discussion for simple operations
- **Reduce safety theater**: Balance caution with productivity - not everything needs multiple confirmations

## Parallel Agents System

For truly independent tasks that can run concurrently, use the parallel agents system to spawn multiple Copilot CLI instances:

```bash
# Example: Run multiple independent tasks simultaneously
./parallel-agents.py quick \
  "Check Swift syntax in Core/" \
  "Build iOS target" \
  "Run tests" \
  --approval='--allow-all-tools'
```

**Use parallel agents for:**
- Multi-platform builds (iOS + macOS + tests simultaneously)
- Independent code quality checks (syntax + lint + security scans)
- Parallel feature development across different modules
- Concurrent documentation generation
- Large-scale refactoring across independent files

See `PARALLEL_AGENTS_README.md` for complete documentation.

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

## MCP Server Integration

This project leverages Model Context Protocol (MCP) servers for intelligent automation and enhanced development workflows. **ALWAYS prefer MCP server commands over manual CLI operations** for consistency and automation.

### Available MCP Servers

#### 1. **sequential-thinking** - Master Planning and Analysis Tool
Your **primary cognitive command center** for complex problem-solving.

**ALWAYS use sequential-thinking FIRST for:**
- Feature planning (5-10 thoughts minimum)
- Bug root cause analysis (10-15 thoughts)
- Architecture decisions (8-12 thoughts)
- Performance optimization (12-20 thoughts)
- Refactoring strategies (8-15 thoughts)
- Test strategy development (5-8 thoughts)

**Key capabilities:**
- Dynamic thought adjustment (can increase totalThoughts mid-stream)
- Thought revision (mark thoughts as revisions to course-correct)
- Branching (explore multiple solution paths)
- Hypothesis generation and verification

**Example usage:**
```python
# Start with initial estimate
sequential_thinking:sequentialthinking(
    thought="Planning Timeline Refresh feature implementation",
    totalThoughts=8,
    nextThoughtNeeded=True,
    thoughtNumber=1
)

# Revise based on new findings
sequential_thinking:sequentialthinking(
    thought="Revising approach based on performance analysis",
    isRevision=True,
    revisesThought=3,
    thoughtNumber=7,
    totalThoughts=10  # Increased from 8
)
```

#### 2. **xcodebuild-mcp** - Xcode Build Operations
Comprehensive Xcode automation for builds, tests, and project management.

**Common operations:**
- `build_sim()` - Build for iOS/watchOS/tvOS/visionOS simulators
- `build_device()` - Build for physical devices
- `build_macos()` - Build for macOS
- `build_run_macos()` - Build and launch macOS app
- `test_sim()` - Run tests on simulator
- `test_device()` - Run tests on physical device
- `test_macos()` - Run tests on macOS
- `clean()` - Clean build artifacts
- `list_schemes()` - List available schemes
- `show_build_settings()` - Display build configuration

**Example workflow:**
```python
# Check project health
xcodebuild_mcp:doctor()

# Discover projects
xcodebuild_mcp:discover_projs(workspaceRoot="/path/to/Catbird")

# Build and test
xcodebuild_mcp:build_sim(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird",
    simulatorName="iPhone 16 Pro"
)

xcodebuild_mcp:test_sim(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird",
    simulatorName="iPhone 16 Pro"
)
```

#### 3. **ios-simulator** - Precise UI Automation
Automated UI testing with coordinate-based interactions. **NEVER guess coordinates from screenshots** - always use `describe_ui()` first.

**Critical operations:**
- `describe_ui()` - Get complete UI hierarchy with precise coordinates
- `tap()` - Tap at specific coordinates
- `swipe()` - Swipe between two points
- `type_text()` - Type text into focused field
- `screenshot()` - Capture current screen
- `record_sim_video()` - Record simulator video
- `launch_app_sim()` - Launch app by bundle ID

**Mandatory workflow for UI testing:**
```python
# Step 1: ALWAYS get UI hierarchy first
ui_tree = ios_simulator:describe_ui(simulatorUuid="...")

# Step 2: Use coordinates from ui_tree (never guess!)
ios_simulator:tap(
    x=ui_tree['button']['frame']['x'],
    y=ui_tree['button']['frame']['y'],
    simulatorUuid="..."
)

# Step 3: Verify with screenshot
ios_simulator:screenshot(simulatorUuid="...")
```

#### 4. **github** - Repository Management
Automated GitHub operations for issues, PRs, and workflows.

**Common operations:**
- `create_pull_request()` - Create PR with description
- `request_copilot_review()` - Request AI code review
- `add_issue_comment()` - Comment on issues
- `search_issues()` - Search repository issues
- `list_pull_requests()` - List PRs with filters
- `get_pull_request_diff()` - Get PR changes

**Example PR workflow:**
```python
# Create PR
github:create_pull_request(
    title="feat: Add Timeline Refresh",
    body="## Description\nImplemented pull-to-refresh...\n\n## Planning\nUsed sequential-thinking with 8 thoughts",
    base="main",
    head="feature/timeline-refresh"
)

# Request Copilot review
github:request_copilot_review(
    owner="catbird",
    repo="catbird",
    pullNumber=123
)
```

#### 5. **apple-doc-mcp** - Documentation Search
Access Apple framework documentation and best practices.

**Operations:**
- `search_symbols()` - Search for APIs and symbols
- `get_documentation()` - Get detailed documentation
- `list_technologies()` - List available frameworks

**Example usage:**
```python
# Research SwiftUI performance
apple_doc_mcp:search_symbols(
    query="SwiftUI performance optimization",
    framework="SwiftUI"
)

# Get specific API docs
apple_doc_mcp:get_documentation(
    path="documentation/SwiftUI/View"
)
```

### MCP Workflow Patterns

#### Pattern 1: Feature Development
```yaml
step_1_planning:
  tool: sequential-thinking
  thoughts: 8-10
  purpose: "Comprehensive feature planning with revision capability"

step_2_research:
  tool: apple-doc-mcp
  action: "Research relevant APIs and best practices"

step_3_implementation:
  tools: [Read, Write, Edit]
  guided_by: "sequential-thinking output"

step_4_build_test:
  tools:
    - xcodebuild-mcp:build_sim
    - xcodebuild-mcp:test_sim

step_5_ui_automation:
  tools:
    - ios-simulator:describe_ui  # Get precise coordinates
    - ios-simulator:tap
    - ios-simulator:screenshot

step_6_submission:
  tools:
    - github:create_pull_request
    - github:request_copilot_review
```

#### Pattern 2: Bug Diagnosis
```yaml
step_1_analysis:
  tool: sequential-thinking
  thoughts: 12-15
  features:
    - Generate hypotheses
    - Test each hypothesis
    - Revise based on findings

step_2_investigation:
  tools:
    - Read (examine code)
    - Grep (search patterns)
    - ios-simulator:describe_ui (reproduce bug)

step_3_verification:
  tools:
    - xcodebuild-mcp:test_sim
    - ios-simulator:screenshot (verify fix)

step_4_documentation:
  tool: github:add_issue_comment
```

#### Pattern 3: Performance Optimization
```yaml
step_1_strategy:
  tool: sequential-thinking
  thoughts: 15-20
  purpose: "Deep analysis of bottlenecks and optimization strategies"

step_2_profiling:
  tools:
    - xcodebuild-mcp:build_sim (release config)
    - ios-simulator:record_sim_video (baseline)

step_3_research:
  tool: apple-doc-mcp
  query: "performance optimization techniques"

step_4_implementation:
  tools: [Edit]
  implementing: "sequential-thinking solution"

step_5_validation:
  tools:
    - xcodebuild-mcp:test_sim
    - ios-simulator:record_sim_video (comparison)
```

## Build and Development Commands

### MCP-Enhanced Building (Preferred)

#### iOS Builds
```python
# Build for simulator
xcodebuild_mcp:build_sim(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird",
    simulatorName="iPhone 16 Pro"
)

# Build for physical device
xcodebuild_mcp:build_device(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird",
    configuration="Debug"
)

# Clean build
xcodebuild_mcp:clean(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird"
)
```

#### macOS Builds
```python
# Build for macOS
xcodebuild_mcp:build_macos(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird"
)

# Build and run
xcodebuild_mcp:build_run_macos(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird"
)
```

### Legacy Commands (Fallback Only)
Use only if MCP servers unavailable:
- **Quick incremental build**: `./quick-build.sh [scheme]`
- **Xcode GUI**: `open Catbird.xcodeproj` (run with ⌘R)
- **Manual xcodebuild**: `xcodebuild -project Catbird.xcodeproj -scheme Catbird -configuration Debug build`

### Testing

#### MCP-Enhanced Testing (Preferred)

**iOS Testing:**
```python
# Run tests on simulator with MCP
xcodebuild_mcp:test_sim(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird",
    simulatorName="iPhone 16 Pro"
)

# Run tests on physical device
xcodebuild_mcp:test_device(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird",
    deviceId="device-uuid-from-list_devices"
)
```

**macOS Testing:**
```python
# Run tests on macOS
xcodebuild_mcp:test_macos(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird"
)
```

**UI Testing with Sequential Thinking:**
```python
# Step 1: Plan test strategy
sequential_thinking:sequentialthinking(
    thought="Planning UI test for timeline refresh",
    totalThoughts=5
)

# Step 2: Get UI coordinates (NEVER guess!)
ui_tree = ios_simulator:describe_ui(simulatorUuid="...")

# Step 3: Execute automated interactions
ios_simulator:tap(x=ui_tree['refresh_button']['x'], y=...)
ios_simulator:screenshot()
```

#### General Testing
- **Test framework**: Swift Testing (NOT XCTest) - use `@Test` attribute
- **Quick syntax check**: `./swift-check.sh` or `./quick-error-check.sh`
- **Swift frontend parsing**: `swift -frontend -parse filename.swift`
- **Full typecheck (iOS)**: `swiftc -typecheck -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk -target arm64-apple-ios18.0 [filename]`
- **Full typecheck (macOS)**: `swiftc -typecheck -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos13.0 [filename]`

### Petrel Code Generation
```bash
# Generate AT Protocol models
cd Petrel && python Generator/main.py
```
- Generated files go to `Petrel/Sources/Petrel/Generated/`
- Lexicon definitions in `Petrel/Generator/lexicons/`

### Code Quality Checks
```bash
# Swift syntax check
swift -frontend -parse [filename]

# SwiftLint
swiftlint

# Batch check multiple files
find Catbird/ -name "*.swift" | head -10 | xargs -I {} swift -frontend -parse {}
```

## Headless Task Automation (copilot-cli MCP)

Spawn and manage multiple Copilot CLI agent instances via the **copilot-cli** MCP server for parallel or sequential task execution.

### Quick Start Examples

**Spawn a single agent:**
```python
# Run a syntax check task
copilot_cli:run_agent(
    prompt="Check all Swift files for syntax errors",
    workingDirectory="/path/to/Catbird",
    approval=["--allow-tool", "Bash(swift)"]
)
```

**Spawn multiple agents in parallel:**
```python
# Build for both platforms simultaneously
copilot_cli:run_agent(
    prompt="Build Catbird for iOS simulator",
    workingDirectory="/path/to/Catbird",
    approval=["--allow-all-tools"]
)

copilot_cli:run_agent(
    prompt="Build Catbird for macOS",
    workingDirectory="/path/to/Catbird",
    approval=["--allow-all-tools"]
)

copilot_cli:run_agent(
    prompt="Run SwiftLint on the codebase",
    workingDirectory="/path/to/Catbird",
    approval=["--allow-tool", "Bash(swiftlint)"]
)
```

**Check agent status:**
```python
# List all running agents
copilot_cli:list_agents()

# Get specific agent output
copilot_cli:get_agent_output(agentId="agent-uuid")

# Stop a running agent
copilot_cli:stop_agent(agentId="agent-uuid")
```

### Available Operations

| Operation | Description |
|-----------|-------------|
| `run_agent()` | Spawn a new Copilot CLI agent with a prompt |
| `list_agents()` | List all active agent instances |
| `get_agent_output()` | Get stdout/stderr from an agent |
| `stop_agent()` | Terminate a running agent |

### Key Features

- **Parallel execution**: Spawn multiple agents simultaneously for independent tasks
- **Managed lifecycle**: Track, monitor, and stop agents as needed
- **Output capture**: Retrieve agent output for verification
- **Security controls**: Granular approval flags per agent
- **Working directory**: Each agent can operate in a specific directory

### Security & Approval Flags

Control what each agent can do:

```python
# Safe: Only allow specific commands
approval=["--allow-tool", "Bash(swift)"]        # Allow Swift compiler only
approval=["--allow-tool", "Bash(git status)"]   # Allow read-only git
approval=["--deny-tool", "Bash(rm)"]            # Block dangerous commands

# Moderate: Allow builds but deny destructive operations
approval=["--allow-tool", "Bash(xcodebuild)", "--deny-tool", "Bash(rm)"]

# Full automation (⚠️ use in containers/VMs only)
approval=["--allow-all-tools"]
```

### Common Development Workflows

**Pre-commit Validation:**
```python
# Spawn agents for pre-commit checks
copilot_cli:run_agent(
    prompt="Check Swift syntax in all files",
    approval=["--allow-tool", "Bash(swift)"]
)
copilot_cli:run_agent(
    prompt="Run SwiftLint and report issues",
    approval=["--allow-tool", "Bash(swiftlint)"]
)
```

**Multi-platform CI Build:**
```python
# Parallel builds for CI
copilot_cli:run_agent(prompt="Build iOS target for simulator", approval=["--allow-all-tools"])
copilot_cli:run_agent(prompt="Build macOS target", approval=["--allow-all-tools"])
copilot_cli:run_agent(prompt="Run all unit tests", approval=["--allow-all-tools"])
```

**Parallel Quality Checks:**
```python
# Run multiple quality checks simultaneously
copilot_cli:run_agent(prompt="Run SwiftLint", approval=["--allow-tool", "Bash(swiftlint)"])
copilot_cli:run_agent(prompt="Find TODO comments in code", approval=["--allow-tool", "Bash(rg)"])
copilot_cli:run_agent(prompt="Find print statements", approval=["--allow-tool", "Bash(rg)"])

## MCP Development Workflows

### Workflow 1: Feature Development
```yaml
1. Planning (sequential-thinking, 8 thoughts):
   - Break down feature requirements
   - Identify dependencies and edge cases
   - Plan implementation approach

2. Research (apple-doc-mcp):
   - Search relevant APIs: search_symbols()
   - Get documentation: get_documentation()

3. Implementation:
   - Edit files with Read/Write/Edit tools
   - Build: xcodebuild-mcp:build_sim()
   - Test: xcodebuild-mcp:test_sim()

4. UI Testing:
   - Get coordinates: ios-simulator:describe_ui()
   - Automate: ios-simulator:tap/swipe/type_text()
   - Verify: ios-simulator:screenshot()

5. Submission:
   - Create PR: github:create_pull_request()
   - Request review: github:request_copilot_review()
```

### Workflow 2: Bug Diagnosis
```yaml
1. Analysis (sequential-thinking, 12 thoughts):
   - Generate multiple hypotheses
   - Plan investigation steps
   - Revise as findings emerge

2. Investigation:
   - Examine code: Read/Grep tools
   - Reproduce: ios-simulator automation

3. Fix & Verify:
   - Edit files
   - Test: xcodebuild-mcp:test_sim()
   - Document: github:add_issue_comment()
```

### Workflow 3: Performance Optimization
```yaml
1. Strategy (sequential-thinking, 15 thoughts):
   - Identify bottlenecks
   - Propose optimizations
   - Plan measurement approach

2. Baseline:
   - Build release: xcodebuild-mcp:build_sim(configuration="Release")
   - Record: ios-simulator:record_sim_video()

3. Optimize & Measure:
   - Edit files
   - Re-measure: ios-simulator:record_sim_video()
   - Compare results
```

## Code Style & Architecture

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

### Code Style Requirements
- **Swift 6 strict concurrency** enabled
- **@Observable** macro for state objects (NOT ObservableObject)
- **Actors** for thread-safe state management
- **async/await** for all asynchronous operations
- **OSLog** for logging with appropriate subsystem/category
- **2 spaces** indentation (not tabs)
- **MARK:** comments to organize code sections
- **AppNavigationManager** for all navigation
- **Planning**: Use sequential-thinking for architecture decisions
- **MCP First**: Prefer MCP commands over manual CLI operations
- Swift API Design Guidelines; 2-space indent; `// MARK:` sectioning
- Concurrency first: async/await throughout; use Actors for shared mutable state
- State: prefer `@Observable` models; avoid `ObservableObject` unless required by APIs
- Navigation: use central navigation types in `Core/Navigation`
- Conditional compilation: keep `#if os(...)` inside helpers/modifiers
- **Swift 6 capture semantics**: Always consider capture semantics for `self` in closures

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

### Liquid Glass Best Practices for Code
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

## Common Development Tasks

### Adding a New Feature
1. **Plan with sequential-thinking** (8-10 thoughts minimum)
2. Create feature folder in `/Features`
3. Add Observable ViewModel if needed
4. Implement SwiftUI views with cross-platform support
5. Use proper `@available(iOS 26.0, macOS 26.0, *)` annotations
6. Handle platform differences with ViewModifier protocols
7. Wire up navigation in AppNavigationManager
8. Add unit tests using Swift Testing for both platforms
9. Test on both iOS simulator and macOS with MCP tools
10. Consider A/B test wrapper if experimental

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
ast-grep --pattern 'func $_($_) { $$ }' path/to/file.swift

# Find all @Observable classes
ast-grep --pattern '@Observable class $_ { $$ }' --lang swift

# Find all NavigationDestination enum cases
ast-grep --pattern 'case $_($_)' Catbird/Core/Navigation/

# Find all SwiftUI View structs
ast-grep --pattern 'struct $_: View { $$ }' --lang swift
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
- **ALWAYS** use sequential-thinking for complex tasks (feature planning, bug diagnosis, optimization)
- **ALWAYS** use `describe_ui()` before UI automation (never guess coordinates)
- **Prefer MCP servers** over manual commands for consistency
- **Test on both platforms** when making UI changes (if instructed)

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

### Parallel Testing (M4 Max)

Run tests across multiple targets simultaneously. See `~/Developer/.claude/AGENTS.md` for full parallel testing documentation.

**Quick Reference - Available Targets:**
| Target | Simulator ID | Notes |
|--------|--------------|-------|
| iPhone 17 Pro | `40111BBE-8709-40D0-9016-A27448486A80` | Default |
| iPhone 17 Pro Max | `B53B2875-BFF5-4127-B56A-50529F7813CB` | Large screen |
| iPad Pro 13-inch | `56D76971-EC63-4C7C-B2D8-A6D0C3FD07B0` | Tablet layout |
| macOS | N/A | Native build |
| Physical iPhone | `6AFBE06D-301D-5F38-80D6-06B26ED62A2C` | Real device |

**Parallel Test Command (example):**
```python
# Execute in parallel (single message):
XcodeBuildMCP_test_sim(simulatorId="40111BBE...")  # iPhone
XcodeBuildMCP_test_sim(simulatorId="56D76971...")  # iPad
XcodeBuildMCP_test_macos()                          # macOS
```

**Tab Bar Navigation (coordinates):**
```python
# Tab bar y=832 on iPhone (center of 791-874)
tap(x=50, y=832)   # Home
tap(x=140, y=832)  # Notifications
tap(x=230, y=832)  # Messages
tap(x=320, y=832)  # Search
```

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

## Commits & PRs (GitHub MCP)
- **Commit style**: Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`)
- **PR creation**: Use `github:create_pull_request()`
- **Include**: sequential-thinking analysis, test results, screenshots
- **Review**: Use `github:request_copilot_review()` for AI review
- **Screenshots**: Capture with `ios-simulator:screenshot()`

## Security & Configuration
- No secrets in repo. Use Keychain/secure storage
- Validate entitlements and `PrivacyInfo.xcprivacy`
- **MCP validation**: Use MCP servers for automated security checks

## Non-Negotiables
- **Sequential-thinking mandatory** for complex tasks (3+ steps)
- **Never guess UI coordinates** - always use `describe_ui()`
- **Prefer MCP over manual** for consistency and automation
- **BUILD FREELY** - builds take ~20 seconds on M4 Max
- Production quality only: no placeholders, no TODOs, no temporary code
- Maintain strict compiler warnings-free builds (when building)

## MCP Server Quick Reference

### Decision Tree: Which MCP Server to Use?

```
Is the task complex or multi-step?
├─ YES → Start with sequential-thinking
│   ├─ Feature planning → 5-10 thoughts
│   ├─ Bug diagnosis → 10-15 thoughts
│   ├─ Architecture → 12-20 thoughts
│   └─ Performance → 15-25 thoughts
│
├─ Building/Testing?
│   ├─ iOS → xcodebuild-mcp:build_sim / test_sim
│   ├─ macOS → xcodebuild-mcp:build_macos / test_macos
│   └─ Device → xcodebuild-mcp:build_device / test_device
│
├─ UI Testing?
│   ├─ 1. ios-simulator:describe_ui (get coordinates)
│   ├─ 2. ios-simulator:tap/swipe/type_text
│   └─ 3. ios-simulator:screenshot/record_video
│
├─ Research APIs?
│   └─ apple-doc-mcp:search_symbols / get_documentation
│
└─ GitHub Operations?
    ├─ Create PR → github:create_pull_request
    ├─ Request review → github:request_copilot_review
    └─ Comment → github:add_issue_comment
```

### Common Task Workflows

| Task | MCP Workflow |
|------|-------------|
| **Add Feature** | 1. sequential-thinking (8 thoughts)<br>2. apple-doc-mcp:search_symbols<br>3. Edit files<br>4. Syntax check (`swift -frontend -parse`)<br>5. (Build only if instructed)<br>6. github:create_pull_request |
| **Fix Bug** | 1. sequential-thinking (12 thoughts)<br>2. Grep patterns<br>3. Edit files<br>4. Syntax check<br>5. (Build/test only if instructed) |
| **Optimize** | 1. sequential-thinking (15 thoughts)<br>2. Edit files<br>3. Syntax check<br>4. (Build/profile only if instructed) |
| **UI Test** | 1. (Only when instructed)<br>2. ios-simulator:describe_ui<br>3. ios-simulator:tap (precise coords)<br>4. ios-simulator:screenshot |

### MCP Server Health Check

Run daily to verify all MCP servers are operational:
```python
# Verify server availability
sequential_thinking:sequentialthinking(thought="Health check", totalThoughts=1)
xcodebuild_mcp:doctor()
ios_simulator:list_sims()
github:get_me()
apple_doc_mcp:list_technologies()
```

### Emergency Fallback

If MCP servers are unavailable:
1. Use legacy commands documented in sections above
2. Report MCP server issues immediately
3. Document manual steps for later automation

## Golden Rules for MCP Usage

1. **Sequential-Thinking First**: For any non-trivial task (3+ steps), start with sequential-thinking
2. **Never Guess Coordinates**: Always use `describe_ui()` before UI automation
3. **Embrace Revision**: Use sequential-thinking's revision capability freely
4. **Document Planning**: Include sequential-thinking analysis in PRs
5. **Prefer MCP Over Manual**: Use MCP servers instead of CLI commands
6. **Health Check Daily**: Verify all MCP servers are operational
7. **Test Both Platforms**: Run tests on iOS and macOS with MCP tools

---

*This document provides comprehensive guidelines for AI agents working in this repository. For human-oriented documentation optimized for Claude Code specifically, see CLAUDE.md. For detailed MCP server usage, simulator automation, and testing patterns, see TESTING_COOKBOOK.md and other documentation files.*
