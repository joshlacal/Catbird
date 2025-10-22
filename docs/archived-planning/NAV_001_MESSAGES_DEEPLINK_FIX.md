# NAV-001: Messages Deep-Link Navigation Bug Fix

## Issue Summary
Deep-link navigation to messages (e.g., from push notifications) was broken due to incorrect tab indexing and incompatible navigation architecture between NavigationPath and NavigationSplitView.

## Root Causes

### 1. Wrong Tab Index
**Location:** `NotificationManager.swift:2839-2843`

The notification handler was navigating to tab index 1 instead of tab 4:
```swift
// ❌ BEFORE (Incorrect)
appState.navigationManager.updateCurrentTab(1) // Wrong tab!
appState.navigationManager.navigate(to: destination, in: 1)
```

Chat tab is actually at index 4 (as defined in `AppNavigationManager` and used throughout the codebase).

### 2. NavigationSplitView Architecture Mismatch
**Location:** `ChatTabView.swift:32-36, 191-198`

ChatTabView uses `NavigationSplitView` with two key components:
- **Sidebar:** Conversation list
- **Detail:** NavigationStack showing the selected conversation

The detail view displays conversations based on `selectedConvoId` state, not via NavigationPath:
```swift
NavigationStack(path: chatNavigationPath) {
  if let convoId = selectedConvoId {
    ConversationView(convoId: convoId)
  }
}
```

However, `AppNavigationManager.navigate()` was appending to NavigationPath, which doesn't affect `selectedConvoId`.

## Solution

### 1. Fixed Tab Index
**File:** `NotificationManager.swift`
```swift
// ✅ AFTER (Correct)
appState.navigationManager.updateCurrentTab(4) // Chat tab
appState.navigationManager.navigate(to: destination, in: 4)
```

### 2. Added Deep-Link Conversation Handling
**File:** `AppNavigationManager.swift`

Added `targetConversationId` property:
```swift
// Target conversation for deep-link navigation (Chat tab specific)
var targetConversationId: String?
```

Enhanced `navigate()` method with special handling for conversations:
```swift
#if os(iOS)
// Special handling for conversation navigation in chat tab
if case .conversation(let convoId) = destination, targetTab == 4 {
    // Set the target conversation ID for NavigationSplitView
    targetConversationId = convoId
    // Clear navigation path for clean state
    tabPaths[targetTab] = NavigationPath()
    return
}
#endif
```

### 3. ChatTabView Observer
**File:** `ChatTabView.swift`

Added observer to react to deep-link navigation:
```swift
.onChange(of: appState.navigationManager.targetConversationId) { oldValue, newValue in
  // Handle deep-link navigation to a specific conversation
  if let convoId = newValue, convoId != selectedConvoId {
    logger.info("Deep-link navigation to conversation: \(convoId)")
    selectedConvoId = convoId
    // Clear the target after setting to avoid repeated navigation
    appState.navigationManager.targetConversationId = nil
  }
}
```

## How It Works

1. **Notification arrives** with conversation ID
2. **NotificationManager** switches to tab 4 and navigates to conversation
3. **AppNavigationManager.navigate()** detects conversation destination for tab 4
4. Sets `targetConversationId` instead of appending to NavigationPath
5. Clears navigation path for clean state
6. **ChatTabView** observes `targetConversationId` change
7. Updates `selectedConvoId`, which triggers NavigationSplitView to show the conversation
8. Clears `targetConversationId` to prevent re-navigation

## Benefits

- ✅ Properly respects NavigationSplitView architecture
- ✅ Cleans up navigation stack when switching conversations
- ✅ Works on both iPhone and iPad
- ✅ Handles column visibility correctly (detail-only on iPhone, split on iPad)
- ✅ No breaking changes to existing navigation patterns
- ✅ Backward compatible with non-conversation destinations

## Testing

Test scenarios:
1. **Push notification → conversation**: Tap message notification, verify correct conversation opens
2. **Deep link URL → conversation**: Open bsky.app message link, verify navigation
3. **Tab switch with pending conversation**: Navigate to conversation while on different tab
4. **iPad split view**: Verify sidebar and detail columns work correctly
5. **iPhone navigation**: Verify detail-only column visibility on iPhone

## Files Modified

- `Catbird/Core/Navigation/AppNavigationManager.swift`
- `Catbird/Features/Chat/Views/ChatTabView.swift`
- `Catbird/Features/Notifications/Services/NotificationManager.swift`

## Related Issues

This fix addresses the "NavigationSplitView stack cleanup" mentioned in the TODO. The stack is now properly cleared when navigating to conversations via deep links.

## Future Considerations

If other features need similar split-view navigation patterns, consider:
- Generalizing `targetConversationId` to a more flexible `targetSelection: Any?` approach
- Creating a protocol for tab views that use NavigationSplitView
- Adding navigation stack depth monitoring for debugging
