# MLS Member Duplication Debugging Infrastructure

## Problem Statement

Groups are showing 451 members when they should only have 2 members. This happens on **new groups with new builds**, indicating an active bug rather than corrupted legacy data.

## Hypothesis

Members are being added repeatedly during some operation (possibly on each sync, load, or state change).

## Debugging Infrastructure Added

### 1. Swift Layer - MLSClient.swift `addMembers()` (Lines 212-235)

**What it tracks:**
- Member count BEFORE calling Rust FFI `add_members()`
- Member count AFTER calling Rust FFI (before merge)
- Expected increase based on key package count

**Log format:**
```
🔍 DEBUG [MLSClient.addMembers] Member count BEFORE add: X
🔍 DEBUG [MLSClient.addMembers] Member count AFTER add (before merge): Y
🔍 DEBUG [MLSClient.addMembers] Expected increase: Z
```

**What to look for:**
- If `Y - X != Z`, members are being added unexpectedly
- If `Y - X > Z`, duplicate members are being added

### 2. Rust FFI - `add_members()` (Lines 136-199 in api.rs)

**What it tracks:**
- Duplicate key packages in input (by credential)
- Member count before `group.add_members()`
- Member count after `group.add_members()` (before merge)
- Delta validation

**Log format:**
```
[MLS-FFI] 🔍 DEBUG: Checking N key packages for duplicates...
[MLS-FFI] KeyPackage[0] credential: abc123...
[MLS-FFI] ⚠️ WARNING: Duplicate key package detected at index 1: abc123...
[MLS-FFI] ❌ CRITICAL: Found N duplicate key packages in input!
[MLS-FFI] 🔍 DEBUG: Member count BEFORE add_members: X
[MLS-FFI] 🔍 DEBUG: Adding N key packages
[MLS-FFI] 🔍 DEBUG: Member count AFTER add_members (before merge): Y
[MLS-FFI] 🔍 DEBUG: Member delta: Y-X (expected: N)
[MLS-FFI] ⚠️ WARNING: Member count delta (Y-X) doesn't match key package count (N)
```

**What to look for:**
- Duplicate key package warnings indicate input corruption
- Member delta mismatches indicate OpenMLS is behaving unexpectedly
- Critical duplicate warnings mean the Swift layer is passing duplicate data

### 3. Rust FFI - `merge_pending_commit()` (Lines 916-944 in api.rs)

**What it tracks:**
- Member count before merge
- Member count after merge
- Warns if count changes (it shouldn't)

**Log format:**
```
[MLS-FFI] 🔍 DEBUG: Member count BEFORE merge_pending_commit: X
[MLS-FFI] 🔍 DEBUG: Member count AFTER merge_pending_commit: Y
[MLS-FFI] ⚠️ WARNING: Member count changed during merge! Before: X, After: Y
```

**What to look for:**
- Member count should **NEVER** change during merge
- If it does, there's a serious bug in OpenMLS or our usage

### 4. Rust FFI - `process_welcome()` (Lines 646-649 in api.rs)

**What it tracks:**
- Initial member count when joining a group via Welcome message
- Epoch at join time

**Log format:**
```
[MLS-FFI] 🔍 DEBUG: Group created from Welcome with N members at epoch X
```

**What to look for:**
- Initial member count should match expected group size
- High member counts on join indicate the Welcome message itself is corrupted

### 5. FFI Helper - `get_group_member_count()` (Lines 913-925 in api.rs)

**What it does:**
- Provides direct query capability for member count
- Can be called from Swift at any time

**Usage:**
```swift
let count = try mlsClient.context.getGroupMemberCount(groupId: groupId)
logger.debug("Current member count: \(count)")
```

## Debugging Workflow

1. **Create a new group** with 1 other member (2 total expected)

2. **Watch for these log patterns:**
   ```
   # Initial creation
   [MLS-FFI] 🔍 DEBUG: Checking 1 key packages for duplicates...
   [MLS-FFI] ✅ No duplicate key packages detected in input
   [MLS-FFI] 🔍 DEBUG: Member count BEFORE add_members: 1  # Just creator
   [MLS-FFI] 🔍 DEBUG: Member count AFTER add_members: 2   # Creator + 1 new
   [MLS-FFI] 🔍 DEBUG: Member delta: 1 (expected: 1)       # ✅ Correct
   ```

3. **If duplicates appear:**
   ```
   # BUG: Duplicate key packages
   [MLS-FFI] ❌ CRITICAL: Found 5 duplicate key packages in input!
   # → Bug is in Swift layer - check MLSConversationManager.addMembers()

   # BUG: Wrong delta
   [MLS-FFI] ⚠️ WARNING: Member count delta (5) doesn't match key package count (1)
   # → OpenMLS is adding more members than key packages provided
   # → OR group state is corrupted
   ```

4. **Track member count over time:**
   - Use `get_group_member_count()` before and after operations
   - Compare with expected values
   - Identify which operation causes member inflation

## Expected Behavior

For a 2-person group:
1. **Creator creates group:** 1 member (self)
2. **addMembers(1 key package):** 2 members total (delta: +1)
3. **mergePendingCommit():** 2 members total (delta: 0)
4. **Other person processes Welcome:** Sees 2 members

## Known Bug Patterns

### Pattern 1: Duplicate Key Packages
- **Symptom:** `❌ CRITICAL: Found N duplicate key packages in input!`
- **Cause:** Swift layer fetching same key package multiple times
- **Fix:** Check MLSConversationManager key package fetching logic

### Pattern 2: Member Inflation on Sync
- **Symptom:** Member count increases on every sync/load
- **Cause:** Group state being re-added instead of updated
- **Fix:** Check group state synchronization logic

### Pattern 3: Self-Addition Loop
- **Symptom:** Same credential appears multiple times
- **Cause:** Adding self repeatedly (creator added as member)
- **Fix:** Check member addition flow for self-exclusion

## Rebuilding with Debug Logs

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird/MLS/mls-ffi
./create-xcframework.sh
```

## Next Steps

1. ✅ Added comprehensive debugging infrastructure
2. 🔄 Rebuild FFI framework (in progress)
3. ⏳ Create new test group and observe logs
4. ⏳ Identify where member duplication occurs
5. ⏳ Fix root cause
6. ⏳ Remove debugging logs (or gate behind compile flag)

## Contact

If you see unexpected patterns in these logs, document:
- Full log output from group creation
- Member count at each stage
- Any duplicate warnings
- Expected vs. actual member counts
