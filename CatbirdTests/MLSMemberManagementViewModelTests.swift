//
//  MLSMemberManagementViewModelTests.swift
//  CatbirdTests
//
//  Created by Josh LaCalamito on 10/21/24.
//

import XCTest
import Combine
@testable import Catbird

@MainActor
final class MLSMemberManagementViewModelTests: XCTestCase {
    var viewModel: MLSMemberManagementViewModel!
    var mockAPIClient: MockMLSAPIClientMember!
    var cancellables: Set<AnyCancellable>!
    let testConversationId = "test-convo-123"
    
    override func setUp() async throws {
        try await super.setUp()
        mockAPIClient = MockMLSAPIClientMember()
        viewModel = MLSMemberManagementViewModel(
            conversationId: testConversationId,
            apiClient: mockAPIClient
        )
        cancellables = Set<AnyCancellable>()
    }
    
    override func tearDown() async throws {
        cancellables.forEach { $0.cancel() }
        cancellables = nil
        viewModel = nil
        mockAPIClient = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitialization() {
        XCTAssertEqual(viewModel.conversationId, testConversationId)
        XCTAssertNil(viewModel.conversation)
        XCTAssertTrue(viewModel.members.isEmpty)
        XCTAssertFalse(viewModel.isLoadingMembers)
        XCTAssertFalse(viewModel.isAddingMembers)
        XCTAssertNil(viewModel.error)
    }
    
    // MARK: - Load Members Tests
    
    func testLoadMembersSuccess() async {
        // Given
        let mockConvo = createMockConversation(memberCount: 3)
        mockAPIClient.mockConversation = mockConvo
        
        let expectation = XCTestExpectation(description: "Members loaded")
        viewModel.membersUpdatedPublisher.sink { members in
            XCTAssertEqual(members.count, 3)
            expectation.fulfill()
        }.store(in: &cancellables)
        
        // When
        await viewModel.loadMembers()
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(viewModel.members.count, 3)
        XCTAssertFalse(viewModel.isLoadingMembers)
        XCTAssertNil(viewModel.error)
    }
    
    func testLoadMembersNotFound() async {
        // Given
        mockAPIClient.mockConversation = nil
        
        let expectation = XCTestExpectation(description: "Error received")
        viewModel.errorPublisher.sink { error in
            XCTAssertNotNil(error)
            expectation.fulfill()
        }.store(in: &cancellables)
        
        // When
        await viewModel.loadMembers()
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNotNil(viewModel.error)
        XCTAssertTrue(viewModel.members.isEmpty)
    }
    
    // MARK: - Add Members Tests
    
    func testAddMembersSuccess() async {
        // Given
        let initialConvo = createMockConversation(memberCount: 2)
        mockAPIClient.mockConversation = initialConvo
        await viewModel.loadMembers()
        
        let newMembers = ["did:plc:newmember1", "did:plc:newmember2"]
        let updatedConvo = createMockConversation(memberCount: 4)
        mockAPIClient.mockUpdatedConversation = updatedConvo
        
        let expectation = XCTestExpectation(description: "Members added")
        var callCount = 0
        viewModel.membersUpdatedPublisher.sink { members in
            callCount += 1
            if callCount == 2 { // Skip initial load, wait for update
                XCTAssertEqual(members.count, 4)
                expectation.fulfill()
            }
        }.store(in: &cancellables)
        
        // When
        await viewModel.addMembers(newMembers)
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(viewModel.members.count, 4)
        XCTAssertFalse(viewModel.isAddingMembers)
        XCTAssertEqual(mockAPIClient.addMembersCallCount, 1)
    }
    
    func testAddMembersFailure() async {
        // Given
        let initialConvo = createMockConversation(memberCount: 2)
        mockAPIClient.mockConversation = initialConvo
        await viewModel.loadMembers()
        
        mockAPIClient.shouldFailAddMembers = true
        
        let expectation = XCTestExpectation(description: "Error received")
        var errorReceived = false
        viewModel.errorPublisher.sink { error in
            if !errorReceived {
                errorReceived = true
                expectation.fulfill()
            }
        }.store(in: &cancellables)
        
        // When
        await viewModel.addMembers(["did:plc:newmember"])
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNotNil(viewModel.error)
        XCTAssertFalse(viewModel.isAddingMembers)
    }
    
    func testAddEmptyMembersList() async {
        // Given
        let initialConvo = createMockConversation(memberCount: 2)
        mockAPIClient.mockConversation = initialConvo
        await viewModel.loadMembers()
        
        // When
        await viewModel.addMembers([])
        
        // Then
        XCTAssertEqual(mockAPIClient.addMembersCallCount, 0)
    }
    
    // MARK: - Pending Members Tests
    
    func testAddPendingMember() async {
        // When
        await viewModel.addPendingMember("did:plc:pending1")
        
        // Then
        XCTAssertEqual(viewModel.pendingMembers.count, 1)
        XCTAssertTrue(viewModel.pendingMembers.contains("did:plc:pending1"))
    }
    
    func testAddDuplicatePendingMember() async {
        // Given
        await viewModel.addPendingMember("did:plc:pending1")
        
        // When
        await viewModel.addPendingMember("did:plc:pending1")
        
        // Then
        XCTAssertEqual(viewModel.pendingMembers.count, 1)
    }
    
    func testAddExistingMemberAsPending() async {
        // Given
        let convo = createMockConversation(memberCount: 2)
        mockAPIClient.mockConversation = convo
        await viewModel.loadMembers()
        
        let existingMemberDid = convo.members[0].did
        
        // When
        await viewModel.addPendingMember(existingMemberDid)
        
        // Then
        XCTAssertTrue(viewModel.pendingMembers.isEmpty)
    }
    
    func testRemovePendingMember() async {
        // Given
        await viewModel.addPendingMember("did:plc:pending1")
        await viewModel.addPendingMember("did:plc:pending2")
        
        // When
        await viewModel.removePendingMember("did:plc:pending1")
        
        // Then
        XCTAssertEqual(viewModel.pendingMembers.count, 1)
        XCTAssertFalse(viewModel.pendingMembers.contains("did:plc:pending1"))
        XCTAssertTrue(viewModel.pendingMembers.contains("did:plc:pending2"))
    }
    
    func testCommitPendingMembers() async {
        // Given
        let initialConvo = createMockConversation(memberCount: 2)
        mockAPIClient.mockConversation = initialConvo
        await viewModel.loadMembers()
        
        await viewModel.addPendingMember("did:plc:pending1")
        await viewModel.addPendingMember("did:plc:pending2")
        
        let updatedConvo = createMockConversation(memberCount: 4)
        mockAPIClient.mockUpdatedConversation = updatedConvo
        
        // When
        await viewModel.commitPendingMembers()
        
        // Then
        XCTAssertTrue(viewModel.pendingMembers.isEmpty)
        XCTAssertEqual(mockAPIClient.addMembersCallCount, 1)
    }
    
    func testCommitEmptyPendingMembers() async {
        // When
        await viewModel.commitPendingMembers()
        
        // Then
        XCTAssertEqual(mockAPIClient.addMembersCallCount, 0)
    }
    
    // MARK: - Search Tests
    
    func testSearchWithValidDID() async {
        // Given
        let convo = createMockConversation(memberCount: 2)
        mockAPIClient.mockConversation = convo
        await viewModel.loadMembers()
        
        // When
        viewModel.memberSearchQuery = "did:plc:newmember"
        try? await Task.sleep(nanoseconds: 400_000_000)
        
        // Then
        XCTAssertEqual(viewModel.searchResults.count, 1)
        XCTAssertEqual(viewModel.searchResults.first, "did:plc:newmember")
    }
    
    func testSearchExcludesExistingMembers() async {
        // Given
        let convo = createMockConversation(memberCount: 2)
        mockAPIClient.mockConversation = convo
        await viewModel.loadMembers()
        
        let existingMemberDid = convo.members[0].did
        
        // When
        viewModel.memberSearchQuery = existingMemberDid
        try? await Task.sleep(nanoseconds: 400_000_000)
        
        // Then
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }
    
    func testSearchWithInvalidDID() async {
        // When
        viewModel.memberSearchQuery = "invalid"
        try? await Task.sleep(nanoseconds: 400_000_000)
        
        // Then
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }
    
    func testClearSearch() async {
        // Given
        viewModel.memberSearchQuery = "did:plc:test"
        try? await Task.sleep(nanoseconds: 400_000_000)
        
        // When
        await viewModel.clearSearch()
        
        // Then
        XCTAssertEqual(viewModel.memberSearchQuery, "")
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }
    
    // MARK: - Permission Tests
    
    func testCanManageMembersAsCreator() {
        // Given
        let creatorDid = "did:plc:creator"
        let convo = createMockConversation(memberCount: 2, creator: creatorDid)
        mockAPIClient.mockConversation = convo
        
        // Need to load conversation first
        Task {
            await viewModel.loadMembers()
            
            // Then
            XCTAssertTrue(viewModel.canManageMembers(userDid: creatorDid))
        }
    }
    
    func testCannotManageMembersAsNonCreator() {
        // Given
        let convo = createMockConversation(memberCount: 2, creator: "did:plc:creator")
        mockAPIClient.mockConversation = convo
        
        Task {
            await viewModel.loadMembers()
            
            // Then
            XCTAssertFalse(viewModel.canManageMembers(userDid: "did:plc:othermember"))
        }
    }
    
    // MARK: - Validation Tests
    
    func testValidateDid() {
        XCTAssertTrue(viewModel.validateDid("did:plc:test123"))
        XCTAssertTrue(viewModel.validateDid("did:web:example.com"))
        XCTAssertFalse(viewModel.validateDid("invalid"))
        XCTAssertFalse(viewModel.validateDid("did:"))
        XCTAssertFalse(viewModel.validateDid(""))
    }
    
    // MARK: - Display Name Tests
    
    func testGetMemberDisplayName() {
        // Given
        let member = MLSMemberView(
            did: "did:plc:test123",
            joinedAt: Date(),
            leafIndex: 0,
            credential: nil
        )
        
        // When
        let displayName = viewModel.getMemberDisplayName(member)
        
        // Then
        XCTAssertEqual(displayName, "did:plc:test123")
    }
    
    // MARK: - Refresh Tests
    
    func testRefresh() async {
        // Given
        let initialConvo = createMockConversation(memberCount: 2)
        mockAPIClient.mockConversation = initialConvo
        await viewModel.loadMembers()
        
        let updatedConvo = createMockConversation(memberCount: 4)
        mockAPIClient.mockConversation = updatedConvo
        
        // When
        await viewModel.refresh()
        
        // Then
        XCTAssertEqual(viewModel.members.count, 4)
    }
    
    // MARK: - Helper Methods
    
    private func createMockConversation(memberCount: Int, creator: String = "did:plc:creator") -> MLSConvoView {
        let members = (0..<memberCount).map { index in
            MLSMemberView(
                did: "did:plc:member\(index)",
                joinedAt: Date(),
                leafIndex: index,
                credential: nil
            )
        }
        
        return MLSConvoView(
            id: testConversationId,
            groupId: "group-123",
            creator: creator,
            members: members,
            epoch: 1,
            cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
            createdAt: Date(),
            lastMessageAt: Date(),
            metadata: MLSConvoMetadata(name: "Test Conversation", description: nil, avatar: nil)
        )
    }
}

// MARK: - Mock API Client

class MockMLSAPIClientMember: MLSAPIClient {
    var mockConversation: MLSConvoView?
    var mockUpdatedConversation: MLSConvoView?
    var shouldFailAddMembers = false
    var addMembersCallCount = 0
    
    override func getConversations(
        limit: Int = 50,
        cursor: String? = nil,
        sortBy: String = "lastMessageAt",
        sortOrder: String = "desc"
    ) async throws -> (convos: [MLSConvoView], cursor: String?) {
        if let convo = mockConversation {
            return ([convo], nil)
        }
        throw NSError(domain: "TestError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Not found"])
    }
    
    override func addMembers(
        convoId: String,
        members: [String]
    ) async throws -> MLSAddMembersResponse {
        addMembersCallCount += 1
        
        if shouldFailAddMembers {
            throw NSError(domain: "TestError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Add members failed"])
        }
        
        guard let convo = mockUpdatedConversation else {
            throw NSError(domain: "TestError", code: 500, userInfo: [NSLocalizedDescriptionKey: "No mock conversation"])
        }
        
        return MLSAddMembersResponse(
            convo: convo,
            commit: "mock-commit",
            welcomeMessages: []
        )
    }
}
