# MLS Database "Out of Memory" Error - Root Cause and Fix

## Problem Description

Users experiencing repeated errors:
```
Sync failed: SQLite error 7: out of memory - while executing `BEGIN IMMEDIATE TRANSACTION`
```

Or after account switching:
```
⚠️ Cached database connection unhealthy, reconnecting: SQLite error 7: out of memory - while executing SELECT 1 FROM sqlite_master LIMIT 1
```

## Root Cause

**NOT** an actual memory issue. This is SQLite error code 7 (`SQLITE_NOMEM`), which in the context of SQLCipher indicates:

### Primary Causes

1. **Account Switching Race Condition** (Most Common)
   - Database for User A not fully closed before opening for User B
   - WAL file contains uncommitted data from User A
   - Encryption codec context conflicts between users
   - HMAC verification fails due to key mismatch

2. **WAL Mode Conflicts**
   - SQLite WAL mode creates `-wal` and `-shm` (shared memory) files
   - These files require proper thread synchronization
   - Incomplete checkpoints leave WAL in inconsistent state

3. **Connection Pool Exhaustion**
   - Multiple accounts cached = multiple DatabasePools
   - Each pool has readers + writer = many connections
   - iOS has limited file descriptors

## Fixes Implemented (December 2024)

### 1. Account Switch Serialization (Critical Fix)

**Problem:** Fire-and-forget database close during account switch
```swift
// OLD - Race condition!
Task {
  await MLSGRDBManager.shared.closeDatabaseAndDrain(for: lruDID, timeout: 3.0)
}
```

**Fix:** Await database close before switching accounts
```swift
// NEW - Properly serialized
let closeSuccess = await MLSGRDBManager.shared.closeDatabaseAndDrain(for: previousUserDID, timeout: 5.0)
if !closeSuccess {
  logger.warning("⚠️ Previous database close timed out")
}
```

**Files:**
- `AppStateManager.swift` - `transitionToAuthenticated()` now closes previous DB before switch
- `AppStateManager.swift` - `evictLRUIfNeeded()` now async and awaited

### 2. Pending Close Operation Tracking

New tracking in `MLSGRDBManager` prevents opening a database while it's being closed:

```swift
private var pendingCloseOperations: Set<String> = []

// In getDatabasePool():
if pendingCloseOperations.contains(userDID) {
  // Wait for close to complete before opening
}
```

### 3. Increased SQLite Cache for SQLCipher

**Problem:** 1MB cache too small for SQLCipher encryption overhead

**Fix:**
```swift
// OLD
try db.execute(sql: "PRAGMA cache_size = -1000;")  // 1MB

// NEW
try db.execute(sql: "PRAGMA cache_size = -2000;")  // 2MB per connection
```

### 4. More Aggressive WAL Checkpointing

**Problem:** Large WAL files causing memory pressure

**Fix:**
```swift
// OLD
try db.execute(sql: "PRAGMA wal_autocheckpoint = 500;")  // 2MB

// NEW
try db.execute(sql: "PRAGMA wal_autocheckpoint = 200;")  // 800KB
```

### 5. Periodic Checkpoint During Polling

Added to `MLSConversationListView`:
```swift
if pollCycleCount % 10 == 0 {  // Every 10 poll cycles (~2.5 minutes)
  try await MLSGRDBManager.shared.checkpointDatabase(for: userDID)
}
```

### 6. Transient Error Exclusion

**Problem:** Temporary errors (busy, locked) triggering destructive recovery

**Fix:** New `isTransientError()` check excludes these from recovery:
```swift
// These now DON'T trigger database repair:
- "database is locked"
- "sqlite_busy" / "sqlite error 5"
- "sqlite error 6" (SQLITE_LOCKED)
- "timeout"
- "cancelled"
```

### 7. Active User Tracking

Only one database is actively used at a time:
```swift
private var activeUserDID: String?

// When switching users, checkpoint the previous database first
if activeUserDID != userDID {
  if let previousDB = databases[activeUserDID] {
    try previousDB.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE);")
    }
  }
  activeUserDID = userDID
}
```

## Configuration (No Changes Needed)

### Info.plist
No SQLite-specific settings needed. All configuration is via PRAGMA statements.

### Xcode Build Settings
No changes needed. SQLCipher configuration is programmatic.

## Files Modified

### CatbirdMLSCore/Sources/CatbirdMLSCore/Storage/MLSGRDBManager.swift
- Added `pendingCloseOperations` tracking
- Added `activeUserDID` tracking
- Updated `closeDatabase()` to track pending operations
- Updated `closeDatabaseAndDrain()` to return success status
- Added `closeAllExcept(keepUserDID:)` for aggressive cleanup
- Increased `cache_size` from 1MB to 2MB
- Reduced `wal_autocheckpoint` from 500 to 200 pages
- Added `busy_timeout` PRAGMA
- Enhanced `isRecoverableCodecError()` to exclude transient errors
- Added `isTransientError()` helper

### Catbird/Core/State/AppStateManager.swift
- `transitionToAuthenticated()` now closes previous DB before switch
- `evictLRUIfNeeded()` now async and properly awaited
- `clearInactiveAccounts()` now async and uses `closeAllExcept()`

### Catbird/Features/MLSChat/MLSConversationListView.swift
- Added periodic WAL checkpoint during polling loop
- Tracks poll cycle count for checkpoint scheduling

## Testing

1. **Account Switch Test:**
   - Log in to Account A, open chats
   - Switch to Account B
   - Switch back to Account A
   - Verify no OOM errors in logs

2. **Multi-Account Stress Test:**
   - Add 3+ accounts
   - Rapidly switch between them
   - Verify databases open/close cleanly

3. **Background/Foreground Test:**
   - Open chats, background app
   - Wait 30+ seconds
   - Return to app
   - Verify database reconnects cleanly

## Monitoring

Watch for these log patterns:

### Good (Expected):
```
🔒 Closing previous account's MLS database before switch
✅ Database closed and drained for user
📀 getDatabasePool requested for user
✅ Created new database pool for user
🔄 Periodic WAL checkpoint (poll cycle 10)
```

### Warning (Investigate if frequent):
```
⏳ Waiting for pending close operation
⚠️ Previous database close timed out
⚠️ Periodic checkpoint failed
```

### Error (Should not occur with fixes):
```
🔐 HMAC check failed - WRONG ENCRYPTION KEY
❌ Database creation failed
🚨 Performing FULL DATABASE RESET
```
