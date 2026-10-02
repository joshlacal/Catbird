# MLS Recovery Hardening & Reaction Event Cleanup

## Overview

Two workstreams:
1. Remove deprecated plaintext `reactionEvent` from the server, lexicons, and clients
2. Implement server-side quorum-based auto-reset for MLS group recovery

## Workstream 1: Remove Deprecated `reactionEvent`

Reactions have migrated from plaintext server-side events to encrypted MLS application messages. The old plaintext path is deprecated and needs removal.

### Removals

**Server (mls-ds):**
- `handle_add_reaction()` and `handle_remove_reaction()` in `send_message.rs`
- Write paths to `message_reactions` table
- SSE emission of `reactionEvent` type
- `get_message_reactions()`, `add_reaction()`, `remove_reaction()` in `db.rs` (read function exists but is never called)
- Database migration to drop `message_reactions` table (no active read paths depend on it)

**Lexicon / Generated Code (Petrel):**
- `reactionEvent` variant from `BlueCatbirdMlsChatSubscribeEvents.Message` union
- `ReactionEvent` struct definition
- Source lexicon JSON that generates these types
- Regenerate: `cd Petrel && python Generator/main.py`

**Clients (Catbird, catmos):**
- Any `case .reactionEvent` handling in WebSocket event switches

### What Stays
- `MLSMessagePayload::reaction()` in catbird-mls (encrypted send path)
- `MLSReactionPayload` struct (encrypted reaction model)
- `send_reaction()` in the orchestrator (active encrypted path)

---

## Workstream 2: Quorum-Based Auto-Reset

### Problem

When an MLS group's cryptographic state is broken for most or all members, recovery stalls. External Commit (tier 1) fixes individual device desync but can't help when the group itself is corrupted. Full group reset (tier 2) is currently admin-only, but admins have no way to discover the problem — users must report it through a side channel.

### Design

#### Recovery Escalation Flow

```
Device can't decrypt
  → Retry External Commit (existing RecoveryTracker, exponential backoff)
  → Exhausted max_attempts?
    → Yes: Call reportRecoveryFailure endpoint
           Enter "waiting for reset" state
           Listen for groupResetEvent
    → No:  Keep retrying with backoff
```

#### New Server State: `recovery_failures` Table

```sql
CREATE TABLE recovery_failures (
    convo_id    TEXT NOT NULL,
    member_did  TEXT NOT NULL,
    reported_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    failure_type TEXT NOT NULL,  -- e.g., "external_commit_exhausted"
    PRIMARY KEY (convo_id, member_did)
);

CREATE INDEX idx_recovery_failures_convo ON recovery_failures(convo_id);
```

Each row: "this member has exhausted External Commit retries and can't rejoin." Upserted — one active failure per member per conversation. Cleared on reset or successful rejoin.

#### New Endpoint: `blue.catbird.mlsChat.reportRecoveryFailure`

**Input:** `convo_id`, `failure_type`

**Server logic:**
1. Validate caller is a member of the conversation
2. Upsert into `recovery_failures`
3. Count distinct `member_did` entries for this `convo_id` (excluding reports older than 1 hour)
4. Fetch total member count for the conversation
5. Evaluate auto-reset policy:

| Condition | Triggers reset? |
|---|---|
| 1:1 conversation, 1 member reports | Yes (50% threshold met) |
| Group, ≥50% of members report | Yes (majority consensus) |
| Group, <50% of members report | No (likely a local issue) |

6. If threshold met and no cooldown active → execute auto-reset
7. If threshold met but cooldown active → log, wait for cooldown expiry and re-evaluate

#### Auto-Reset Execution

Same logic as existing `resetGroup`, invoked internally:
- Swap `group_id` to new value
- Reset `current_epoch` to 0
- Clear `confirmation_tag`
- Delete `welcome_messages` and `pending_device_additions` for the conversation
- Increment `reset_count`
- Set `last_reset_by = "system:auto_recovery"`
- Set `last_reset_at = NOW()`
- Emit `groupResetEvent` via SSE
- Delete `recovery_failures` rows for the conversation

#### Client-Side Changes

**After exhausting `RecoveryTracker` max_attempts (`recovery.rs`):**
1. Call `reportRecoveryFailure` endpoint
2. Stop retrying External Commit
3. Enter "waiting for reset" state for this conversation
4. Continue listening on SSE stream

**On `groupResetEvent` received:**
1. Update local `group_id` to new value from event
2. Clear `RecoveryTracker` failure state for this conversation
3. Rejoin via External Commit using new `GroupInfo`
4. Insert `history_boundary` marker

**"Waiting for reset" behavior:**
- Conversation remains visible with full message history
- Cannot send or decrypt new messages (degraded)
- No retry loop — waiting for server-side reset
- Resumes normal operation when `groupResetEvent` arrives

No UI changes in this design. Degraded state is implicit (send fails, decrypt fails). A future pass could add a "This conversation is being repaired" banner.

#### Safety Guards

**Per-conversation cooldown:**
- Max 1 auto-reset per 30 minutes
- Failure reports during cooldown are still tracked; server re-evaluates when window expires

**Circuit breaker:**
- 3 auto-resets within 24 hours → disable auto-reset for that conversation
- Store `auto_reset_disabled_at TIMESTAMP` on `conversations` row
- Manual `resetGroup` endpoint still works; only automatic path blocked
- Prevents reset loops when the underlying issue isn't crypto state

**Failure report expiry:**
- Reports older than 1 hour are excluded from threshold evaluation
- Stale failures from offline members don't count toward quorum
- Lazy expiry on read (filter by `reported_at > NOW() - INTERVAL '1 hour'`)

**Audit trail:**
- `last_reset_by`: `"system:auto_recovery"` for auto-resets, member DID for manual
- `reset_count`: increments as before
- `recovery_failures` reports logged for debugging (who reported, when, failure type)

---

## Out of Scope

- Typing indicator changes (current model is fine: ephemeral, not stored, TLS-encrypted in transit)
- UI for degraded conversation state (future work)
- Removing the manual `resetGroup` admin endpoint (stays available as a fallback)
