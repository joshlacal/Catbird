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
import PetrelCatbird
@testable import Catbird
@testable import CatbirdMLSCore

/// Test suite for MLS moderation and admin API endpoints
@Suite("MLS Moderation API Tests")
struct MLSModerationAPITests {

  // MARK: - Test Data

  let testConvoId = "test-convo-123"
  let testDid = "did:plc:test123"
  let testTargetDid = "did:plc:target456"

  func createMockATProtoClient() -> ATProtoClient {
    ATProtoClient(
      networkService: MockNetworkService(),
      authProvider: MockAuthProvider()
    )
  }

  // MARK: - Remove Member Tests

  @Test("removeMember - success case")
  func testRemoveMemberSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let (ok, epochHint) = try await apiClient.removeMember(
      convoId: testConvoId,
      targetDid: try DID(didString: testTargetDid),
      reason: "Violation of community guidelines"
    )

    #expect(ok == true)
  }

  // MARK: - Promote Admin Tests

  @Test("promoteAdmin - success case")
  func testPromoteAdminSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let success = try await apiClient.promoteAdmin(
      convoId: testConvoId,
      targetDid: try DID(didString: testTargetDid)
    )

    #expect(success == true)
  }

  // MARK: - Demote Admin Tests

  @Test("demoteAdmin - success case")
  func testDemoteAdminSuccess() async throws {
    let mockClient = createMockATProtoClient()
    let apiClient = MLSAPIClient(atProtoClient: mockClient)

    let success = try await apiClient.demoteAdmin(
      convoId: testConvoId,
      targetDid: try DID(didString: testTargetDid)
    )

    #expect(success == true)
  }
}

// MARK: - Supporting Mock Classes

final class MockNetworkService: NetworkService {
  // Minimal mock implementation
}

final class MockAuthProvider: AuthProvider {
  // Minimal mock implementation
}
