# MSG-002: Messages Polish - Analysis & Implementation Plan

**Date**: October 14, 2025  
**Status**: Analysis Complete - Implementation Deferred  
**Priority**: P2 (UX improvement)

## Current State Analysis

### ✅ What's Already Working

#### 1. State Management
**ChatManager** (`Catbird/Features/Chat/Services/ChatManager.swift`):
- ✅ Proper state handling with `@Observable`
- ✅ Conversation and message maps for efficient lookup
- ✅ Message delivery status tracking
- ✅ Pending message management
- ✅ Profile caching with `profileCache: [String: AppBskyActorDefs.ProfileViewDetailed]`
- ✅ Unread count tracking and callbacks
- ✅ Message deduplication and validation

#### 2. Real-Time Updates
- ✅ Polling system with different intervals:
  - Active conversation: 1.5s
  - Conversation list: 10s
  - Background: 60s
  - Inactive: 180s
- ✅ App state awareness (active/background)
- ✅ Last seen message tracking

#### 3. Unread Tracking
- ✅ `unreadCount` per conversation
- ✅ `totalUnreadCount` computed property
- ✅ `unreadMessageRequestsCount` for requests
- ✅ Callback: `onUnreadCountChanged`
- ✅ Mark as read functionality

#### 4. Message Validation (ConversationView)
- ✅ Empty ID filtering
- ✅ Duplicate message detection
- ✅ Invalid user data filtering
- ✅ Defensive validation before rendering

### 🔄 Areas for Improvement

#### 1. Profile Fetching Optimization
**Current**: Individual `getProfile()` calls per user  
**TODO** (Line 356 in ChatManager): Batch fetch with `getProfiles` API

**Impact**: 
- Reduces API calls from N to 1 (where N = conversation members)
- Faster initial load
- Better rate limit usage

**Implementation**:
```swift
// Extract all unique DIDs from conversations
let allDIDs = Set(conversations.flatMap { conv in
    conv.members.map { $0.did.didString() }
})

// Batch fetch profiles
if !allDIDs.isEmpty {
    await batchFetchProfiles(dids: Array(allDIDs))
}
```

#### 2. Unread Message Markers (UI Enhancement)
**Current**: Unread count in conversation list  
**Missing**: Visual separator showing "unread messages start here"

**Implementation Approach**:
- Add `lastReadMessageId` per conversation
- Insert marker view when rendering messages
- Use ExyteChat's message decoration system

#### 3. Scrolling Performance (Requires Profiling)
**Current**: Uses ExyteChat library (third-party)  
**Constraints**: 
- Limited control over scroll implementation
- Need Instruments profiling to identify bottlenecks
- Likely issues: Large message lists, media rendering

**Profiling Steps**:
1. Run app in Instruments (Time Profiler)
2. Load conversation with 500+ messages
3. Scroll rapidly up/down
4. Identify hot paths:
   - Message view building
   - Image loading
   - Attribute calculation

**Potential Optimizations**:
- Lazy loading older messages
- Image thumbnail caching
- Message view recycling
- Reduce view complexity

#### 4. Read Receipts
**Current**: Message delivery status exists but unclear if read receipts are shown  
**Check**: 
- Does ExyteChat show read indicators?
- Is `messageDeliveryStatus` map being used?

### iOS-Only Constraints

The messaging system is **iOS-only** (`#if os(iOS)`):
- Uses ExyteChat framework (not available on macOS)
- UIKit dependencies
- iOS-specific notifications

**Impact**: Cannot implement or test on macOS

## Implementation Priority

### High Priority (Do These)

#### 1. Batch Profile Fetching ✅ (Can Implement Now)
**Time**: 1-2 hours  
**Value**: High (reduces API calls, faster loading)  
**Risk**: Low (additive change)

**Steps**:
1. Create `batchFetchProfiles(dids: [String])` function
2. Call after loading conversations
3. Update `profileCache` with results
4. Add logging for cache hit/miss ratio

#### 2. Documentation ✅ (Done)
**Time**: 1 hour  
**Value**: High (helps future work)  
**Risk**: None

### Medium Priority (Requires Testing)

#### 3. Unread Markers
**Time**: 2-3 hours  
**Value**: Medium (nice UX improvement)  
**Risk**: Medium (need to test with ExyteChat)

**Blockers**:
- Need to run app to test
- ExyteChat integration testing
- Visual design decisions

#### 4. Read Receipt Indicators
**Time**: 1-2 hours  
**Value**: Medium (user expectation)  
**Risk**: Medium (ExyteChat integration)

### Low Priority (Requires Profiling)

#### 5. Scrolling Performance Optimization
**Time**: 4-8 hours  
**Value**: Variable (depends on if there's actually an issue)  
**Risk**: High (could break things without proper testing)

**Blockers**:
- Must profile with Instruments first
- Need real device testing
- Might require ExyteChat fork or workarounds

## Recommended Approach

### Phase 1: Quick Wins (Now)
1. ✅ Document current state (this file)
2. ✅ Implement batch profile fetching
3. ✅ Add performance logging

### Phase 2: Manual Testing (Next Session)
1. Run app on iOS simulator
2. Test with conversation with 100+ messages
3. Profile scrolling with Instruments
4. Identify actual performance issues
5. Test unread markers manually

### Phase 3: Targeted Improvements (Based on Testing)
1. Fix identified performance issues
2. Implement unread markers if UX gap confirmed
3. Add read receipt indicators if missing

## Files Involved

### Core Services
- `Catbird/Features/Chat/Services/ChatManager.swift` - Main business logic
- `Catbird/Features/Chat/Views/ConversationView.swift` - UI implementation

### Supporting Files
- `Catbird/Features/Chat/Views/MessageBubble.swift` - Message rendering
- `Catbird/Features/Chat/Views/ConversationRow.swift` - List view
- `Catbird/Features/Chat/Extensions/` - Various utilities

## Decision: Partial Implementation

Given constraints:
1. ✅ **Do**: Batch profile fetching (concrete improvement, no testing needed)
2. ✅ **Do**: Documentation and profiling guide
3. ⏸️ **Defer**: Unread markers (needs UI testing)
4. ⏸️ **Defer**: Scrolling optimization (needs profiling)
5. ⏸️ **Defer**: Read receipts (needs testing)

**Rationale**: 
- Can't properly test iOS-only features without running app
- Scrolling "issues" are hypothetical without profiling
- Batch fetching is a clear improvement that can be implemented now
- Documentation enables future work

## Implementation: Batch Profile Fetching

### Code to Add

```swift
// In ChatManager.swift

/// Batch fetch profiles for multiple DIDs to populate cache
private func batchFetchProfiles(dids: [String]) async {
    guard let client = client else { return }
    guard !dids.isEmpty else { return }
    
    // Filter out already cached DIDs
    let uncachedDIDs = dids.filter { profileCache[$0] == nil }
    guard !uncachedDIDs.isEmpty else {
        logger.debug("All \(dids.count) profiles already cached")
        return
    }
    
    logger.info("Batch fetching \(uncachedDIDs.count) profiles")
    
    do {
        // Batch API supports up to 25 profiles per request
        let batchSize = 25
        let batches = stride(from: 0, to: uncachedDIDs.count, by: batchSize).map {
            Array(uncachedDIDs[$0..<min($0 + batchSize, uncachedDIDs.count)])
        }
        
        for batch in batches {
            let actors = try batch.map { try ATIdentifier(string: $0) }
            let params = AppBskyActorGetProfiles.Parameters(actors: actors)
            let (responseCode, response) = try await client.app.bsky.actor.getProfiles(input: params)
            
            guard responseCode >= 200 && responseCode < 300 else {
                logger.error("Batch profile fetch failed: HTTP \(responseCode)")
                continue
            }
            
            // Cache all fetched profiles
            for profile in response.profiles {
                profileCache[profile.did.didString()] = profile
            }
            
            logger.debug("Cached \(response.profiles.count) profiles from batch")
        }
        
        logger.info("Batch fetch complete: \(profileCache.count) total cached profiles")
        
    } catch {
        logger.error("Error batch fetching profiles: \(error.localizedDescription)")
    }
}

/// Prefetch profiles for all conversation members
private func prefetchConversationProfiles() async {
    // Extract all unique DIDs from conversations
    var allDIDs = Set<String>()
    
    for conversation in conversations {
        for member in conversation.members {
            allDIDs.insert(member.did.didString())
        }
    }
    
    logger.debug("Prefetching profiles for \(allDIDs.count) unique conversation members")
    await batchFetchProfiles(dids: Array(allDIDs))
}
```

### Where to Call

Replace the TODO comment (line 356) with:
```swift
// Batch fetch all conversation member profiles for caching
await prefetchConversationProfiles()
```

## Testing Checklist

### Batch Profile Fetching
- [ ] Profiles cached after loading conversations
- [ ] No duplicate API calls for same DID
- [ ] Handles > 25 DIDs (multiple batches)
- [ ] Logs cache hit/miss ratio
- [ ] Error handling for API failures

### Unread Markers (When Implemented)
- [ ] Marker appears at correct position
- [ ] Updates when marking as read
- [ ] Doesn't appear in fully read conversations
- [ ] Scrolls to marker on conversation open

### Scrolling Performance (When Profiled)
- [ ] 60fps scrolling with 100+ messages
- [ ] No janking when loading media
- [ ] Smooth scroll to bottom/top
- [ ] Memory usage stays reasonable

### Read Receipts (When Implemented)
- [ ] Shows when message is delivered
- [ ] Shows when message is read
- [ ] Updates in real-time
- [ ] Handles group conversations correctly

## Success Metrics

- **Profile Fetch**: Reduce API calls by 80%+ (N calls → 1 call per 25 users)
- **Cache Hit Rate**: 90%+ for repeat conversation views
- **Scrolling**: Consistent 60fps in Instruments
- **State Sync**: No desyncs between UI and ChatManager

---

**Status**: Analysis complete. Batch profile fetching ready to implement. Other improvements deferred pending testing.
