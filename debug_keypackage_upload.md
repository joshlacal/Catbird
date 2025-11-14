# MLS Keypackage Upload Debugging

## Issue
App is not uploading keypackages to the MLS server on initialization.

## Root Cause
The client HAS the upload logic, but errors are being silently caught. Check for these issues:

### 1. Check Client Logs
Look for these log messages in the app console:

```
MLS: Creating new conversation manager for user: <userDid>
MLS: ✅ Created and initialized new conversation manager successfully
```

OR error messages like:

```
MLS: ❌ Failed to initialize conversation manager: <error>
Failed to upload initial key packages: <error>
```

### 2. Server Binary Version
The server is running an **OLD binary from 3 hours ago**. Deploy the latest version:

```bash
cd /home/ubuntu/mls/server
docker build -f Dockerfile.prebuilt -t catbird-mls-server:latest .
docker compose restart mls-server
```

### 3. Test Keypackage Upload Manually
Add temporary logging to see what's happening:

In `MLSConversationManager.swift`, around line 1547, add:

```swift
logger.error("🔍 DEBUG: About to upload \(recommendation.recommendedBatchSize) keypackages")
try await uploadKeyPackageBatchSmart(count: recommendation.recommendedBatchSize)
logger.error("🔍 DEBUG: Upload succeeded!")
```

### 4. Test API Client Connection
In `MLSConversationManager.swift`, add a health check in `initialize()`:

```swift
// After line 255, add:
do {
    logger.error("🔍 DEBUG: Testing API client health...")
    let testHealth = try await apiClient.checkHealth()
    logger.error("🔍 DEBUG: API health check result: \(testHealth)")
} catch {
    logger.error("🔍 DEBUG: API health check FAILED: \(error)")
}
```

### 5. Check Server Logs
On the server, check if ANY requests are coming in:

```bash
docker logs catbird-mls-server --tail 100 --follow
```

Look for:
- `/api/blue.catbird.mls.getKeyPackageStats` requests
- `/api/blue.catbird.mls.publishKeyPackages` requests
- Any 404, 500, or authentication errors

## Expected Behavior

When the app initializes MLS, it should:

1. Call `getKeyPackageStats()` - server returns `{available: 0, threshold: 10}`
2. Determine replenishment needed (0 < 10)
3. Upload batch of ~100 keypackages
4. Log success message

## Quick Test

To verify the client can upload, add this to a test or debug view:

```swift
Task {
    guard let manager = await appState.getMLSConversationManager() else {
        print("❌ Failed to get conversation manager")
        return
    }

    do {
        try await manager.smartRefreshKeyPackages()
        print("✅ Manual keypackage refresh succeeded")
    } catch {
        print("❌ Manual keypackage refresh failed: \(error)")
    }
}
```

## Server Deployment Status

**Current Issue**: Server is running OLD binary without new endpoints.

**Fix**: Deploy latest server code with keypackage sync changes.

---

*Created: 2025-11-10*
