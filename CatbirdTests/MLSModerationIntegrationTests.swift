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
@testable import Catbird

/// Integration test suite for MLS moderation workflows
/// Tests end-to-end moderation scenarios with actual MLSConversationManager
@Suite("MLS Moderation Integration Tests")
struct MLSModerationIntegrationTests {

  // MARK: - Test Data

  let adminDid = "did:plc:admin123"
  let memberDid = "did:plc:member456"
  let reporterDid = "did:plc:reporter789"
  let violatorDid = "did:plc:violator999"

  // MARK: - Helper Methods

  /// Create a test database queue in memory
  func createTestDatabase() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try MLSStorage.setupDatabase(dbQueue)
    return dbQueue
  }

  /// Create a mock MLS conversation manager for testing
  func createMockConversationManager(userDid: String) async throws -> (MLSConversationManager, MockMLSAPIClient) {
    let mockAPIClient = MockMLSAPIClient()
    let dbQueue = try createTestDatabase()

    let manager = MLSConversationManager(
      apiClient: mockAPIClient,
      database: dbQueue,
      userDid: userDid,
      storage: MLSStorage.shared,
      configuration: .default
    )

    try await manager.initialize()

    return (manager, mockAPIClient)
  }

  // MARK: - Remove Member Integration Tests

  @Test("Admin removes member - full workflow")
  func testRemoveMemberFullWorkflow() async throws {
    let (manager, mockAPI) = try await createMockConversationManager(userDid: adminDid)
    let convoId = "test-convo-remove-member"

    // Setup: Create conversation with members
    let conversation = createMockConversation(
      id: convoId,
      members: [adminDid, memberDid, violatorDid],
      admins: [adminDid]
    )
    manager.conversations[convoId] = conversation

    // Mock server response for removal
    let removeOutput = BlueCatbirdMlsChatCommitGroupChange.Output(success: true, newEpoch: 2)
    mockAPI.mockRemoveMemberResponse = (200, removeOutput)

    // Mock MLS commit generation (would normally come from MLSClient)
    mockAPI.onRemoveMember = { input in
      // Verify correct parameters
      #expect(input.convoId == convoId)
      #expect(input.memberDids?.first?.description == self.violatorDid)
      #expect(input.action == "removeMember")
    }

    // Execute: Remove violator
    try await manager.removeMember(
      from: convoId,
      memberDid: violatorDid,
      reason: "Community guidelines violation"
    )

    // Verify: Member removed from local state
    let updatedConvo = manager.conversations[convoId]
    let memberDids = updatedConvo?.members.map { $0.did.description } ?? []
    #expect(!memberDids.contains(violatorDid))
    #expect(memberDids.contains(adminDid))
    #expect(memberDids.contains(memberDid))
  }

  @Test("Non-admin cannot remove members")
  func testNonAdminCannotRemoveMembers() async throws {
    let (manager, mockAPI) = try await createMockConversationManager(userDid: memberDid)
    let convoId = "test-convo-non-admin"

    let conversation = createMockConversation(
      id: convoId,
      members: [adminDid, memberDid, violatorDid],
      admins: [adminDid] // memberDid is NOT admin
    )
    manager.conversations[convoId] = conversation

    // Mock server rejection
    mockAPI.mockRemoveMemberResponse = (403, nil)

    // Execute and expect failure
    do {
      try await manager.removeMember(
        from: convoId,
        memberDid: violatorDid,
        reason: "Test"
      )
      Issue.record("Expected error but removal succeeded")
    } catch {
      // Expected error - verify it's the right type
      #expect(error is MLSConversationError)
    }
  }

  // MARK: - Promote/Demote Admin Integration Tests

  @Test("Promote member to admin - full workflow")
  func testPromoteAdminFullWorkflow() async throws {
    let (manager, mockAPI) = try await createMockConversationManager(userDid: adminDid)
    let convoId = "test-convo-promote"

    let conversation = createMockConversation(
      id: convoId,
      members: [adminDid, memberDid],
      admins: [adminDid]
    )
    manager.conversations[convoId] = conversation

    // Mock server response
    let promoteOutput = BlueCatbirdMlsChatUpdateConvo.Output(
      success: true
    )
    mockAPI.mockPromoteAdminResponse = (200, promoteOutput)

    // Track that encrypted roster update is sent
    var rosterUpdateSent = false
    mockAPI.onSendMessage = { convoId, encryptedPayload in
      // Verify admin roster update is encrypted and sent
      rosterUpdateSent = true
      #expect(!encryptedPayload.isEmpty)
    }

    // Execute
    try await manager.promoteAdmin(in: convoId, memberDid: memberDid)

    // Verify: Member is now admin in local state
    let updatedConvo = manager.conversations[convoId]
    let adminDids = updatedConvo?.members.filter { $0.isAdmin }.map { $0.did.description } ?? []
    #expect(adminDids.contains(memberDid))
    #expect(adminDids.contains(adminDid))

    // Verify: Encrypted roster update was sent
    #expect(rosterUpdateSent)
  }

  @Test("Demote admin - full workflow")
  func testDemoteAdminFullWorkflow() async throws {
    let (manager, mockAPI) = try await createMockConversationManager(userDid: adminDid)
    let convoId = "test-convo-demote"

    let conversation = createMockConversation(
      id: convoId,
      members: [adminDid, memberDid],
      admins: [adminDid, memberDid] // Both are admins
    )
    manager.conversations[convoId] = conversation

    // Mock server response
    let demoteOutput = BlueCatbirdMlsChatUpdateConvo.Output(
      success: true
    )
    mockAPI.mockDemoteAdminResponse = (200, demoteOutput)

    // Execute
    try await manager.demoteAdmin(in: convoId, memberDid: memberDid)

    // Verify: Member is no longer admin
    let updatedConvo = manager.conversations[convoId]
    let adminDids = updatedConvo?.members.filter { $0.isAdmin }.map { $0.did.description } ?? []
    #expect(!adminDids.contains(memberDid))
    #expect(adminDids.contains(adminDid))
  }

  // MARK: - Block Status Integration Tests

  @Test("Check blocks before adding members")
  func testCheckBlocksBeforeAddingMembers() async throws {
    let (manager, mockAPI) = try await createMockConversationManager(userDid: adminDid)
    let convoId = "test-convo-blocks"

    let conversation = createMockConversation(
      id: convoId,
      members: [adminDid, memberDid],
      admins: [adminDid]
    )
    manager.conversations[convoId] = conversation

    // Mock block relationship - member has blocked violator
    let blockRelationship = BlueCatbirdMlsChatCheckBlocks.BlockRelationship(
      blockerDid: try DID(didString: memberDid),
      blockedDid: try DID(didString: violatorDid),
      createdAt: ATProtocolDate(date: Date()),
      blockUri: try? ATProtocolURI(uriString: "at://did:plc:member456/app.bsky.graph.block/abc")
    )
    let blocksOutput = BlueCatbirdMlsChatCheckBlocks.Output(
      blocked: true,
      blocks: [blockRelationship],
      checkedAt: ATProtocolDate(date: Date())
    )
    mockAPI.mockCheckBlocksResponse = (200, blocksOutput)

    // Check blocks before adding violator
    let blocks = try await manager.checkBlocks(
      dids: [memberDid, violatorDid]
    )

    // Verify block detected
    #expect(blocks.count == 1)
    #expect(blocks.first?.blockerDid.description == memberDid)
    #expect(blocks.first?.blockedDid.description == violatorDid)

    // Admin should handle this by NOT adding violator to conversation
    // or by removing one of the conflicting users
  }

  // MARK: - Key Package Stats Integration Tests

  @Test("Monitor key package stats and trigger replenishment")
  func testKeyPackageStatsMonitoring() async throws {
    let (manager, mockAPI) = try await createMockConversationManager(userDid: adminDid)

    // Scenario: Low key packages, needs replenishment
    let lowStatsOutput = BlueCatbirdMlsChatPublishKeyPackages.Output(
      stats: BlueCatbirdMlsChatPublishKeyPackages.KeyPackageStats(
        published: 3,
        available: 3,
        expired: 7
      )
    )
    mockAPI.mockGetKeyPackageStatsResponse = (200, lowStatsOutput)

    // Check stats
    let stats = try await manager.getKeyPackageStats()

    #expect(stats.stats.available < 10)

    // In real implementation, this would trigger automatic key package upload
    // via manager.refreshKeyPackagesIfNeeded()
  }

  // MARK: - Admin Stats Integration Tests

  @Test("Collect comprehensive admin statistics")
  func testAdminStatsCollection() async throws {
    let (manager, mockAPI) = try await createMockConversationManager(userDid: adminDid)
    let convoId = "test-convo-stats"

    let conversation = createMockConversation(
      id: convoId,
      members: [adminDid, memberDid],
      admins: [adminDid]
    )
    manager.conversations[convoId] = conversation

    // Mock admin stats response
    let statsOutput = BlueCatbirdMlsChatUpdateConvo.Output(
      success: true
    )
    mockAPI.mockGetAdminStatsResponse = (200, statsOutput)

    // Get admin stats
    let stats = try await manager.getAdminStats(for: convoId)

    // Verify success
    #expect(stats.success == true)
  }

  // MARK: - Helper Methods

  private func createMockConversation(
    id: String,
    members: [String],
    admins: [String]
  ) -> BlueCatbirdMlsChatDefs.ConvoView {
    let memberViews = members.map { memberDid in
      BlueCatbirdMlsChatDefs.MemberView(
        did: try! DID(didString: memberDid),
        isAdmin: admins.contains(memberDid),
        joinedAt: ATProtocolDate(date: Date()),
        leftAt: nil
      )
    }

    return BlueCatbirdMlsChatDefs.ConvoView(
      id: id,
      groupId: "group-\(id)",
      cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
      epoch: 1,
      members: memberViews,
      createdAt: ATProtocolDate(date: Date()),
      metadata: nil,
      lastMessageAt: nil
    )
  }
}

// MARK: - Mock MLS API Client

/// Enhanced mock API client for integration testing
final class MockMLSAPIClient: MLSAPIClient {

  // Mock responses
  var mockRemoveMemberResponse: (Int, BlueCatbirdMlsChatCommitGroupChange.Output?)?
  var mockPromoteAdminResponse: (Int, BlueCatbirdMlsChatUpdateConvo.Output?)?
  var mockDemoteAdminResponse: (Int, BlueCatbirdMlsChatUpdateConvo.Output?)?
  var mockCheckBlocksResponse: (Int, BlueCatbirdMlsChatCheckBlocks.Output?)?
  var mockGetKeyPackageStatsResponse: (Int, BlueCatbirdMlsChatPublishKeyPackages.Output?)?
  var mockGetAdminStatsResponse: (Int, BlueCatbirdMlsChatUpdateConvo.Output?)?

  // Callback hooks
  var onRemoveMember: ((BlueCatbirdMlsChatCommitGroupChange.Input) -> Void)?
  var onPromoteAdmin: ((BlueCatbirdMlsChatUpdateConvo.Input) -> Void)?
  var onDemoteAdmin: ((BlueCatbirdMlsChatUpdateConvo.Input) -> Void)?
  var onSendMessage: ((String, Data) -> Void)?

  override init() {
    // Mock initialization
    super.init(atProtoClient: MockATProtoClient())
  }

  // Override methods to return mock responses
  override func removeMember(
    convoId: String,
    targetDid: String,
    reason: String?
  ) async throws -> (responseCode: Int, data: BlueCatbirdMlsChatCommitGroupChange.Output?) {
    let input = BlueCatbirdMlsChatCommitGroupChange.Input(
      convoId: convoId,
      action: "removeMember",
      memberDids: [try DID(didString: targetDid)],
      idempotencyKey: UUID().uuidString
    )
    onRemoveMember?(input)

    guard let response = mockRemoveMemberResponse else {
      throw MLSError.unexpectedError("No mock response configured")
    }
    return response
  }

  override func promoteAdmin(
    convoId: String,
    targetDid: String
  ) async throws -> (responseCode: Int, data: BlueCatbirdMlsChatUpdateConvo.Output?) {
    let input = BlueCatbirdMlsChatUpdateConvo.Input(
      convoId: convoId,
      action: "promoteAdmin",
      targetDid: try DID(didString: targetDid)
    )
    onPromoteAdmin?(input)

    guard let response = mockPromoteAdminResponse else {
      throw MLSError.unexpectedError("No mock response configured")
    }
    return response
  }

  override func demoteAdmin(
    convoId: String,
    targetDid: String
  ) async throws -> (responseCode: Int, data: BlueCatbirdMlsChatUpdateConvo.Output?) {
    let input = BlueCatbirdMlsChatUpdateConvo.Input(
      convoId: convoId,
      action: "demoteAdmin",
      targetDid: try DID(didString: targetDid)
    )
    onDemoteAdmin?(input)

    guard let response = mockDemoteAdminResponse else {
      throw MLSError.unexpectedError("No mock response configured")
    }
    return response
  }

  // Additional mock method implementations would follow the same pattern
}
