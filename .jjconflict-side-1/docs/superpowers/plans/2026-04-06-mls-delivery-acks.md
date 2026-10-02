# MLS Delivery Acks & Message Recovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add E2EE delivery acks proving recipient decryption, per-member delivery state aggregation, recipient-initiated message recovery, and "Sent/Delivered/Read" UI indicators.

**Architecture:** Two new `MLSMessageType` cases (`.deliveryAck`, `.recoveryRequest`) travel as encrypted MLS app messages through the existing SSE pipeline. A new `MLSDeliveryAckModel` GRDB table stores per-member ack state. `MessageDeliveryState` drives badge rendering on outgoing message bubbles. Acks are emitted by the recipient immediately after successful decryption; recovery requests are emitted after buffer timeouts exhaust.

**Tech Stack:** Swift 6, GRDB (SQLCipher), async/await, actors, XCTestCase (CatbirdMLSCore), Swift Testing `@Test` (Catbird iOS), SwiftUI

---

## File Map

### CatbirdMLSCore — New files
| File | Responsibility |
|---|---|
| `CatbirdMLSCore/Sources/CatbirdMLSCore/Models/MLSDeliveryAckModel.swift` | GRDB record: per-member delivery ack rows |
| `CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+DeliveryAcks.swift` | `sendDeliveryAck`, `handleReceivedDeliveryAck`, `sendRecoveryRequest`, `handleRecoveryRequest` |
| `CatbirdMLSCore/Tests/CatbirdMLSCoreTests/MLSDeliveryAckModelTests.swift` | GRDB model insert/fetch/upsert unit tests |

### CatbirdMLSCore — Modified files
| File | Change |
|---|---|
| `CatbirdMLSCore/Sources/CatbirdMLSCore/Models/MLSMessagePayload.swift` | Add `.deliveryAck`, `.recoveryRequest` enum cases; `MLSDeliveryAckPayload`, `MLSMessageRecoveryRequestPayload` structs; `deliveryAck`, `recoveryRequest`, `recoveredMessageId` fields + init params; factory methods |
| `CatbirdMLSCore/Sources/CatbirdMLSCore/Storage/MLSGRDBManager.swift` | Add `v7_delivery_acks` migration |
| `CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+Messaging.swift` | Handle `.deliveryAck` and `.recoveryRequest` in the `messageType` switch; call `enqueueDeliveryAck` after decryption |
| `CatbirdMLSCore/Sources/CatbirdMLSCore/Service/Models/DecryptedMLSMessage.swift` | Add `.deliveryAck`, `.recoveryRequest` to exhaustive `isControlMessage` switch |

### Catbird iOS — New files
| File | Responsibility |
|---|---|
| `Catbird/Catbird/Features/MLSChat/Models/MessageDeliveryState.swift` | `MessageDeliveryState` enum + `deliveryState()` pure function |
| `Catbird/CatbirdTests/Features/MLSChat/MessageDeliveryStateTests.swift` | State derivation unit tests (Swift Testing) |

### Catbird iOS — Modified files
| File | Change |
|---|---|
| `Catbird/Catbird/Features/MLSChat/ViewModels/MLSConversationDetailViewModel.swift` | Batch ack fetch; per-message `deliveryState`; `MLSDeliveryAckReceived` notification handler |
| `Catbird/Catbird/Features/MLSChat/Views/MLSMessageRowView.swift` | Render delivery badge on outgoing messages |

---

## Task 1: Protocol types in MLSMessagePayload

**Files:**
- Modify: `CatbirdMLSCore/Sources/CatbirdMLSCore/Models/MLSMessagePayload.swift`
- Modify: `CatbirdMLSCore/Sources/CatbirdMLSCore/Service/Models/DecryptedMLSMessage.swift`

- [ ] **Step 1: Add new MLSMessageType cases**

In `MLSMessagePayload.swift`, find the `MLSMessageType` enum and add two cases:

```swift
public enum MLSMessageType: String, Codable, Sendable {
  case text
  case reaction
  case readReceipt
  case typing
  case adminRoster
  case adminAction
  case system
  case deliveryAck       // proof of successful decryption
  case recoveryRequest   // request re-delivery of a missed message
}
```

- [ ] **Step 2: Add payload structs**

Directly below the existing `MLSReadReceiptPayload` struct in `MLSMessagePayload.swift`, add:

```swift
/// Emitted immediately after a device successfully decrypts a message.
/// Sender DID is proven via MLS credential — not included in payload.
public struct MLSDeliveryAckPayload: Codable, Sendable, Equatable {
  public let messageId: String

  public init(messageId: String) {
    self.messageId = messageId
  }
}

/// Emitted by a recipient device that failed to decrypt or missed a message.
/// Distinct from MLS group recovery (epoch/tree divergence).
public struct MLSMessageRecoveryRequestPayload: Codable, Sendable, Equatable {
  public let messageId: String
  public let epoch: Int64
  public let sequenceNumber: Int64

  public init(messageId: String, epoch: Int64, sequenceNumber: Int64) {
    self.messageId = messageId
    self.epoch = epoch
    self.sequenceNumber = sequenceNumber
  }
}
```

- [ ] **Step 3: Add fields to MLSMessagePayload struct**

In `MLSMessagePayload.swift`, add three new optional fields after `adminAction`:

```swift
/// Delivery ack payload (for messageType: deliveryAck)
public let deliveryAck: MLSDeliveryAckPayload?

/// Message recovery request payload (for messageType: recoveryRequest)
public let recoveryRequest: MLSMessageRecoveryRequestPayload?

/// Set on a re-sent message to identify which original message this recovers.
/// Nil on normal messages.
public let recoveredMessageId: String?
```

Update the init to include them with `nil` defaults:

```swift
public init(
  version: Int = 1,
  messageType: MLSMessageType,
  text: String? = nil,
  embed: MLSEmbedData? = nil,
  reaction: MLSReactionPayload? = nil,
  readReceipt: MLSReadReceiptPayload? = nil,
  typing: MLSTypingPayload? = nil,
  adminRoster: MLSAdminRosterPayload? = nil,
  adminAction: MLSAdminActionPayload? = nil,
  deliveryAck: MLSDeliveryAckPayload? = nil,
  recoveryRequest: MLSMessageRecoveryRequestPayload? = nil,
  recoveredMessageId: String? = nil
) {
  self.version = version
  self.messageType = messageType
  self.text = text
  self.embed = embed
  self.reaction = reaction
  self.readReceipt = readReceipt
  self.typing = typing
  self.adminRoster = adminRoster
  self.adminAction = adminAction
  self.deliveryAck = deliveryAck
  self.recoveryRequest = recoveryRequest
  self.recoveredMessageId = recoveredMessageId
}
```

- [ ] **Step 4: Add factory methods**

Add after the existing `adminAction` factory method in `MLSMessagePayload.swift`:

```swift
/// Create a delivery ack payload (sent after successful decryption)
public static func deliveryAck(messageId: String) -> MLSMessagePayload {
  MLSMessagePayload(
    messageType: .deliveryAck,
    deliveryAck: MLSDeliveryAckPayload(messageId: messageId)
  )
}

/// Create a message recovery request (sent when decryption fails after retries)
public static func recoveryRequest(
  messageId: String,
  epoch: Int64,
  sequenceNumber: Int64
) -> MLSMessagePayload {
  MLSMessagePayload(
    messageType: .recoveryRequest,
    recoveryRequest: MLSMessageRecoveryRequestPayload(
      messageId: messageId,
      epoch: epoch,
      sequenceNumber: sequenceNumber
    )
  )
}
```

- [ ] **Step 5: Fix exhaustive switch in DecryptedMLSMessage.swift**

In `DecryptedMLSMessage.swift`, find the `isControlMessage` computed property and add the two new cases so it compiles:

```swift
var isControlMessage: Bool {
  switch payload.messageType {
  case .reaction:
    return true
  case .text, .readReceipt, .typing, .adminRoster, .adminAction, .system,
       .deliveryAck, .recoveryRequest:
    return false
  }
}
```

- [ ] **Step 6: Build to verify it compiles**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/CatbirdMLSCore
swift build 2>&1 | tail -20
```

Expected: `Build complete!` with no errors.

- [ ] **Step 7: Commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
git add CatbirdMLSCore/Sources/CatbirdMLSCore/Models/MLSMessagePayload.swift \
        CatbirdMLSCore/Sources/CatbirdMLSCore/Service/Models/DecryptedMLSMessage.swift
git commit -m "CatbirdMLSCore: Add deliveryAck and recoveryRequest MLS message types"
```

---

## Task 2: MLSDeliveryAckModel GRDB record

**Files:**
- Create: `CatbirdMLSCore/Sources/CatbirdMLSCore/Models/MLSDeliveryAckModel.swift`
- Create: `CatbirdMLSCore/Tests/CatbirdMLSCoreTests/MLSDeliveryAckModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `CatbirdMLSCore/Tests/CatbirdMLSCoreTests/MLSDeliveryAckModelTests.swift`:

```swift
import XCTest
import GRDB
@testable import CatbirdMLSCore

final class MLSDeliveryAckModelTests: XCTestCase {

  private var db: DatabaseQueue!

  override func setUp() async throws {
    db = try DatabaseQueue()
    try await db.write { db in
      try db.create(table: "MLSDeliveryAck") { t in
        t.column("messageId", .text).notNull()
        t.column("conversationId", .text).notNull()
        t.column("senderDID", .text).notNull()
        t.column("ackedAt", .datetime).notNull()
        t.column("currentUserDID", .text).notNull()
        t.primaryKey(["messageId", "senderDID", "currentUserDID"])
      }
    }
  }

  func testInsertAndFetch() async throws {
    let ack = MLSDeliveryAckModel(
      messageId: "msg-1",
      conversationId: "convo-1",
      senderDID: "did:plc:alice",
      ackedAt: Date(timeIntervalSince1970: 1000),
      currentUserDID: "did:plc:bob"
    )
    try await db.write { db in try ack.insert(db) }

    let fetched = try await db.read { db in
      try MLSDeliveryAckModel.fetchAll(db)
    }
    XCTAssertEqual(fetched.count, 1)
    XCTAssertEqual(fetched[0].messageId, "msg-1")
    XCTAssertEqual(fetched[0].senderDID, "did:plc:alice")
  }

  func testUpsertIsIdempotent() async throws {
    let ack = MLSDeliveryAckModel(
      messageId: "msg-1",
      conversationId: "convo-1",
      senderDID: "did:plc:alice",
      ackedAt: Date(timeIntervalSince1970: 1000),
      currentUserDID: "did:plc:bob"
    )
    try await db.write { db in try ack.save(db) }
    try await db.write { db in try ack.save(db) }  // second upsert — no error

    let count = try await db.read { db in try MLSDeliveryAckModel.fetchCount(db) }
    XCTAssertEqual(count, 1)
  }

  func testMultipleSendersForSameMessage() async throws {
    let ack1 = MLSDeliveryAckModel(messageId: "msg-1", conversationId: "c", senderDID: "did:plc:alice", ackedAt: Date(), currentUserDID: "did:plc:bob")
    let ack2 = MLSDeliveryAckModel(messageId: "msg-1", conversationId: "c", senderDID: "did:plc:carol", ackedAt: Date(), currentUserDID: "did:plc:bob")
    try await db.write { db in
      try ack1.insert(db)
      try ack2.insert(db)
    }
    let acks = try await db.read { db in
      try MLSDeliveryAckModel
        .filter(Column("messageId") == "msg-1")
        .fetchAll(db)
    }
    XCTAssertEqual(acks.count, 2)
  }
}
```

- [ ] **Step 2: Run test — expect failure**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/CatbirdMLSCore
swift test --filter MLSDeliveryAckModelTests 2>&1 | tail -20
```

Expected: compile error — `MLSDeliveryAckModel` does not exist.

- [ ] **Step 3: Create MLSDeliveryAckModel.swift**

Create `CatbirdMLSCore/Sources/CatbirdMLSCore/Models/MLSDeliveryAckModel.swift`:

```swift
//
//  MLSDeliveryAckModel.swift
//  CatbirdMLSCore
//
//  GRDB record storing per-member delivery acks for MLS messages.
//  One row per (messageId, senderDID, currentUserDID) — the composite primary key
//  makes upserts idempotent: duplicate acks from retries are silent no-ops.
//

import Foundation
import GRDB

public struct MLSDeliveryAckModel: Codable, FetchableRecord, PersistableRecord, Sendable {
  public static let databaseTableName = "MLSDeliveryAck"

  /// Conflict policy: duplicate (messageId, senderDID, currentUserDID) silently replaces.
  public static let persistenceConflictPolicy = PersistenceConflictPolicy(
    insert: .replace,
    update: .replace
  )

  /// Server-assigned messageId that was acked.
  public let messageId: String

  /// Conversation this ack belongs to.
  public let conversationId: String

  /// DID of the member who sent this ack (extracted from MLS credential).
  public let senderDID: String

  /// When the ack message was decrypted locally.
  public let ackedAt: Date

  /// Per-user DB partition key — matches the DB file owner.
  public let currentUserDID: String

  public init(
    messageId: String,
    conversationId: String,
    senderDID: String,
    ackedAt: Date,
    currentUserDID: String
  ) {
    self.messageId = messageId
    self.conversationId = conversationId
    self.senderDID = senderDID
    self.ackedAt = ackedAt
    self.currentUserDID = currentUserDID
  }
}
```

- [ ] **Step 4: Run test — expect pass**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/CatbirdMLSCore
swift test --filter MLSDeliveryAckModelTests 2>&1 | tail -20
```

Expected: `Test Suite 'MLSDeliveryAckModelTests' passed`

- [ ] **Step 5: Commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
git add CatbirdMLSCore/Sources/CatbirdMLSCore/Models/MLSDeliveryAckModel.swift \
        CatbirdMLSCore/Tests/CatbirdMLSCoreTests/MLSDeliveryAckModelTests.swift
git commit -m "CatbirdMLSCore: Add MLSDeliveryAckModel GRDB record"
```

---

## Task 3: Database migration

**Files:**
- Modify: `CatbirdMLSCore/Sources/CatbirdMLSCore/Storage/MLSGRDBManager.swift`

- [ ] **Step 1: Find the migration registration site**

Open `MLSGRDBManager.swift` and find `runMigrations`. The existing migrations end with `v6_membership_history`. Add immediately after the closing brace of that migration:

- [ ] **Step 2: Add v7 migration**

```swift
// MARK: v7 - Delivery acks
migrator.registerMigration("v7_delivery_acks") { db in
  try db.create(table: "MLSDeliveryAck", ifNotExists: true) { t in
    t.column("messageId", .text).notNull()
    t.column("conversationId", .text).notNull()
    t.column("senderDID", .text).notNull()
    t.column("ackedAt", .datetime).notNull()
    t.column("currentUserDID", .text).notNull()
    t.primaryKey(["messageId", "senderDID", "currentUserDID"])
  }
  try db.execute(sql: """
    CREATE INDEX IF NOT EXISTS idx_delivery_ack_conversation
    ON MLSDeliveryAck(conversationId, currentUserDID)
  """)
}
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/CatbirdMLSCore
swift build 2>&1 | tail -10
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
git add CatbirdMLSCore/Sources/CatbirdMLSCore/Storage/MLSGRDBManager.swift
git commit -m "CatbirdMLSCore: Add v7 migration for MLSDeliveryAck table"
```

---

## Task 4: Send delivery ack after decryption

**Files:**
- Create: `CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+DeliveryAcks.swift`
- Modify: `CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+Messaging.swift`

- [ ] **Step 1: Create the DeliveryAcks extension file**

Create `CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+DeliveryAcks.swift`:

```swift
//
//  MLSConversationManager+DeliveryAcks.swift
//  CatbirdMLSCore
//
//  Delivery ack send/receive and message recovery request logic.
//

import Foundation
import GRDB
import OSLog

extension MLSConversationManager {

  // MARK: - Send

  /// Enqueues an encrypted delivery ack for a message that was successfully decrypted.
  ///
  /// Called immediately after `decryptMessageWithSender` succeeds for a non-self message.
  /// Skips silently if this device has already acked this message (idempotent).
  ///
  /// - Parameters:
  ///   - messageId: The server-assigned messageId that was just decrypted.
  ///   - conversationId: The conversation the message belongs to.
  func enqueueDeliveryAck(messageId: String, conversationId: String) {
    guard let userDid else { return }

    Task { [weak self] in
      guard let self else { return }

      // Deduplication: skip if we already acked this message from this device.
      let alreadyAcked = (try? await self.database?.read { db in
        try MLSDeliveryAckModel
          .filter(
            Column("messageId") == messageId &&
            Column("senderDID") == userDid &&
            Column("currentUserDID") == userDid
          )
          .fetchOne(db)
      }) != nil
      guard !alreadyAcked else { return }

      try? await self.sendDeliveryAck(messageId: messageId, conversationId: conversationId)
    }
  }

  /// Sends an encrypted `deliveryAck` MLS application message.
  /// Follows the same pre-cache-before-send pattern as `sendEncryptedReaction`.
  private func sendDeliveryAck(messageId: String, conversationId: String) async throws {
    try throwIfShuttingDown("sendDeliveryAck")

    guard let userDid, let convo = conversations[conversationId] else { return }
    guard let groupIdData = Data(hexEncoded: convo.groupId) else { return }

    _ = try await sendQueueCoordinator.enqueueSend(conversationID: conversationId) { [self] in
      try throwIfShuttingDown("sendDeliveryAck-queued")

      let payload = MLSMessagePayload.deliveryAck(messageId: messageId)
      let payloadData = try payload.encodeToJSON()

      let result = try await groupOperationCoordinator.withExclusiveLock(groupId: convo.groupId) { [self] in
        let localEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
        let tagData = try? await mlsClient.getConfirmationTag(for: userDid, groupId: groupIdData)
        let tagB64 = tagData?.base64EncodedString()
        let ciphertext = try await encryptMessageImpl(groupId: convo.groupId, plaintext: payloadData)
        let paddedSize = ciphertext.count
        let localMsgId = UUID().uuidString

        let optimisticSeq: Int
        if let cursor = try? await storage.fetchLastMessageCursor(
          conversationID: conversationId,
          currentUserDID: userDid,
          database: database
        ) {
          optimisticSeq = Int(cursor.seq) + 1
        } else {
          optimisticSeq = 1
        }

        // Pre-cache BEFORE network send to avoid CannotDecryptOwnMessage race.
        try await cacheControlMessageEnvelope(
          message: BlueCatbirdMlsChatDefs.MessageView(
            id: localMsgId,
            convoId: conversationId,
            ciphertext: Bytes(data: ciphertext),
            epoch: Int(localEpoch),
            seq: optimisticSeq,
            createdAt: ATProtocolDate(date: Date()),
            messageType: "deliveryAck"
          ),
          payload: payload,
          senderDID: userDid,
          currentUserDID: userDid
        )

        let sendResult = try await apiClient.sendMessage(
          convoId: conversationId,
          msgId: localMsgId,
          ciphertext: ciphertext,
          epoch: Int(localEpoch),
          paddedSize: paddedSize,
          senderDid: try DID(didString: userDid),
          confirmationTag: tagB64
        )
        return (localMsgId, sendResult)
      }

      let (localMsgId, sendResult) = result
      try? await storage.updateMessageMetadata(
        messageID: localMsgId,
        currentUserDID: userDid,
        epoch: sendResult.epoch,
        sequenceNumber: sendResult.sequenceNumber,
        timestamp: sendResult.receivedAt.date,
        database: database,
        newMessageID: sendResult.messageId
      )
    }
  }

  // MARK: - Receive

  /// Stores a received delivery ack and notifies the UI.
  /// Called from the `.deliveryAck` case in the message processing switch.
  func handleReceivedDeliveryAck(
    payload: MLSDeliveryAckPayload,
    senderDID: String,
    conversationId: String
  ) async {
    guard let userDid else { return }

    let ack = MLSDeliveryAckModel(
      messageId: payload.messageId,
      conversationId: conversationId,
      senderDID: senderDID,
      ackedAt: Date(),
      currentUserDID: userDid
    )

    try? await database?.write { db in try ack.save(db) }

    await MainActor.run {
      NotificationCenter.default.post(
        name: Notification.Name("MLSDeliveryAckReceived"),
        object: nil,
        userInfo: [
          "messageId": payload.messageId,
          "conversationId": conversationId,
          "senderDID": senderDID,
        ]
      )
    }
  }
}
```

- [ ] **Step 2: Hook ack emission into the decryption success path**

In `MLSConversationManager+Messaging.swift`, find the section after `persistProcessedPayload` is called for a `.text` message (the successful decryption path for normal messages). The pattern to find is where `senderDID != userDid` and the message is persisted as a received text. Add the ack enqueue call immediately after persisting:

Search for the `.text` case in the large `switch cachedPayload.messageType` block around line 1920. Add after the persist call for received text messages:

```swift
case .text:
  // ... existing text processing code ...

  // After persisting the decrypted text message, enqueue a delivery ack.
  // Only ack messages from other users (not echoes of our own sends).
  if senderDID != userDid {
    enqueueDeliveryAck(messageId: message.id, conversationId: message.convoId)
  }
```

- [ ] **Step 3: Add .deliveryAck and .recoveryRequest cases to the processing switch**

In the same switch statement, add two new cases after the `.system` case:

```swift
case .deliveryAck:
  guard let ackPayload = payload.deliveryAck else { break }
  _ = try await persistProcessedPayload(
    message: message,
    payload: payload,
    senderID: senderDID,
    processingError: nil,
    validationReason: nil,
    context: context
  )
  await handleReceivedDeliveryAck(
    payload: ackPayload,
    senderDID: senderDID,
    conversationId: message.convoId
  )

case .recoveryRequest:
  guard let recoveryPayload = payload.recoveryRequest else { break }
  _ = try await persistProcessedPayload(
    message: message,
    payload: payload,
    senderID: senderDID,
    processingError: nil,
    validationReason: nil,
    context: context
  )
  await handleRecoveryRequest(
    payload: recoveryPayload,
    requesterDID: senderDID,
    conversationId: message.convoId
  )
```

- [ ] **Step 4: Build**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/CatbirdMLSCore
swift build 2>&1 | tail -15
```

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
git add CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+DeliveryAcks.swift \
        CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+Messaging.swift
git commit -m "CatbirdMLSCore: Send and store delivery acks after successful decryption"
```

---

## Task 5: Message recovery request

**Files:**
- Modify: `CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+DeliveryAcks.swift`

This adds two methods: `sendRecoveryRequest` (called when buffer timeout exhausts) and `handleRecoveryRequest` (called when we receive another device's request).

- [ ] **Step 1: Add sendRecoveryRequest to the extension**

Append to `MLSConversationManager+DeliveryAcks.swift` inside the extension:

```swift
// MARK: - Recovery Request

/// Sends an encrypted recovery request for a message this device failed to decrypt.
/// Called by the message ordering coordinator after its buffer timeout exhausts.
///
/// - Parameters:
///   - messageId: The server-assigned messageId that could not be decrypted.
///   - epoch: The epoch the missing message belongs to.
///   - sequenceNumber: The sequence number of the missing message.
///   - conversationId: The conversation the message belongs to.
func sendRecoveryRequest(
  messageId: String,
  epoch: Int64,
  sequenceNumber: Int64,
  conversationId: String
) async {
  guard let userDid, let convo = conversations[conversationId] else { return }
  guard let groupIdData = Data(hexEncoded: convo.groupId) else { return }

  _ = try? await sendQueueCoordinator.enqueueSend(conversationID: conversationId) { [self] in
    try throwIfShuttingDown("sendRecoveryRequest-queued")

    let payload = MLSMessagePayload.recoveryRequest(
      messageId: messageId,
      epoch: epoch,
      sequenceNumber: sequenceNumber
    )
    let payloadData = try payload.encodeToJSON()

    let result = try await groupOperationCoordinator.withExclusiveLock(groupId: convo.groupId) { [self] in
      let localEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
      let tagData = try? await mlsClient.getConfirmationTag(for: userDid, groupId: groupIdData)
      let tagB64 = tagData?.base64EncodedString()
      let ciphertext = try await encryptMessageImpl(groupId: convo.groupId, plaintext: payloadData)
      let paddedSize = ciphertext.count
      let localMsgId = UUID().uuidString

      let optimisticSeq: Int
      if let cursor = try? await storage.fetchLastMessageCursor(
        conversationID: conversationId,
        currentUserDID: userDid,
        database: database
      ) {
        optimisticSeq = Int(cursor.seq) + 1
      } else {
        optimisticSeq = 1
      }

      try await cacheControlMessageEnvelope(
        message: BlueCatbirdMlsChatDefs.MessageView(
          id: localMsgId,
          convoId: conversationId,
          ciphertext: Bytes(data: ciphertext),
          epoch: Int(localEpoch),
          seq: optimisticSeq,
          createdAt: ATProtocolDate(date: Date()),
          messageType: "recoveryRequest"
        ),
        payload: payload,
        senderDID: userDid,
        currentUserDID: userDid
      )

      let sendResult = try await apiClient.sendMessage(
        convoId: conversationId,
        msgId: localMsgId,
        ciphertext: ciphertext,
        epoch: Int(localEpoch),
        paddedSize: paddedSize,
        senderDid: try DID(didString: userDid),
        confirmationTag: tagB64
      )
      return (localMsgId, sendResult)
    }

    let (localMsgId, sendResult) = result
    try? await storage.updateMessageMetadata(
      messageID: localMsgId,
      currentUserDID: userDid,
      epoch: sendResult.epoch,
      sequenceNumber: sendResult.sequenceNumber,
      timestamp: sendResult.receivedAt.date,
      database: database,
      newMessageID: sendResult.messageId
    )
  }
}

/// Handles an incoming recovery request from another group member.
///
/// If this device holds the requested plaintext in SQLCipher, it re-sends
/// the original content after a random jitter window (to avoid duplicate responses).
///
/// - Parameters:
///   - payload: The recovery request describing which message is needed.
///   - requesterDID: The DID of the member who sent the request.
///   - conversationId: The conversation ID.
func handleRecoveryRequest(
  payload: MLSMessageRecoveryRequestPayload,
  requesterDID: String,
  conversationId: String
) async {
  guard let userDid else { return }
  // Don't respond to our own requests
  guard requesterDID != userDid else { return }

  // Check if we have the plaintext
  guard let storedMessage = try? await database?.read({ db in
    try MLSMessageModel
      .filter(
        Column("messageID") == payload.messageId &&
        Column("currentUserDID") == userDid
      )
      .fetchOne(db)
  }),
  let payloadJSON = storedMessage.payloadJSON,
  let originalPayload = try? JSONDecoder().decode(MLSMessagePayload.self, from: payloadJSON)
  else { return }

  // Jitter: 500–2000ms random delay before responding.
  // First responder wins; others see the recovered message arrive and skip.
  let jitterMs = Int.random(in: 500...2000)
  try? await Task.sleep(for: .milliseconds(jitterMs))

  // Check if the message has already been recovered (another device responded first).
  // A recovery response will have `recoveredMessageId` set to our payload.messageId.
  let alreadyRecovered = (try? await database?.read({ db in
    try MLSMessageModel
      .filter(
        sql: "payloadJSON LIKE ?",
        arguments: ["%\(payload.messageId)%"]  // quick check; full validation happens on receipt
      )
      .filter(Column("conversationID") == conversationId)
      .fetchOne(db)
  })) != nil
  guard !alreadyRecovered else { return }

  // Re-send the original content with recoveredMessageId set.
  guard let convo = conversations[conversationId],
        let groupIdData = Data(hexEncoded: convo.groupId)
  else { return }

  _ = try? await sendQueueCoordinator.enqueueSend(conversationID: conversationId) { [self] in
    let recoveryPayload = MLSMessagePayload(
      messageType: originalPayload.messageType,
      text: originalPayload.text,
      embed: originalPayload.embed,
      recoveredMessageId: payload.messageId
    )
    let payloadData = try recoveryPayload.encodeToJSON()

    let result = try await groupOperationCoordinator.withExclusiveLock(groupId: convo.groupId) { [self] in
      let localEpoch = try await mlsClient.getEpoch(for: userDid, groupId: groupIdData)
      let tagData = try? await mlsClient.getConfirmationTag(for: userDid, groupId: groupIdData)
      let tagB64 = tagData?.base64EncodedString()
      let ciphertext = try await encryptMessageImpl(groupId: convo.groupId, plaintext: payloadData)
      let paddedSize = ciphertext.count
      let localMsgId = UUID().uuidString

      let optimisticSeq: Int
      if let cursor = try? await storage.fetchLastMessageCursor(
        conversationID: conversationId,
        currentUserDID: userDid,
        database: database
      ) {
        optimisticSeq = Int(cursor.seq) + 1
      } else {
        optimisticSeq = 1
      }

      try await cacheControlMessageEnvelope(
        message: BlueCatbirdMlsChatDefs.MessageView(
          id: localMsgId,
          convoId: conversationId,
          ciphertext: Bytes(data: ciphertext),
          epoch: Int(localEpoch),
          seq: optimisticSeq,
          createdAt: ATProtocolDate(date: Date()),
          messageType: originalPayload.messageType.rawValue
        ),
        payload: recoveryPayload,
        senderDID: userDid,
        currentUserDID: userDid
      )

      let sendResult = try await apiClient.sendMessage(
        convoId: conversationId,
        msgId: localMsgId,
        ciphertext: ciphertext,
        epoch: Int(localEpoch),
        paddedSize: paddedSize,
        senderDid: try DID(didString: userDid),
        confirmationTag: tagB64
      )
      return (localMsgId, sendResult)
    }

    let (localMsgId, sendResult) = result
    try? await storage.updateMessageMetadata(
      messageID: localMsgId,
      currentUserDID: userDid,
      epoch: sendResult.epoch,
      sequenceNumber: sendResult.sequenceNumber,
      timestamp: sendResult.receivedAt.date,
      database: database,
      newMessageID: sendResult.messageId
    )
  }
}
```

- [ ] **Step 2: Handle received recovery response in +Messaging.swift**

In the `.text` processing case (around the existing text handler), add a check for `recoveredMessageId`:

```swift
case .text:
  // ... existing text handling ...

  // If this is a recovery response (re-sent content for a missed message),
  // mark the original failed message slot as recovered.
  if let originalId = payload.recoveredMessageId {
    try? await storage.updateProcessingState(
      messageID: originalId,
      conversationID: message.convoId,
      currentUserDID: userDid,
      processingState: "recovered",
      database: database
    )
  }

  if senderDID != userDid {
    enqueueDeliveryAck(messageId: message.id, conversationId: message.convoId)
  }
```

- [ ] **Step 3: Build**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/CatbirdMLSCore
swift build 2>&1 | tail -15
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
git add CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+DeliveryAcks.swift \
        CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+Messaging.swift
git commit -m "CatbirdMLSCore: Add message recovery request send and response handling"
```

---

## Task 6: MessageDeliveryState enum (Catbird iOS)

**Files:**
- Create: `Catbird/Catbird/Features/MLSChat/Models/MessageDeliveryState.swift`
- Create: `Catbird/CatbirdTests/Features/MLSChat/MessageDeliveryStateTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Catbird/CatbirdTests/Features/MLSChat/MessageDeliveryStateTests.swift`:

```swift
import Testing
import Foundation
@testable import Catbird
@testable import CatbirdMLSCore

@Suite("MessageDeliveryState")
struct MessageDeliveryStateTests {

  // Helpers
  private func ack(messageId: String = "m1", senderDID: String) -> MLSDeliveryAckModel {
    MLSDeliveryAckModel(
      messageId: messageId,
      conversationId: "c1",
      senderDID: senderDID,
      ackedAt: Date(),
      currentUserDID: "did:plc:sender"
    )
  }

  @Test func sendingWhenNotSent() {
    let state = MessageDeliveryState.compute(
      isSent: false,
      acks: [],
      hasReadReceipt: false,
      memberCount: 2,
      readReceiptsEnabled: true
    )
    #expect(state == .sending)
  }

  @Test func sentWhenNoAcks() {
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [],
      hasReadReceipt: false,
      memberCount: 2,
      readReceiptsEnabled: true
    )
    #expect(state == .sent)
  }

  @Test func deliveredPartialWhenSomeAcked() {
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [ack(senderDID: "did:plc:alice")],
      hasReadReceipt: false,
      memberCount: 3,  // sender + alice + bob → alice acked, bob hasn't
      readReceiptsEnabled: true
    )
    #expect(state == .deliveredPartial(count: 1, total: 2))
  }

  @Test func deliveredAllWhenAllAcked() {
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [ack(senderDID: "did:plc:alice"), ack(senderDID: "did:plc:bob")],
      hasReadReceipt: false,
      memberCount: 3,
      readReceiptsEnabled: true
    )
    #expect(state == .deliveredAll)
  }

  @Test func readWhenReceiptAndEnabled() {
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [ack(senderDID: "did:plc:alice")],
      hasReadReceipt: true,
      memberCount: 2,
      readReceiptsEnabled: true
    )
    #expect(state == .read)
  }

  @Test func deliveredAllNotReadWhenReceiptsDisabled() {
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [ack(senderDID: "did:plc:alice")],
      hasReadReceipt: true,
      memberCount: 2,
      readReceiptsEnabled: false  // opt-out
    )
    #expect(state == .deliveredAll)
  }

  @Test func deduplicatesDuplicateAcksFromSameSender() {
    // Two acks from same DID (e.g. retry) should count as one member
    let state = MessageDeliveryState.compute(
      isSent: true,
      acks: [ack(senderDID: "did:plc:alice"), ack(senderDID: "did:plc:alice")],
      hasReadReceipt: false,
      memberCount: 3,
      readReceiptsEnabled: true
    )
    #expect(state == .deliveredPartial(count: 1, total: 2))
  }
}
```

- [ ] **Step 2: Run test — expect failure**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing CatbirdTests/MessageDeliveryStateTests 2>&1 | tail -20
```

Expected: compile error — `MessageDeliveryState` does not exist.

- [ ] **Step 3: Create MessageDeliveryState.swift**

Create `Catbird/Catbird/Features/MLSChat/Models/MessageDeliveryState.swift`:

```swift
//
//  MessageDeliveryState.swift
//  Catbird
//
//  Derived delivery state for outgoing MLS messages.
//  Pure function — no side effects, no async.
//

import CatbirdMLSCore

/// The display state for an outgoing message's delivery indicator.
public enum MessageDeliveryState: Equatable {
  /// Message is being sent (not yet confirmed by server).
  case sending
  /// Server confirmed receipt; no member has acked yet.
  case sent
  /// Some but not all non-sender members have acked.
  case deliveredPartial(count: Int, total: Int)
  /// All non-sender members have acked.
  case deliveredAll
  /// At least one read receipt received (requires opt-in).
  case read
}

public extension MessageDeliveryState {

  /// Derives the delivery state from raw signal inputs.
  ///
  /// - Parameters:
  ///   - isSent: Whether the server has confirmed the message (seq assigned).
  ///   - acks: All delivery ack rows for this message from `MLSDeliveryAckModel`.
  ///   - hasReadReceipt: Whether any read receipt exists for this message.
  ///   - memberCount: Total member count of the conversation (including sender).
  ///   - readReceiptsEnabled: Whether the local user has read receipts enabled.
  static func compute(
    isSent: Bool,
    acks: [MLSDeliveryAckModel],
    hasReadReceipt: Bool,
    memberCount: Int,
    readReceiptsEnabled: Bool
  ) -> MessageDeliveryState {
    guard isSent else { return .sending }
    if readReceiptsEnabled && hasReadReceipt { return .read }
    let ackedDIDs = Set(acks.map(\.senderDID))
    let expected = max(memberCount - 1, 0)  // exclude sender
    if ackedDIDs.isEmpty { return .sent }
    if ackedDIDs.count < expected {
      return .deliveredPartial(count: ackedDIDs.count, total: expected)
    }
    return .deliveredAll
  }
}
```

- [ ] **Step 4: Run test — expect pass**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing CatbirdTests/MessageDeliveryStateTests 2>&1 | tail -20
```

Expected: `Test Suite 'MessageDeliveryStateTests' passed`

- [ ] **Step 5: Commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
git add Catbird/Catbird/Features/MLSChat/Models/MessageDeliveryState.swift \
        Catbird/CatbirdTests/Features/MLSChat/MessageDeliveryStateTests.swift
git commit -m "Catbird: Add MessageDeliveryState enum and compute function"
```

---

## Task 7: ViewModel — batch ack fetch and delivery state

**Files:**
- Modify: `Catbird/Catbird/Features/MLSChat/ViewModels/MLSConversationDetailViewModel.swift`

- [ ] **Step 1: Add a deliveryStates dictionary property**

In `MLSConversationDetailViewModel`, add a stored property below the `messages` property:

```swift
/// Keyed by messageId. Computed from MLSDeliveryAckModel rows after each refresh.
/// Only populated for outgoing messages (sender == currentUserDID).
var deliveryStates: [String: MessageDeliveryState] = [:]
```

- [ ] **Step 2: Add batch ack fetch function**

Add this method to the view model:

```swift
/// Fetches all delivery acks for visible outgoing messages in one query
/// and recomputes `deliveryStates`. Call after `loadMessages()` and on
/// `MLSDeliveryAckReceived` notifications.
@MainActor
private func refreshDeliveryStates() async {
  guard let conversationID, let currentUserDID else { return }

  // Visible outgoing messageIds
  let outgoingIds = messages
    .filter { $0.senderDid == currentUserDID }
    .map(\.id)
  guard !outgoingIds.isEmpty else { deliveryStates = [:]; return }

  // Batch fetch all acks for these messages
  let acks = (try? await mlsConversationManager.fetchDeliveryAcks(
    messageIds: outgoingIds,
    conversationId: conversationID,
    currentUserDID: currentUserDID
  )) ?? []

  // Group by messageId
  var acksByMessage: [String: [MLSDeliveryAckModel]] = [:]
  for ack in acks { acksByMessage[ack.messageId, default: []].append(ack) }

  // Read receipts — derive from existing read receipt storage
  let readReceiptMessageIds = Set(
    messages.compactMap { msg -> String? in
      guard msg.isRead else { return nil }
      return msg.id
    }
  )

  let memberCount = await mlsConversationManager.memberCount(for: conversationID) ?? 2
  let readReceiptsEnabled = preferencesManager.readReceiptsEnabled

  var newStates: [String: MessageDeliveryState] = [:]
  for msg in messages where msg.senderDid == currentUserDID {
    newStates[msg.id] = MessageDeliveryState.compute(
      isSent: msg.isSent,
      acks: acksByMessage[msg.id] ?? [],
      hasReadReceipt: readReceiptMessageIds.contains(msg.id),
      memberCount: memberCount,
      readReceiptsEnabled: readReceiptsEnabled
    )
  }
  deliveryStates = newStates
}
```

- [ ] **Step 3: Add fetchDeliveryAcks to MLSConversationManager**

Add this method in `MLSConversationManager+DeliveryAcks.swift`:

```swift
/// Batch-fetches delivery acks for a set of messageIds in one DB query.
public func fetchDeliveryAcks(
  messageIds: [String],
  conversationId: String,
  currentUserDID: String
) async throws -> [MLSDeliveryAckModel] {
  guard let database else { return [] }
  return try await database.read { db in
    try MLSDeliveryAckModel
      .filter(
        messageIds.contains(Column("messageId")) &&
        Column("conversationId") == conversationId &&
        Column("currentUserDID") == currentUserDID
      )
      .fetchAll(db)
  }
}

/// Returns the active member count for a conversation (includes sender).
public func memberCount(for conversationId: String) async -> Int? {
  guard let userDid, let database else { return nil }
  return try? await database.read { db in
    try MLSMemberModel
      .filter(
        Column("conversationID") == conversationId &&
        Column("currentUserDID") == userDid &&
        Column("isActive") == true
      )
      .fetchCount(db)
  }
}
```

- [ ] **Step 4: Call refreshDeliveryStates after loadMessages**

In `MLSConversationDetailViewModel.loadMessages()`, add a call after loading completes:

```swift
await loadMessages()
await refreshDeliveryStates()  // add this line
```

- [ ] **Step 5: Subscribe to MLSDeliveryAckReceived notifications**

In `setupNotificationObservers()` (or wherever notification observers are configured in the view model), add:

```swift
NotificationCenter.default.publisher(for: Notification.Name("MLSDeliveryAckReceived"))
  .receive(on: DispatchQueue.main)
  .sink { [weak self] notification in
    guard let self,
          let convoId = notification.userInfo?["conversationId"] as? String,
          convoId == self.conversationID
    else { return }
    Task { await self.refreshDeliveryStates() }
  }
  .store(in: &cancellables)
```

- [ ] **Step 6: Build**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
git add Catbird/Catbird/Features/MLSChat/ViewModels/MLSConversationDetailViewModel.swift \
        CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+DeliveryAcks.swift
git commit -m "Catbird: Batch-fetch delivery acks and compute per-message delivery state in ViewModel"
```

---

## Task 8: UI — delivery badge in MLSMessageRowView

**Files:**
- Modify: `Catbird/Catbird/Features/MLSChat/Views/MLSMessageRowView.swift`

`MLSMessageRowView` renders individual message bubbles. The delivery badge goes beneath the timestamp on outgoing messages only.

- [ ] **Step 1: Add deliveryState parameter to MLSMessageRowView**

In `MLSMessageRowView`, add a new property alongside the existing ones:

```swift
let deliveryState: MessageDeliveryState?  // nil for incoming messages
```

- [ ] **Step 2: Add the delivery badge subview**

Add a new computed property inside `MLSMessageRowView`:

```swift
@ViewBuilder
private var deliveryBadge: some View {
  if let state = deliveryState, message.user.isCurrentUser {
    HStack(spacing: 2) {
      switch state {
      case .sending:
        Image(systemName: "clock")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)

      case .sent:
        Image(systemName: "checkmark")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)

      case .deliveredPartial(let count, let total):
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        Text("\(count)/\(total)")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)

      case .deliveredAll:
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 10))
          .foregroundStyle(Color.accentColor)

      case .read:
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.blue)
      }
    }
    .padding(.trailing, DesignTokens.Spacing.xs)
  }
}
```

- [ ] **Step 3: Attach badge to the message footer**

In the `messageView` body (the section that renders timestamp + reactions beneath the bubble), add `deliveryBadge` next to the timestamp for outgoing messages. Find the HStack or VStack that holds the message timestamp and add:

```swift
// In the timestamp row for outgoing messages:
HStack(spacing: 4) {
  deliveryBadge   // add this
  Text(message.timestamp, style: .time)
    .designCaption()
    .foregroundStyle(.tertiary)
}
```

- [ ] **Step 4: Thread deliveryState from MLSMessageView**

Find where `MLSMessageRowView` is instantiated (in `MLSMessageView.swift` or wherever the list is built). Update the call site to pass the delivery state from the view model:

```swift
MLSMessageRowView(
  message: message,
  conversationID: conversationID,
  reactions: reactions,
  currentUserDID: currentUserDID,
  participantProfiles: participantProfiles,
  deliveryState: viewModel.deliveryStates[message.id],  // add this
  onAddReaction: onAddReaction,
  onRemoveReaction: onRemoveReaction,
  navigationPath: $navigationPath
)
```

- [ ] **Step 5: Build and run on simulator**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird
xcodebuild -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

Boot the simulator and verify that:
- Outgoing messages show a clock icon while sending
- Outgoing messages show a single gray checkmark after send confirmation
- No badge appears on incoming messages

- [ ] **Step 6: Commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
git add Catbird/Catbird/Features/MLSChat/Views/MLSMessageRowView.swift \
        Catbird/Catbird/Features/MLSChat/Views/MLSMessageView.swift
git commit -m "Catbird: Add delivery state badge to outgoing message bubbles"
```

---

## Task 9: Large group ack cap

**Files:**
- Modify: `CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+DeliveryAcks.swift`

- [ ] **Step 1: Add the cap constant**

At the top of `MLSConversationManager+DeliveryAcks.swift`, add:

```swift
/// Conversations with more than this many members skip delivery acks
/// to avoid SSE amplification storms. Configurable via PreferencesManager.
private let defaultDeliveryAckGroupSizeCap = 20
```

- [ ] **Step 2: Guard enqueueDeliveryAck with member count**

In `enqueueDeliveryAck`, add a member count check before enqueuing:

```swift
func enqueueDeliveryAck(messageId: String, conversationId: String) {
  guard let userDid else { return }

  Task { [weak self] in
    guard let self else { return }

    // Skip acks for large groups to prevent SSE amplification.
    let cap = defaultDeliveryAckGroupSizeCap
    if let count = await self.memberCount(for: conversationId), count > cap {
      return
    }

    // Deduplication check
    let alreadyAcked = (try? await self.database?.read { db in
      try MLSDeliveryAckModel
        .filter(
          Column("messageId") == messageId &&
          Column("senderDID") == userDid &&
          Column("currentUserDID") == userDid
        )
        .fetchOne(db)
    }) != nil
    guard !alreadyAcked else { return }

    try? await self.sendDeliveryAck(messageId: messageId, conversationId: conversationId)
  }
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/CatbirdMLSCore
swift build 2>&1 | tail -10
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
git add CatbirdMLSCore/Sources/CatbirdMLSCore/Service/MLSConversationManager+DeliveryAcks.swift
git commit -m "CatbirdMLSCore: Skip delivery acks in groups above size cap to prevent SSE amplification"
```

---

## Task 10: Full build + test run

- [ ] **Step 1: Run CatbirdMLSCore tests**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/CatbirdMLSCore
swift test 2>&1 | tail -30
```

Expected: All tests pass. No compile errors.

- [ ] **Step 2: Run Catbird iOS tests**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Verify on simulator — 1:1 flow**

Using the E2E test simulators (E2E-ChatA as `catbirdbot.bsky.social`, E2E-ChatB as `j0sh.bsky.social`):

1. Send a message from ChatA
2. ChatB (recipient) should auto-emit a delivery ack
3. ChatA should show double checkmark (accent color) under the message bubble within a few seconds
4. If ChatB has read receipts enabled, opening the conversation should advance the badge to blue

- [ ] **Step 4: Final commit**

```bash
cd /Users/joshlacalamito/Developer/Catbird+Petrel
git add -A
git commit -m "Catbird: MLS delivery acks — wire end-to-end and verify"
```

---

## Out of scope (separate plans)

- **catbird-mls (Rust) + catmos**: Equivalent `delivery_acks` table in the Rust SQLCipher DB, UniFFI exposure, catmos desktop UI
- **Android**: `DeliveryAckEntity` Room table + equivalent send/receive/UI logic
- **Per-member name list in UI**: The `2/4` count badge is V1. Showing "Alice, Bob ✓" on long-press is a follow-on.
