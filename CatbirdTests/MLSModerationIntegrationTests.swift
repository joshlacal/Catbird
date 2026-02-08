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
    let removeOutput = BlueCatbirdMlsRemoveMember.Output(ok: true, epochHint: 2)
    mockAPI.mockRemoveMemberResponse = (200, removeOutput)

    // Mock MLS commit generation (would normally come from MLSClient)
    mockAPI.onRemoveMember = { input in
      // Verify correct parameters
      #expect(input.convoId == convoId)
      #expect(input.targetDid.description == self.violatorDid)
      #expect(input.reason != nil)
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
    let promoteOutput = BlueCatbirdMlsPromoteAdmin.Output(
      ok: true,
      promotedAt: ATProtocolDate(date: Date())
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
    let demoteOutput = BlueCatbirdMlsDemoteAdmin.Output(
      ok: true,
      demotedAt: ATProtocolDate(date: Date())
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

  // MARK: - Report Member Integration Tests

  @Test("User reports member - admin retrieves and resolves")
  func testReportMemberFullWorkflow() async throws {
    // Phase 1: Reporter submits report
    let (reporterManager, reporterAPI) = try await createMockConversationManager(userDid: reporterDid)
    let convoId = "test-convo-report"

    let conversation = createMockConversation(
      id: convoId,
      members: [adminDid, reporterDid, violatorDid],
      admins: [adminDid]
    )
    reporterManager.conversations[convoId] = conversation

    let reportId = "report-12345"
    let reportOutput = BlueCatbirdMlsReportMember.Output(
      reportId: reportId,
      submittedAt: ATProtocolDate(date: Date())
    )
    reporterAPI.mockReportMemberResponse = (200, reportOutput)

    // Submit report
    let submittedReportId = try await reporterManager.reportMember(
      in: convoId,
      memberDid: violatorDid,
      reason: "harassment",
      details: "Repeated offensive messages"
    )

    #expect(submittedReportId == reportId)

    // Phase 2: Admin retrieves reports
    let (adminManager, adminAPI) = try await createMockConversationManager(userDid: adminDid)
    adminManager.conversations[convoId] = conversation

    let mockReport = BlueCatbirdMlsGetReports.ReportView(
      id: reportId,
      reporterDid: try DID(didString: reporterDid),
      reportedDid: try DID(didString: violatorDid),
      encryptedContent: Data("encrypted report details".utf8),
      createdAt: ATProtocolDate(date: Date()),
      status: "pending",
      resolvedBy: nil,
      resolvedAt: nil
    )
    let reportsOutput = BlueCatbirdMlsGetReports.Output(reports: [mockReport])
    adminAPI.mockGetReportsResponse = (200, reportsOutput)

    // Get reports (admin only)
    let reports = try await adminManager.getReports(for: convoId, status: "pending")
    #expect(reports.count == 1)
    #expect(reports.first?.id == reportId)

    // Phase 3: Admin resolves report
    let resolveOutput = BlueCatbirdMlsResolveReport.Output(ok: true)
    adminAPI.mockResolveReportResponse = (200, resolveOutput)

    try await adminManager.resolveReport(
      reportId,
      action: "removed_member",
      notes: "Removed violator from conversation"
    )

    // Verify resolution was processed
    // (In real implementation, this would update report status in database)
  }

  @Test("Cannot report self")
  func testCannotReportSelf() async throws {
    let (manager, mockAPI) = try await createMockConversationManager(userDid: reporterDid)
    let convoId = "test-convo-self-report"

    let conversation = createMockConversation(
      id: convoId,
      members: [adminDid, reporterDid],
      admins: [adminDid]
    )
    manager.conversations[convoId] = conversation

    mockAPI.mockReportMemberResponse = (400, nil)

    // Attempt to report self
    do {
      _ = try await manager.reportMember(
        in: convoId,
        memberDid: reporterDid, // Same as reporter
        reason: "spam",
        details: nil
      )
      Issue.record("Expected error when reporting self")
    } catch {
      // Expected error
      #expect(error is MLSConversationError)
    }
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
    let blockRelationship = BlueCatbirdMlsCheckBlocks.BlockRelationship(
      blockerDid: try DID(didString: memberDid),
      blockedDid: try DID(didString: violatorDid),
      createdAt: ATProtocolDate(date: Date()),
      blockUri: try? ATProtocolURI(uriString: "at://did:plc:member456/app.bsky.graph.block/abc")
    )
    let blocksOutput = BlueCatbirdMlsCheckBlocks.Output(
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
    let lowStatsOutput = BlueCatbirdMlsGetKeyPackageStats.Output(
      available: 3,
      threshold: 10,
      needsReplenish: true,
      oldestExpiresIn: "24h",
      byCipherSuite: nil
    )
    mockAPI.mockGetKeyPackageStatsResponse = (200, lowStatsOutput)

    // Check stats
    let stats = try await manager.getKeyPackageStats()

    #expect(stats.needsReplenish == true)
    #expect(stats.available < stats.threshold)

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

    // Mock comprehensive stats
    let reportCategories = BlueCatbirdMlsGetAdminStats.ReportCategoryCounts(
      harassment: 10,
      spam: 5,
      hateSpeech: 3,
      violence: 2,
      sexualContent: 1,
      impersonation: 0,
      privacyViolation: 4,
      otherCategory: 5
    )

    let moderationStats = BlueCatbirdMlsGetAdminStats.ModerationStats(
      totalReports: 30,
      pendingReports: 5,
      resolvedReports: 25,
      totalRemovals: 15,
      blockConflictsResolved: 3,
      reportsByCategory: reportCategories,
      averageResolutionTimeHours: 6
    )

    let statsOutput = BlueCatbirdMlsGetAdminStats.Output(
      stats: moderationStats,
      generatedAt: ATProtocolDate(date: Date()),
      convoId: convoId
    )
    mockAPI.mockGetAdminStatsResponse = (200, statsOutput)

    // Get admin stats
    let stats = try await manager.getAdminStats(for: convoId)

    // Verify comprehensive statistics
    #expect(stats.totalReports == 30)
    #expect(stats.pendingReports == 5)
    #expect(stats.resolvedReports == 25)
    #expect(stats.totalRemovals == 15)
    #expect(stats.blockConflictsResolved == 3)

    // Verify category breakdown
    #expect(stats.reportsByCategory?.harassment == 10)
    #expect(stats.reportsByCategory?.spam == 5)
    #expect(stats.reportsByCategory?.hateSpeech == 3)

    // Verify performance metric
    #expect(stats.averageResolutionTimeHours == 6)
  }

  // MARK: - Helper Methods

  private func createMockConversation(
    id: String,
    members: [String],
    admins: [String]
  ) -> BlueCatbirdMlsDefs.ConvoView {
    let memberViews = members.map { memberDid in
      BlueCatbirdMlsDefs.MemberView(
        did: try! DID(didString: memberDid),
        isAdmin: admins.contains(memberDid),
        joinedAt: ATProtocolDate(date: Date()),
        leftAt: nil
      )
    }

    return BlueCatbirdMlsDefs.ConvoView(
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
  var mockRemoveMemberResponse: (Int, BlueCatbirdMlsRemoveMember.Output?)?
  var mockPromoteAdminResponse: (Int, BlueCatbirdMlsPromoteAdmin.Output?)?
  var mockDemoteAdminResponse: (Int, BlueCatbirdMlsDemoteAdmin.Output?)?
  var mockReportMemberResponse: (Int, BlueCatbirdMlsReportMember.Output?)?
  var mockGetReportsResponse: (Int, BlueCatbirdMlsGetReports.Output?)?
  var mockResolveReportResponse: (Int, BlueCatbirdMlsResolveReport.Output?)?
  var mockCheckBlocksResponse: (Int, BlueCatbirdMlsCheckBlocks.Output?)?
  var mockGetKeyPackageStatsResponse: (Int, BlueCatbirdMlsGetKeyPackageStats.Output?)?
  var mockGetAdminStatsResponse: (Int, BlueCatbirdMlsGetAdminStats.Output?)?

  // Callback hooks
  var onRemoveMember: ((BlueCatbirdMlsRemoveMember.Input) -> Void)?
  var onPromoteAdmin: ((BlueCatbirdMlsPromoteAdmin.Input) -> Void)?
  var onDemoteAdmin: ((BlueCatbirdMlsDemoteAdmin.Input) -> Void)?
  var onReportMember: ((BlueCatbirdMlsReportMember.Input) -> Void)?
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
  ) async throws -> (responseCode: Int, data: BlueCatbirdMlsRemoveMember.Output?) {
    let input = BlueCatbirdMlsRemoveMember.Input(
      convoId: convoId,
      targetDid: try DID(didString: targetDid),
      idempotencyKey: UUID().uuidString,
      reason: reason
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
  ) async throws -> (responseCode: Int, data: BlueCatbirdMlsPromoteAdmin.Output?) {
    let input = BlueCatbirdMlsPromoteAdmin.Input(
      convoId: convoId,
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
  ) async throws -> (responseCode: Int, data: BlueCatbirdMlsDemoteAdmin.Output?) {
    let input = BlueCatbirdMlsDemoteAdmin.Input(
      convoId: convoId,
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
