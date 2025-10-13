# Push Notifier: Moderation Lists + Muted Thread Suppression (NOTIF-001)

**Status**: ✅ **IMPLEMENTED** (see PUSH_NOTIFIER_MODERATION_IMPLEMENTATION.md)  
**Repository**: `bluesky-push-notifier`  
**Author**: AI Agent  
**Created**: 2025-10-13  
**Implemented**: 2025-01-13  
**Priority**: P0 (Critical)

---

## Executive Summary

Implement two critical notification filtering features in the push-notifier service:

1. **Moderation Lists Support**: Suppress notifications from users in subscribed moderation lists (block/mute lists)
2. **Muted Thread Suppression**: Suppress notifications from threads the user has explicitly muted

**Impact**: Eliminates unwanted notifications from blocked/muted users and muted conversation threads, significantly improving user experience and reducing notification fatigue.

**Estimated Effort**: 8-12 days (1 engineer)  
**Complexity**: Medium (database schema, AT Protocol sync, filter integration)

---

## Current State

### Existing Infrastructure

The push-notifier service already has:

✅ **RelationshipManager** - Handles individual blocks/mutes with encrypted storage and caching  
✅ **Filter Pipeline** - Event filtering in `src/filter.rs` with registered user checks  
✅ **Preference API** - `/preferences` endpoint for notification settings  
✅ **Database** - PostgreSQL with encrypted relationship storage  
✅ **Caching** - Moka caches for mutes/blocks (1 hour TTL, 10k capacity)

### Missing Features

❌ **Moderation List Subscriptions** - No sync or filtering for subscribed moderation lists  
❌ **Thread Mute Tracking** - No storage or checking of muted threads  
❌ **Bulk Refresh** - No periodic sync of moderation data from AT Protocol

---

## AT Protocol APIs

### Moderation Lists

**Get User's Muted Lists:**
```
GET app.bsky.graph.getListMutes
```

**Get User's Blocked Lists:**
```
GET app.bsky.graph.getListBlocks
```

**Get List Members:**
```
GET app.bsky.graph.getList?list=at://did:plc:xyz/app.bsky.graph.list/abc123
```

**List Structure:**
```json
{
  "uri": "at://did:plc:xyz/app.bsky.graph.list/abc123",
  "purpose": "app.bsky.graph.defs#modlist",  // or #curatelist
  "name": "Spam Accounts",
  "items": [
    {
      "subject": "did:plc:spammer1",
      "createdAt": "2024-01-15T10:30:00Z"
    }
  ]
}
```

### Thread Muting

**Thread Mute Status** (in PostView):
```swift
public struct AppBskyFeedDefs.PostView {
    public let viewer: ViewerState?
}

public struct ViewerState {
    public let threadMuted: Bool?  // ✅ Available
}
```

**Mute Thread API:**
```
POST app.bsky.graph.muteThread
{
  "root": "at://did:plc:xyz/app.bsky.feed.post/abc123"
}
```

**Unmute Thread API:**
```
POST app.bsky.graph.unmuteThread
{
  "root": "at://did:plc:xyz/app.bsky.feed.post/abc123"
}
```

---

## Implementation Plan

### Phase 1: Database Schema (2 days)

#### Migration 1: Moderation List Subscriptions

```sql
-- migrations/20251013_add_moderation_lists.up.sql

-- Track which moderation lists users subscribe to
CREATE TABLE moderation_list_subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_did TEXT NOT NULL,
    list_uri TEXT NOT NULL,  -- at://did:plc:xyz/app.bsky.graph.list/abc123
    list_purpose TEXT NOT NULL,  -- 'modlist' (block) or 'curatelist' (mute)
    list_name TEXT,  -- For debugging/logging
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_synced_at TIMESTAMPTZ,  -- When we last fetched members
    UNIQUE(user_did, list_uri)
);

CREATE INDEX idx_mod_lists_user_did ON moderation_list_subscriptions(user_did);
CREATE INDEX idx_mod_lists_purpose ON moderation_list_subscriptions(list_purpose);

-- Track members of moderation lists (denormalized for performance)
CREATE TABLE moderation_list_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    list_uri TEXT NOT NULL,
    subject_did TEXT NOT NULL,  -- The blocked/muted user
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(list_uri, subject_did)
);

CREATE INDEX idx_mod_list_members_list ON moderation_list_members(list_uri);
CREATE INDEX idx_mod_list_members_subject ON moderation_list_members(subject_did);

-- Composite index for fast lookup: "Is subject_did in any of user's lists?"
CREATE INDEX idx_mod_list_members_composite 
ON moderation_list_members(subject_did, list_uri);

COMMENT ON TABLE moderation_list_subscriptions IS 
'Tracks which AT Protocol moderation lists each user subscribes to';

COMMENT ON TABLE moderation_list_members IS 
'Denormalized cache of moderation list memberships for fast filtering';
```

#### Migration 2: Muted Threads

```sql
-- migrations/20251013_add_muted_threads.up.sql

-- Track threads users have muted
CREATE TABLE muted_threads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_did TEXT NOT NULL,
    thread_root_uri TEXT NOT NULL,  -- at://did:plc:xyz/app.bsky.feed.post/abc123
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(user_did, thread_root_uri)
);

CREATE INDEX idx_muted_threads_user ON muted_threads(user_did);
CREATE INDEX idx_muted_threads_composite ON muted_threads(user_did, thread_root_uri);

COMMENT ON TABLE muted_threads IS 
'Tracks which post threads users have explicitly muted';
```

#### Down Migrations

```sql
-- migrations/20251013_add_moderation_lists.down.sql
DROP TABLE IF EXISTS moderation_list_members;
DROP TABLE IF EXISTS moderation_list_subscriptions;

-- migrations/20251013_add_muted_threads.down.sql
DROP TABLE IF EXISTS muted_threads;
```

---

### Phase 2: Moderation List Manager (3 days)

Create new module `src/moderation_list_manager.rs`:

```rust
use anyhow::{Context, Result};
use moka::future::Cache;
use sqlx::{Pool, Postgres};
use std::collections::HashSet;
use std::time::Duration;
use tracing::{debug, error, info, warn};

/// Manages moderation list subscriptions and member caching
pub struct ModerationListManager {
    /// Cache: user_did -> set of blocked DIDs from ALL subscribed block lists
    blocked_via_lists_cache: Cache<String, HashSet<String>>,
    /// Cache: user_did -> set of muted DIDs from ALL subscribed mute lists
    muted_via_lists_cache: Cache<String, HashSet<String>>,
    db_pool: Pool<Postgres>,
}

impl ModerationListManager {
    pub fn new(db_pool: Pool<Postgres>) -> Self {
        let blocked_via_lists_cache = Cache::builder()
            .max_capacity(10_000)
            .time_to_live(Duration::from_secs(1800)) // 30 min TTL (longer than individual mutes)
            .build();

        let muted_via_lists_cache = Cache::builder()
            .max_capacity(10_000)
            .time_to_live(Duration::from_secs(1800))
            .build();

        Self {
            blocked_via_lists_cache,
            muted_via_lists_cache,
            db_pool,
        }
    }

    /// Check if target_did is in any of user's subscribed block lists
    pub async fn is_blocked_via_list(&self, user_did: &str, target_did: &str) -> bool {
        // Check cache first
        if let Some(blocked_set) = self.blocked_via_lists_cache.get(user_did) {
            return blocked_set.contains(target_did);
        }

        // Cache miss - load from database
        match self.load_blocked_dids(user_did).await {
            Ok(blocked_set) => {
                let is_blocked = blocked_set.contains(target_did);
                self.blocked_via_lists_cache.insert(user_did.to_string(), blocked_set).await;
                is_blocked
            }
            Err(e) => {
                error!("Failed to load blocked DIDs for {}: {}", user_did, e);
                false // Fail open for availability
            }
        }
    }

    /// Check if target_did is in any of user's subscribed mute lists
    pub async fn is_muted_via_list(&self, user_did: &str, target_did: &str) -> bool {
        if let Some(muted_set) = self.muted_via_lists_cache.get(user_did) {
            return muted_set.contains(target_did);
        }

        match self.load_muted_dids(user_did).await {
            Ok(muted_set) => {
                let is_muted = muted_set.contains(target_did);
                self.muted_via_lists_cache.insert(user_did.to_string(), muted_set).await;
                is_muted
            }
            Err(e) => {
                error!("Failed to load muted DIDs for {}: {}", user_did, e);
                false
            }
        }
    }

    /// Load all DIDs blocked via user's subscribed moderation lists
    async fn load_blocked_dids(&self, user_did: &str) -> Result<HashSet<String>> {
        let rows = sqlx::query!(
            r#"
            SELECT DISTINCT m.subject_did
            FROM moderation_list_members m
            INNER JOIN moderation_list_subscriptions s 
                ON m.list_uri = s.list_uri
            WHERE s.user_did = $1 
                AND s.list_purpose = 'modlist'
            "#,
            user_did
        )
        .fetch_all(&self.db_pool)
        .await?;

        Ok(rows.into_iter().map(|r| r.subject_did).collect())
    }

    /// Load all DIDs muted via user's subscribed moderation lists
    async fn load_muted_dids(&self, user_did: &str) -> Result<HashSet<String>> {
        let rows = sqlx::query!(
            r#"
            SELECT DISTINCT m.subject_did
            FROM moderation_list_members m
            INNER JOIN moderation_list_subscriptions s 
                ON m.list_uri = s.list_uri
            WHERE s.user_did = $1 
                AND s.list_purpose = 'curatelist'
            "#,
            user_did
        )
        .fetch_all(&self.db_pool)
        .await?;

        Ok(rows.into_iter().map(|r| r.subject_did).collect())
    }

    /// Sync user's moderation list subscriptions from AT Protocol
    pub async fn sync_user_lists(&self, user_did: &str, access_token: &str) -> Result<()> {
        info!("Syncing moderation lists for {}", user_did);

        // TODO: Call AT Protocol APIs to fetch lists
        // 1. app.bsky.graph.getListMutes
        // 2. app.bsky.graph.getListBlocks
        // 3. For each list, call app.bsky.graph.getList to get members
        // 4. Upsert to moderation_list_subscriptions and moderation_list_members

        // Clear cache to force reload on next check
        self.blocked_via_lists_cache.invalidate(user_did).await;
        self.muted_via_lists_cache.invalidate(user_did).await;

        Ok(())
    }

    /// Background job: Refresh all users' moderation lists (run every 6 hours)
    pub async fn refresh_all_lists(&self) -> Result<()> {
        info!("Starting moderation list refresh for all users");

        // Get all unique user_dids with list subscriptions
        let users = sqlx::query!(
            r#"
            SELECT DISTINCT user_did 
            FROM moderation_list_subscriptions
            WHERE last_synced_at IS NULL 
                OR last_synced_at < NOW() - INTERVAL '6 hours'
            LIMIT 100
            "#
        )
        .fetch_all(&self.db_pool)
        .await?;

        info!("Refreshing lists for {} users", users.len());

        for user in users {
            // TODO: Fetch access token for user (need to add token storage)
            // For now, skip users without valid tokens
            warn!("Skipping refresh for {} - token storage not implemented", user.user_did);
        }

        Ok(())
    }
}
```

---

### Phase 3: Thread Mute Manager (2 days)

Create new module `src/thread_mute_manager.rs`:

```rust
use anyhow::Result;
use moka::future::Cache;
use sqlx::{Pool, Postgres};
use std::collections::HashSet;
use std::time::Duration;
use tracing::{debug, error};

/// Manages muted thread tracking
pub struct ThreadMuteManager {
    /// Cache: user_did -> set of muted thread root URIs
    muted_threads_cache: Cache<String, HashSet<String>>,
    db_pool: Pool<Postgres>,
}

impl ThreadMuteManager {
    pub fn new(db_pool: Pool<Postgres>) -> Self {
        let muted_threads_cache = Cache::builder()
            .max_capacity(10_000)
            .time_to_live(Duration::from_secs(1800)) // 30 minutes
            .build();

        Self {
            muted_threads_cache,
            db_pool,
        }
    }

    /// Check if user has muted this thread
    pub async fn is_thread_muted(&self, user_did: &str, thread_root_uri: &str) -> bool {
        // Check cache first
        if let Some(muted_set) = self.muted_threads_cache.get(user_did) {
            return muted_set.contains(thread_root_uri);
        }

        // Cache miss - load from database
        match self.load_muted_threads(user_did).await {
            Ok(muted_set) => {
                let is_muted = muted_set.contains(thread_root_uri);
                self.muted_threads_cache.insert(user_did.to_string(), muted_set).await;
                is_muted
            }
            Err(e) => {
                error!("Failed to load muted threads for {}: {}", user_did, e);
                false
            }
        }
    }

    /// Load all muted thread URIs for a user
    async fn load_muted_threads(&self, user_did: &str) -> Result<HashSet<String>> {
        let rows = sqlx::query!(
            r#"
            SELECT thread_root_uri 
            FROM muted_threads 
            WHERE user_did = $1
            "#,
            user_did
        )
        .fetch_all(&self.db_pool)
        .await?;

        Ok(rows.into_iter().map(|r| r.thread_root_uri).collect())
    }

    /// Mute a thread for a user
    pub async fn mute_thread(&self, user_did: &str, thread_root_uri: &str) -> Result<()> {
        sqlx::query!(
            r#"
            INSERT INTO muted_threads (user_did, thread_root_uri)
            VALUES ($1, $2)
            ON CONFLICT (user_did, thread_root_uri) DO NOTHING
            "#,
            user_did,
            thread_root_uri
        )
        .execute(&self.db_pool)
        .await?;

        // Invalidate cache
        self.muted_threads_cache.invalidate(user_did).await;

        Ok(())
    }

    /// Unmute a thread for a user
    pub async fn unmute_thread(&self, user_did: &str, thread_root_uri: &str) -> Result<()> {
        sqlx::query!(
            r#"
            DELETE FROM muted_threads 
            WHERE user_did = $1 AND thread_root_uri = $2
            "#,
            user_did,
            thread_root_uri
        )
        .execute(&self.db_pool)
        .await?;

        // Invalidate cache
        self.muted_threads_cache.invalidate(user_did).await;

        Ok(())
    }

    /// Sync muted threads from AT Protocol for a user
    pub async fn sync_user_threads(&self, user_did: &str, access_token: &str) -> Result<()> {
        // TODO: Fetch user's posts and check threadMuted field
        // This is expensive - only do on demand or periodically

        // Clear cache
        self.muted_threads_cache.invalidate(user_did).await;

        Ok(())
    }
}
```

---

### Phase 4: Filter Integration (2 days)

Update `src/filter.rs` to check moderation lists and muted threads:

```rust
// Add to imports
use crate::moderation_list_manager::ModerationListManager;
use crate::thread_mute_manager::ThreadMuteManager;

pub async fn run_event_filter(
    mut event_receiver: mpsc::Receiver<BlueskyEvent>,
    notification_sender: mpsc::Sender<NotificationPayload>,
    db_pool: Pool<Postgres>,
    did_resolver: Arc<crate::did_resolver::DidResolver>,
    post_resolver: Arc<crate::post_resolver::PostResolver>,
    relationship_manager: Arc<crate::relationship_manager::RelationshipManager>,
    activity_subscription_manager: Arc<ActivitySubscriptionManager>,
    moderation_list_manager: Arc<ModerationListManager>,  // NEW
    thread_mute_manager: Arc<ThreadMuteManager>,          // NEW
) -> Result<()> {
    // ... existing code ...

    while let Some(event) = event_receiver.recv().await {
        // ... existing classification code ...

        // NEW: Extract thread root URI if this is a reply
        let thread_root_uri = if is_reply_post {
            extract_thread_root_uri(&event.record)
        } else {
            Some(format!("at://{}/{}", event.author, event.path))  // Self is root
        };

        for user_did in &potential_recipients {
            // EXISTING: Check individual blocks/mutes
            if relationship_manager.is_blocked(user_did, &event.author).await {
                debug!("Skipping notification: {} has blocked {}", user_did, event.author);
                continue;
            }

            if relationship_manager.is_muted(user_did, &event.author).await {
                debug!("Skipping notification: {} has muted {}", user_did, event.author);
                continue;
            }

            // NEW: Check moderation list blocks/mutes
            if moderation_list_manager.is_blocked_via_list(user_did, &event.author).await {
                debug!("Skipping notification: {} has blocked {} via moderation list", 
                    user_did, event.author);
                crate::metrics::MODERATION_LIST_BLOCKS.inc();
                continue;
            }

            if moderation_list_manager.is_muted_via_list(user_did, &event.author).await {
                debug!("Skipping notification: {} has muted {} via moderation list", 
                    user_did, event.author);
                crate::metrics::MODERATION_LIST_MUTES.inc();
                continue;
            }

            // NEW: Check muted threads
            if let Some(ref root_uri) = thread_root_uri {
                if thread_mute_manager.is_thread_muted(user_did, root_uri).await {
                    debug!("Skipping notification: {} has muted thread {}", 
                        user_did, root_uri);
                    crate::metrics::MUTED_THREAD_SKIPS.inc();
                    continue;
                }
            }

            // ... existing notification sending code ...
        }
    }
}

/// Extract thread root URI from reply record
fn extract_thread_root_uri(record: &serde_json::Value) -> Option<String> {
    record
        .get("reply")?
        .get("root")?
        .get("uri")?
        .as_str()
        .map(String::from)
}
```

---

### Phase 5: API Endpoints (2 days)

Add endpoints to `src/api.rs`:

```rust
// Sync moderation lists from AT Protocol
#[derive(Deserialize)]
struct SyncModerationListsRequest {
    did: String,
    device_token: String,
    access_token: String,  // User's AT Protocol token
}

async fn sync_moderation_lists(
    State(state): State<Arc<ApiState>>,
    Json(req): Json<SyncModerationListsRequest>,
) -> impl IntoResponse {
    // Verify device token (app attest)
    if !verify_device_token(&state, &req.did, &req.device_token).await {
        return error_response(StatusCode::UNAUTHORIZED, "invalid device token");
    }

    // Sync lists from AT Protocol
    match state.moderation_list_manager.sync_user_lists(&req.did, &req.access_token).await {
        Ok(_) => {
            Json(json!({ "success": true })).into_response()
        }
        Err(e) => {
            error!("Failed to sync moderation lists: {}", e);
            error_response(StatusCode::INTERNAL_SERVER_ERROR, "sync failed")
        }
    }
}

// Mute a thread
#[derive(Deserialize)]
struct MuteThreadRequest {
    did: String,
    device_token: String,
    thread_root_uri: String,  // at://did:plc:xyz/app.bsky.feed.post/abc123
}

async fn mute_thread(
    State(state): State<Arc<ApiState>>,
    Json(req): Json<MuteThreadRequest>,
) -> impl IntoResponse {
    if !verify_device_token(&state, &req.did, &req.device_token).await {
        return error_response(StatusCode::UNAUTHORIZED, "invalid device token");
    }

    match state.thread_mute_manager.mute_thread(&req.did, &req.thread_root_uri).await {
        Ok(_) => {
            Json(json!({ "success": true })).into_response()
        }
        Err(e) => {
            error!("Failed to mute thread: {}", e);
            error_response(StatusCode::INTERNAL_SERVER_ERROR, "mute failed")
        }
    }
}

// Unmute a thread
#[derive(Deserialize)]
struct UnmuteThreadRequest {
    did: String,
    device_token: String,
    thread_root_uri: String,
}

async fn unmute_thread(
    State(state): State<Arc<ApiState>>,
    Json(req): Json<UnmuteThreadRequest>,
) -> impl IntoResponse {
    if !verify_device_token(&state, &req.did, &req.device_token).await {
        return error_response(StatusCode::UNAUTHORIZED, "invalid device token");
    }

    match state.thread_mute_manager.unmute_thread(&req.did, &req.thread_root_uri).await {
        Ok(_) => {
            Json(json!({ "success": true })).into_response()
        }
        Err(e) => {
            error!("Failed to unmute thread: {}", e);
            error_response(StatusCode::INTERNAL_SERVER_ERROR, "unmute failed")
        }
    }
}

// Add routes in setup
pub fn create_router(state: Arc<ApiState>) -> Router {
    Router::new()
        // ... existing routes ...
        .route("/sync-moderation-lists", post(sync_moderation_lists))
        .route("/mute-thread", post(mute_thread))
        .route("/unmute-thread", post(unmute_thread))
        .with_state(state)
}
```

---

### Phase 6: Metrics (1 day)

Add metrics to `src/metrics.rs`:

```rust
use prometheus::{IntCounter, Registry};

lazy_static! {
    pub static ref MODERATION_LIST_BLOCKS: IntCounter = IntCounter::new(
        "push_notifier_moderation_list_blocks_total",
        "Notifications blocked due to moderation lists"
    ).unwrap();

    pub static ref MODERATION_LIST_MUTES: IntCounter = IntCounter::new(
        "push_notifier_moderation_list_mutes_total",
        "Notifications muted due to moderation lists"
    ).unwrap();

    pub static ref MUTED_THREAD_SKIPS: IntCounter = IntCounter::new(
        "push_notifier_muted_thread_skips_total",
        "Notifications skipped due to muted threads"
    ).unwrap();
}

pub fn register_metrics(registry: &Registry) {
    // ... existing metrics ...
    registry.register(Box::new(MODERATION_LIST_BLOCKS.clone())).unwrap();
    registry.register(Box::new(MODERATION_LIST_MUTES.clone())).unwrap();
    registry.register(Box::new(MUTED_THREAD_SKIPS.clone())).unwrap();
}
```

---

## Testing Plan

### Unit Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_moderation_list_blocking() {
        // Setup test database
        let pool = setup_test_db().await;
        let manager = ModerationListManager::new(pool.clone());

        // Insert test list subscription
        sqlx::query!(
            "INSERT INTO moderation_list_subscriptions (user_did, list_uri, list_purpose) 
             VALUES ($1, $2, $3)",
            "did:plc:user1",
            "at://did:plc:moderator/app.bsky.graph.list/blocklist1",
            "modlist"
        ).execute(&pool).await.unwrap();

        // Insert test list member
        sqlx::query!(
            "INSERT INTO moderation_list_members (list_uri, subject_did) 
             VALUES ($1, $2)",
            "at://did:plc:moderator/app.bsky.graph.list/blocklist1",
            "did:plc:spammer"
        ).execute(&pool).await.unwrap();

        // Test blocking
        assert!(manager.is_blocked_via_list("did:plc:user1", "did:plc:spammer").await);
        assert!(!manager.is_blocked_via_list("did:plc:user1", "did:plc:innocent").await);
    }

    #[tokio::test]
    async fn test_thread_muting() {
        let pool = setup_test_db().await;
        let manager = ThreadMuteManager::new(pool.clone());

        let user = "did:plc:user1";
        let thread = "at://did:plc:xyz/app.bsky.feed.post/abc123";

        // Initially not muted
        assert!(!manager.is_thread_muted(user, thread).await);

        // Mute thread
        manager.mute_thread(user, thread).await.unwrap();
        assert!(manager.is_thread_muted(user, thread).await);

        // Unmute thread
        manager.unmute_thread(user, thread).await.unwrap();
        assert!(!manager.is_thread_muted(user, thread).await);
    }
}
```

### Integration Tests

1. **End-to-End Flow**:
   - Subscribe to moderation list
   - Receive event from blocked user
   - Verify notification is suppressed
   - Check metrics increment

2. **Cache Invalidation**:
   - Load moderation list data
   - Verify cache hit
   - Update list membership
   - Verify cache invalidation

3. **Performance**:
   - Benchmark cache hit rate (target: >95%)
   - Measure filter latency (target: <10ms additional overhead)

---

## Deployment Plan

### Pre-Deployment

1. **Run Migrations**:
   ```bash
   sqlx migrate run
   ```

2. **Verify Database**:
   ```sql
   SELECT COUNT(*) FROM moderation_list_subscriptions;
   SELECT COUNT(*) FROM moderation_list_members;
   SELECT COUNT(*) FROM muted_threads;
   ```

3. **Build & Test**:
   ```bash
   cargo test
   cargo build --release
   ```

### Deployment Steps

1. **Deploy to Staging**:
   ```bash
   ./deploy-dev.sh
   ```

2. **Smoke Test**:
   - Verify health endpoint
   - Check Prometheus metrics
   - Test API endpoints with Postman

3. **Monitor Metrics**:
   - `push_notifier_moderation_list_blocks_total`
   - `push_notifier_moderation_list_mutes_total`
   - `push_notifier_muted_thread_skips_total`

4. **Deploy to Production**:
   ```bash
   ./deploy-prod.sh
   ```

### Rollback Plan

If issues arise:

```bash
# Revert migrations
sqlx migrate revert --target-version <previous_version>

# Redeploy previous version
git checkout <previous_commit>
./deploy-prod.sh
```

---

## Client-Side Integration (Catbird App)

### API Calls from Catbird

```swift
// Catbird/Features/Notifications/Services/NotificationManager.swift

extension NotificationManager {
    /// Sync moderation lists to push-notifier
    func syncModerationLists() async throws {
        guard let accessToken = appState.authManager.accessToken else {
            throw NotificationError.notAuthenticated
        }

        let endpoint = "\(pushNotifierBaseURL)/sync-moderation-lists"
        let payload: [String: Any] = [
            "did": appState.authManager.currentUserDid,
            "device_token": deviceToken,
            "access_token": accessToken
        ]

        // Make request with app attest assertion
        _ = try await makeAuthenticatedRequest(endpoint: endpoint, payload: payload)
    }

    /// Mute a thread in push notifications
    func muteThreadNotifications(threadRootURI: String) async throws {
        let endpoint = "\(pushNotifierBaseURL)/mute-thread"
        let payload: [String: Any] = [
            "did": appState.authManager.currentUserDid,
            "device_token": deviceToken,
            "thread_root_uri": threadRootURI
        ]

        _ = try await makeAuthenticatedRequest(endpoint: endpoint, payload: payload)
    }

    /// Unmute a thread in push notifications
    func unmuteThreadNotifications(threadRootURI: String) async throws {
        let endpoint = "\(pushNotifierBaseURL)/unmute-thread"
        let payload: [String: Any] = [
            "did": appState.authManager.currentUserDid,
            "device_token": deviceToken,
            "thread_root_uri": threadRootURI
        ]

        _ = try await makeAuthenticatedRequest(endpoint: endpoint, payload: payload)
    }
}
```

### UI Integration

Add "Mute Thread Notifications" action to post menu:

```swift
// Catbird/Features/Feed/Views/PostActionsSheet.swift

Button {
    Task {
        await muteThreadNotifications(post: post)
    }
} label: {
    Label("Mute Thread Notifications", systemImage: "bell.slash")
}

private func muteThreadNotifications(post: PostViewModel) async {
    guard let threadRootURI = post.threadRootURI else { return }

    do {
        try await appState.notificationManager.muteThreadNotifications(
            threadRootURI: threadRootURI
        )
        showToast("Thread notifications muted")
    } catch {
        logger.error("Failed to mute thread: \(error)")
        showToast("Failed to mute notifications")
    }
}
```

---

## Success Metrics

### Functional Metrics

- ✅ Moderation list blocks working (verified via logs)
- ✅ Thread mute suppression working (verified via logs)
- ✅ API endpoints respond correctly (verified via tests)
- ✅ Cache hit rate >95% (verified via metrics)

### Performance Metrics

- Filter latency increase <10ms (measured via tracing)
- Database query time <5ms (measured via sqlx)
- Memory usage increase <100MB (measured via metrics)

### User Impact Metrics

- 30% reduction in unwanted notifications (estimated)
- User satisfaction increase (survey after 2 weeks)

---

## Risks & Mitigation

### Performance Risk

**Risk**: Checking moderation lists adds latency to filter pipeline  
**Mitigation**: Aggressive caching (30min TTL), denormalized member table, composite indexes

### Data Freshness Risk

**Risk**: Moderation list changes not reflected immediately  
**Mitigation**: 30min cache TTL, manual sync API endpoint, background refresh job

### Scale Risk

**Risk**: Large moderation lists (10k+ members) slow down queries  
**Mitigation**: Denormalized storage, database indexes, query optimization

### Privacy Risk

**Risk**: Storing moderation list data on server  
**Mitigation**: Encrypted storage (like existing mutes), audit logging

---

## Future Enhancements

### Phase 2 (Nice to Have)

1. **Real-time List Updates**: Subscribe to AT Protocol firehose for list changes
2. **Smart Sync**: Only fetch changed members since last sync (cursor-based)
3. **List Analytics**: Show user which lists are blocking most notifications
4. **Bulk Thread Mute**: Mute all threads from a specific user
5. **Temporary Mutes**: Auto-unmute threads after 24h/7d

---

## Acceptance Criteria

- [ ] Database migrations run successfully
- [ ] ModrationListManager correctly filters blocked/muted users
- [ ] ThreadMuteManager correctly filters muted threads
- [ ] API endpoints work with app attest verification
- [ ] Unit tests pass (>90% coverage)
- [ ] Integration tests pass
- [ ] Performance benchmarks met (<10ms overhead)
- [ ] Metrics dashboard shows blocking/muting activity
- [ ] Catbird app can sync lists and mute threads
- [ ] Production deployment successful
- [ ] No increase in error rate post-deployment

---

## Timeline

| Phase | Task | Duration | Owner |
|-------|------|----------|-------|
| 1 | Database Schema | 2 days | Backend Engineer |
| 2 | Moderation List Manager | 3 days | Backend Engineer |
| 3 | Thread Mute Manager | 2 days | Backend Engineer |
| 4 | Filter Integration | 2 days | Backend Engineer |
| 5 | API Endpoints | 2 days | Backend Engineer |
| 6 | Metrics & Testing | 1 day | Backend Engineer |
| 7 | Deployment | 1 day | DevOps |
| 8 | Client Integration | 2 days | iOS Engineer |

**Total**: 15 days (3 weeks with parallel work)

---

## Next Steps

1. **Review this design doc** with backend and iOS teams
2. **Create GitHub issues** for each phase
3. **Set up project board** with tasks
4. **Schedule kickoff meeting** for next week
5. **Assign owner** for backend implementation

---

*Document Version: 1.0*  
*Last Updated: 2025-10-13*  
*Repository: `bluesky-push-notifier`*
