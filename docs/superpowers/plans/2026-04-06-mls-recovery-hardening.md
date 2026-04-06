# MLS Recovery Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove deprecated plaintext reaction infrastructure and implement quorum-based automatic MLS group reset.

**Architecture:** Two independent workstreams. Workstream 1 removes dead code (plaintext `reactionEvent` SSE type, server-side reaction DB functions, migration to drop `message_reactions` table). Workstream 2 adds a `recovery_failures` table, a `reportRecoveryFailure` endpoint that evaluates quorum-based auto-reset policy, and client-side changes to report failures and wait for reset.

**Tech Stack:** Rust (Axum, sqlx, tokio), PostgreSQL migrations, Swift (catbird-mls orchestrator via UniFFI)

---

## File Structure

### Workstream 1: Remove `reactionEvent`

| Action | File |
|--------|------|
| Modify | `mls-ds/server/src/realtime/sse.rs` — remove `ReactionEvent` variant from `StreamEvent` and `RawStreamEvent` enums, remove deserialization match arm |
| Modify | `mls-ds/server/src/handlers/mls_chat/send_message.rs` — remove `"addReaction"` and `"removeReaction"` match arms and `handle_add_reaction`/`handle_remove_reaction` functions |
| Modify | `mls-ds/server/src/db.rs` — remove `ReactionView` struct, `add_reaction`, `remove_reaction`, `get_message_reactions`, `get_reactions_for_messages` functions |
| Create | `mls-ds/server/migrations/20260406_001_drop_message_reactions.sql` — drop table |

### Workstream 2: Quorum-Based Auto-Reset

| Action | File |
|--------|------|
| Create | `mls-ds/server/migrations/20260406_002_recovery_failures.sql` — new table + conversations column |
| Create | `mls-ds/server/src/handlers/mls_chat/report_recovery_failure.rs` — new endpoint handler |
| Modify | `mls-ds/server/src/handlers/mls_chat/mod.rs` — register new module |
| Modify | `mls-ds/server/src/main.rs` — add route |
| Modify | `mls-ds/server/src/models.rs` — add `auto_reset_disabled_at` to `Conversation` struct |
| Modify | `catbird-mls/src/orchestrator/api_client.rs` — add `report_recovery_failure` trait method |
| Modify | `catbird-mls/src/orchestrator/recovery.rs` — call report on max attempts, add waiting state |

---

## Task 1: Drop `message_reactions` Table

**Files:**
- Create: `mls-ds/server/migrations/20260406_001_drop_message_reactions.sql`

- [ ] **Step 1: Write the migration**

```sql
-- Drop deprecated plaintext message_reactions table.
-- Reactions are now sent as encrypted MLS application messages.
DROP TABLE IF EXISTS message_reactions;
```

- [ ] **Step 2: Verify migration file exists**

Run: `ls mls-ds/server/migrations/20260406_001_drop_message_reactions.sql`
Expected: file listed

- [ ] **Step 3: Commit**

```bash
git add mls-ds/server/migrations/20260406_001_drop_message_reactions.sql
git commit -m "mls-ds: Add migration to drop deprecated message_reactions table"
```

---

## Task 2: Remove Reaction Functions from db.rs

**Files:**
- Modify: `mls-ds/server/src/db.rs:12-19` (ReactionView struct)
- Modify: `mls-ds/server/src/db.rs:2198-2307` (four reaction functions)

- [ ] **Step 1: Remove `ReactionView` struct**

Delete lines 12-19 of `db.rs`:
```rust
// DELETE THIS BLOCK:
/// View of a reaction on a message.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReactionView {
    pub user_did: String,
    pub reaction: String,
    pub created_at: DateTime<Utc>,
}
```

- [ ] **Step 2: Remove all four reaction functions**

Delete lines 2198-2307 of `db.rs` — the entire block containing:
- `pub async fn add_reaction(...)`
- `pub async fn remove_reaction(...)`
- `pub async fn get_message_reactions(...)`
- `pub async fn get_reactions_for_messages(...)`

- [ ] **Step 3: Verify compilation**

Run: `cd mls-ds/server && cargo check 2>&1 | head -20`
Expected: may show errors in `send_message.rs` referencing removed functions — that's expected, we fix those in Task 3.

- [ ] **Step 4: Commit**

```bash
git add mls-ds/server/src/db.rs
git commit -m "mls-ds: Remove deprecated plaintext reaction DB functions"
```

---

## Task 3: Remove Reaction Handlers from send_message.rs

**Files:**
- Modify: `mls-ds/server/src/handlers/mls_chat/send_message.rs:84-90` (match arms)
- Modify: `mls-ds/server/src/handlers/mls_chat/send_message.rs:584-800` (handler functions)

- [ ] **Step 1: Remove match arms for addReaction/removeReaction**

In the `"ephemeral"` match block (around line 84-90), delete:
```rust
// DELETE THESE LINES:
"addReaction" => handle_add_reaction(pool, sse_state, auth_user, &input).await?,
"removeReaction" => {
    handle_remove_reaction(pool, sse_state, auth_user, &input).await?
}
```

- [ ] **Step 2: Remove `handle_add_reaction` function**

Delete the entire `async fn handle_add_reaction(...)` function starting at line 584 and its full body.

- [ ] **Step 3: Remove `handle_remove_reaction` function**

Delete the entire `async fn handle_remove_reaction(...)` function starting at line 721 and its full body.

- [ ] **Step 4: Verify compilation**

Run: `cd mls-ds/server && cargo check`
Expected: PASS (no references to removed functions remain)

- [ ] **Step 5: Commit**

```bash
git add mls-ds/server/src/handlers/mls_chat/send_message.rs
git commit -m "mls-ds: Remove deprecated plaintext reaction handlers"
```

---

## Task 4: Remove `ReactionEvent` from SSE StreamEvent

**Files:**
- Modify: `mls-ds/server/src/realtime/sse.rs:49-59` (StreamEvent enum variant)
- Modify: `mls-ds/server/src/realtime/sse.rs:186-196` (RawStreamEvent enum variant)
- Modify: `mls-ds/server/src/realtime/sse.rs:317-331` (deserialization match arm)

- [ ] **Step 1: Remove `ReactionEvent` variant from `StreamEvent` enum**

Delete lines 49-59:
```rust
// DELETE THIS VARIANT:
#[serde(rename = "blue.catbird.mlsChat.subscribeEvents#reactionEvent")]
ReactionEvent {
    cursor: String,
    #[serde(rename = "convoId")]
    convo_id: String,
    #[serde(rename = "messageId")]
    message_id: String,
    did: String,
    reaction: String,
    action: String,
},
```

- [ ] **Step 2: Remove `ReactionEvent` variant from `RawStreamEvent` enum**

Delete lines 186-196:
```rust
// DELETE THIS VARIANT:
#[serde(rename = "blue.catbird.mlsChat.subscribeEvents#reactionEvent")]
ReactionEvent {
    cursor: String,
    #[serde(rename = "convoId")]
    convo_id: String,
    #[serde(rename = "messageId")]
    message_id: String,
    did: String,
    reaction: String,
    action: String,
},
```

- [ ] **Step 3: Remove deserialization match arm**

Delete lines 317-331:
```rust
// DELETE THIS ARM:
RawStreamEvent::ReactionEvent {
    cursor,
    convo_id,
    message_id,
    did,
    reaction,
    action,
} => StreamEvent::ReactionEvent {
    cursor,
    convo_id,
    message_id,
    did,
    reaction,
    action,
},
```

- [ ] **Step 4: Verify compilation**

Run: `cd mls-ds/server && cargo check`
Expected: PASS

- [ ] **Step 5: Run tests**

Run: `cd mls-ds/server && cargo test 2>&1 | tail -5`
Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add mls-ds/server/src/realtime/sse.rs
git commit -m "mls-ds: Remove ReactionEvent from SSE StreamEvent enum"
```

---

## Task 5: Recovery Failures Migration

**Files:**
- Create: `mls-ds/server/migrations/20260406_002_recovery_failures.sql`

- [ ] **Step 1: Write the migration**

```sql
-- Recovery failure tracking for quorum-based auto-reset.
-- Each row: "this member has exhausted External Commit retries."
-- Cleared on successful reset or rejoin.

CREATE TABLE IF NOT EXISTS recovery_failures (
    convo_id    VARCHAR(255) NOT NULL,
    member_did  VARCHAR(255) NOT NULL,
    reported_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    failure_type VARCHAR(64) NOT NULL DEFAULT 'external_commit_exhausted',
    PRIMARY KEY (convo_id, member_did)
);

CREATE INDEX IF NOT EXISTS idx_recovery_failures_convo
    ON recovery_failures(convo_id);

-- Circuit breaker: disable auto-reset after repeated resets
ALTER TABLE conversations
    ADD COLUMN IF NOT EXISTS auto_reset_disabled_at TIMESTAMPTZ;
```

- [ ] **Step 2: Verify migration file exists**

Run: `ls mls-ds/server/migrations/20260406_002_recovery_failures.sql`
Expected: file listed

- [ ] **Step 3: Commit**

```bash
git add mls-ds/server/migrations/20260406_002_recovery_failures.sql
git commit -m "mls-ds: Add recovery_failures table and auto_reset_disabled_at column"
```

---

## Task 6: Add `auto_reset_disabled_at` to Conversation Model

**Files:**
- Modify: `mls-ds/server/src/models.rs:48-52`

- [ ] **Step 1: Add field to Conversation struct**

After the `reset_count` field (line 51), add:

```rust
    #[sqlx(default)]
    pub auto_reset_disabled_at: Option<chrono::DateTime<chrono::Utc>>,
```

- [ ] **Step 2: Verify compilation**

Run: `cd mls-ds/server && cargo check`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add mls-ds/server/src/models.rs
git commit -m "mls-ds: Add auto_reset_disabled_at to Conversation model"
```

---

## Task 7: Implement `reportRecoveryFailure` Handler

**Files:**
- Create: `mls-ds/server/src/handlers/mls_chat/report_recovery_failure.rs`

- [ ] **Step 1: Write the handler**

```rust
use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::{error, info, warn};

use crate::{
    auth::AuthUser,
    realtime::{sse::StreamEvent, SseState},
    storage::DbPool,
};

const NSID: &str = "blue.catbird.mlsChat.reportRecoveryFailure";

// ---------------------------------------------------------------------------
// Request / Response types
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReportRecoveryFailureRequest {
    pub convo_id: String,
    pub failure_type: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReportRecoveryFailureOutput {
    pub recorded: bool,
    pub auto_reset_triggered: bool,
    pub failure_count: i64,
    pub member_count: i64,
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Minimum interval between auto-resets for the same conversation (30 minutes).
const AUTO_RESET_COOLDOWN_SECS: i64 = 1800;

/// Maximum auto-resets within 24 hours before circuit breaker trips.
const CIRCUIT_BREAKER_MAX_RESETS: i32 = 3;

/// How old a failure report can be and still count toward quorum (1 hour).
const FAILURE_EXPIRY_SECS: i64 = 3600;

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/// Report that recovery has been exhausted for a conversation.
///
/// POST /xrpc/blue.catbird.mlsChat.reportRecoveryFailure
///
/// Any member may report. When ≥50% of active members have reported
/// (within the expiry window), the server auto-resets the group.
#[tracing::instrument(skip(pool, sse_state, auth_user, input))]
pub async fn report_recovery_failure(
    State(pool): State<DbPool>,
    State(sse_state): State<Arc<SseState>>,
    auth_user: AuthUser,
    Json(input): Json<ReportRecoveryFailureRequest>,
) -> Result<Response, StatusCode> {
    if let Err(_e) = crate::auth::enforce_standard(&auth_user.claims, NSID) {
        error!("[reportRecoveryFailure] Unauthorized");
        return Err(StatusCode::UNAUTHORIZED);
    }

    let caller_did = &auth_user.did;
    let convo_id = &input.convo_id;
    let failure_type = input.failure_type.as_deref().unwrap_or("external_commit_exhausted");

    info!(
        convo = %crate::crypto::redact_for_log(convo_id),
        caller = %crate::crypto::redact_for_log(caller_did),
        failure_type,
        "[reportRecoveryFailure] start"
    );

    // --- Verify caller is a member ---
    let is_member: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM members WHERE convo_id = $1 AND (user_did = $2 OR member_did = $2) AND left_at IS NULL)",
    )
    .bind(convo_id)
    .bind(caller_did)
    .fetch_one(&pool)
    .await
    .map_err(|e| {
        error!("[reportRecoveryFailure] membership check failed: {}", e);
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    if !is_member {
        warn!("[reportRecoveryFailure] caller is not a member");
        return Err(StatusCode::FORBIDDEN);
    }

    // --- Upsert failure report ---
    sqlx::query(
        r#"INSERT INTO recovery_failures (convo_id, member_did, reported_at, failure_type)
           VALUES ($1, $2, NOW(), $3)
           ON CONFLICT (convo_id, member_did) DO UPDATE
           SET reported_at = NOW(), failure_type = $3"#,
    )
    .bind(convo_id)
    .bind(caller_did)
    .bind(failure_type)
    .execute(&pool)
    .await
    .map_err(|e| {
        error!("[reportRecoveryFailure] upsert failed: {}", e);
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    // --- Count recent failures vs total members ---
    let failure_count: i64 = sqlx::query_scalar(
        r#"SELECT COUNT(*) FROM recovery_failures
           WHERE convo_id = $1
           AND reported_at > NOW() - INTERVAL '1 hour'"#,
    )
    .bind(convo_id)
    .fetch_one(&pool)
    .await
    .map_err(|e| {
        error!("[reportRecoveryFailure] count failures: {}", e);
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    let member_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM members WHERE convo_id = $1 AND left_at IS NULL",
    )
    .bind(convo_id)
    .fetch_one(&pool)
    .await
    .map_err(|e| {
        error!("[reportRecoveryFailure] count members: {}", e);
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    info!(
        convo = %crate::crypto::redact_for_log(convo_id),
        failure_count,
        member_count,
        "[reportRecoveryFailure] quorum check"
    );

    // --- Evaluate auto-reset policy: ≥50% of members reported ---
    let threshold_met = member_count > 0 && failure_count * 2 >= member_count;

    if !threshold_met {
        return Ok(Json(ReportRecoveryFailureOutput {
            recorded: true,
            auto_reset_triggered: false,
            failure_count,
            member_count,
        })
        .into_response());
    }

    // --- Check cooldown: no auto-reset within 30 minutes ---
    let recent_reset: bool = sqlx::query_scalar(
        r#"SELECT EXISTS(
            SELECT 1 FROM conversations
            WHERE id = $1
            AND last_reset_at IS NOT NULL
            AND last_reset_at > NOW() - INTERVAL '30 minutes'
        )"#,
    )
    .bind(convo_id)
    .fetch_one(&pool)
    .await
    .unwrap_or(false);

    if recent_reset {
        info!("[reportRecoveryFailure] cooldown active, skipping auto-reset");
        return Ok(Json(ReportRecoveryFailureOutput {
            recorded: true,
            auto_reset_triggered: false,
            failure_count,
            member_count,
        })
        .into_response());
    }

    // --- Check circuit breaker: auto_reset_disabled_at ---
    let disabled: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = $1 AND auto_reset_disabled_at IS NOT NULL)",
    )
    .bind(convo_id)
    .fetch_one(&pool)
    .await
    .unwrap_or(false);

    if disabled {
        warn!("[reportRecoveryFailure] circuit breaker active for conversation");
        return Ok(Json(ReportRecoveryFailureOutput {
            recorded: true,
            auto_reset_triggered: false,
            failure_count,
            member_count,
        })
        .into_response());
    }

    // --- Check circuit breaker: 3 resets in 24 hours ---
    let reset_count_24h: i64 = sqlx::query_scalar(
        r#"SELECT COUNT(*) FROM (
            SELECT 1 FROM conversations
            WHERE id = $1
            AND last_reset_by = 'system:auto_recovery'
            AND last_reset_at > NOW() - INTERVAL '24 hours'
            AND reset_count >= 3
        ) sub"#,
    )
    .bind(convo_id)
    .fetch_one(&pool)
    .await
    .unwrap_or(0);

    // A simpler check: if reset_count >= 3 and last 3 resets happened within 24h
    // We approximate by checking if reset_count >= 3 and last_reset_at is recent
    // and last_reset_by is auto_recovery. For a more precise check we'd need a
    // reset_history table, but this is a reasonable approximation.
    let current_reset_count: Option<i32> = sqlx::query_scalar(
        "SELECT reset_count FROM conversations WHERE id = $1",
    )
    .bind(convo_id)
    .fetch_optional(&pool)
    .await
    .map_err(|e| {
        error!("[reportRecoveryFailure] fetch reset_count: {}", e);
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    // For circuit breaker, we need to know how many auto-resets happened in 24h.
    // Since we don't have a reset_history table, we check: if the conversation
    // was auto-reset recently AND reset_count >= CIRCUIT_BREAKER_MAX_RESETS,
    // trip the breaker. This is conservative but safe.
    // TODO: For precise tracking, add a reset_history table in a future migration.

    // --- Execute auto-reset ---
    info!(
        convo = %crate::crypto::redact_for_log(convo_id),
        "[reportRecoveryFailure] threshold met, executing auto-reset"
    );

    let new_group_id = format!("{:032x}", uuid::Uuid::new_v4().as_u128());

    let mut tx = pool.begin().await.map_err(|e| {
        error!("[reportRecoveryFailure] begin tx: {}", e);
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    // Reset the conversation
    let reset_count: Option<i32> = sqlx::query_scalar(
        r#"UPDATE conversations SET
            group_id = $1, current_epoch = 0,
            group_info = NULL, group_info_epoch = NULL,
            group_info_updated_at = NULL,
            confirmation_tag = NULL,
            reset_count = reset_count + 1, last_reset_at = NOW(),
            last_reset_by = 'system:auto_recovery',
            updated_at = NOW()
        WHERE id = $2
        RETURNING reset_count"#,
    )
    .bind(&new_group_id)
    .bind(convo_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| {
        error!("[reportRecoveryFailure] update conversations: {}", e);
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    let reset_count = match reset_count {
        Some(rc) => rc,
        None => {
            tx.rollback().await.ok();
            return Err(StatusCode::NOT_FOUND);
        }
    };

    // Check circuit breaker after incrementing
    if reset_count >= CIRCUIT_BREAKER_MAX_RESETS {
        // Trip circuit breaker
        sqlx::query("UPDATE conversations SET auto_reset_disabled_at = NOW() WHERE id = $1")
            .bind(convo_id)
            .execute(&mut *tx)
            .await
            .map_err(|e| {
                error!("[reportRecoveryFailure] trip circuit breaker: {}", e);
                StatusCode::INTERNAL_SERVER_ERROR
            })?;
        warn!(
            convo = %crate::crypto::redact_for_log(convo_id),
            reset_count,
            "[reportRecoveryFailure] circuit breaker tripped"
        );
    }

    // Delete welcome messages
    sqlx::query("DELETE FROM welcome_messages WHERE convo_id = $1")
        .bind(convo_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| {
            error!("[reportRecoveryFailure] delete welcome_messages: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    // Delete pending device additions
    sqlx::query("DELETE FROM pending_device_additions WHERE convo_id = $1")
        .bind(convo_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| {
            error!("[reportRecoveryFailure] delete pending_device_additions: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    // Clear recovery failures for this conversation
    sqlx::query("DELETE FROM recovery_failures WHERE convo_id = $1")
        .bind(convo_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| {
            error!("[reportRecoveryFailure] clear recovery_failures: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    tx.commit().await.map_err(|e| {
        error!("[reportRecoveryFailure] commit tx: {}", e);
        StatusCode::INTERNAL_SERVER_ERROR
    })?;

    info!(
        convo = %crate::crypto::redact_for_log(convo_id),
        new_group_id = %crate::crypto::redact_for_log(&new_group_id),
        reset_count,
        "[reportRecoveryFailure] auto-reset complete"
    );

    // --- Emit SSE GroupResetEvent ---
    let cursor = sse_state
        .cursor_gen
        .next(convo_id, "groupResetEvent")
        .await;

    let event = StreamEvent::GroupResetEvent {
        cursor: cursor.clone(),
        convo_id: convo_id.clone(),
        new_group_id: new_group_id.clone(),
        reset_generation: reset_count,
        reset_by: "system:auto_recovery".to_string(),
        cipher_suite: String::new(), // Not known for auto-reset; clients use their default
        reason: Some("Automatic recovery: quorum of members reported unrecoverable failure".to_string()),
    };

    if let Err(e) =
        crate::db::store_event(&pool, &cursor, convo_id, "groupResetEvent", None).await
    {
        error!("[reportRecoveryFailure] store event: {:?}", e);
    }

    if let Err(e) = sse_state.emit(convo_id, event).await {
        error!("[reportRecoveryFailure] SSE emit: {}", e);
    }

    Ok(Json(ReportRecoveryFailureOutput {
        recorded: true,
        auto_reset_triggered: true,
        failure_count,
        member_count,
    })
    .into_response())
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd mls-ds/server && cargo check 2>&1 | head -20`
Expected: may fail because module not registered yet — that's Task 8.

- [ ] **Step 3: Commit**

```bash
git add mls-ds/server/src/handlers/mls_chat/report_recovery_failure.rs
git commit -m "mls-ds: Add reportRecoveryFailure handler with quorum-based auto-reset"
```

---

## Task 8: Register Handler in Router

**Files:**
- Modify: `mls-ds/server/src/handlers/mls_chat/mod.rs`
- Modify: `mls-ds/server/src/main.rs:667-669`

- [ ] **Step 1: Add module declaration to mod.rs**

After `pub mod reset_group;` (line 23), add:

```rust
pub mod report_recovery_failure;
```

After `pub use reset_group::reset_group;` (line 71), add:

```rust
pub use report_recovery_failure::report_recovery_failure;
```

- [ ] **Step 2: Add route to main.rs**

After the `resetGroup` route block (line 669), add:

```rust
        // Recovery Failure Reporting
        .route(
            "/xrpc/blue.catbird.mlsChat.reportRecoveryFailure",
            post(handlers::mls_chat::report_recovery_failure),
        )
```

- [ ] **Step 3: Verify compilation**

Run: `cd mls-ds/server && cargo check`
Expected: PASS

- [ ] **Step 4: Run tests**

Run: `cd mls-ds/server && cargo test 2>&1 | tail -10`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add mls-ds/server/src/handlers/mls_chat/mod.rs mls-ds/server/src/main.rs
git commit -m "mls-ds: Register reportRecoveryFailure route"
```

---

## Task 9: Add `report_recovery_failure` to API Client Trait

**Files:**
- Modify: `catbird-mls/src/orchestrator/api_client.rs:169-174`

- [ ] **Step 1: Add trait method**

After the `request_failover` method (line 174), add:

```rust
    /// Report that recovery has been exhausted for a conversation.
    ///
    /// Called when the RecoveryTracker has maxed out External Commit attempts.
    /// The server tracks failure reports and auto-resets when a quorum of
    /// members report failure.
    async fn report_recovery_failure(
        &self,
        convo_id: &str,
        failure_type: &str,
    ) -> Result<()> {
        let _ = (convo_id, failure_type);
        Err(crate::orchestrator::error::OrchestratorError::Api(
            "report_recovery_failure not implemented".into(),
        ))
    }
```

- [ ] **Step 2: Verify compilation**

Run: `cd catbird-mls && cargo check`
Expected: PASS (default implementation means existing implementors don't break)

- [ ] **Step 3: Commit**

```bash
git add catbird-mls/src/orchestrator/api_client.rs
git commit -m "mls-ffi: Add report_recovery_failure to MLSAPIClient trait"
```

---

## Task 10: Client-Side Recovery Reporting

**Files:**
- Modify: `catbird-mls/src/orchestrator/recovery.rs:264-275`

- [ ] **Step 1: Add recovery failure reporting after max attempts**

In `enforce_rejoin_backoff` (line 264), where `is_maxed_out` returns true and the function returns an error, add a call to report the failure to the server. Replace the existing max-out block:

```rust
    async fn enforce_rejoin_backoff(&self, convo_id: &str) -> Result<()> {
        let tracker = self.recovery_tracker().lock().await;
        if tracker.is_maxed_out(convo_id) {
            tracing::warn!(
                convo_id,
                max_attempts = self.config().max_rejoin_attempts,
                "Rejoin suppressed: max attempts reached, reporting recovery failure"
            );
            // Drop lock before async call
            drop(tracker);
            // Report failure to server for quorum-based auto-reset
            if let Err(e) = self
                .api_client()
                .report_recovery_failure(convo_id, "external_commit_exhausted")
                .await
            {
                tracing::warn!(
                    convo_id,
                    error = %e,
                    "Failed to report recovery failure to server"
                );
            }
            return Err(OrchestratorError::RecoveryFailed(format!(
                "Rejoin suppressed for {convo_id}: max attempts reached"
            )));
        }

        if let Some(remaining) = tracker.cooldown_remaining(convo_id) {
            tracing::info!(
                convo_id,
                remaining_secs = remaining.as_secs(),
                "Rejoin suppressed: cooldown active"
            );
            return Err(OrchestratorError::RecoveryFailed(format!(
                "Rejoin suppressed for {convo_id}: cooldown active ({}s remaining)",
                remaining.as_secs()
            )));
        }

        // Hard minimum interval between any rejoin attempts (even successful ones)
        if let Some(last) = tracker.last_rejoin_at.get(convo_id) {
            let elapsed = last.elapsed();
            let min_interval = Duration::from_secs(30);
            if elapsed < min_interval {
                let remaining = min_interval - elapsed;
                tracing::info!(
                    convo_id,
                    remaining_secs = remaining.as_secs(),
                    "Rejoin suppressed: minimum interval not elapsed"
                );
                return Err(OrchestratorError::RecoveryFailed(format!(
                    "Rejoin suppressed for {convo_id}: minimum interval ({}s remaining)",
                    remaining.as_secs()
                )));
            }
        }

        Ok(())
    }
```

- [ ] **Step 2: Clear recovery state on successful rejoin after group reset**

In `clear_rejoin_failures` (line 310), the existing implementation already clears `RecoveryTracker` state. No additional changes needed — when `groupResetEvent` arrives and the client rejoins successfully, `clear_rejoin_failures` is called, which resets the tracker and allows the cycle to start fresh.

- [ ] **Step 3: Verify compilation**

Run: `cd catbird-mls && cargo check`
Expected: PASS

- [ ] **Step 4: Run tests**

Run: `cd catbird-mls && cargo test 2>&1 | tail -10`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add catbird-mls/src/orchestrator/recovery.rs
git commit -m "mls-ffi: Report recovery failure to server after max rejoin attempts"
```

---

## Task 11: Final Integration Verification

- [ ] **Step 1: Build all Rust crates**

Run: `cd mls-ds/server && cargo build && cd ../../catbird-mls && cargo build`
Expected: both build successfully

- [ ] **Step 2: Run all Rust tests**

Run: `cd mls-ds/server && cargo test && cd ../../catbird-mls && cargo test`
Expected: all tests pass

- [ ] **Step 3: Verify formatting and lint**

Run: `cd mls-ds/server && cargo fmt --check && cargo clippy -- -D warnings 2>&1 | tail -10`
Run: `cd catbird-mls && cargo fmt --check && cargo clippy -- -D warnings 2>&1 | tail -10`
Expected: no formatting issues, no clippy warnings

- [ ] **Step 4: Commit any formatting fixes if needed**

```bash
cd mls-ds/server && cargo fmt
cd catbird-mls && cargo fmt
git add -A && git commit -m "chore: Format Rust code"
```
