# Push Notifier Moderation - Quick Reference

## For Backend Engineers

### Running Migrations
```bash
cd /path/to/bluesky-push-notifier
sqlx migrate run
```

### Testing Endpoints

#### Sync Moderation Lists
```bash
curl -X POST https://notifications.catbird.blue/sync-moderation-lists \
  -H "Content-Type: application/json" \
  -H "X-App-Attest-Assertion: <assertion>" \
  -d '{
    "did": "did:plc:xyz...",
    "device_token": "abc123...",
    "lists": [
      {
        "uri": "at://did:plc:xyz/app.bsky.graph.list/abc123",
        "purpose": "modlist",
        "name": "Spam Accounts"
      }
    ]
  }'
```

#### Mute Thread
```bash
curl -X POST https://notifications.catbird.blue/mute-thread \
  -H "Content-Type: application/json" \
  -H "X-App-Attest-Assertion: <assertion>" \
  -d '{
    "did": "did:plc:xyz...",
    "device_token": "abc123...",
    "thread_root_uri": "at://did:plc:xyz/app.bsky.feed.post/abc123"
  }'
```

#### Get Muted Threads
```bash
curl -X GET "https://notifications.catbird.blue/muted-threads?did=did:plc:xyz...&device_token=abc123..."
```

### Monitoring

#### Check Cache Stats
```rust
let (block_cache_size, mute_cache_size) = moderation_list_manager.get_cache_stats();
let thread_mute_cache_size = thread_mute_manager.get_cache_stats();
```

#### Check Logs
```bash
# Filter decisions
grep "Skipping notification.*block list\|mute list\|thread.*muted" /var/log/push-notifier.log

# Sync operations
grep "Successfully synced moderation lists" /var/log/push-notifier.log
```

## For iOS Engineers

### Using in Code

#### Mute Thread (already integrated in context menu)
```swift
// In PostContextMenuViewModel.swift - already implemented
func muteThread() async {
    // Calls both AT Protocol AND push notifier
    // Thread root URI automatically determined
}
```

#### Manual Thread Mute
```swift
Task {
    try await appState.notificationManager.muteThreadNotifications(
        threadRootURI: "at://did:plc:xyz/app.bsky.feed.post/abc123"
    )
}
```

#### Manual Thread Unmute
```swift
Task {
    try await appState.notificationManager.unmuteThreadNotifications(
        threadRootURI: "at://did:plc:xyz/app.bsky.feed.post/abc123"
    )
}
```

#### Manual Moderation List Sync
```swift
// Auto-syncs on app launch, but can trigger manually:
Task {
    await appState.notificationManager.syncModerationLists()
}
```

### Testing UI

1. **Test Thread Mute**:
   - Long-press any post → "Mute Thread"
   - Reply to that thread from another account
   - Verify: no push notification received

2. **Test List Sync**:
   - Create/subscribe to moderation list in Bluesky
   - Force app restart or sync
   - Post from list member
   - Verify: no push notification

## Database Schema

### moderation_list_subscriptions
```sql
CREATE TABLE moderation_list_subscriptions (
    id UUID PRIMARY KEY,
    user_did TEXT NOT NULL,
    list_uri TEXT NOT NULL,
    list_purpose TEXT NOT NULL,  -- 'modlist' or 'curatelist'
    list_name TEXT,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    last_synced_at TIMESTAMPTZ,
    UNIQUE(user_did, list_uri)
);
```

### moderation_list_members
```sql
CREATE TABLE moderation_list_members (
    id UUID PRIMARY KEY,
    list_uri TEXT NOT NULL,
    subject_did TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    UNIQUE(list_uri, subject_did)
);
```

### thread_mutes
```sql
CREATE TABLE thread_mutes (
    id UUID PRIMARY KEY,
    user_did TEXT NOT NULL,
    thread_root_uri TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    UNIQUE(user_did, thread_root_uri)
);
```

## Troubleshooting

### Issue: Lists not syncing
**Check**:
1. Is `DATABASE_URL` set in backend .env?
2. Are migrations applied?
3. Check backend logs for "Successfully synced moderation lists"
4. Verify AT Protocol API credentials

### Issue: Thread still sending notifications
**Check**:
1. Is thread root URI correct? (check logs)
2. Was mute successful? (HTTP 200)
3. Check filter logs: "Skipping notification - thread is muted"
4. Cache may need to expire (30 min TTL)

### Issue: Performance degradation
**Check**:
1. Cache hit rate (should be >95%)
2. Database query times (should be <5ms)
3. Number of list members (optimize if >10k)

## Performance Targets

- **Filter latency increase**: <10ms
- **Cache hit rate**: >95%
- **Database query time**: <5ms
- **Memory increase**: <100MB

## Future TODOs

1. ✅ **~~Implement AT Protocol List APIs~~** - COMPLETED
   - ✅ Fully implemented using `app.bsky.graph.getListMutes` and `app.bsky.graph.getListBlocks`
   - ✅ Supports pagination with cursor
   - ✅ Fetches all pages automatically

2. **Real-time Updates**:
   - Subscribe to AT Protocol firehose
   - Listen for list membership changes
   - Auto-refresh without manual sync

3. **Analytics**:
   - Track which lists block most notifications
   - Show user breakdown in settings
   - Help users optimize their lists

## Contact

- Backend Issues: Check `bluesky-push-notifier` repo
- iOS Issues: Check `Catbird` repo
- Design Questions: See `PUSH_NOTIFIER_MODERATION_DESIGN.md`
- Implementation Details: See `PUSH_NOTIFIER_MODERATION_IMPLEMENTATION.md`
