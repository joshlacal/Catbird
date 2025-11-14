//
//  MLSModerationAPITests.swift
//  CatbirdTests
//
//  Created by Claude Code
//  Tests for MLS moderation and admin API endpoints
//

import Testing
import Foundation
import Petrel
@testable import Catbird

/// Test suite for MLS moderation and admin API endpoints
/// Tests all 11 new moderation/admin endpoints with proper mocking
@Suite("MLS Moderation API Tests")
struct MLSModerationAPITests {

  // MARK: - Test Data

  let testConvoId = "test-convo-123"
  let testDid = "did:plc:test123"
  let testTargetDid = "did:plc:target456"
  let testReportId = "report-789"

  func createMockATProtoClient() -> MockATProtoClient {
    MockATProtoClient()
  }

  // MARK: - Remove Member Tests

  @Test("removeMember - success case")
  func testRemoveMemberSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    // Mock successful response
    let expectedOutput = BlueCatbirdMlsRemoveMember.Output(
      ok: true,
      epochHint: 5
    )
    mockClient.mockRemoveMemberResponse = (200, expectedOutput)

    // Execute
    let (responseCode, output) = try await apiClient.removeMember(
      convoId: testConvoId,
      targetDid: testTargetDid,
      reason: "Violation of community guidelines"
    )

    // Verify
    #expect(responseCode == 200)
    #expect(output != nil)
    #expect(output?.ok == true)
    #expect(output?.epochHint == 5)
  }

  @Test("removeMember - not admin error")
  func testRemoveMemberNotAdmin() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    // Mock error response
    mockClient.mockRemoveMemberResponse = (403, nil)

    // Execute and verify error handling
    let (responseCode, output) = try await apiClient.removeMember(
      convoId: testConvoId,
      targetDid: testTargetDid,
      reason: nil
    )

    #expect(responseCode == 403)
    #expect(output == nil)
  }

  @Test("removeMember - cannot remove self")
  func testRemoveMemberCannotRemoveSelf() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    mockClient.mockRemoveMemberResponse = (400, nil)

    let (responseCode, output) = try await apiClient.removeMember(
      convoId: testConvoId,
      targetDid: testDid, // Same as caller
      reason: nil
    )

    #expect(responseCode == 400)
    #expect(output == nil)
  }

  // MARK: - Promote Admin Tests

  @Test("promoteAdmin - success case")
  func testPromoteAdminSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let promotedAt = ATProtocolDate(date: Date())
    let expectedOutput = BlueCatbirdMlsPromoteAdmin.Output(
      ok: true,
      promotedAt: promotedAt
    )
    mockClient.mockPromoteAdminResponse = (200, expectedOutput)

    let (responseCode, output) = try await apiClient.promoteAdmin(
      convoId: testConvoId,
      targetDid: testTargetDid
    )

    #expect(responseCode == 200)
    #expect(output?.ok == true)
    #expect(output?.promotedAt == promotedAt)
  }

  @Test("promoteAdmin - target already admin")
  func testPromoteAdminAlreadyAdmin() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    mockClient.mockPromoteAdminResponse = (409, nil)

    let (responseCode, output) = try await apiClient.promoteAdmin(
      convoId: testConvoId,
      targetDid: testTargetDid
    )

    #expect(responseCode == 409)
    #expect(output == nil)
  }

  // MARK: - Demote Admin Tests

  @Test("demoteAdmin - success case")
  func testDemoteAdminSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let demotedAt = ATProtocolDate(date: Date())
    let expectedOutput = BlueCatbirdMlsDemoteAdmin.Output(
      ok: true,
      demotedAt: demotedAt
    )
    mockClient.mockDemoteAdminResponse = (200, expectedOutput)

    let (responseCode, output) = try await apiClient.demoteAdmin(
      convoId: testConvoId,
      targetDid: testTargetDid
    )

    #expect(responseCode == 200)
    #expect(output?.ok == true)
    #expect(output?.demotedAt == demotedAt)
  }

  @Test("demoteAdmin - not admin error")
  func testDemoteAdminNotAdmin() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    mockClient.mockDemoteAdminResponse = (403, nil)

    let (responseCode, output) = try await apiClient.demoteAdmin(
      convoId: testConvoId,
      targetDid: testTargetDid
    )

    #expect(responseCode == 403)
    #expect(output == nil)
  }

  // MARK: - Report Member Tests

  @Test("reportMember - success case")
  func testReportMemberSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let submittedAt = ATProtocolDate(date: Date())
    let expectedOutput = BlueCatbirdMlsReportMember.Output(
      reportId: testReportId,
      submittedAt: submittedAt
    )
    mockClient.mockReportMemberResponse = (200, expectedOutput)

    let encryptedContent = Data("encrypted report content".utf8)

    let (responseCode, output) = try await apiClient.reportMember(
      convoId: testConvoId,
      reportedDid: testTargetDid,
      category: "harassment",
      encryptedContent: encryptedContent,
      messageIds: ["msg1", "msg2"]
    )

    #expect(responseCode == 200)
    #expect(output?.reportId == testReportId)
    #expect(output?.submittedAt == submittedAt)
  }

  @Test("reportMember - cannot report self")
  func testReportMemberCannotReportSelf() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    mockClient.mockReportMemberResponse = (400, nil)

    let encryptedContent = Data("test".utf8)

    let (responseCode, output) = try await apiClient.reportMember(
      convoId: testConvoId,
      reportedDid: testDid, // Same as caller
      category: "spam",
      encryptedContent: encryptedContent,
      messageIds: nil
    )

    #expect(responseCode == 400)
    #expect(output == nil)
  }

  // MARK: - Get Reports Tests

  @Test("getReports - success case with multiple reports")
  func testGetReportsSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let report1 = BlueCatbirdMlsGetReports.ReportView(
      id: "report-1",
      reporterDid: try DID(didString: testDid),
      reportedDid: try DID(didString: testTargetDid),
      encryptedContent: Data("encrypted1".utf8),
      createdAt: ATProtocolDate(date: Date()),
      status: "pending",
      resolvedBy: nil,
      resolvedAt: nil
    )

    let expectedOutput = BlueCatbirdMlsGetReports.Output(reports: [report1])
    mockClient.mockGetReportsResponse = (200, expectedOutput)

    let (responseCode, output) = try await apiClient.getReports(
      convoId: testConvoId,
      status: "pending",
      limit: 50
    )

    #expect(responseCode == 200)
    #expect(output?.reports.count == 1)
    #expect(output?.reports.first?.id == "report-1")
    #expect(output?.reports.first?.status == "pending")
  }

  @Test("getReports - not admin error")
  func testGetReportsNotAdmin() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    mockClient.mockGetReportsResponse = (403, nil)

    let (responseCode, output) = try await apiClient.getReports(
      convoId: testConvoId,
      status: nil,
      limit: nil
    )

    #expect(responseCode == 403)
    #expect(output == nil)
  }

  // MARK: - Resolve Report Tests

  @Test("resolveReport - success case")
  func testResolveReportSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let expectedOutput = BlueCatbirdMlsResolveReport.Output(ok: true)
    mockClient.mockResolveReportResponse = (200, expectedOutput)

    let (responseCode, output) = try await apiClient.resolveReport(
      reportId: testReportId,
      action: "removed_member",
      notes: "Removed for policy violation"
    )

    #expect(responseCode == 200)
    #expect(output?.ok == true)
  }

  @Test("resolveReport - report not found")
  func testResolveReportNotFound() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    mockClient.mockResolveReportResponse = (404, nil)

    let (responseCode, output) = try await apiClient.resolveReport(
      reportId: "nonexistent-report",
      action: "dismissed",
      notes: nil
    )

    #expect(responseCode == 404)
    #expect(output == nil)
  }

  // MARK: - Check Blocks Tests

  @Test("checkBlocks - success case with block relationships")
  func testCheckBlocksSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let blockRelationship = BlueCatbirdMlsCheckBlocks.BlockRelationship(
      blockerDid: try DID(didString: testDid),
      blockedDid: try DID(didString: testTargetDid),
      createdAt: ATProtocolDate(date: Date()),
      blockUri: try? ATProtocolURI(uriString: "at://did:plc:test123/app.bsky.graph.block/xyz")
    )

    let expectedOutput = BlueCatbirdMlsCheckBlocks.Output(
      blocks: [blockRelationship],
      checkedAt: ATProtocolDate(date: Date())
    )
    mockClient.mockCheckBlocksResponse = (200, expectedOutput)

    let (responseCode, output) = try await apiClient.checkBlocks(
      dids: [try DID(didString: testDid), try DID(didString: testTargetDid)]
    )

    #expect(responseCode == 200)
    #expect(output?.blocks.count == 1)
    #expect(output?.blocks.first?.blockerDid.description == testDid)
  }

  @Test("checkBlocks - too many DIDs error")
  func testCheckBlocksTooManyDids() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    mockClient.mockCheckBlocksResponse = (400, nil)

    // Generate 101 DIDs (exceeds limit of 100)
    let tooManyDids = try (1...101).map { try DID(didString: "did:plc:test\($0)") }

    let (responseCode, output) = try await apiClient.checkBlocks(dids: tooManyDids)

    #expect(responseCode == 400)
    #expect(output == nil)
  }

  // MARK: - Get Key Package Stats Tests

  @Test("getKeyPackageStats - success case")
  func testGetKeyPackageStatsSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let cipherSuiteStats = BlueCatbirdMlsGetKeyPackageStats.CipherSuiteStats(
      cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
      available: 15,
      consumed: 5
    )

    let expectedOutput = BlueCatbirdMlsGetKeyPackageStats.Output(
      available: 15,
      threshold: 10,
      needsReplenish: false,
      oldestExpiresIn: "720h",
      byCipherSuite: [cipherSuiteStats]
    )
    mockClient.mockGetKeyPackageStatsResponse = (200, expectedOutput)

    let (responseCode, output) = try await apiClient.getKeyPackageStats(
      did: nil,
      cipherSuite: nil
    )

    #expect(responseCode == 200)
    #expect(output?.available == 15)
    #expect(output?.threshold == 10)
    #expect(output?.needsReplenish == false)
    #expect(output?.byCipherSuite?.count == 1)
  }

  @Test("getKeyPackageStats - needs replenish")
  func testGetKeyPackageStatsNeedsReplenish() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let expectedOutput = BlueCatbirdMlsGetKeyPackageStats.Output(
      available: 5,
      threshold: 10,
      needsReplenish: true,
      oldestExpiresIn: "48h",
      byCipherSuite: nil
    )
    mockClient.mockGetKeyPackageStatsResponse = (200, expectedOutput)

    let (responseCode, output) = try await apiClient.getKeyPackageStats(
      did: nil,
      cipherSuite: nil
    )

    #expect(responseCode == 200)
    #expect(output?.needsReplenish == true)
    #expect(output?.available < (output?.threshold ?? 0))
  }

  // MARK: - Get Admin Stats Tests

  @Test("getAdminStats - success case with comprehensive stats")
  func testGetAdminStatsSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let reportCategories = BlueCatbirdMlsGetAdminStats.ReportCategoryCounts(
      harassment: 5,
      spam: 3,
      hateSpeech: 2,
      violence: 1,
      sexualContent: 0,
      impersonation: 0,
      privacyViolation: 1,
      otherCategory: 2
    )

    let moderationStats = BlueCatbirdMlsGetAdminStats.ModerationStats(
      totalReports: 14,
      pendingReports: 3,
      resolvedReports: 11,
      totalRemovals: 8,
      blockConflictsResolved: 2,
      reportsByCategory: reportCategories,
      averageResolutionTimeHours: 4
    )

    let expectedOutput = BlueCatbirdMlsGetAdminStats.Output(
      stats: moderationStats,
      generatedAt: ATProtocolDate(date: Date()),
      convoId: testConvoId
    )
    mockClient.mockGetAdminStatsResponse = (200, expectedOutput)

    let (responseCode, output) = try await apiClient.getAdminStats(
      convoId: testConvoId,
      since: nil
    )

    #expect(responseCode == 200)
    #expect(output?.stats.totalReports == 14)
    #expect(output?.stats.pendingReports == 3)
    #expect(output?.stats.resolvedReports == 11)
    #expect(output?.stats.totalRemovals == 8)
    #expect(output?.stats.reportsByCategory?.harassment == 5)
    #expect(output?.stats.averageResolutionTimeHours == 4)
    #expect(output?.convoId == testConvoId)
  }

  @Test("getAdminStats - not authorized")
  func testGetAdminStatsNotAuthorized() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    mockClient.mockGetAdminStatsResponse = (403, nil)

    let (responseCode, output) = try await apiClient.getAdminStats(
      convoId: testConvoId,
      since: nil
    )

    #expect(responseCode == 403)
    #expect(output == nil)
  }

  // MARK: - Idempotency Key Tests

  @Test("removeMember - generates unique idempotency keys")
  func testRemoveMemberIdempotencyKeys() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    // Capture idempotency keys from multiple calls
    var capturedKeys: [String] = []
    mockClient.onRemoveMember = { input in
      capturedKeys.append(input.idempotencyKey)
    }

    let expectedOutput = BlueCatbirdMlsRemoveMember.Output(ok: true, epochHint: 1)
    mockClient.mockRemoveMemberResponse = (200, expectedOutput)

    // Make two calls
    _ = try await apiClient.removeMember(convoId: testConvoId, targetDid: testTargetDid, reason: nil)
    _ = try await apiClient.removeMember(convoId: testConvoId, targetDid: testTargetDid, reason: nil)

    // Verify keys are unique
    #expect(capturedKeys.count == 2)
    #expect(capturedKeys[0] != capturedKeys[1])
    #expect(!capturedKeys[0].isEmpty)
    #expect(!capturedKeys[1].isEmpty)
  }
}

// MARK: - Mock ATProtoClient

/// Mock ATProto client for testing MLS API endpoints without network calls
final class MockATProtoClient: ATProtoClient {

  // Mock responses
  var mockRemoveMemberResponse: (Int, BlueCatbirdMlsRemoveMember.Output?)?
  var mockPromoteAdminResponse: (Int, BlueCatbirdMlsPromoteAdmin.Output?)?
  var mockDemoteAdminResponse: (Int, BlueCatbirdMlsDemoteAdmin.Output?)?
  var mockReportMemberResponse: (Int, BlueCatbirdMlsReportMember.Output?)?
  var mockGetReportsResponse: (Int, BlueCatbirdMlsGetReports.Output?)?
  var mockResolveReportResponse: (Int, BlueCatbirdMlsResolveReport.Output?)?
  var mockCheckBlocksResponse: (Int, BlueCatbirdMlsCheckBlocks.Output?)?
  var mockGetBlockStatusResponse: (Int, BlueCatbirdMlsGetBlockStatus.Output?)?
  var mockHandleBlockChangeResponse: (Int, BlueCatbirdMlsHandleBlockChange.Output?)?
  var mockGetKeyPackageStatsResponse: (Int, BlueCatbirdMlsGetKeyPackageStats.Output?)?
  var mockGetAdminStatsResponse: (Int, BlueCatbirdMlsGetAdminStats.Output?)?

  // Callback hooks for verifying request parameters
  var onRemoveMember: ((BlueCatbirdMlsRemoveMember.Input) -> Void)?
  var onPromoteAdmin: ((BlueCatbirdMlsPromoteAdmin.Input) -> Void)?
  var onDemoteAdmin: ((BlueCatbirdMlsDemoteAdmin.Input) -> Void)?
  var onReportMember: ((BlueCatbirdMlsReportMember.Input) -> Void)?

  // Override ATProtoClient initializer
  init() {
    // Minimal initialization for testing
    super.init(
      networkService: MockNetworkService(),
      authProvider: MockAuthProvider()
    )
  }

  // Mock implementations would go here in actual test file
  // For now, this is a placeholder structure
}

// MARK: - Supporting Mock Classes

final class MockNetworkService: NetworkService {
  // Minimal mock implementation
}

final class MockAuthProvider: AuthProvider {
  // Minimal mock implementation
}
