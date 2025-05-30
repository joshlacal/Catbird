# Catbird Testing Cookbook

This cookbook provides ready-to-use test recipes for common Catbird testing scenarios. Each recipe is designed to be copy-paste ready with minimal modifications needed.

## Table of Contents
1. [Setup and Prerequisites](#setup-and-prerequisites)
2. [Basic Testing Patterns](#basic-testing-patterns)
3. [Authentication Tests](#authentication-tests)
4. [Feed Testing](#feed-testing)
5. [Navigation Testing](#navigation-testing)
6. [Performance Testing](#performance-testing)
7. [Visual Regression Testing](#visual-regression-testing)
8. [Error Recovery](#error-recovery)

## Setup and Prerequisites

### Required Constants
```javascript
const SIMULATOR_UUID = "DEEB371A-6A16-4922-8831-BCABBCEB4E41"; // iPhone 16 Pro
const PROJECT_PATH = "/Users/joshlacalamito/Developer/Catbird:Petrel/Catbird/Catbird.xcodeproj";
const SCHEME = "Catbird";
const BUNDLE_ID = "blue.catbird";

// Wait times
const WAIT_BLACK_SCREEN = 8;
const WAIT_INITIALIZING = 10;
const WAIT_TOTAL_INIT = 18;
const WAIT_NAVIGATION = 2;
const WAIT_ANIMATION = 1;
```

### Helper Functions
```javascript
// Launch app and wait for initialization
async function launchCatbird() {
  await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
    projectPath: PROJECT_PATH,
    scheme: SCHEME,
    simulatorName: "iPhone 16 Pro",
    configuration: "Debug"
  });
  
  await Bash({ command: `sleep ${WAIT_TOTAL_INIT}` });
  
  // Verify app launched
  const ui = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: SIMULATOR_UUID 
  });
  
  if (!ui || ui.length === 0) {
    throw new Error("App failed to launch");
  }
  
  return ui;
}

// Find element by label
async function findElement(label, type = null) {
  const ui = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: SIMULATOR_UUID 
  });
  
  const element = ui[0].children.find(el => {
    if (type) {
      return el.AXLabel === label && el.type === type;
    }
    return el.AXLabel === label;
  });
  
  return element;
}

// Tap element at center
async function tapElement(element) {
  if (!element) throw new Error("Element not found");
  
  const centerX = Math.round(element.frame.x + element.frame.width / 2);
  const centerY = Math.round(element.frame.y + element.frame.height / 2);
  
  await mcp__XcodeBuildMCP__tap({ 
    simulatorUuid: SIMULATOR_UUID, 
    x: centerX, 
    y: centerY 
  });
}
```

## Basic Testing Patterns

### Recipe: Take Screenshot with Timestamp
```javascript
async function takeScreenshot(prefix = "screenshot") {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const filename = `${prefix}_${timestamp}.png`;
  
  await mcp__XcodeBuildMCP__screenshot({ 
    simulatorUuid: SIMULATOR_UUID 
  });
  
  return filename;
}

// Usage
await takeScreenshot("login_screen");
await takeScreenshot("feed_view");
```

### Recipe: Verify Current Screen
```javascript
async function verifyScreen(expectedElements) {
  const ui = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: SIMULATOR_UUID 
  });
  
  const missingElements = [];
  
  for (const expected of expectedElements) {
    const found = ui[0].children.some(el => 
      el.AXLabel === expected.label && 
      (!expected.type || el.type === expected.type)
    );
    
    if (!found) {
      missingElements.push(expected);
    }
  }
  
  if (missingElements.length > 0) {
    throw new Error(`Missing elements: ${JSON.stringify(missingElements)}`);
  }
  
  return true;
}

// Usage: Verify login screen
await verifyScreen([
  { label: "Sign In", type: "Button" },
  { label: "Create Account", type: "Button" },
  { label: "Catbird", type: "StaticText" }
]);
```

## Authentication Tests

### Recipe: Complete Login Flow
```javascript
async function testLoginFlow(email, password) {
  // 1. Launch app
  await launchCatbird();
  
  // 2. Take initial screenshot
  await takeScreenshot("login_initial");
  
  // 3. Tap Sign In button
  const signInBtn = await findElement("Sign In", "Button");
  await tapElement(signInBtn);
  await Bash({ command: `sleep ${WAIT_NAVIGATION}` });
  
  // 4. Enter email
  await mcp__XcodeBuildMCP__type_text({ 
    simulatorUuid: SIMULATOR_UUID, 
    text: email 
  });
  
  // 5. Tab to password field (adjust coordinates as needed)
  await mcp__XcodeBuildMCP__tap({ 
    simulatorUuid: SIMULATOR_UUID, 
    x: 201, y: 500 
  });
  
  // 6. Enter password
  await mcp__XcodeBuildMCP__type_text({ 
    simulatorUuid: SIMULATOR_UUID, 
    text: password 
  });
  
  // 7. Submit (adjust coordinates as needed)
  await mcp__XcodeBuildMCP__tap({ 
    simulatorUuid: SIMULATOR_UUID, 
    x: 201, y: 580 
  });
  
  // 8. Wait for login to complete
  await Bash({ command: "sleep 5" });
  
  // 9. Verify successful login (look for feed elements)
  await takeScreenshot("login_success");
  
  return true;
}

// Usage
await testLoginFlow("test@example.com", "password123");
```

### Recipe: Test Create Account Flow
```javascript
async function testCreateAccount() {
  // 1. Launch app
  await launchCatbird();
  
  // 2. Tap Create Account
  const createBtn = await findElement("Create Account", "Button");
  await tapElement(createBtn);
  await Bash({ command: `sleep ${WAIT_NAVIGATION}` });
  
  // 3. Take screenshot of create account screen
  await takeScreenshot("create_account_screen");
  
  // Continue with form filling...
}
```

## Feed Testing

### Recipe: Test Feed Scrolling
```javascript
async function testFeedScroll(scrollCount = 5) {
  const screenshots = [];
  
  for (let i = 0; i < scrollCount; i++) {
    // Scroll down
    await mcp__XcodeBuildMCP__swipe({
      simulatorUuid: SIMULATOR_UUID,
      x1: 200, y1: 600,
      x2: 200, y2: 200,
      velocity: 1500
    });
    
    // Wait for content to load
    await Bash({ command: "sleep 1" });
    
    // Take screenshot
    const filename = await takeScreenshot(`feed_scroll_${i}`);
    screenshots.push(filename);
  }
  
  return screenshots;
}

// Usage
const scrollScreenshots = await testFeedScroll(10);
```

### Recipe: Test Pull to Refresh
```javascript
async function testPullToRefresh() {
  // 1. Take initial screenshot
  await takeScreenshot("feed_before_refresh");
  
  // 2. Pull down to refresh
  await mcp__XcodeBuildMCP__swipe({
    simulatorUuid: SIMULATOR_UUID,
    x1: 200, y1: 200,
    x2: 200, y2: 600,
    velocity: 1000
  });
  
  // 3. Wait for refresh
  await Bash({ command: "sleep 3" });
  
  // 4. Take screenshot after refresh
  await takeScreenshot("feed_after_refresh");
}
```

### Recipe: Test Post Interaction
```javascript
async function testPostInteraction() {
  // Find and tap like button (adjust pattern as needed)
  const ui = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: SIMULATOR_UUID 
  });
  
  // Look for like button - this will depend on your UI structure
  const likeButton = ui[0].children.find(el => 
    el.type === "Button" && el.AXLabel && el.AXLabel.includes("like")
  );
  
  if (likeButton) {
    await tapElement(likeButton);
    await Bash({ command: `sleep ${WAIT_ANIMATION}` });
    await takeScreenshot("post_liked");
  }
}
```

## Navigation Testing

### Recipe: Test Feeds Drawer Navigation
```javascript
async function testFeedsDrawer() {
  // 1. Open feeds drawer
  await mcp__XcodeBuildMCP__swipe({
    simulatorUuid: SIMULATOR_UUID,
    x1: 5, y1: 400,
    x2: 300, y2: 400,
    velocity: 1000
  });
  await Bash({ command: `sleep ${WAIT_ANIMATION}` });
  await takeScreenshot("feeds_drawer_open");
  
  // 2. Scroll to bottom of feeds list
  await mcp__XcodeBuildMCP__swipe({
    simulatorUuid: SIMULATOR_UUID,
    x1: 250, y1: 600,
    x2: 250, y2: 100,
    velocity: 2000
  });
  await Bash({ command: `sleep ${WAIT_ANIMATION}` });
  await takeScreenshot("feeds_drawer_scrolled");
  
  // 3. Close feeds drawer
  await mcp__XcodeBuildMCP__swipe({
    simulatorUuid: SIMULATOR_UUID,
    x1: 300, y1: 400,
    x2: 5, y2: 400,
    velocity: 1000
  });
  await Bash({ command: `sleep ${WAIT_ANIMATION}` });
  await takeScreenshot("feeds_drawer_closed");
}
```

### Recipe: Test Tab Navigation
```javascript
async function testTabNavigation() {
  // Assuming bottom tab bar with standard positions
  const tabs = [
    { name: "home", x: 50, y: 850 },
    { name: "search", x: 150, y: 850 },
    { name: "notifications", x: 250, y: 850 },
    { name: "profile", x: 350, y: 850 }
  ];
  
  for (const tab of tabs) {
    await mcp__XcodeBuildMCP__tap({ 
      simulatorUuid: SIMULATOR_UUID, 
      x: tab.x, 
      y: tab.y 
    });
    await Bash({ command: `sleep ${WAIT_NAVIGATION}` });
    await takeScreenshot(`tab_${tab.name}`);
  }
}
```

## Performance Testing

### Recipe: Measure Feed Load Time
```javascript
async function measureFeedLoadTime() {
  const startTime = Date.now();
  
  // Launch app
  await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
    projectPath: PROJECT_PATH,
    scheme: SCHEME,
    simulatorName: "iPhone 16 Pro"
  });
  
  // Wait for black screen phase
  await Bash({ command: `sleep ${WAIT_BLACK_SCREEN}` });
  
  // Check for initializing
  let initialized = false;
  let attempts = 0;
  
  while (!initialized && attempts < 20) {
    const ui = await mcp__XcodeBuildMCP__describe_all({ 
      simulatorUuid: SIMULATOR_UUID 
    });
    
    // Check if we're past initialization
    const hasSignIn = ui[0].children.some(el => el.AXLabel === "Sign In");
    if (hasSignIn) {
      initialized = true;
      break;
    }
    
    await Bash({ command: "sleep 1" });
    attempts++;
  }
  
  const endTime = Date.now();
  const loadTime = (endTime - startTime) / 1000;
  
  console.log(`App load time: ${loadTime} seconds`);
  return loadTime;
}
```

### Recipe: Memory Usage During Scroll
```javascript
async function testMemoryDuringScroll() {
  const measurements = [];
  
  // Start memory monitoring (requires additional setup)
  // This is a placeholder - actual implementation would use Instruments
  
  for (let i = 0; i < 20; i++) {
    // Rapid scroll
    await mcp__XcodeBuildMCP__swipe({
      simulatorUuid: SIMULATOR_UUID,
      x1: 200, y1: 600,
      x2: 200, y2: 100,
      velocity: 2500
    });
    
    await Bash({ command: "sleep 0.5" });
    
    // Take screenshot for visual inspection
    if (i % 5 === 0) {
      await takeScreenshot(`memory_test_scroll_${i}`);
    }
  }
  
  return measurements;
}
```

## Visual Regression Testing

### Recipe: Compare UI Changes
```javascript
async function compareUIChanges(editFunction) {
  // 1. Take before screenshot
  await takeScreenshot("before_change");
  const beforeUI = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: SIMULATOR_UUID 
  });
  
  // 2. Make code changes
  await editFunction();
  
  // 3. Rebuild and relaunch
  await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
    projectPath: PROJECT_PATH,
    scheme: SCHEME,
    simulatorName: "iPhone 16 Pro"
  });
  await Bash({ command: `sleep ${WAIT_TOTAL_INIT}` });
  
  // 4. Take after screenshot
  await takeScreenshot("after_change");
  const afterUI = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: SIMULATOR_UUID 
  });
  
  // 5. Compare UI structures
  const changes = {
    elementCountBefore: beforeUI[0].children.length,
    elementCountAfter: afterUI[0].children.length,
    elementCountDiff: afterUI[0].children.length - beforeUI[0].children.length
  };
  
  return changes;
}

// Usage
const changes = await compareUIChanges(async () => {
  await Edit({
    file_path: "/path/to/View.swift",
    old_string: "padding: 16",
    new_string: "padding: 20"
  });
});
```

### Recipe: Test Dark Mode
```javascript
async function testDarkMode() {
  // 1. Set light mode and take screenshot
  await mcp__XcodeBuildMCP__set_sim_appearance({ 
    simulatorUuid: SIMULATOR_UUID,
    mode: "light"
  });
  await Bash({ command: `sleep ${WAIT_ANIMATION}` });
  await takeScreenshot("light_mode");
  
  // 2. Set dark mode and take screenshot
  await mcp__XcodeBuildMCP__set_sim_appearance({ 
    simulatorUuid: SIMULATOR_UUID,
    mode: "dark"
  });
  await Bash({ command: `sleep ${WAIT_ANIMATION}` });
  await takeScreenshot("dark_mode");
  
  // 3. Compare UI elements visibility
  const darkUI = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: SIMULATOR_UUID 
  });
  
  // Verify all elements are still visible in dark mode
  return darkUI;
}
```

## Error Recovery

### Recipe: Recover from App Crash
```javascript
async function recoverFromCrash() {
  try {
    // Check if app is responsive
    const ui = await mcp__XcodeBuildMCP__describe_all({ 
      simulatorUuid: SIMULATOR_UUID 
    });
    
    if (!ui || ui.length === 0) {
      throw new Error("App not responding");
    }
  } catch (error) {
    console.log("App crashed, attempting recovery...");
    
    // 1. Force quit
    await Bash({ 
      command: `xcrun simctl terminate ${SIMULATOR_UUID} ${BUNDLE_ID}` 
    });
    await Bash({ command: "sleep 2" });
    
    // 2. Clear app data (optional)
    // await Bash({ 
    //   command: `xcrun simctl uninstall ${SIMULATOR_UUID} ${BUNDLE_ID}` 
    // });
    
    // 3. Relaunch
    await launchCatbird();
    
    console.log("Recovery successful");
  }
}
```

### Recipe: Handle Build Failures
```javascript
async function buildWithRetry(maxAttempts = 3) {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      console.log(`Build attempt ${attempt}...`);
      
      const result = await mcp__XcodeBuildMCP__build_run_ios_sim_name_proj({
        projectPath: PROJECT_PATH,
        scheme: SCHEME,
        simulatorName: "iPhone 16 Pro"
      });
      
      if (result.includes("BUILD SUCCEEDED")) {
        console.log("Build successful!");
        return result;
      }
    } catch (error) {
      console.log(`Build failed: ${error.message}`);
      
      if (attempt < maxAttempts) {
        // Clean and retry
        await mcp__XcodeBuildMCP__clean_proj({
          projectPath: PROJECT_PATH,
          scheme: SCHEME
        });
        await Bash({ command: "sleep 5" });
      }
    }
  }
  
  throw new Error("Build failed after maximum attempts");
}
```

## Advanced Patterns

### Recipe: Automated Test Suite
```javascript
async function runTestSuite() {
  const results = {
    passed: [],
    failed: [],
    startTime: Date.now()
  };
  
  const tests = [
    { name: "App Launch", fn: launchCatbird },
    { name: "Login Flow", fn: () => testLoginFlow("test@example.com", "password") },
    { name: "Feed Scroll", fn: () => testFeedScroll(5) },
    { name: "Feeds Drawer", fn: testFeedsDrawer },
    { name: "Dark Mode", fn: testDarkMode }
  ];
  
  for (const test of tests) {
    try {
      console.log(`Running test: ${test.name}`);
      await test.fn();
      results.passed.push(test.name);
      console.log(`✅ ${test.name} passed`);
    } catch (error) {
      results.failed.push({ name: test.name, error: error.message });
      console.log(`❌ ${test.name} failed: ${error.message}`);
      
      // Recover for next test
      await recoverFromCrash();
    }
  }
  
  results.endTime = Date.now();
  results.duration = (results.endTime - results.startTime) / 1000;
  
  console.log(`\nTest Results:`);
  console.log(`Passed: ${results.passed.length}`);
  console.log(`Failed: ${results.failed.length}`);
  console.log(`Duration: ${results.duration} seconds`);
  
  return results;
}
```

### Recipe: Continuous UI Monitoring
```javascript
async function monitorUI(durationSeconds = 60, intervalSeconds = 5) {
  const endTime = Date.now() + (durationSeconds * 1000);
  const snapshots = [];
  
  while (Date.now() < endTime) {
    const snapshot = {
      timestamp: new Date().toISOString(),
      ui: await mcp__XcodeBuildMCP__describe_all({ 
        simulatorUuid: SIMULATOR_UUID 
      }),
      screenshot: await takeScreenshot("monitor")
    };
    
    snapshots.push(snapshot);
    
    // Perform random action every 3rd interval
    if (snapshots.length % 3 === 0) {
      await mcp__XcodeBuildMCP__swipe({
        simulatorUuid: SIMULATOR_UUID,
        x1: 200, y1: 400,
        x2: 200, y2: 300,
        velocity: 1000
      });
    }
    
    await Bash({ command: `sleep ${intervalSeconds}` });
  }
  
  return snapshots;
}
```

## Tips and Best Practices

1. **Always wait after actions**: Use appropriate wait times after navigation, animations, and launches
2. **Use helper functions**: Create reusable functions for common patterns
3. **Take screenshots liberally**: Visual verification is fast and helpful for debugging
4. **Handle errors gracefully**: Always include error recovery patterns
5. **Use meaningful names**: Name screenshots and test functions descriptively
6. **Batch related tests**: Minimize rebuild cycles by grouping related tests
7. **Verify UI state**: Use `describe_all` to ensure you're on the expected screen
8. **Document coordinates**: When using hardcoded coordinates, document what they represent
9. **Test on consistent simulator**: Stick to iPhone 16 Pro for reproducible results
10. **Clean build sparingly**: Only clean when necessary to save time

## Debugging Helpers

### Log UI Hierarchy
```javascript
async function logUIHierarchy() {
  const ui = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: SIMULATOR_UUID 
  });
  console.log(JSON.stringify(ui, null, 2));
}
```

### Find All Buttons
```javascript
async function findAllButtons() {
  const ui = await mcp__XcodeBuildMCP__describe_all({ 
    simulatorUuid: SIMULATOR_UUID 
  });
  
  const buttons = ui[0].children.filter(el => el.type === "Button");
  console.log("Found buttons:", buttons.map(b => ({
    label: b.AXLabel,
    frame: b.frame
  })));
  
  return buttons;
}
```

### Capture Debug Info
```javascript
async function captureDebugInfo(prefix = "debug") {
  const debugInfo = {
    timestamp: new Date().toISOString(),
    screenshot: await takeScreenshot(`${prefix}_screenshot`),
    uiHierarchy: await mcp__XcodeBuildMCP__describe_all({ 
      simulatorUuid: SIMULATOR_UUID 
    }),
    // Add more debug data as needed
  };
  
  // Save to file
  await Write({
    file_path: `/tmp/${prefix}_debug_${Date.now()}.json`,
    content: JSON.stringify(debugInfo, null, 2)
  });
  
  return debugInfo;
}
```