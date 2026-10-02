import Foundation
import GRDB
import Petrel
import Testing
@testable import Catbird
@testable import CatbirdMLSCore

#if os(iOS)
extension MLSSuspensionCloseCoordinatorTests {
  @Test("A retained data source observes the replacement pool after close and reopen")
  func retainedDataSourceObservesReopenedPool() async throws {
    let fixture = try await ProjectionFixture()
    defer { fixture.finish() }
    let source = fixture.source
    let pendingID = source.beginPendingSend(text: "Still sending", embed: nil)
    source.draftText = "Unsent draft"

    await source.loadMessages()
    try await waitUntil { source.messages.contains { $0.id == "before-close" } }

    let oldPool = fixture.pool
    try oldPool.close()
    let reopenedPool = try DatabasePool(path: fixture.databaseURL.path)
    fixture.pool = reopenedPool
    fixture.appState.updateMLSDatabase(reopenedPool)
    await source.loadMessages()
    try await reopenedPool.write { database in
      try database.execute(sql: "UPDATE MLSMessageModel SET isTombstone = 1 WHERE messageID = 'before-close'")
      try ProjectionFixture.message(id: "after-reopen", sequence: 2).insert(database)
    }
    try await waitUntil {
      source.messages.map(\.id) == ["after-reopen", pendingID]
    }

    // Repeating load on the same pool must retain the observation and local state.
    await source.loadMessages()
    try await reopenedPool.write { database in
      try ProjectionFixture.message(id: "later-on-reopened-pool", sequence: 3).insert(database)
    }
    try await waitUntil {
      source.messages.map(\.id) == ["after-reopen", "later-on-reopened-pool", pendingID]
    }
    #expect(source.draftText == "Unsent draft")
    #expect(source.pendingSends.map(\.id) == [pendingID])
    #expect(source.error == nil)
    #expect(throws: DatabaseError.self) { try ProjectionFixture.messageCount(in: oldPool) }
  }

  @Test("Stopping observation rejects an already queued initial message callback")
  func stopRejectsQueuedInitialCallback() async throws {
    let fixture = try await ProjectionFixture()
    defer { fixture.finish() }
    let source = fixture.source
    let pendingID = source.beginPendingSend(text: "Pending survives stop", embed: nil)

    // The immediate GRDB emission queues a main-actor task. Stop before yielding
    // this actor so cancellation must invalidate that task as well as GRDB.
    await source.loadMessages()
    source.stopObserving()
    try await Task.sleep(for: .milliseconds(250))
    #expect(source.messages.map(\.id) == [pendingID])

    await source.loadMessages()
    try await waitUntil { source.messages.map(\.id) == ["before-close", pendingID] }
  }

  @Test("A retained detail model marks messages read through the manager's replacement pool")
  func retainedDetailModelUsesReplacementPool() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("mls-detail-pool-rebind-\(UUID().uuidString).sqlite")
    let oldPool = try ProjectionFixture.makePool(at: databaseURL)
    let client = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
    let api = await MLSAPIClient(
      client: client, environment: .custom(serviceDID: "did:web:example.com#atproto_mls")
    )
    let manager = MLSConversationManager(
      apiClient: api, database: oldPool, userDid: ProjectionFixture.userDID,
      atProtoClient: client, protocolAuthorityMode: .rustFull
    )
    let detail = MLSConversationDetailViewModel(
      conversationId: ProjectionFixture.conversationID, apiClient: api, conversationManager: manager
    )
    detail.draftMessage = "Retained detail draft"

    try oldPool.close()
    let reopenedPool = try DatabasePool(path: databaseURL.path)
    defer { try? reopenedPool.close() }
    manager.database = reopenedPool
    let initiallyUnread = try await reopenedPool.read {
      try Int.fetchOne($0, sql: "SELECT isRead FROM MLSMessageModel WHERE messageID = 'before-close'")
    }
    #expect(initiallyUnread == 0)

    await detail.markMessagesAsRead()

    let nowRead = try await reopenedPool.read {
      try Int.fetchOne($0, sql: "SELECT isRead FROM MLSMessageModel WHERE messageID = 'before-close'")
    }
    #expect(nowRead == 1)
    #expect(detail.draftMessage == "Retained detail draft")
    #expect(throws: DatabaseError.self) { try ProjectionFixture.messageCount(in: oldPool) }
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "The real database observation did not publish the expected message IDs")
  }
}

@MainActor
private final class ProjectionFixture {
  nonisolated static let userDID = "did:plc:projectionpoolfixture"
  nonisolated static let conversationID = "d615ab35-7086-4293-b095-83012e1b0ad4"
  let databaseURL: URL
  var pool: DatabasePool
  let appState: AppState
  let source: MLSConversationDataSource
  private let previousLifecycle: AppLifecycle

  init() async throws {
    databaseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("mls-projection-pool-rebind-\(UUID().uuidString).sqlite")
    pool = try Self.makePool(at: databaseURL)
    let client = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
    appState = AppState(userDID: Self.userDID, client: client)
    appState.updateMLSDatabase(pool)
    source = MLSConversationDataSource(
      conversationId: Self.conversationID, currentUserDID: Self.userDID, appState: appState
    )
    source.preloadProfiles([
      Self.userDID: .init(did: Self.userDID, handle: "fixture.test", displayName: "Fixture", avatarURL: nil)
    ])

    // Keep the fixture's projection offline: existing inactive-account guards
    // skip manager initialization and Rust context creation, using payloadJSON.
    previousLifecycle = AppStateManager.shared.lifecycle
    let otherAccount = AppState(userDID: "did:plc:otherprojectionfixture", client: client)
    AppStateManager.shared.setLifecycleForTesting(.authenticated(otherAccount))
  }

  func finish() {
    source.stopObserving()
    try? pool.close()
    AppStateManager.shared.setLifecycleForTesting(previousLifecycle)
  }

  nonisolated static func makePool(at url: URL) throws -> DatabasePool {
    let pool = try DatabasePool(path: url.path)
    try MLSGRDBManager.makeMigrator().migrate(pool)
    try pool.write { database in
      try database.execute(sql: """
        CREATE TABLE IF NOT EXISTS mls_orchestrator_terminal_access (
          user_did TEXT NOT NULL, conversation_id TEXT NOT NULL,
          group_id BLOB NOT NULL, state TEXT NOT NULL,
          PRIMARY KEY(user_did, conversation_id))
        """)
      try MLSConversationModel(
        conversationID: conversationID, currentUserDID: userDID,
        groupID: Data(repeating: 0x31, count: 32)
      ).insert(database)
      try message(id: "before-close", sequence: 1).insert(database)
    }
    return pool
  }

  nonisolated static func message(id: String, sequence: Int64) -> MLSMessageModel {
    MLSMessageModel(
      messageID: id, currentUserDID: userDID, conversationID: conversationID,
      senderID: userDID, payloadJSON: try? MLSMessagePayload.text(id).encodeToJSON(),
      timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)), epoch: 1,
      sequenceNumber: sequence, isDelivered: true, payloadKeyVersion: 1
    )
  }

  nonisolated static func messageCount(in pool: DatabasePool) throws -> Int {
    try pool.read { try MLSMessageModel.fetchCount($0) }
  }
}
#endif
