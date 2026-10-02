# MLS E2EE Delivery Acks & Message Recovery — Design Spec

**Date:** 2026-04-06
**Status:** Approved
**Scope:** CatbirdMLSCore (Swift), catbird-mls (Rust/UniFFI), Android, Catbird iOS/macOS UI

---

## Problem Statement

The current MLS messaging stack has `isDelivered: Bool` on `MLSMessageModel`, but "delivered" means *server acknowledged the send* — not *recipient device successfully decrypted the message*. There is no cryptographic proof that a recipient's device received and decrypted a message, no per-member delivery tracking for group chats, and no recovery path when a device fails to decrypt a message.

This spec defines:
1. A delivery ack protocol proving decryption occurred
2. Per-member delivery state aggregation for 1:1 and group chats
3. A recipient-initiated plaintext recovery mechanism
4. UI display of Sent / Delivered / Read states
5. Cross-platform storage and behavior

---

## Scope Decisions

- Delivery acks work in **all conversations** (1:1 and group), with a configurable size cap for large groups
- Ack payload is **minimal** — `messageId` only; sender identity proven via MLS credential, not payload
- Acks are **always sent** by all clients — not opt-in. They are a transport-layer guarantee, not a social signal
- Read receipts remain **opt-in** per existing `PreferencesManager` setting
- **No server changes required** — acks are opaque ciphertext to mls-ds

---

## 1. Protocol Layer

### New Message Types

Two new cases added to `MLSMessageType` in `CatbirdMLSCore/Sources/CatbirdMLSCore/Models/MLSMessagePayload.swift`:

```swift
public enum MLSMessageType: String, Codable, Sendable {
    case text
    case reaction
    case readReceipt
    case typing
    case adminRoster
    case adminAction
    case system
    case deliveryAck           // NEW: proof of successful decryption
    case recoveryRequest       // NEW: request re-delivery of a missed message
}
```

### New Payload Structs

```swift
/// Emitted immediately after successful decryption of a message.
/// Sender DID is proven cryptographically via MLS credential — not included in payload.
public struct MLSDeliveryAckPayload: Codable, Sendable, Equatable {
    public let messageId: String
}

/// Emitted by a recipient device that failed to decrypt or missed a message.
/// Distinct from group recovery (epoch/tree divergence recovery).
public struct MLSMessageRecoveryRequestPayload: Codable, Sendable, Equatable {
    public let messageId: String
    public let epoch: Int64
    public let sequenceNumber: Int64
}
```

### Recovery Response Encoding

When a group member responds to a recovery request, they re-send the original plaintext as a `text` message (or matching original type) with an additional `recoveredMessageId` field in the payload:

```swift
// Added to MLSMessagePayload alongside existing optional fields:
public let recoveredMessageId: String?  // non-nil only on recovery responses
```

On receipt, if `recoveredMessageId` is non-nil, the receiver:
1. Stores the message normally (new `messageId`, same content)
2. Marks the original `recoveredMessageId` in `MLSMessageModel` as `processingState = "recovered"`
3. Emits a `deliveryAck` for the **new** `messageId` (the recovered copy)

This allows the sender to see delivery confirmed for the recovered message, and the UI deduplicates the original (failed) slot against the recovered message by `recoveredMessageId`.

Both types are added to `MLSMessagePayload` with corresponding factory methods:

```swift
public static func deliveryAck(messageId: String) -> MLSMessagePayload
public static func recoveryRequest(messageId: String, epoch: Int64, sequenceNumber: Int64) -> MLSMessagePayload
```

### Message Persistence

Both types are **non-ephemeral** — they are stored in mls-ds persistent message storage and assigned sequence numbers. This ensures a device syncing after going offline can reconstruct full delivery state by replaying the message stream. They are filtered from the UI message list in the same way typing indicators and read receipts are filtered today.

---

## 2. Storage Layer

### New GRDB Table: `MLSDeliveryAckModel`

Added to `CatbirdMLSCore`, following existing GRDB patterns:

```swift
public struct MLSDeliveryAckModel: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "MLSDeliveryAck"

    public let messageId: String        // Server-assigned messageId being acked
    public let conversationId: String
    public let senderDID: String        // Extracted from MLS credential after decryption
    public let ackedAt: Date
    public let currentUserDID: String   // Per-user DB partition key

    public static let persistenceConflictPolicy =
        PersistenceConflictPolicy(insert: .replace, update: .replace)
}
```

**Schema:**
```sql
CREATE TABLE MLSDeliveryAck (
    messageId       TEXT NOT NULL,
    conversationId  TEXT NOT NULL,
    senderDID       TEXT NOT NULL,
    ackedAt         REAL NOT NULL,
    currentUserDID  TEXT NOT NULL,
    PRIMARY KEY (messageId, senderDID, currentUserDID)
);
CREATE INDEX idx_delivery_ack_conversation ON MLSDeliveryAck(conversationId, currentUserDID);
```

The `REPLACE` conflict policy makes ack insertion idempotent — duplicate acks from retries are no-ops.

### Existing `MLSMessageModel` Fields

`isDelivered: Bool` on `MLSMessageModel` retains its existing meaning but gains a clearer semantic: it becomes `true` when **at least one** non-sender member has an entry in `MLSDeliveryAckModel` for that `messageId`. No schema change required — this is derived at query time.

### Cross-Platform Storage

| Platform | Stack | Storage |
|---|---|---|
| iOS / macOS Catalyst | CatbirdMLSCore (Swift + GRDB) | `MLSDeliveryAckModel` GRDB table |
| Catmos desktop | catbird-mls (Rust + SQLCipher) | `delivery_acks` table in Rust-managed DB, UniFFI-exposed |
| Android | Kotlin + Room | `DeliveryAckEntity` Room table |

The mls-ds server requires **no changes**. Acks are opaque ciphertext.

---

## 3. Send/Receive Flow

### Ack Emission (Recipient Side)

After successful decryption, a delivery ack is enqueued immediately:

```
SSE delivers MessageEvent (ciphertext)
  ↓
MLSConversationManager.decryptMessageWithSender()
  ↓ success → plaintext + senderDID extracted
Store plaintext to MLSMessageModel  ← persisted BEFORE ack send
  ↓
Enqueue deliveryAck via sendQueueCoordinator:
  MLSMessagePayload.deliveryAck(messageId: serverMessageId)
  → encrypted MLS app message
  → apiClient.sendMessage()
```

The ack is enqueued *after* plaintext is persisted. If the app crashes between decrypt and ack-send, plaintext is safe and the ack is simply not sent. The sender will see "not yet delivered" and the recipient can recover via the recovery path.

**Deduplication:** Do not re-send an ack if `MLSDeliveryAckModel` already contains a row for `(messageId, currentUserDID)` with `senderDID == currentUserDID`. This prevents duplicate acks on restart.

### Ack Reception (Sender Side)

```
SSE delivers ack ciphertext
  ↓
decryptMessageWithSender() → MLSDeliveryAckPayload
  ↓
MLSDeliveryAckModel.upsert(messageId, senderDID, ackedAt)
  ↓
NotificationCenter.post("MLSDeliveryAckReceived", userInfo: [convoId, messageId])
  ↓
MLSConversationDetailViewModel refreshes delivery state for visible messages
```

### Recovery Request Flow (Recipient-Initiated)

```
Decryption fails (epoch mismatch, gap, or buffer timeout exhausted)
  ↓
MLSMessageRecoveryRequestPayload(messageId, epoch, seq) sent to group
  ↓
All group members with matching plaintext in local SQLCipher storage:
  1. Apply random jitter: 500–2000ms
  2. Check if another member already responded (monitor SSE for re-sent message)
  3. If no response seen: re-encrypt original plaintext from SQLCipher → new MLS app message
     (same content, new server messageId, `recoveredMessageId` field set to the original messageId)
  ↓
Recipient decrypts recovered message, stores it
  ↓
Recipient emits deliveryAck for the recovered message's new messageId
```

**Jitter rationale:** Multiple devices may hold the plaintext. Random jitter (500–2000ms) before responding prevents simultaneous duplicate resends. The first responder wins; others abort when they observe the recovered message arrive on SSE.

**Forward secrecy:** Re-sent messages are encrypted under the *current* MLS epoch keys. Old epoch keys are never re-used. Forward secrecy is preserved.

---

## 4. Delivery State Computation

### State Enum

```swift
public enum MessageDeliveryState: Equatable {
    case sending                                          // isSent == false
    case sent                                             // server confirmed, no acks
    case deliveredPartial(count: Int, total: Int)         // some members acked
    case deliveredAll                                     // all non-sender members acked
    case read                                             // at least one read receipt received
}
```

### Derivation Function

```swift
func deliveryState(
    for message: MLSMessageModel,
    acks: [MLSDeliveryAckModel],
    readReceipts: [MLSReadReceiptModel],
    memberCount: Int,
    readReceiptsEnabled: Bool
) -> MessageDeliveryState {
    guard message.isSent else { return .sending }
    let ackedDIDs = Set(acks.map(\.senderDID))
    let expected = memberCount - 1   // exclude sender
    if readReceiptsEnabled && !readReceipts.isEmpty { return .read }
    if ackedDIDs.isEmpty { return .sent }
    if ackedDIDs.count < expected {
        return .deliveredPartial(count: ackedDIDs.count, total: expected)
    }
    return .deliveredAll
}
```

### Performance

A single GRDB batch query fetches all acks for a conversation's visible messages — not per-message queries. Computed in `MLSConversationDetailViewModel`, not inline in SwiftUI views.

---

## 5. UI Display

Delivery state is shown **only on outgoing messages** for the sender's own device. Other group members see no delivery indicators under that bubble.

| State | Visual |
|---|---|
| Sending | Single gray clock icon (existing) |
| Sent | Single gray checkmark |
| Delivered (partial) | Double gray checkmark + count, e.g. "✓✓ 2/4" |
| Delivered (all) | Double checkmark, accent color |
| Read | Double checkmark, blue (existing read receipt color) |

---

## 6. Large Group Mitigation

A group with N members generates N-1 ack messages per text sent. For large groups this creates amplification:

- **Group size cap:** Delivery acks are disabled (state caps at `.sent`) for groups above a configurable member threshold. Default: 20 members. Above this threshold the UI shows "Sent" only.
- **Configuration:** The threshold is a server-synced flag in `PreferencesManager` so it can be tuned without an app update.
- **Deduplication window:** Acks already have idempotent storage (`REPLACE` conflict policy), preventing duplicate writes from network retries.

---

## 7. Privacy Implications

**Server visibility:** None beyond existing metadata (sender DID, timestamp, ciphertext size). Acks are indistinguishable from regular app messages to mls-ds.

**Group member visibility:** All group members can decrypt all acks. Members learn which peers have (and haven't) acked a given message and rough decryption timing. This is a deliberate tradeoff consistent with how Signal and WhatsApp handle group delivery receipts.

**Recovery request visibility:** A recovery request reveals to all group members that a specific device failed to decrypt a specific message. Acceptable — the alternative (silent message loss) is worse.

**Delivery acks vs. read receipts:** Delivery acks are always sent — they are a protocol-level transport guarantee, not a user preference. Read receipts remain opt-in. Settings copy should make this distinction explicit:
> *"Delivery confirmations let others know your device received their message. These are always sent. Read receipts (letting others know you've opened a message) can be turned off below."*

---

## 8. Out of Scope

- Changes to mls-ds server
- Ack aggregation UI showing *which specific members* acked (per-member name list) — the count badge (`2/4`) is sufficient for V1
- Delivery acks for Bluesky DM (non-MLS) conversations
- Group-level recovery (epoch/tree divergence) — this is a separate system being implemented in parallel; `MLSMessageRecoveryRequestPayload` name chosen to avoid collision with that work
