# OAuth Callback Debugging Guide

## Issue Description
Users get "stuck" after selecting an account to sign back into. The authentication flow starts but doesn't complete.

## Root Cause Analysis

When a user selects an account with expired tokens:
1. `AccountSwitcherView` calls `switchToAccount()`
2. Token validation fails → triggers reauthentication
3. `ASWebAuthenticationSession` opens with OAuth provider
4. User completes authentication successfully
5. **OAuth provider redirects to `https://catbird.blue/oauth/callback`**
6. **The callback should return to the app, but it hangs**

### Why It Hangs

The `webAuthenticationSession.authenticate()` call in `handleReauthentication()` had **no timeout**, causing it to wait indefinitely if:
- Universal link handling fails
- The callback URL isn't recognized by the system
- There's a timing issue with the app receiving the callback
- The OAuth session loses track of the pending authentication

## Fixes Applied

### 1. Added Timeout Handling
- `webAuthenticationSession.authenticate()` now has a 2-minute timeout
- Uses `withThrowingTaskGroup` to race the auth task against a timeout task
- Provides clear timeout error message to users

### 2. Enhanced Logging
Added debug logging at each step:
- When reauthentication starts (with handle and authURL)
- When ASWebAuthenticationSession opens
- When callback URL is received (with full URL for debugging)
- When callback processing succeeds/fails

### 3. Fixed iOS < 17.4 Fallback Bug
The pre-17.4 code was using a hardcoded dummy URL:
```swift
// BEFORE (BROKEN)
callbackURL = try await webAuthenticationSession.authenticate(
  using: URL(string: "https://catbird/oauth/callback")!,  // WRONG!
  callbackURLScheme: "catbird",
  preferredBrowserSession: .shared
)

// AFTER (FIXED)
callbackURL = try await webAuthenticationSession.authenticate(
  using: request.authURL,  // Correct OAuth authorization URL
  callbackURLScheme: "catbird",
  preferredBrowserSession: .shared
)
```

### 4. Better Error Messages
- Timeout errors now show: "Authentication timed out. The authentication session took too long to complete. Please try again."
- Other errors show the underlying error message
- Errors are logged for debugging

## Debugging Steps

If a user reports being stuck, check these logs (in Console.app):

1. **"Handling automatic reauthentication for handle: [handle]"**
   - If missing: `pendingReauthenticationRequest` wasn't set (check why `addAccount()` failed)

2. **"Auth URL: [url]"**
   - Verify the OAuth URL looks correct (should be `https://bsky.social/oauth/authorize?...` or similar)

3. **"Opening ASWebAuthenticationSession..."**
   - If missing: Code never reached the authenticate call
   - If present but no follow-up: Session is hanging

4. **"Reauthentication session completed successfully"**
   - If missing after 2 minutes: Timeout occurred
   - Check for timeout error message

5. **"Callback URL: [url]"**
   - Should be `https://catbird.blue/oauth/callback?code=...&state=...`
   - If missing: Callback never returned from OAuth session

6. **"Callback processed successfully"**
   - If missing: `authManager.handleCallback()` failed
   - Check for error logs from AuthManager

## Testing Checklist

To verify the fix works:

1. ✅ Install app with expired account tokens
2. ✅ Launch app → see AccountSwitcherView
3. ✅ Tap an account
4. ✅ Verify ASWebAuthenticationSession sheet appears
5. ✅ Complete OAuth authentication
6. ✅ Verify callback returns and account is switched
7. ✅ Test timeout: Start auth but don't complete for 2+ minutes
8. ✅ Verify timeout error message appears

## Universal Link Configuration

The app is properly configured for universal links:

**Entitlements** (`Catbird.entitlements`):
```xml
<key>com.apple.developer.associated-domains</key>
<array>
  <string>applinks:catbird.blue</string>
  <string>webcredentials:catbird.blue</string>
</array>
```

**Server** (`https://catbird.blue/.well-known/apple-app-site-association`):
```json
{
  "applinks": {
    "apps": [],
    "details": [{
      "appID": "44U2ZPNQPK.blue.catbird",
      "paths": ["/oauth/callback"]
    }]
  }
}
```

**CatbirdApp.swift** (URL handling):
```swift
.onOpenURL { url in
  if url.absoluteString.contains("/oauth/callback") {
    Task {
      do {
        try await appState.authManager.handleCallback(url)
      } catch {
        logger.error("Error handling OAuth callback: \(error)")
      }
    }
  }
}
```

## Known Issues & Workarounds

### Issue: Universal Link Not Working
If universal links aren't working properly:
1. Uninstall and reinstall the app
2. Verify device has internet connection (universal links require validation)
3. Check Console.app for "swcd" logs showing universal link validation
4. Wait 24-48 hours after domain setup for Apple's CDN to update

### Issue: Session Opens but Never Returns
This is now handled by the timeout. After 2 minutes, the user will see an error and can try again.

## Future Improvements

1. **Add "Skip" or "Try Different Account" button** during authentication
2. **Reduce timeout to 60 seconds** (2 minutes might be too long)
3. **Add progress indicator** showing "Waiting for authentication..."
4. **Implement retry with exponential backoff** for network issues
5. **Detect common OAuth errors** and provide specific guidance

## Related Files

- `Catbird/Features/Auth/Views/AccountSwitcherView.swift` - Account switching and reauthentication
- `Catbird/Core/State/AuthManager.swift` - OAuth flow implementation
- `Catbird/App/CatbirdApp.swift` - URL callback handling
- `Catbird/Catbird.entitlements` - Associated Domains configuration
