# Preferences Boundary Documentation

## Overview
This document defines the clear boundary between Bluesky server-synced preferences and local app settings in Catbird.

## Core Principle
- **Server Preferences (PreferencesManager)**: Control WHAT content is shown
- **Local Settings (AppSettings)**: Control HOW content is displayed

## Bluesky Server Preferences (Synced)
Managed by `PreferencesManager` and synced via AT Protocol:

### Content & Behavior
- `adultContentEnabled` - Whether to show adult content
- `contentLabelPrefs` - Content moderation labels (porn, violence, etc.)
- `mutedWords` - Words/phrases to filter out
- `hiddenPosts` - Specific posts to hide
- `labelers` - Third-party moderation services

### Feeds & Display Logic
- `pinnedFeeds` - User's pinned feed order
- `savedFeeds` - Saved custom feeds
- `feedViewPref` - How feeds behave (hide replies, etc.)
- `threadViewPref` - Thread display preferences (sort order, prioritize followed)

### Profile & Social
- `personalDetails` - Birth date for content filtering
- `interests` - User interests for recommendations

## Local App Settings (Device-Only)
Managed by `AppSettings` and stored in SwiftData:

### UI Appearance
- `theme` - Light/Dark/System mode
- `darkThemeMode` - Dim/True black
- `fontStyle` - System/Serif/Rounded/Monospaced
- `fontSize` - Small/Default/Large/Extra Large

### Accessibility & Motion
- `reduceMotion` - Minimize animations
- `prefersCrossfade` - Use crossfade transitions
- `disableHaptics` - Turn off haptic feedback
- `requireAltText` - Require alt text for images

### Display Preferences
- `increaseContrast` - High contrast mode
- `boldText` - Use bold fonts
- `displayScale` - UI scaling factor
- `highlightLinks` - Visual link highlighting

### Local Behavior
- `autoplayVideos` - Auto-play video content
- `useInAppBrowser` - Open links in-app
- `confirmBeforeActions` - Confirmation dialogs
- `shakeToUndo` - Shake gesture support

### External Media (Local Filtering)
- `allowYouTube`, `allowSpotify`, etc. - Control which embeds to show
- These are local because they control client-side display, not content availability

## Implementation Rules

### DO:
1. Always check if a preference affects content (server) vs display (local)
2. Use PreferencesManager for anything that should sync across devices
3. Use AppSettings for device-specific UI preferences
4. Keep clear separation in the UI about what syncs

### DON'T:
1. Never add UI preferences to PreferencesManager
2. Never try to sync AppSettings to Bluesky servers
3. Don't mix server and local preferences in the same UI section
4. Don't assume external service preferences need syncing

## Examples

### Correct: Theme Setting (Local Only)
```swift
// In AppSettings
var theme: String = "system"

// In AppearanceSettingsView
Picker("Theme", selection: $appState.appSettings.theme) {
    Text("System").tag("system")
    Text("Light").tag("light")
    Text("Dark").tag("dark")
}
```

### Correct: Adult Content (Server Synced)
```swift
// In PreferencesManager
func updateAdultContentEnabled(_ enabled: Bool) async throws {
    let preferences = try await getPreferences()
    preferences.adultContentEnabled = enabled
    try await saveAndSyncPreferences(preferences)
}
```

### Incorrect: Trying to Sync UI Settings
```swift
// NEVER DO THIS
preferences.theme = appSettings.theme // ❌ Theme is not a server preference
```

## Testing Checklist
- [ ] UI settings don't trigger network calls
- [ ] Server preferences sync across devices
- [ ] Settings UI clearly indicates what syncs
- [ ] No console errors about unknown preferences
- [ ] App respects both local and server preferences