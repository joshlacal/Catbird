# MCP iOS Simulator Setup Guide for Catbird Development

This guide provides a battle-tested, foolproof workflow for agentic iOS simulator control and testing of the Catbird app. This setup enables Claude to build, launch, interact with, and test iOS apps through a combination of XcodeBuildMCP and ios-simulator MCP servers.

## Prerequisites

1. **macOS** with Xcode 16+ installed
2. **Node.js** v14.0.0 or higher
3. **Homebrew** installed
4. **Claude Desktop** app
5. **iOS Simulators** installed via Xcode (iOS 18.4+)
6. **XcodeBuildMCP** server (requires separate installation)
7. **ios-simulator MCP** server (built into Claude Desktop)

## Current Status (Updated 5/27/2025)

### Working MCP Servers:
- ✅ **XcodeBuildMCP** - Fully functional for building, launching, and comprehensive UI automation
- ✅ **ios-simulator** - Works for basic UI automation and screenshots
- ✅ **filesystem** - File operations
- ✅ **fetch** - Web content fetching
- ✅ **sequential-thinking** - Complex problem solving

### Unified Testing Architecture

#### 1. XcodeBuildMCP (Primary Development Tool)
- **Purpose**: Complete iOS development lifecycle - building, installing, launching apps, and advanced UI automation
- **Key Features**: 
  - Project discovery and scheme management
  - Build configurations and deployment
  - Full UI hierarchy inspection with `describe_all`
  - Precise tap, swipe, and text input
  - Integrated screenshot capabilities
  - Log capture and debugging
- **Status**: Fully operational and recommended for all testing

#### 2. ios-simulator MCP (Basic UI Control)
- **Purpose**: Lightweight simulator interaction
- **Key Features**: Basic screenshots and simple UI commands
- **When to use**: Only for quick screenshots when XcodeBuildMCP is unavailable
- **Status**: Functional but limited compared to XcodeBuildMCP

## Quick Start: Optimal Testing Workflow

The recommended approach uses XcodeBuildMCP for everything:

### Step 1: Build and Launch in One Command
```javascript
// Build and run on iPhone 16 Pro
await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
  projectPath: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj",
  scheme: "Catbird",
  simulatorName: "iPhone 16 Pro",  // or "iPhone 16"
  configuration: "Debug"
});

// Wait for full initialization
await Bash({ command: "sleep 18" });  // 8s black screen + 10s initializing

// Verify app is ready
await mcp__XcodeBuildMCP__screenshot({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});
```

### Step 2: Interact with the App
```javascript
// Get UI hierarchy to find elements
const ui = await mcp__XcodeBuildMCP__describe_all({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});

// Tap on element (e.g., Sign In button)
await mcp__XcodeBuildMCP__tap({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41", 
  x: 201, y: 430 
});

// Type text
await mcp__XcodeBuildMCP__type_text({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41", 
  text: "Hello Bluesky!" 
});

// Swipe gesture
await mcp__XcodeBuildMCP__swipe({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41",
  x1: 200, y1: 600,
  x2: 200, y2: 200,
  velocity: 1500
});
```

## Working ios-simulator MCP Functions

These functions are confirmed working:

### Basic Info
```javascript
// Get current booted simulator
mcp__ios-simulator__get_booted_sim_id()
// Returns: Booted Simulator: "iPhone 16 Pro". UUID: "DEEB371A-6A16-4922-8831-BCABBCEB4E41"
```

### Screenshots
```javascript
// Take screenshot (saves to ~/Downloads/)
mcp__ios-simulator__screenshot({ output_path: "screenshot.png" })
// Returns: Wrote screenshot to: /Users/joshlacalamito/Downloads/screenshot.png
```

### UI Interaction (when app is running)
```javascript
// Tap at coordinates
mcp__ios-simulator__ui_tap({ x: 200, y: 400 })

// Type text
mcp__ios-simulator__ui_type({ text: "Hello Bluesky!" })

// Swipe gesture
mcp__ios-simulator__ui_swipe({ 
  x_start: 200, y_start: 600,
  x_end: 200, y_end: 200,
  delta: 5
})
```

## Catbird-Specific Information

### Known Simulator UUIDs
- **iPhone 16**: `9DEB446A-BB21-4E3A-BD6A-D51FBC28617C` 
- **iPhone 16 Pro**: `DEEB371A-6A16-4922-8831-BCABBCEB4E41` (Currently Booted)
- **iPhone 16 Plus**: `C4F81FC1-3AC8-40F1-AA1C-EBC3FFE81B6F`
- **iPhone 16 Pro Max**: `E7C83B56-76C6-44D0-BA08-5F6DD8C9D27D`

### Catbird Build Info
- **Bundle ID**: `blue.catbird`
- **Scheme**: `Catbird`
- **Min iOS**: 18.0
- **Project Path**: `/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj`

## Complete Testing Workflow Example

### Full Test Cycle: Edit → Build → Test → Verify

```javascript
// 1. Take baseline screenshot before changes
await mcp__XcodeBuildMCP__screenshot({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});

// 2. Make code changes
await Edit({
  file_path: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird/Features/Feed/Views/FeedView.swift",
  old_string: "padding(.horizontal, 16)",
  new_string: "padding(.horizontal, 20)"
});

// 3. Rebuild and launch (this replaces the running app)
await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
  projectPath: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj",
  scheme: "Catbird",
  simulatorName: "iPhone 16 Pro"
});

// 4. Wait for app to fully initialize
await Bash({ command: "sleep 18" });

// 5. Navigate to the changed view (if needed)
// Example: Sign in first
const ui = await mcp__XcodeBuildMCP__describe_all({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});

const signInBtn = ui[0].children.find(el => el.AXLabel === "Sign In");
if (signInBtn) {
  await mcp__XcodeBuildMCP__tap({ 
    simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41", 
    x: Math.round(signInBtn.frame.x + signInBtn.frame.width / 2), 
    y: Math.round(signInBtn.frame.y + signInBtn.frame.height / 2)
  });
}

// 6. Take comparison screenshot
await mcp__XcodeBuildMCP__screenshot({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});

// 7. Optionally read both screenshots to compare
const before = await Read({ file_path: "/path/to/before.png" });
const after = await Read({ file_path: "/path/to/after.png" });
```

## Troubleshooting

### App Shows Black Screen
**Solution**: 
- This is normal! Wait 8 seconds for initial load
- Then wait another 10 seconds for "INITIALIZING..." to complete
- Total wait time: 18 seconds from launch to ready

### Build Takes Too Long
**Issue**: First build can take 45-90 seconds due to Swift Package Manager
**Solutions**:
1. Be patient on first build - packages are being resolved
2. Subsequent builds are much faster (10-20 seconds)
3. Use `clean_proj` only when necessary

### Can't Find UI Elements
**Solution**:
```javascript
// Always get fresh UI hierarchy
const ui = await mcp__XcodeBuildMCP__describe_all({ 
  simulatorUuid: "DEEB371A-6A16-4922-8831-BCABBCEB4E41" 
});

// Log the structure to understand layout
console.log(JSON.stringify(ui, null, 2));

// Find elements by AXLabel
const element = ui[0].children.find(el => el.AXLabel === "Target Label");
```

### App Crashed or Not Responding
**Recovery Steps**:
```javascript
// 1. Force quit
await Bash({ command: "xcrun simctl terminate DEEB371A-6A16-4922-8831-BCABBCEB4E41 blue.catbird" });

// 2. Clean build
await mcp__XcodeBuildMCP__clean_proj({
  projectPath: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj",
  scheme: "Catbird"
});

// 3. Rebuild and launch
await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
  projectPath: "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj",
  scheme: "Catbird",
  simulatorName: "iPhone 16 Pro"
});
```

## Best Practices Summary

### ✅ What Works Perfectly:
1. **XcodeBuildMCP** - Complete build, launch, and UI automation
2. **ios-simulator MCP** - Basic screenshots and UI interaction
3. **File system operations** - Edit, Read, Write tools
4. **UI hierarchy inspection** - Finding elements by accessibility labels
5. **Visual regression testing** - Screenshot comparisons
6. **Gesture simulation** - Taps, swipes, text input

### 🚀 Recommended Workflow:
1. **Always use XcodeBuildMCP** for building and primary UI automation
2. **Wait 18 seconds** after launch for full initialization
3. **Use UI hierarchy** to find elements instead of hardcoding coordinates
4. **Take screenshots frequently** for visual verification
5. **Batch related tests** to minimize rebuild cycles

### 📱 Key Simulator UUIDs:
- **iPhone 16 Pro**: `DEEB371A-6A16-4922-8831-BCABBCEB4E41` (Recommended)
- **iPhone 16**: `9DEB446A-BB21-4E3A-BD6A-D51FBC28617C`
- **iPhone 16 Plus**: `C4F81FC1-3AC8-40F1-AA1C-EBC3FFE81B6F`
- **iPhone 16 Pro Max**: `E7C83B56-76C6-44D0-BA08-5F6DD8C9D27D`

## Summary

The combination of XcodeBuildMCP and proper wait times enables fully automated iOS testing workflows. The key is understanding the initialization phases (black screen → initializing → ready) and using the UI hierarchy for reliable element selection. With these patterns, you can efficiently test UI changes, perform visual regression testing, and validate user flows without manual intervention.