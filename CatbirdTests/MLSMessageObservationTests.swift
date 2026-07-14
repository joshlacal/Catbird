import Foundation
import GRDB
import Testing
@testable import Catbird
@testable import CatbirdMLSCore

private final class MessageObservationEmissions: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [[String]] = []

  func append(_ messageIDs: [String]) {
    lock.lock()
    values.append(messageIDs)
    lock.unlock()
  }

  func snapshot() -> [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

@Suite("MLS message observation")
@MainActor
struct MLSMessageObservationTests {
  @Test("Tombstoned rows converge to removal and never reinsert")
  func tombstonedRowsConvergeToRemovalWithoutOrderingJump() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let database = try DatabasePool(
      path: temporaryDirectory.appendingPathComponent("messages.sqlite").path
    )
    try await database.write { db in
      try Self.createMessageTable(in: db)
      for (id, sequence) in [("first", 1), ("removed", 2), ("last", 3)] {
        try Self.message(id: id, sequence: Int64(sequence)).insert(db)
      }
    }

    let emissions = MessageObservationEmissions()
    let observation = MLSDisplayableMessageQuery.observation(
      conversationID: "convo-1",
      currentUserDID: "did:plc:tester"
    )

    let cancellable = observation.start(
      in: database,
      scheduling: .immediate,
      onError: { error in
        Issue.record("Observation failed: \(error)")
      },
      onChange: { models in
        emissions.append(models.map(\.messageID))
      }
    )

    try await Self.waitUntil {
      emissions.snapshot().last == ["first", "removed", "last"]
    }

    try await database.write { db in
      try db.execute(
        sql: "UPDATE MLSMessageModel SET isTombstone = 1 WHERE messageID = ?",
        arguments: ["removed"]
      )
    }
    try await Self.waitUntil {
      emissions.snapshot().last == ["first", "last"]
    }

    let removalEmissionIndex = try #require(
      emissions.snapshot().lastIndex(of: ["first", "last"])
    )
    try await database.write { db in
      try db.execute(
        sql: "UPDATE MLSMessageModel SET timestamp = ? WHERE messageID = ?",
        arguments: [Date(timeIntervalSince1970: 9_999), "removed"]
      )
    }
    try await Task.sleep(for: .milliseconds(250))

    let emissionsAfterRemoval = emissions.snapshot().suffix(from: removalEmissionIndex)
    #expect(emissionsAfterRemoval.allSatisfy { $0 == ["first", "last"] })
    withExtendedLifetime(cancellable) {}
  }

  nonisolated private static func message(id: String, sequence: Int64) -> MLSMessageModel {
    MLSMessageModel(
      messageID: id,
      currentUserDID: "did:plc:tester",
      conversationID: "convo-1",
      senderID: "did:plc:tester",
      payloadJSON: try? MLSMessagePayload.text(id).encodeToJSON(),
      timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
      epoch: 1,
      sequenceNumber: sequence,
      isDelivered: true,
      payloadKeyVersion: 1
    )
  }

  nonisolated private static func createMessageTable(in db: Database) throws {
    try db.create(table: MLSMessageModel.databaseTableName) { table in
      table.primaryKey("messageID", .text).notNull()
      table.column("currentUserDID", .text).notNull()
      table.column("conversationID", .text).notNull()
      table.column("senderID", .text).notNull()
      table.column("payloadJSON", .blob)
      table.column("wireFormat", .blob)
      table.column("contentType", .text).notNull()
      table.column("timestamp", .datetime).notNull()
      table.column("epoch", .integer).notNull()
      table.column("sequenceNumber", .integer).notNull()
      table.column("authenticatedData", .blob)
      table.column("signature", .blob)
      table.column("isDelivered", .boolean).notNull().defaults(to: false)
      table.column("isRead", .boolean).notNull().defaults(to: false)
      table.column("isSent", .boolean).notNull().defaults(to: false)
      table.column("sendAttempts", .integer).notNull().defaults(to: 0)
      table.column("error", .text)
      table.column("processingState", .text).notNull()
      table.column("gapBefore", .boolean).notNull().defaults(to: false)
      table.column("payloadExpired", .boolean).notNull().defaults(to: false)
      table.column("processingError", .text)
      table.column("processingAttempts", .integer).notNull().defaults(to: 0)
      table.column("validationFailureReason", .text)
      table.column("payloadEncrypted", .blob)
      table.column("entryHMAC", .blob)
      table.column("payloadKeyVersion", .integer).notNull().defaults(to: 1)
      table.column("isTombstone", .integer).notNull().defaults(to: 0)
      table.column("deletedAt", .integer)
      table.column("isEdited", .integer).notNull().defaults(to: 0)
      table.column("editedAt", .datetime)
      table.column("appliedEditSeq", .integer)
    }
  }

  private static func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () -> Bool
  ) async throws {
    try await confirmation("Observation reaches expected state") { confirmation in
      let deadline = ContinuousClock.now + timeout
      while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      if condition() {
        confirmation()
      }
    }
  }
}
