# Preview Infrastructure

Simple, centralized preview state that uses your app's actual authentication.

## Quick Start

The easiest way to use previews with real network access:

```swift
#Preview {
    MyView()
        .previewWithAuthenticatedState()
}
```

That's it! This will:
- ✅ Use your existing logged-in session from the app
- ✅ Provide real network access (no mock data)
- ✅ Initialize AppState automatically
- ✅ Show a helpful message if you're not logged in

## How It Works

`PreviewContainer` wraps `AppStateManager.shared`, which means:
- Previews use the same authentication as your running app
- No need to create separate test accounts or mock data
- Just log in to the app once, and all previews work

## Examples

### Basic Usage (Recommended)
```swift
#Preview {
    FeedView()
        .previewWithAuthenticatedState()
}
```

### Access AppState Directly
```swift
#Preview {
    Task {
        guard let appState = await PreviewContainer.shared.appState else {
            return Text("Log in to the app first")
        }
        
        return ProfileView()
            .environment(appState)
    }
}
```

### Access Specific Managers
```swift
#Preview {
    Task {
        guard let appState = await PreviewContainer.shared.appState else {
            return Text("Not authenticated")
        }
        
        let bookmarks = appState.bookmarksManager
        
        return BookmarksView()
            .environment(appState)
    }
}
```

### Use AppStateManager Lifecycle
```swift
#Preview {
    ContentView()
        .environment(PreviewContainer.shared.appStateManager)
}
```

## Files

- **PreviewContainer.swift** - Main container that wraps AppStateManager
- **PreviewModifiers.swift** - View modifiers like `.previewWithAuthenticatedState()`
- **PreviewHelpers.swift** - Helper extensions and examples

## Notes

- **First time setup**: Log in to the app first, then previews will automatically use your session
- **No mock data needed**: All previews use real Bluesky API calls
- **Automatic initialization**: AppStateManager initializes automatically when first accessed
- **Error handling**: Shows helpful message if not authenticated
