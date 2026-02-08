//
//  MLSConversationListViewModelTests.swift
//  CatbirdTests
//
//  Created by Josh LaCalamito on 10/21/24.
//

import XCTest
import Combine
@testable import Catbird

@MainActor
final class MLSConversationListViewModelTests: XCTestCase {
    var viewModel: MLSConversationListViewModel!
    var mockAPIClient: MockMLSAPIClient!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        mockAPIClient = MockMLSAPIClient()
        viewModel = MLSConversationListViewModel(apiClient: mockAPIClient)
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
        XCTAssertTrue(viewModel.conversations.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertEqual(viewModel.searchQuery, "")
    }
    
    // MARK: - Load Conversations Tests
    
    func testLoadConversationsSuccess() async {
        // Given
        let mockConversations = createMockConversations(count: 3)
        mockAPIClient.mockConversations = mockConversations
        mockAPIClient.mockCursor = "cursor123"
        
        let expectation = XCTestExpectation(description: "Conversations loaded")
        viewModel.conversationsPublisher.sink { conversations in
            XCTAssertEqual(conversations.count, 3)
            expectation.fulfill()
        }.store(in: &cancellables)
        
        // When
        await viewModel.loadConversations()
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(viewModel.conversations.count, 3)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
        XCTAssertTrue(viewModel.hasMore)
    }
    
    func testLoadConversationsFailure() async {
        // Given
        mockAPIClient.shouldFail = true
        
        let expectation = XCTestExpectation(description: "Error received")
        viewModel.errorPublisher.sink { error in
            XCTAssertNotNil(error)
            expectation.fulfill()
        }.store(in: &cancellables)
        
        // When
        await viewModel.loadConversations()
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertTrue(viewModel.conversations.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNotNil(viewModel.error)
    }
    
    func testLoadConversationsWhileLoading() async {
        // Given
        mockAPIClient.delayResponse = true
        
        // When
        async let firstLoad: () = viewModel.loadConversations()
        async let secondLoad: () = viewModel.loadConversations()
        
        await firstLoad
        await secondLoad
        
        // Then - Second call should be ignored
        XCTAssertEqual(mockAPIClient.getConversationsCallCount, 1)
    }
    
    // MARK: - Pagination Tests
    
    func testLoadMoreConversations() async {
        // Given
        let initialConversations = createMockConversations(count: 2)
        mockAPIClient.mockConversations = initialConversations
        mockAPIClient.mockCursor = "cursor1"
        await viewModel.loadConversations()
        
        let moreConversations = createMockConversations(count: 2, startIndex: 2)
        mockAPIClient.mockConversations = moreConversations
        mockAPIClient.mockCursor = nil
        
        // When
        await viewModel.loadMoreConversations()
        
        // Then
        XCTAssertEqual(viewModel.conversations.count, 4)
        XCTAssertFalse(viewModel.hasMore)
    }
    
    func testLoadMoreConversationsWithoutCursor() async {
        // Given
        mockAPIClient.mockCursor = nil
        await viewModel.loadConversations()
        
        let initialCount = viewModel.conversations.count
        
        // When
        await viewModel.loadMoreConversations()
        
        // Then - Should not load more
        XCTAssertEqual(viewModel.conversations.count, initialCount)
    }
    
    // MARK: - Search Tests
    
    func testSearchFiltersConversations() async {
        // Given
        let conversations = [
            createMockConversation(id: "1", name: "Test Group"),
            createMockConversation(id: "2", name: "Work Chat"),
            createMockConversation(id: "3", name: "Test Team")
        ]
        mockAPIClient.mockConversations = conversations
        await viewModel.loadConversations()
        
        // When
        viewModel.searchQuery = "Test"
        try? await Task.sleep(nanoseconds: 100_000_000) // Wait for search
        
        // Then
        XCTAssertEqual(viewModel.filteredConversations.count, 2)
    }
    
    func testSearchWithEmptyQuery() async {
        // Given
        let conversations = createMockConversations(count: 3)
        mockAPIClient.mockConversations = conversations
        await viewModel.loadConversations()
        
        // When
        viewModel.searchQuery = ""
        
        // Then
        XCTAssertEqual(viewModel.filteredConversations.count, 3)
    }
    
    // MARK: - Refresh Tests
    
    func testRefresh() async {
        // Given
        let initialConversations = createMockConversations(count: 2)
        mockAPIClient.mockConversations = initialConversations
        mockAPIClient.mockCursor = "cursor1"
        await viewModel.loadConversations()
        
        let newConversations = createMockConversations(count: 3)
        mockAPIClient.mockConversations = newConversations
        mockAPIClient.mockCursor = nil
        
        // When
        await viewModel.refresh()
        
        // Then
        XCTAssertEqual(viewModel.conversations.count, 3)
        XCTAssertFalse(viewModel.hasMore)
    }
    
    // MARK: - Update/Delete Tests
    
    func testUpdateConversation() async {
        // Given
        let conversations = createMockConversations(count: 3)
        mockAPIClient.mockConversations = conversations
        await viewModel.loadConversations()
        
        var updatedConvo = conversations[1]
        let updatedMetadata = MLSConvoMetadata(name: "Updated Name", description: nil, avatar: nil)
        updatedConvo = MLSConvoView(
            id: updatedConvo.id,
            groupId: updatedConvo.groupId,
            creator: updatedConvo.creator,
            members: updatedConvo.members,
            epoch: updatedConvo.epoch,
            cipherSuite: updatedConvo.cipherSuite,
            createdAt: updatedConvo.createdAt,
            lastMessageAt: updatedConvo.lastMessageAt,
            metadata: updatedMetadata
        )
        
        // When
        await viewModel.updateConversation(updatedConvo)
        
        // Then
        XCTAssertEqual(viewModel.conversations[1].metadata?.name, "Updated Name")
    }
    
    func testDeleteConversationLocally() async {
        // Given
        let conversations = createMockConversations(count: 3)
        mockAPIClient.mockConversations = conversations
        await viewModel.loadConversations()
        
        let convoToDelete = conversations[1].id
        
        // When
        await viewModel.deleteConversationLocally(conversationId: convoToDelete)
        
        // Then
        XCTAssertEqual(viewModel.conversations.count, 2)
        XCTAssertFalse(viewModel.conversations.contains { $0.id == convoToDelete })
    }
    
    func testAddConversation() async {
        // Given
        let conversations = createMockConversations(count: 2)
        mockAPIClient.mockConversations = conversations
        await viewModel.loadConversations()
        
        let newConvo = createMockConversation(id: "new-convo", name: "New Conversation")
        
        // When
        await viewModel.addConversation(newConvo)
        
        // Then
        XCTAssertEqual(viewModel.conversations.count, 3)
        XCTAssertEqual(viewModel.conversations.first?.id, "new-convo")
    }
    
    // MARK: - Helper Methods
    
    private func createMockConversations(count: Int, startIndex: Int = 0) -> [MLSConvoView] {
        (startIndex..<(startIndex + count)).map { index in
            createMockConversation(id: "convo-\(index)", name: "Conversation \(index)")
        }
    }
    
    private func createMockConversation(id: String, name: String) -> MLSConvoView {
        MLSConvoView(
            id: id,
            groupId: "group-\(id)",
            creator: "did:plc:creator",
            members: [
                MLSMemberView(did: "did:plc:member1", joinedAt: Date(), leafIndex: 0, credential: nil)
            ],
            epoch: 1,
            cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
            createdAt: Date(),
            lastMessageAt: Date(),
            metadata: MLSConvoMetadata(name: name, description: nil, avatar: nil)
        )
    }
}

// MARK: - Mock API Client

class MockMLSAPIClient: MLSAPIClient {
    var mockConversations: [MLSConvoView] = []
    var mockCursor: String?
    var shouldFail = false
    var delayResponse = false
    var getConversationsCallCount = 0
    
    override func getConversations(
        limit: Int = 50,
        cursor: String? = nil,
        sortBy: String = "lastMessageAt",
        sortOrder: String = "desc"
    ) async throws -> (convos: [MLSConvoView], cursor: String?) {
        getConversationsCallCount += 1
        
        if delayResponse {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
        
        if shouldFail {
            throw NSError(domain: "TestError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Mock error"])
        }
        
        return (mockConversations, mockCursor)
    }
}
