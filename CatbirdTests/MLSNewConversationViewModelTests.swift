//
//  MLSNewConversationViewModelTests.swift
//  CatbirdTests
//
//  Created by Josh LaCalamito on 10/21/24.
//

import XCTest
import Combine
import Petrel
@testable import Catbird

@MainActor
final class MLSNewConversationViewModelTests: XCTestCase {
    var viewModel: MLSNewConversationViewModel!
    var mockConversationManager: MockMLSConversationManager!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        try await super.setUp()
        mockConversationManager = MockMLSConversationManager()
        viewModel = MLSNewConversationViewModel(conversationManager: mockConversationManager)
        cancellables = Set<AnyCancellable>()
    }
    
    override func tearDown() async throws {
        cancellables.forEach { $0.cancel() }
        cancellables = nil
        viewModel = nil
        mockConversationManager = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitialization() {
        XCTAssertTrue(viewModel.selectedMembers.isEmpty)
        XCTAssertEqual(viewModel.conversationName, "")
        XCTAssertEqual(viewModel.conversationDescription, "")
        XCTAssertEqual(viewModel.selectedCipherSuite, "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519")
        XCTAssertFalse(viewModel.isCreating)
        XCTAssertNil(viewModel.error)
        XCTAssertFalse(viewModel.isValid)
    }
    
    // MARK: - Validation Tests
    
    func testValidationWithNameAndMembers() {
        // When
        viewModel.conversationName = "Test Group"
        viewModel.addMember("did:plc:member1")
        
        // Then
        XCTAssertTrue(viewModel.isValid)
    }
    
    func testValidationWithoutName() {
        // When
        viewModel.addMember("did:plc:member1")
        
        // Then
        XCTAssertFalse(viewModel.isValid)
    }
    
    func testValidationWithoutMembers() {
        // When
        viewModel.conversationName = "Test Group"
        
        // Then
        XCTAssertFalse(viewModel.isValid)
    }
    
    func testValidationWithWhitespaceName() {
        // When
        viewModel.conversationName = "   "
        viewModel.addMember("did:plc:member1")
        
        // Then
        XCTAssertFalse(viewModel.isValid)
    }
    
    func testValidateMethod() {
        // Given - Empty form
        var errors = viewModel.validate()
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.contains("Conversation name is required"))
        XCTAssertTrue(errors.contains("At least one member is required"))
        
        // When - Add name
        viewModel.conversationName = "Test"
        errors = viewModel.validate()
        XCTAssertEqual(errors.count, 1)
        
        // When - Add valid member
        viewModel.addMember("did:plc:member1")
        errors = viewModel.validate()
        XCTAssertEqual(errors.count, 0)
        
        // When - Add invalid member
        viewModel.addMember("invalid-did")
        errors = viewModel.validate()
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.contains("Invalid DID format: invalid-did"))
    }
    
    // MARK: - Member Management Tests
    
    func testAddMember() async {
        // When
        await viewModel.addMember("did:plc:member1")
        
        // Then
        XCTAssertEqual(viewModel.selectedMembers.count, 1)
        XCTAssertTrue(viewModel.selectedMembers.contains("did:plc:member1"))
    }
    
    func testAddDuplicateMember() async {
        // Given
        await viewModel.addMember("did:plc:member1")
        
        // When
        await viewModel.addMember("did:plc:member1")
        
        // Then
        XCTAssertEqual(viewModel.selectedMembers.count, 1)
    }
    
    func testRemoveMember() async {
        // Given
        await viewModel.addMember("did:plc:member1")
        await viewModel.addMember("did:plc:member2")
        
        // When
        await viewModel.removeMember("did:plc:member1")
        
        // Then
        XCTAssertEqual(viewModel.selectedMembers.count, 1)
        XCTAssertFalse(viewModel.selectedMembers.contains("did:plc:member1"))
        XCTAssertTrue(viewModel.selectedMembers.contains("did:plc:member2"))
    }
    
    func testToggleMember() async {
        // When - Add member
        await viewModel.toggleMember("did:plc:member1")
        XCTAssertTrue(viewModel.selectedMembers.contains("did:plc:member1"))
        
        // When - Remove member
        await viewModel.toggleMember("did:plc:member1")
        XCTAssertFalse(viewModel.selectedMembers.contains("did:plc:member1"))
    }
    
    // MARK: - Create Conversation Tests
    
    func testCreateConversationSuccess() async {
        // Given
        viewModel.conversationName = "Test Group"
        viewModel.conversationDescription = "Test description"
        await viewModel.addMember("did:plc:member1")
        await viewModel.addMember("did:plc:member2")
        
        let mockConvo = createMockConversation()
        mockConversationManager.mockCreatedConversation = mockConvo
        
        let expectation = XCTestExpectation(description: "Conversation created")
        viewModel.conversationCreatedPublisher.sink { conversation in
            XCTAssertEqual(conversation.id, "test-convo-id")
            expectation.fulfill()
        }.store(in: &cancellables)
        
        // When
        await viewModel.createConversation()
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(mockConversationManager.createGroupCallCount, 1)
        XCTAssertFalse(viewModel.isCreating)
        XCTAssertNil(viewModel.error)
        
        // Form should be reset
        XCTAssertEqual(viewModel.conversationName, "")
        XCTAssertEqual(viewModel.conversationDescription, "")
        XCTAssertTrue(viewModel.selectedMembers.isEmpty)
    }
    
    func testCreateConversationFailure() async {
        // Given
        viewModel.conversationName = "Test Group"
        await viewModel.addMember("did:plc:member1")
        mockConversationManager.shouldFail = true
        
        let expectation = XCTestExpectation(description: "Error received")
        viewModel.errorPublisher.sink { error in
            XCTAssertNotNil(error)
            expectation.fulfill()
        }.store(in: &cancellables)
        
        // When
        await viewModel.createConversation()
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNotNil(viewModel.error)
        XCTAssertFalse(viewModel.isCreating)
        
        // Form should not be reset on failure
        XCTAssertEqual(viewModel.conversationName, "Test Group")
    }
    
    func testCreateConversationWithInvalidForm() async {
        // Given - Invalid form (no name)
        await viewModel.addMember("did:plc:member1")
        
        // When
        await viewModel.createConversation()
        
        // Then
        XCTAssertEqual(mockConversationManager.createGroupCallCount, 0)
    }
    
    func testCreateConversationWhileCreating() async {
        // Given
        viewModel.conversationName = "Test Group"
        await viewModel.addMember("did:plc:member1")
        mockConversationManager.delayResponse = true
        
        // When
        async let firstCreate: () = viewModel.createConversation()
        async let secondCreate: () = viewModel.createConversation()
        
        await firstCreate
        await secondCreate
        
        // Then
        XCTAssertEqual(mockConversationManager.createGroupCallCount, 1)
    }
    
    // MARK: - Search Tests
    
    func testSearchWithValidDID() async {
        // When
        viewModel.memberSearchQuery = "did:plc:test123"
        try? await Task.sleep(nanoseconds: 400_000_000) // Wait for search
        
        // Then
        XCTAssertEqual(viewModel.searchResults.count, 1)
        XCTAssertEqual(viewModel.searchResults.first, "did:plc:test123")
    }
    
    func testSearchWithInvalidDID() async {
        // When
        viewModel.memberSearchQuery = "invalid"
        try? await Task.sleep(nanoseconds: 400_000_000)
        
        // Then
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }
    
    func testSearchWithEmptyQuery() async {
        // When
        viewModel.memberSearchQuery = ""
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Then
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }
    
    // MARK: - Reset Tests
    
    func testReset() async {
        // Given
        viewModel.conversationName = "Test"
        viewModel.conversationDescription = "Description"
        await viewModel.addMember("did:plc:member1")
        viewModel.memberSearchQuery = "search"
        
        // When
        await viewModel.reset()
        
        // Then
        XCTAssertEqual(viewModel.conversationName, "")
        XCTAssertEqual(viewModel.conversationDescription, "")
        XCTAssertTrue(viewModel.selectedMembers.isEmpty)
        XCTAssertEqual(viewModel.memberSearchQuery, "")
        XCTAssertTrue(viewModel.searchResults.isEmpty)
        XCTAssertNil(viewModel.error)
    }
    
    // MARK: - Cipher Suite Tests
    
    func testAvailableCipherSuites() {
        XCTAssertFalse(viewModel.availableCipherSuites.isEmpty)
        XCTAssertTrue(viewModel.availableCipherSuites.contains("MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"))
    }
    
    func testChangeCipherSuite() {
        // When
        viewModel.selectedCipherSuite = "MLS_256_DHKEMX448_AES256GCM_SHA512_Ed448"
        
        // Then
        XCTAssertEqual(viewModel.selectedCipherSuite, "MLS_256_DHKEMX448_AES256GCM_SHA512_Ed448")
    }
    
    // MARK: - Helper Methods
    
    private func createMockConversation() -> BlueCatbirdMlsDefs.ConvoView {
        let creator = try! DID(didString: "did:plc:creator")
        let member1 = try! DID(didString: "did:plc:member1")
        let member2 = try! DID(didString: "did:plc:member2")
        
        return BlueCatbirdMlsDefs.ConvoView(
            id: "test-convo-id",
            groupId: "abcdef0123456789",
            creator: creator,
            members: [
                BlueCatbirdMlsDefs.MemberView(did: member1, joinedAt: ATProtocolDate(date: Date()), leafIndex: 0),
                BlueCatbirdMlsDefs.MemberView(did: member2, joinedAt: ATProtocolDate(date: Date()), leafIndex: 1)
            ],
            epoch: 1,
            cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
            createdAt: ATProtocolDate(date: Date()),
            lastMessageAt: nil,
            metadata: BlueCatbirdMlsDefs.ConvoMetadataView(name: "Test Group", description: "Test description")
        )
    }
}

// MARK: - Mock Conversation Manager

class MockMLSConversationManager: MLSConversationManager {
    var mockCreatedConversation: BlueCatbirdMlsDefs.ConvoView?
    var shouldFail = false
    var delayResponse = false
    var createGroupCallCount = 0
    
    override func createGroup(
        initialMembers: [DID]? = nil,
        name: String,
        description: String? = nil,
        avatarUrl: String? = nil
    ) async throws -> BlueCatbirdMlsDefs.ConvoView {
        createGroupCallCount += 1
        
        if delayResponse {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        
        if shouldFail {
            throw NSError(domain: "TestError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Mock error"])
        }
        
        guard let convo = mockCreatedConversation else {
            throw NSError(domain: "TestError", code: 500, userInfo: [NSLocalizedDescriptionKey: "No mock conversation"])
        }
        
        return convo
    }
}
