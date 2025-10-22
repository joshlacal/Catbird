# macOS Drag & Drop Crash Fix

## Issue Summary

**Crash Type**: EXC_BAD_ACCESS (SIGSEGV) - Null pointer dereference at 0x0000000000000000  
**Location**: macOS app during scene/window teardown  
**Trigger**: Drag-and-drop interaction cleanup when closing windows or quitting app

## Root Cause

Drop delegate structs (`FeedDropDelegate`, `DefaultFeedDropDelegate`, `BigDefaultButtonDropDelegate`) stored `UIImpactFeedbackGenerator` instances as properties:

```swift
#if os(iOS)
  let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
#endif
```

**Problem**: During macOS scene invalidation (Catalyst/UIKit layer), these UIKit objects become invalid while SwiftUI still holds references to the delegate structs. When the drop interaction system tries to cancel gesture recognizers during cleanup, it attempts to access these deallocated UIKit objects, causing a null pointer crash.

## Stack Trace Analysis

```
Thread 0 Crashed:
0   libswiftCore.dylib       swift_getObjectType + 25
1   SwiftUI                  (drop interaction handling)
2   UIKitCore                -[UIDropInteraction _dragDestinationGestureStateChanged:]
...
17  UIKitCore                -[UIGestureEnvironment _cancelGestureRecognizers:]
...
27-31 (Scene invalidation/teardown)
```

The crash occurs when:
1. Scene invalidation starts (window closing/app quitting)
2. Gesture recognizers are cancelled recursively through view hierarchy
3. Drop interaction tries to access stored UIKit objects
4. Null pointer dereference in `swift_getObjectType`

## Fix Applied

**Changed from** (stored property):
```swift
#if os(iOS)
  let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
#endif

func dropEntered(info: DropInfo) {
  feedbackGenerator.impactOccurred(intensity: 0.7)
}
```

**Changed to** (local instance):
```swift
func dropEntered(info: DropInfo) {
  #if os(iOS)
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.impactOccurred(intensity: 0.7)
  #endif
}
```

## Files Fixed

✅ **Catbird/Core/UI/Drag/FeedDropDelegate.swift**
- Removed stored `feedbackGenerator` property
- Create local instances in `dropEntered()` and `performDrop()`

✅ **Catbird/Core/UI/Drag/DefaultFeedDropDelegate.swift**
- Removed stored `feedbackGenerator` property  
- Create local instances in `dropEntered()` and `performDrop()`

✅ **Catbird/Core/UI/Drag/BigDefaultButtonDropDelegate.swift**
- Removed stored `feedbackGenerator` property
- Create local instances in `dropEntered()` and `performDrop()`

## Why This Works

1. **No dangling references**: Generators are created only when needed and released immediately
2. **Proper lifecycle**: UIKit objects don't persist in SwiftUI structs during scene teardown
3. **Memory safety**: No access to deallocated UIKit objects during cleanup

## Remaining Considerations

Other files with stored haptic generators were identified but are lower risk:
- **SideDrawer.swift**: Used for drag gestures within views, not drop delegates
- **FeedsStartPage.swift**: View-level haptics, not in drop delegates
- **FeedDiscoveryHeaderView.swift**: Already uses local instances correctly

These don't participate in scene-level drop interaction cleanup, so they're not affected by this specific crash.

## Testing Recommendations

1. Test drag-and-drop operations on macOS with feeds
2. Close windows during active drag operations
3. Quit app while drag-and-drop UI is visible
4. Monitor for any remaining SIGSEGV crashes in drop interaction code

## Related Patterns

This is a general pattern to follow for **any UIKit objects stored in SwiftUI structs**, especially:
- Drop/drag delegates
- Gesture recognizers or their targets
- View controllers or UIKit views
- Any UIKit object that might be accessed during view/scene teardown

**Best practice**: Create UIKit helper objects locally when needed, don't store them in SwiftUI value types (structs).
