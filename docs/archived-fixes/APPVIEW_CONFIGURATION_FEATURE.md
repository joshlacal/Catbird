# Catbird AppView Configuration Feature

## Overview

Added configurable Bluesky AppView and Chat service DIDs as an advanced option in the Catbird login flow. This allows users to configure custom service endpoints before signing in or creating an account.

## Changes Made

### 1. LoginView.swift

#### New State Properties
```swift
// Advanced AppView configuration
@State private var customAppViewDID = "did:web:api.bsky.app#bsky_appview"
@State private var customChatDID = "did:web:api.bsky.chat#bsky_chat"
@State private var showAppViewAdvancedOptions = false
```

#### New Field Types
```swift
enum Field: Hashable {
    case username
    case pdsurl
    case appviewdid  // New
    case chatdid     // New
}
```

#### UI Enhancements
- Added collapsible "Advanced Service Configuration" section in login mode
- Displays when user taps the disclosure button below the username field
- Two text fields for configuring:
  - Bluesky AppView DID
  - Bluesky Chat DID
- "Reset to Defaults" button to restore standard Bluesky service DIDs
- All fields have proper icons and placeholder text
- Smooth animations when showing/hiding advanced options

#### Integration
- Custom service DIDs are passed to AuthManager before authentication starts
- Only applies when advanced options are expanded (defaults remain unchanged otherwise)
- Logging added to track when custom DIDs are being used

### 2. AuthManager.swift

#### New Properties
```swift
// Service DID configuration - can be customized before authentication
var customAppViewDID: String = "did:web:api.bsky.app#bsky_appview"
var customChatDID: String = "did:web:api.bsky.chat#bsky_chat"
```

#### Updated ATProtoClient Initialization
All three locations where `ATProtoClient` is created now include custom service DIDs:

1. **Initial client creation** (line ~325)
2. **Login flow client creation** (line ~535)
3. **Account operations client creation** (line ~876)

```swift
client = await ATProtoClient(
    oauthConfig: oauthConfig,
    namespace: "blue.catbird",
    userAgent: "Catbird/1.0",
    bskyAppViewDID: customAppViewDID,  // New
    bskyChatDID: customChatDID          // New
)
```

## User Experience

### Default Behavior
- No changes to existing user experience
- Default service DIDs match standard Bluesky infrastructure
- Advanced options are hidden by default

### Advanced Configuration
1. User navigates to "Sign In" mode in LoginView
2. Below the username field, user taps "Advanced Service Configuration"
3. Two additional fields appear:
   - **Bluesky AppView DID**: Configure custom AppView endpoint
   - **Bluesky Chat DID**: Configure custom Chat/DM service
4. User can modify DIDs or reset to defaults
5. When user proceeds with sign-in, custom DIDs are applied

### Use Cases

#### Testing Custom AppView
```
Bluesky AppView DID: did:web:dev.appview.mycompany.com#my_appview
Bluesky Chat DID: did:web:api.bsky.chat#bsky_chat
```

#### Full Custom Infrastructure
```
Bluesky AppView DID: did:web:custom.appview.example#custom_appview
Bluesky Chat DID: did:web:custom.chat.example#custom_chat
```

## Technical Details

### Validation
- DID fields use URL keyboard type on iOS for easier input
- No strict validation on DID format (allows flexibility for testing)
- Invalid DIDs will fail during authentication with appropriate error messages from Petrel

### State Management
- Custom DIDs stored in LoginView state
- Transferred to AuthManager only when authentication starts
- AuthManager properties persist for the session
- All subsequent client creations use the configured DIDs

### Visual Design
- Advanced options section uses `.quaternary.opacity(0.5)` background
- Rounded rectangle with 12pt corner radius
- Smooth spring animations when showing/hiding
- Proper spacing and alignment with existing UI
- Icons: server.rack for AppView, bubble icons for Chat

## Implementation Notes

- **Backward Compatible**: Existing authentication flows unchanged
- **Opt-in Feature**: Only activates when user expands advanced options
- **Session Scoped**: Custom DIDs persist for the app session
- **Logging**: Custom DID usage is logged for debugging

## Testing Checklist

- [x] Build succeeds without errors
- [x] Default login flow unaffected
- [x] Advanced options expand/collapse smoothly
- [x] Custom DIDs are passed to ATProtoClient
- [x] Reset to defaults button works correctly
- [x] UI adapts to different screen sizes
- [x] Keyboard navigation works properly

## Future Enhancements

Potential improvements:
- Persist custom DID settings across app launches
- Preset options for common test environments
- Validation for DID format
- In-app service discovery
- Per-account custom service DIDs
