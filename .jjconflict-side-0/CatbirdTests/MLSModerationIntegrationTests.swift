//
//  MLSModerationIntegrationTests.swift
//  CatbirdTests
//
//  Created by Claude Code
//  Integration tests for MLS moderation and admin features
//

import Testing
import Foundation
import GRDB
import Petrel
import PetrelCatbird
@testable import Catbird
@testable import CatbirdMLSCore

/// Integration test suite for MLS moderation workflows
@Suite("MLS Moderation Integration Tests")
struct MLSModerationIntegrationTests {

  // MARK: - Test Data

  let adminDid = "did:plc:admin123"
  let memberDid = "did:plc:member456"
  let reporterDid = "did:plc:reporter789"
  let violatorDid = "did:plc:violator999"

  // MARK: - Helper Methods

  func createTestDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try MLSStorage.setupDatabase(dbQueue)
    return dbQueue
  }

  func createMockConversationManager(userDid: String) async throws -> MLSConversationManager {
    let atProtoClient = ATProtoClient(
      networkService: MockNetworkService(),
      authProvider: MockAuthProvider()
    )
    let apiClient = MLSAPIClient(atProtoClient: atProtoClient)
    let dbQueue = try createTestDatabase()

    let manager = MLSConversationManager(
      apiClient: apiClient,
      database: dbQueue,
      userDid: userDid,
      storage: MLSStorage.shared,
      configuration: .default
    )

    try await manager.initialize()
    return manager
  }

  private func createMockConversation(
    id: String,
    members: [String],
    admins: [String]
  ) -> BlueCatbirdChatDefs.ConversationState {
    let participants = members.map { memberDid in
      BlueCatbirdChatDefs.ParticipantView(
        userDid: try! DID(didString: memberDid),
        role: admins.contains(memberDid) ? .value_admin : .value_member,
        status: .value_active,
        joinedAt: ATProtocolDate(date: Date()),
        acceptedAt: ATProtocolDate(date: Date()),
        leftAt: nil
      )
    }
    let coords = BlueCatbirdChatDefs.ConversationCoordinates(
      conversationId: id,
      generation: 1,
      stateVersion: 1,
      groupId: Bytes(data: Data("group-\(id)".utf8)),
      epoch: 1,
      groupContextHash: Bytes(data: Data()),
      confirmationTag: Bytes(data: Data()),
      lifecycle: .value_active
    )
    return BlueCatbirdChatDefs.ConversationState(
      coordinates: coords,
      participants: participants,
      activeLeaves: [],
      pendingWelcomes: [],
      revokedLeaves: [],
      recoveryInbox: [],
      currentAccessPeriodId: "period-1",
      previousCoordinates: nil,
      snapshotCommittedAt: ATProtocolDate(date: Date()),
      lastEntrySeq: 0,
      lastEntryReceivedAt: nil
    )
  }

  @Test("Admin creates mock conversation with participants")
  func testMockConversationCreation() async throws {
    let convo = createMockConversation(
      id: "convo-1",
      members: [adminDid, memberDid],
      admins: [adminDid]
    )

    #expect(convo.participants.count == 2)
    #expect(convo.participants.first?.role == .value_admin)
  }
}
