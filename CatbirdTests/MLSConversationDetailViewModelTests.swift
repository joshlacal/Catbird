//
//  MLSConversationDetailViewModelTests.swift
//  CatbirdTests
//
//  Created by Josh LaCalamito on 10/21/24.
//

import XCTest
import Combine
@testable import Catbird

@MainActor
final class MLSConversationDetailViewModelTests: XCTestCase {
    var viewModel: MLSConversationDetailViewModel!
    var mockAPIClient: MockMLSAPIClientDetail!
    var cancellables: Set<AnyCancellable>!
    let testConversationId = "test-convo-123"
    
    override func setUp() async throws {
        try await super.setUp()
        mockAPIClient = MockMLSAPIClientDetail()
        viewModel = MLSConversationDetailViewModel(
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
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.isLoadingConversation)
        XCTAssertFalse(viewModel.isLoadingMessages)
        XCTAssertFalse(viewModel.isSendingMessage)
        XCTAssertNil(viewModel.error)
    }
    
    // MARK: - Load Conversation Tests
    
    func testLoadConversationSuccess() async {
        // Given
        let mockConvo = createMockConversation()
        let mockMessages = createMockMessages(count: 5)
        mockAPIClient.mockConversation = mockConvo
        mockAPIClient.mockMessages = mockMessages
        
        let convoExpectation = XCTestExpectation(description: "Conversation loaded")
        viewModel.conversationPublisher.sink { conversation in
            XCTAssertEqual(conversation.id, self.testConversationId)
            convoExpectation.fulfill()
        }.store(in: &cancellables)
        
        let messagesExpectation = XCTestExpectation(description: "Messages loaded")
        viewModel.messagesPublisher.sink { messages in
            XCTAssertEqual(messages.count, 5)
            messagesExpectation.fulfill()
        }.store(in: &cancellables)
        
        // When
        await viewModel.loadConversation()
        
        // Then
        await fulfillment(of: [convoExpectation, messagesExpectation], timeout: 2.0)
        XCTAssertNotNil(viewModel.conversation)
        XCTAssertEqual(viewModel.messages.count, 5)
        XCTAssertFalse(viewModel.isLoadingConversation)
        XCTAssertNil(viewModel.error)
    }
    
    func testLoadConversationNotFound() async {
        // Given
        mockAPIClient.mockConversation = nil
        
        let expectation = XCTestExpectation(description: "Error received")
        viewModel.errorPublisher.sink { error in
            XCTAssertNotNil(error)
            expectation.fulfill()
        }.store(in: &cancellables)
        
        // When
        await viewModel.loadConversation()
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNil(viewModel.conversation)
        XCTAssertNotNil(viewModel.error)
    }
    
    // MARK: - Load Messages Tests
    
    func testLoadMessagesSuccess() async {
        // Given
        let mockMessages = createMockMessages(count: 10)
        mockAPIClient.mockMessages = mockMessages
        mockAPIClient.mockMessagesCursor = "cursor123"
        
        // When
        await viewModel.loadMessages()
        
        // Then
        XCTAssertEqual(viewModel.messages.count, 10)
        XCTAssertTrue(viewModel.hasMoreMessages)
        XCTAssertFalse(viewModel.isLoadingMessages)
    }
    
    func testLoadMoreMessages() async {
        // Given
        let initialMessages = createMockMessages(count: 5, startIndex: 0)
        mockAPIClient.mockMessages = initialMessages
        mockAPIClient.mockMessagesCursor = "cursor1"
        await viewModel.loadMessages()
        
        let moreMessages = createMockMessages(count: 5, startIndex: 5)
        mockAPIClient.mockMessages = moreMessages
        mockAPIClient.mockMessagesCursor = nil
        
        // When
        await viewModel.loadMoreMessages()
        
        // Then
        XCTAssertEqual(viewModel.messages.count, 10)
        XCTAssertFalse(viewModel.hasMoreMessages)
    }
    
    func testLoadMessagesReverseOrder() async {
        // Given
        let messages = createMockMessages(count: 3, startIndex: 0)
        mockAPIClient.mockMessages = messages
        
        // When
        await viewModel.loadMessages()
        
        // Then - Messages should be reversed (oldest first)
        XCTAssertEqual(viewModel.messages.first?.id, messages.last?.id)
        XCTAssertEqual(viewModel.messages.last?.id, messages.first?.id)
    }
    
    // MARK: - Send Message Tests
    
    func testSendMessageSuccess() async {
        // Given
        let messageText = "Hello, world!"
        let sentMessage = MLSMessageView(
            id: "msg-new",
            convoId: testConversationId,
            sender: "did:plc:sender",
            ciphertext: Data(messageText.utf8).base64EncodedString(),
            epoch: 1,
            createdAt: Date(),
            contentType: "text/plain",
            attachments: nil
        )
        mockAPIClient.mockSentMessage = sentMessage
        
        // When
        await viewModel.sendMessage(messageText)
        
        // Then
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.id, "msg-new")
        XCTAssertFalse(viewModel.isSendingMessage)
        XCTAssertNil(viewModel.error)
        XCTAssertEqual(viewModel.draftMessage, "")
    }
    
    func testSendEmptyMessage() async {
        // Given
        let emptyMessage = "   "
        
        // When
        await viewModel.sendMessage(emptyMessage)
        
        // Then
        XCTAssertEqual(mockAPIClient.sendMessageCallCount, 0)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }
    
    func testSendMessageWhileSending() async {
        // Given
        mockAPIClient.delayResponse = true
        
        // When
        async let firstSend: () = viewModel.sendMessage("First message")
        async let secondSend: () = viewModel.sendMessage("Second message")
        
        await firstSend
        await secondSend
        
        // Then
        XCTAssertEqual(mockAPIClient.sendMessageCallCount, 1)
    }
    
    // MARK: - Leave Conversation Tests
    
    func testLeaveConversationSuccess() async {
        // Given
        mockAPIClient.shouldFailLeave = false
        
        // When
        do {
            try await viewModel.leaveConversation()
            XCTAssertFalse(viewModel.isLeavingConversation)
        } catch {
            XCTFail("Should not throw error")
        }
        
        // Then
        XCTAssertEqual(mockAPIClient.leaveConversationCallCount, 1)
    }
    
    func testLeaveConversationFailure() async {
        // Given
        mockAPIClient.shouldFailLeave = true
        
        let expectation = XCTestExpectation(description: "Error received")
        viewModel.errorPublisher.sink { error in
            XCTAssertNotNil(error)
            expectation.fulfill()
        }.store(in: &cancellables)
        
        // When
        do {
            try await viewModel.leaveConversation()
            XCTFail("Should throw error")
        } catch {
            // Expected
        }
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNotNil(viewModel.error)
    }
    
    // MARK: - Typing Status Tests
    
    func testSetTypingTrue() async {
        // When
        await viewModel.setTyping(true)
        
        // Then
        XCTAssertTrue(viewModel.isTyping)
    }
    
    func testSetTypingFalse() async {
        // Given
        await viewModel.setTyping(true)
        
        // When
        await viewModel.setTyping(false)
        
        // Then
        XCTAssertFalse(viewModel.isTyping)
    }
    
    func testTypingTimerExpiration() async {
        // Given
        await viewModel.setTyping(true)
        XCTAssertTrue(viewModel.isTyping)
        
        // When - Wait for timer to expire
        try? await Task.sleep(nanoseconds: 3_500_000_000) // 3.5 seconds
        
        // Then
        XCTAssertFalse(viewModel.isTyping)
    }
    
    // MARK: - Refresh Tests
    
    func testRefresh() async {
        // Given
        let mockConvo = createMockConversation()
        let mockMessages = createMockMessages(count: 3)
        mockAPIClient.mockConversation = mockConvo
        mockAPIClient.mockMessages = mockMessages
        await viewModel.loadConversation()
        
        let newMessages = createMockMessages(count: 5)
        mockAPIClient.mockMessages = newMessages
        
        // When
        await viewModel.refresh()
        
        // Then
        XCTAssertEqual(viewModel.messages.count, 5)
        XCTAssertFalse(viewModel.hasMoreMessages)
    }
    
    // MARK: - Helper Methods
    
    private func createMockConversation() -> MLSConvoView {
        MLSConvoView(
            id: testConversationId,
            groupId: "group-123",
            creator: "did:plc:creator",
            members: [
                MLSMemberView(did: "did:plc:member1", joinedAt: Date(), leafIndex: 0, credential: nil),
                MLSMemberView(did: "did:plc:member2", joinedAt: Date(), leafIndex: 1, credential: nil)
            ],
            epoch: 1,
            cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
            createdAt: Date(),
            lastMessageAt: Date(),
            metadata: MLSConvoMetadata(name: "Test Conversation", description: nil, avatar: nil)
        )
    }
    
    private func createMockMessages(count: Int, startIndex: Int = 0) -> [MLSMessageView] {
        (startIndex..<(startIndex + count)).map { index in
            MLSMessageView(
                id: "msg-\(index)",
                convoId: testConversationId,
                sender: "did:plc:sender",
                ciphertext: "encrypted-\(index)",
                epoch: 1,
                createdAt: Date().addingTimeInterval(Double(index)),
                contentType: "text/plain",
                attachments: nil
            )
        }
    }
}

// MARK: - Mock API Client

class MockMLSAPIClientDetail: MLSAPIClient {
    var mockConversation: MLSConvoView?
    var mockMessages: [MLSMessageView] = []
    var mockMessagesCursor: String?
    var mockSentMessage: MLSMessageView?
    var shouldFailLeave = false
    var delayResponse = false
    var sendMessageCallCount = 0
    var leaveConversationCallCount = 0
    
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
    
    override func getMessages(
        convoId: String,
        limit: Int = 50,
        cursor: String? = nil,
        since: Date? = nil,
        until: Date? = nil,
        epoch: Int? = nil
    ) async throws -> (messages: [MLSMessageView], cursor: String?) {
        if delayResponse {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return (mockMessages, mockMessagesCursor)
    }
    
    override func sendMessage(
        convoId: String,
        ciphertext: String,
        contentType: String = "text/plain",
        attachments: [MLSBlobRef]? = nil
    ) async throws -> MLSSendMessageResponse {
        sendMessageCallCount += 1
        
        if delayResponse {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        
        guard let message = mockSentMessage else {
            throw NSError(domain: "TestError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Mock error"])
        }
        
        return MLSSendMessageResponse(message: message)
    }
    
    override func leaveConversation(convoId: String) async throws -> MLSLeaveConvoResponse {
        leaveConversationCallCount += 1
        
        if shouldFailLeave {
            throw NSError(domain: "TestError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Leave failed"])
        }
        
        return MLSLeaveConvoResponse(
            commit: "mock-commit",
            epoch: MLSEpochInfo(epoch: 2, groupId: "group-123", memberCount: 1, updatedAt: Date())
        )
    }
}
