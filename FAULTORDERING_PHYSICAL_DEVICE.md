# FaultOrdering on Physical Device - Troubleshooting Guide

## The Problem

FaultOrdering is hanging on physical device launch because it's trying to:
1. Attach a debugger to set breakpoints
2. This fails/hangs on physical devices
3. The app never completes launching ("Failed to get matching snapshots: Error getting main window kAXErrorServerNotFound")

## The Solution

We've already collected 28 addresses from your previous test runs! We can use these to create an order file.

## Quick Fix - Use Pre-collected Addresses

### Option 1: Run the Safe Test
```bash
# This test launches WITHOUT FaultOrdering and creates an order file
xcodebuild test -scheme CatbirdUITests -destination 'platform=iOS,name=YOUR_DEVICE' -only-testing:CatbirdUITests/FaultOrderingLaunchTest/testSafePhysicalDeviceLaunch
```

### Option 2: Generate Order File Directly
```bash
# Run the included script
./generate_order_file.sh > order-file.txt
```

### Option 3: Use the Fallback Test
```bash
# This creates an order file from known addresses
xcodebuild test -scheme CatbirdUITests -destination 'platform=iOS,name=YOUR_DEVICE' -only-testing:CatbirdUITests/FaultOrderingLaunchTest/testCreateOrderFileFromKnownAddresses
```

## Using the Order File

1. Copy `order-file.txt` to your project directory
2. In Xcode, select your app target
3. Go to Build Settings → Search for "ORDER_FILE"
4. Set: `ORDER_FILE = $(PROJECT_DIR)/order-file.txt`
5. Clean and rebuild your app

## The 28 Addresses We Collected

These addresses represent the functions accessed during app startup:
- 0x100001140 (4294969536)
- 0x100003B9D (4294978461) 
- ... (26 more)

These are the actual memory addresses of functions that were executed during your app's launch.

## Debug the Hang (Optional)

If you want to understand why FaultOrdering hangs:

```bash
# Run the debug test to see which phase causes the hang
xcodebuild test -scheme CatbirdUITests -destination 'platform=iOS,name=YOUR_DEVICE' -only-testing:CatbirdUITests/FaultOrderingLaunchTest/testDebugFaultOrderingStatus
```

## Technical Details

FaultOrdering uses `SimpleDebugger` which:
- Works great on simulators
- Has issues on physical devices because:
  - Can't attach debugger properly
  - iOS security restrictions
  - Different exception handling

The addresses we collected (28 of them) are still valid and can be used to optimize your app's startup!

## Results

With the order file applied, you should see:
- Reduced app startup time
- Fewer page faults during launch
- Better memory locality

Measure before/after with Instruments or by timing app launches.