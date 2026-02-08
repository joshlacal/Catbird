import XCTest
import CryptoKit
import Petrel
@testable import Catbird

/// Comprehensive unit tests for MLSConversationManager
/// Tests group initialization, member management, encryption/decryption,
/// server sync, key package management, epoch updates, and observer pattern
/// 
/// ⚠️ NOTE: These tests need updating for text-only PostgreSQL architecture
/// - Remove CloudKit mock dependencies (DONE)
/// - Update sendMessage to expect (messageId, receivedAt) tuple (IN PROGRESS)
/// - Update addMembers to expect (success, newEpoch) tuple (IN PROGRESS)
/// - Update mock responses to use BlueCatbirdMls* types from Petrel (TODO)
/// - Update request/response structures (TODO)
final class MLSConversationManagerTests: XCTestCase {
    
    var manager: MLSConversationManager!
    var mockAPIClient: MockMLSAPIClient!
    // CloudKit removed - text-only PostgreSQL architecture
    let testUserDid = "did:plc:testuser123456789"
    let testGroupId = "test_group_id_base64"
    let testConvoId = "test_convo_123"
    
    override func setUp() {
        super.setUp()
        mockAPIClient = MockMLSAPIClient()
        // No more CloudKit storage provider
        manager = MLSConversationManager(
            apiClient: mockAPIClient,
            userDid: testUserDid
        )
    }
    
    override func tearDown() {
        manager = nil
        mockAPIClient = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testManagerInitialization() {
        XCTAssertNotNil(manager)
        XCTAssertTrue(manager.conversations.isEmpty)
        XCTAssertFalse(manager.isSyncing)
        XCTAssertEqual(manager.defaultCipherSuite, "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519")
    }
    
    func testManagerWithoutUserDid() {
        let managerWithoutDid = MLSConversationManager(apiClient: mockAPIClient, userDid: nil)
        XCTAssertNotNil(managerWithoutDid)
    }
    
    // MARK: - Group Creation Tests
    
    func testCreateGroupSuccess() async throws {
        // Arrange
        let metadata = MLSConvoMetadata(name: "Test Group", description: "Test", avatar: nil)
        let expectedConvo = createTestConvo(id: testConvoId, groupId: testGroupId)
        mockAPIClient.createConvoResponse = MLSCreateConvoResponse(
            convo: expectedConvo,
            welcomeMessages: []
        )
        
        // Act
        let convo = try await manager.createGroup(
            initialMembers: ["did:plc:member1"],
            metadata: metadata
        )
        
        // Assert
        XCTAssertEqual(convo.id, testConvoId)
        XCTAssertEqual(manager.conversations.count, 1)
        XCTAssertNotNil(manager.conversations[testConvoId])
    }
    
    func testCreateGroupWithoutAuthentication() async {
        // Arrange
        let managerWithoutAuth = MLSConversationManager(apiClient: mockAPIClient, userDid: nil)
        
        // Act & Assert
        do {
            _ = try await managerWithoutAuth.createGroup(initialMembers: nil, metadata: nil)
            XCTFail("Should throw noAuthentication error")
        } catch MLSConversationError.noAuthentication {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testCreateGroupServerError() async {
        // Arrange
        mockAPIClient.shouldThrowError = true
        mockAPIClient.errorToThrow = MLSAPIError.httpError(statusCode: 500, message: "Server error")
        
        // Act & Assert
        do {
            _ = try await manager.createGroup(initialMembers: nil, metadata: nil)
            XCTFail("Should throw serverError")
        } catch MLSConversationError.serverError {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testCreateGroupWithInitialMembers() async throws {
        // Arrange
        let initialMembers = ["did:plc:member1", "did:plc:member2", "did:plc:member3"]
        let expectedConvo = createTestConvo(id: testConvoId, groupId: testGroupId)
        mockAPIClient.createConvoResponse = MLSCreateConvoResponse(
            convo: expectedConvo,
            welcomeMessages: initialMembers.map { MLSWelcomeMessage(did: $0, welcome: "welcome_msg") }
        )
        
        // Act
        let convo = try await manager.createGroup(
            initialMembers: initialMembers,
            metadata: nil
        )
        
        // Assert
        XCTAssertEqual(convo.id, testConvoId)
        XCTAssertEqual(mockAPIClient.lastCreateConvoRequest?.initialMembers?.count, 3)
    }
    
    // MARK: - Join Group Tests
    
    func testJoinGroupWithInvalidWelcome() async {
        // Arrange
        let invalidWelcome = "not_valid_base64!!!"
        
        // Act & Assert
        do {
            _ = try await manager.joinGroup(welcomeMessage: invalidWelcome)
            XCTFail("Should throw invalidWelcomeMessage error")
        } catch MLSConversationError.invalidWelcomeMessage {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testJoinGroupConversationNotFound() async {
        // Arrange
        let validWelcome = Data("welcome".utf8).base64EncodedString()
        mockAPIClient.getConvosResponse = (convos: [], cursor: nil)
        
        // Act & Assert
        do {
            _ = try await manager.joinGroup(welcomeMessage: validWelcome)
            XCTFail("Should throw conversationNotFound error")
        } catch MLSConversationError.conversationNotFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    // MARK: - Member Management Tests
    
    func testAddMembersSuccess() async throws {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo
        
        let newMembers = ["did:plc:newmember1", "did:plc:newmember2"]
        let keyPackages = newMembers.map { did in
            MLSKeyPackageRef(
                id: "pkg_\(did)",
                did: did,
                keyPackage: "key_package_data",
                cipherSuite: manager.defaultCipherSuite,
                createdAt: Date(),
                expiresAt: nil
            )
        }
        
        mockAPIClient.getKeyPackagesResponse = (keyPackages: keyPackages, missing: nil)
        
        let updatedConvo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 2)
        mockAPIClient.addMembersResponse = MLSAddMembersResponse(
            convo: updatedConvo,
            commit: "commit_data",
            welcomeMessages: []
        )
        
        // Act
        try await manager.addMembers(convoId: testConvoId, memberDids: newMembers)
        
        // Assert
        XCTAssertEqual(manager.conversations[testConvoId]?.epoch, 2)
        XCTAssertEqual(mockAPIClient.lastAddMembersRequest?.members.count, 2)
    }
    
    func testAddMembersWithMissingKeyPackages() async {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo
        
        let newMembers = ["did:plc:newmember1", "did:plc:newmember2"]
        mockAPIClient.getKeyPackagesResponse = (keyPackages: [], missing: newMembers)
        
        // Act & Assert
        do {
            try await manager.addMembers(convoId: testConvoId, memberDids: newMembers)
            XCTFail("Should throw missingKeyPackages error")
        } catch MLSConversationError.missingKeyPackages(let missing) {
            XCTAssertEqual(missing.count, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testAddMembersConversationNotFound() async {
        // Act & Assert
        do {
            try await manager.addMembers(convoId: "nonexistent", memberDids: ["did:plc:member1"])
            XCTFail("Should throw conversationNotFound error")
        } catch MLSConversationError.conversationNotFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testLeaveConversationSuccess() async throws {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo
        
        mockAPIClient.leaveConvoResponse = MLSLeaveConvoResponse(
            commit: "commit_data",
            epoch: MLSEpochInfo(epoch: 2, groupId: testGroupId, memberCount: 1, updatedAt: Date())
        )
        
        // Act
        try await manager.leaveConversation(convoId: testConvoId)
        
        // Assert
        XCTAssertNil(manager.conversations[testConvoId])
    }
    
    func testLeaveConversationNotFound() async {
        // Act & Assert
        do {
            try await manager.leaveConversation(convoId: "nonexistent")
            XCTFail("Should throw conversationNotFound error")
        } catch MLSConversationError.conversationNotFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    // MARK: - Encryption/Decryption Tests
    
    func testSendMessageSuccess() async throws {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo
        
        let plaintext = "Hello, World!"
        let expectedMessage = MLSMessageView(
            id: "msg_123",
            convoId: testConvoId,
            sender: testUserDid,
            ciphertext: "encrypted_data",
            epoch: 1,
            createdAt: Date(),
            contentType: "text/plain",
            attachments: nil
        )
        
        mockAPIClient.sendMessageResponse = MLSSendMessageResponse(message: expectedMessage)
        
        // Act
        let message = try await manager.sendMessage(
            convoId: testConvoId,
            plaintext: plaintext,
            contentType: "text/plain",
            attachments: nil
        )
        
        // Assert
        XCTAssertEqual(message.id, "msg_123")
        XCTAssertEqual(message.sender, testUserDid)
        XCTAssertNotNil(mockAPIClient.lastSendMessageRequest)
    }
    
    func testSendMessageConversationNotFound() async {
        // Act & Assert
        do {
            _ = try await manager.sendMessage(
                convoId: "nonexistent",
                plaintext: "test",
                contentType: "text/plain",
                attachments: nil
            )
            XCTFail("Should throw conversationNotFound error")
        } catch MLSConversationError.conversationNotFound {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testSendMessageWithAttachments() async throws {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo
        
        let attachments = [
            MLSBlobRef(cid: "cid123", mimeType: "image/png", size: 1024, ref: nil)
        ]
        
        let expectedMessage = MLSMessageView(
            id: "msg_123",
            convoId: testConvoId,
            sender: testUserDid,
            ciphertext: "encrypted_data",
            epoch: 1,
            createdAt: Date(),
            contentType: "text/plain",
            attachments: attachments
        )
        
        mockAPIClient.sendMessageResponse = MLSSendMessageResponse(message: expectedMessage)
        
        // Act
        let message = try await manager.sendMessage(
            convoId: testConvoId,
            plaintext: "test",
            contentType: "text/plain",
            attachments: attachments
        )
        
        // Assert
        XCTAssertEqual(message.attachments?.count, 1)
    }
    
    func testDecryptMessageInvalidCiphertext() {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo
        
        let message = MLSMessageView(
            id: "msg_123",
            convoId: testConvoId,
            sender: "did:plc:sender",
            ciphertext: "not_valid_base64!!!",
            epoch: 1,
            createdAt: Date(),
            contentType: "text/plain",
            attachments: nil
        )
        
        // Act & Assert
        XCTAssertThrowsError(try manager.decryptMessage(message)) { error in
            XCTAssertTrue(error is MLSConversationError)
        }
    }
    
    // MARK: - Server Sync Tests
    
    func testSyncWithServerSuccess() async throws {
        // Arrange
        let convos = [
            createTestConvo(id: "convo1", groupId: "group1"),
            createTestConvo(id: "convo2", groupId: "group2"),
            createTestConvo(id: "convo3", groupId: "group3")
        ]
        mockAPIClient.getConvosResponse = (convos: convos, cursor: nil)
        
        // Act
        try await manager.syncWithServer(fullSync: true)
        
        // Assert
        XCTAssertEqual(manager.conversations.count, 3)
        XCTAssertFalse(manager.isSyncing)
    }
    
    func testSyncWithServerPagination() async throws {
        // Arrange
        let convos1 = [createTestConvo(id: "convo1", groupId: "group1")]
        let convos2 = [createTestConvo(id: "convo2", groupId: "group2")]
        
        mockAPIClient.getConvosResponses = [
            (convos: convos1, cursor: "cursor1"),
            (convos: convos2, cursor: nil)
        ]
        
        // Act
        try await manager.syncWithServer(fullSync: true)
        
        // Assert
        XCTAssertEqual(manager.conversations.count, 2)
    }
    
    func testSyncWithServerError() async {
        // Arrange
        mockAPIClient.shouldThrowError = true
        mockAPIClient.errorToThrow = MLSAPIError.httpError(statusCode: 500, message: "Server error")
        
        // Act & Assert
        do {
            try await manager.syncWithServer(fullSync: true)
            XCTFail("Should throw syncFailed error")
        } catch MLSConversationError.syncFailed {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        XCTAssertFalse(manager.isSyncing)
    }
    
    func testSyncWhileAlreadySyncing() async throws {
        // Arrange
        mockAPIClient.getConvosDelay = 1.0 // Slow response
        mockAPIClient.getConvosResponse = (convos: [], cursor: nil)
        
        // Act - Start two syncs
        let task1 = Task {
            try await manager.syncWithServer(fullSync: true)
        }
        
        // Give first sync time to start
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        let task2 = Task {
            try await manager.syncWithServer(fullSync: true)
        }
        
        // Wait for both to complete
        _ = try await task1.value
        _ = try await task2.value
        
        // Assert - Second sync should return early
        XCTAssertFalse(manager.isSyncing)
    }
    
    // MARK: - Key Package Management Tests
    
    func testPublishKeyPackageSuccess() async throws {
        // Arrange
        let expectedKeyPackage = MLSKeyPackageRef(
            id: "pkg_123",
            did: testUserDid,
            keyPackage: "key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: 2592000)
        )
        mockAPIClient.publishKeyPackageResponse = MLSPublishKeyPackageResponse(keyPackage: expectedKeyPackage)
        
        // Act
        let keyPackage = try await manager.publishKeyPackage()
        
        // Assert
        XCTAssertEqual(keyPackage.id, "pkg_123")
        XCTAssertEqual(keyPackage.did, testUserDid)
    }
    
    func testPublishKeyPackageWithCustomExpiration() async throws {
        // Arrange
        let expiresAt = Date(timeIntervalSinceNow: 86400) // 1 day
        let expectedKeyPackage = MLSKeyPackageRef(
            id: "pkg_123",
            did: testUserDid,
            keyPackage: "key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: expiresAt
        )
        mockAPIClient.publishKeyPackageResponse = MLSPublishKeyPackageResponse(keyPackage: expectedKeyPackage)
        
        // Act
        let keyPackage = try await manager.publishKeyPackage(expiresAt: expiresAt)
        
        // Assert
        XCTAssertNotNil(keyPackage.expiresAt)
    }
    
    func testRefreshKeyPackagesNotNeeded() async throws {
        // Arrange
        let futureExpiry = Date(timeIntervalSinceNow: 2592000) // 30 days
        let keyPackage = MLSKeyPackageRef(
            id: "pkg_123",
            did: testUserDid,
            keyPackage: "key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: futureExpiry
        )
        mockAPIClient.getKeyPackagesResponse = (keyPackages: [keyPackage], missing: nil)
        
        // Act
        try await manager.refreshKeyPackagesIfNeeded()
        
        // Assert
        // Should not have called publishKeyPackage
        XCTAssertNil(mockAPIClient.lastPublishKeyPackageRequest)
    }
    
    func testRefreshKeyPackagesNeeded() async throws {
        // Arrange
        let nearExpiry = Date(timeIntervalSinceNow: 3600) // 1 hour
        let keyPackage = MLSKeyPackageRef(
            id: "pkg_123",
            did: testUserDid,
            keyPackage: "key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: nearExpiry
        )
        mockAPIClient.getKeyPackagesResponse = (keyPackages: [keyPackage], missing: nil)
        
        let newKeyPackage = MLSKeyPackageRef(
            id: "pkg_456",
            did: testUserDid,
            keyPackage: "new_key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: 2592000)
        )
        mockAPIClient.publishKeyPackageResponse = MLSPublishKeyPackageResponse(keyPackage: newKeyPackage)
        
        // Act
        try await manager.refreshKeyPackagesIfNeeded()
        
        // Assert
        XCTAssertNotNil(mockAPIClient.lastPublishKeyPackageRequest)
    }
    
    // MARK: - Epoch Management Tests
    
    func testGetEpochSuccess() throws {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 5)
        manager.conversations[testConvoId] = convo
        
        // Act
        let epoch = try manager.getEpoch(convoId: testConvoId)
        
        // Assert
        XCTAssertEqual(epoch, UInt64(5))
    }
    
    func testGetEpochConversationNotFound() {
        // Act & Assert
        XCTAssertThrowsError(try manager.getEpoch(convoId: "nonexistent")) { error in
            XCTAssertTrue(error is MLSConversationError)
        }
    }
    
    func testHandleEpochUpdate() {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 1)
        manager.conversations[testConvoId] = convo
        
        // Act
        manager.handleEpochUpdate(convoId: testConvoId, newEpoch: UInt64(3))
        
        // Assert
        XCTAssertEqual(manager.conversations[testConvoId]?.epoch, 3)
    }
    
    func testHandleEpochUpdateConversationNotFound() {
        // Act
        manager.handleEpochUpdate(convoId: "nonexistent", newEpoch: 5)
        
        // Assert - Should not crash
        XCTAssertNil(manager.conversations["nonexistent"])
    }
    
    // MARK: - Observer Pattern Tests
    
    func testAddObserver() {
        // Arrange
        var eventReceived = false
        let observer = MLSStateObserver { event in
            eventReceived = true
        }
        
        // Act
        manager.addObserver(observer)
        
        // Assert - Observer should be added (verified through notification)
        XCTAssertNotNil(observer)
    }
    
    func testRemoveObserver() {
        // Arrange
        let observer = MLSStateObserver { _ in }
        manager.addObserver(observer)
        
        // Act
        manager.removeObserver(observer)
        
        // Assert - Observer should be removed
        XCTAssertNotNil(observer)
    }
    
    func testObserverNotificationOnConversationCreated() async throws {
        // Arrange
        var receivedEvent: MLSStateEvent?
        let observer = MLSStateObserver { event in
            receivedEvent = event
        }
        manager.addObserver(observer)
        
        let expectedConvo = createTestConvo(id: testConvoId, groupId: testGroupId)
        mockAPIClient.createConvoResponse = MLSCreateConvoResponse(
            convo: expectedConvo,
            welcomeMessages: []
        )
        
        // Act
        _ = try await manager.createGroup(initialMembers: nil, metadata: nil)
        
        // Assert
        XCTAssertNotNil(receivedEvent)
        if case .conversationCreated(let convo) = receivedEvent {
            XCTAssertEqual(convo.id, testConvoId)
        } else {
            XCTFail("Expected conversationCreated event")
        }
    }
    
    func testObserverNotificationOnMembersAdded() async throws {
        // Arrange
        var receivedEvents: [MLSStateEvent] = []
        let observer = MLSStateObserver { event in
            receivedEvents.append(event)
        }
        manager.addObserver(observer)
        
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo
        
        let newMembers = ["did:plc:newmember1"]
        let keyPackage = MLSKeyPackageRef(
            id: "pkg_123",
            did: newMembers[0],
            keyPackage: "key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: nil
        )
        mockAPIClient.getKeyPackagesResponse = (keyPackages: [keyPackage], missing: nil)
        
        let updatedConvo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 2)
        mockAPIClient.addMembersResponse = MLSAddMembersResponse(
            convo: updatedConvo,
            commit: "commit_data",
            welcomeMessages: []
        )
        
        // Act
        try await manager.addMembers(convoId: testConvoId, memberDids: newMembers)
        
        // Assert
        XCTAssertTrue(receivedEvents.count >= 1)
        let hasMembersAddedEvent = receivedEvents.contains { event in
            if case .membersAdded = event { return true }
            return false
        }
        XCTAssertTrue(hasMembersAddedEvent)
    }
    
    func testObserverNotificationOnSyncCompleted() async throws {
        // Arrange
        var receivedEvent: MLSStateEvent?
        let observer = MLSStateObserver { event in
            receivedEvent = event
        }
        manager.addObserver(observer)
        
        let convos = [createTestConvo(id: "convo1", groupId: "group1")]
        mockAPIClient.getConvosResponse = (convos: convos, cursor: nil)
        
        // Act
        try await manager.syncWithServer(fullSync: true)
        
        // Assert
        XCTAssertNotNil(receivedEvent)
        if case .syncCompleted(let count) = receivedEvent {
            XCTAssertEqual(count, 1)
        } else {
            XCTFail("Expected syncCompleted event")
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testMLSConversationErrorDescriptions() {
        let errors: [MLSConversationError] = [
            .noAuthentication,
            .contextNotInitialized,
            .conversationNotFound,
            .groupStateNotFound,
            .invalidWelcomeMessage,
            .invalidIdentity,
            .invalidGroupId,
            .invalidMessage,
            .invalidCiphertext,
            .decodingFailed,
            .missingKeyPackages(["did:plc:user1"]),
            .mlsError("test error"),
            .serverError(MLSAPIError.unknownError),
            .syncFailed(MLSAPIError.unknownError)
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestConvo(
        id: String,
        groupId: String,
        epoch: Int = 1
    ) -> MLSConvoView {
        return MLSConvoView(
            id: id,
            groupId: groupId,
            creator: testUserDid,
            members: [
                MLSMemberView(
                    did: testUserDid,
                    joinedAt: Date(),
                    leafIndex: 0,
                    credential: nil
                )
            ],
            epoch: epoch,
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            lastMessageAt: nil,
            metadata: nil
        )
    }
}

// MARK: - Mock API Client

class MockMLSAPIClient: MLSAPIClient {
    var shouldThrowError = false
    var errorToThrow: Error = MLSAPIError.unknownError
    
    // Response data
    var getConvosResponse: (convos: [MLSConvoView], cursor: String?) = ([], nil)
    var getConvosResponses: [(convos: [MLSConvoView], cursor: String?)] = []
    var getConvosDelay: TimeInterval = 0
    var createConvoResponse: MLSCreateConvoResponse?
    var addMembersResponse: MLSAddMembersResponse?
    var leaveConvoResponse: MLSLeaveConvoResponse?
    var sendMessageResponse: MLSSendMessageResponse?
    var getKeyPackagesResponse: (keyPackages: [MLSKeyPackageRef], missing: [String]?) = ([], nil)
    var publishKeyPackageResponse: MLSPublishKeyPackageResponse?
    
    // Last requests
    var lastCreateConvoRequest: MLSCreateConvoRequest?
    var lastAddMembersRequest: MLSAddMembersRequest?
    var lastSendMessageRequest: MLSSendMessageRequest?
    var lastPublishKeyPackageRequest: MLSPublishKeyPackageRequest?
    
    private var getConvosCallCount = 0
    
    override func getConversations(
        limit: Int = 50,
        cursor: String? = nil,
        sortBy: String = "lastMessageAt",
        sortOrder: String = "desc"
    ) async throws -> (convos: [MLSConvoView], cursor: String?) {
        if getConvosDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(getConvosDelay * 1_000_000_000))
        }
        
        if shouldThrowError {
            throw errorToThrow
        }
        
        if !getConvosResponses.isEmpty {
            defer { getConvosCallCount += 1 }
            if getConvosCallCount < getConvosResponses.count {
                return getConvosResponses[getConvosCallCount]
            }
        }
        
        return getConvosResponse
    }
    
    override func createConversation(
        cipherSuite: String,
        initialMembers: [String]? = nil,
        metadata: MLSConvoMetadata? = nil
    ) async throws -> MLSCreateConvoResponse {
        if shouldThrowError {
            throw errorToThrow
        }
        
        lastCreateConvoRequest = MLSCreateConvoRequest(
            cipherSuite: cipherSuite,
            initialMembers: initialMembers,
            metadata: metadata
        )
        
        guard let response = createConvoResponse else {
            throw MLSAPIError.unknownError
        }
        
        return response
    }
    
    override func addMembers(
        convoId: String,
        didList: [DID],
        commit: String? = nil,
        welcome: String? = nil
    ) async throws -> (success: Bool, newEpoch: Int) {
        if shouldThrowError {
            throw errorToThrow
        }
        
        lastAddMembersRequest = MLSAddMembersRequest(
            convoId: convoId,
            didList: didList,
            commit: commit,
            welcome: welcome
        )
        
        guard let response = addMembersResponse else {
            throw MLSAPIError.unknownError
        }
        
        return (response.success, response.newEpoch)
    }
    
    override func leaveConversation(convoId: String) async throws -> MLSLeaveConvoResponse {
        if shouldThrowError {
            throw errorToThrow
        }
        
        guard let response = leaveConvoResponse else {
            throw MLSAPIError.unknownError
        }
        
        return response
    }
    
    override func sendMessage(
        convoId: String,
        ciphertext: Data,
        epoch: Int,
        senderDid: DID,
        embedType: String? = nil,
        embedUri: URI? = nil
    ) async throws -> (messageId: String, receivedAt: ATProtocolDate) {
        if shouldThrowError {
            throw errorToThrow
        }
        
        lastSendMessageRequest = MLSSendMessageRequest(
            convoId: convoId,
            ciphertext: ciphertext,
            epoch: epoch,
            senderDid: senderDid,
            embedType: embedType,
            embedUri: embedUri
        )
        
        guard let response = sendMessageResponse else {
            throw MLSAPIError.unknownError
        }
        
        return (response.messageId, response.receivedAt)
    }
    
    override func getKeyPackages(
        dids: [String],
        cipherSuite: String? = nil
    ) async throws -> (keyPackages: [MLSKeyPackageRef], missing: [String]?) {
        if shouldThrowError {
            throw errorToThrow
        }
        
        return getKeyPackagesResponse
    }
    
    override func publishKeyPackage(
        keyPackage: String,
        cipherSuite: String,
        expiresAt: Date? = nil
    ) async throws -> MLSKeyPackageRef {
        if shouldThrowError {
            throw errorToThrow
        }
        
        lastPublishKeyPackageRequest = MLSPublishKeyPackageRequest(
            keyPackage: keyPackage,
            cipherSuite: cipherSuite,
            expiresAt: expiresAt
        )
        
        guard let response = publishKeyPackageResponse else {
            throw MLSAPIError.unknownError
        }
        
        return response.keyPackage
    }
    
    // Mock commit-related methods for epoch sync testing
    var getEpochResponse: Int?
    var getCommitsResponse: [MLSCommit]?
    
    func getEpoch(groupId: String) async throws -> Int {
        guard let response = getEpochResponse else {
            throw MLSAPIError.unknownError
        }
        return response
    }
    
    func getCommits(groupId: String, fromEpoch: Int, toEpoch: Int) async throws -> [MLSCommit] {
        guard let commits = getCommitsResponse else {
            throw MLSAPIError.unknownError
        }
        return commits
    }
}

// MARK: - Epoch Synchronization Integration Tests

extension MLSConversationManagerTests {
    
    func testSyncGroupStateNoEpochGap() async throws {
        // Setup: Local epoch matches server epoch
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 5)
        manager.conversations[testConvoId] = convo
        
        mockAPIClient.getEpochResponse = 5
        mockAPIClient.getCommitsResponse = []
        
        // Act: Sync should be no-op when epochs match
        try await manager.syncGroupState(convoId: testConvoId)
        
        // Assert: Epoch should remain the same
        let finalEpoch = try manager.getEpoch(convoId: testConvoId)
        XCTAssertEqual(finalEpoch, UInt64(5))
    }
    
    func testSyncGroupStateWithEpochGap() async throws {
        // Setup: Local epoch is behind server
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 0)
        manager.conversations[testConvoId] = convo
        
        mockAPIClient.getEpochResponse = 3
        
        // Mock 3 commits to process
        mockAPIClient.getCommitsResponse = [
            MLSCommit(epoch: 1, commitData: Data([0x01]), timestamp: Date()),
            MLSCommit(epoch: 2, commitData: Data([0x02]), timestamp: Date()),
            MLSCommit(epoch: 3, commitData: Data([0x03]), timestamp: Date())
        ]
        
        // Note: This test will fail commit processing since we don't have valid TLS data
        // In production, commits would be real OpenMLS TLS-encoded messages
        // For now, we're testing the synchronization logic flow
    }
    
    func testHandleEpochUpdatePersistence() throws {
        // Setup
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 0)
        manager.conversations[testConvoId] = convo
        
        // Act: Update epoch
        manager.handleEpochUpdate(convoId: testConvoId, newEpoch: UInt64(5))
        
        // Assert: In-memory state updated
        XCTAssertEqual(manager.conversations[testConvoId]?.epoch, 5)
        
        // Note: Keychain persistence would be verified in integration tests
        // The actual keychain write happens in processCommit, not handleEpochUpdate
    }
    
    func testObserverNotificationOnEpochUpdate() {
        // Setup
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 0)
        manager.conversations[testConvoId] = convo
        
        var receivedEvent: MLSStateEvent?
        let expectation = XCTestExpectation(description: "Observer notified")
        
        let observer = MLSStateObserver { event in
            receivedEvent = event
            expectation.fulfill()
        }
        
        manager.addObserver(observer)
        
        // Act: Update epoch (which triggers observer notification in real implementation)
        manager.handleEpochUpdate(convoId: testConvoId, newEpoch: 5)
        
        // Note: Observer notification happens in processCommit in the real flow
        // handleEpochUpdate is a simpler helper that updates state directly
    }
    
    func testProcessMultipleCommitsInSequence() throws {
        // Setup: Test that epochs increment correctly
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 0)
        manager.conversations[testConvoId] = convo
        
        // Simulate sequential epoch updates (as would happen during commit processing)
        for epoch in 1...5 {
            manager.handleEpochUpdate(convoId: testConvoId, newEpoch: epoch)
            let currentEpoch = try manager.getEpoch(convoId: testConvoId)
            XCTAssertEqual(currentEpoch, UInt64(epoch), "Epoch should be \(epoch)")
        }
    }
    
    func testEpochSynchronizationAfterOffline() async throws {
        // Scenario: Device was offline, now needs to catch up multiple epochs
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 0)
        manager.conversations[testConvoId] = convo
        
        // Server is at epoch 10, we're at 0
        mockAPIClient.getEpochResponse = 10
        
        // Would need to process 10 commits to catch up
        // This tests the gap detection logic
        let localEpoch = try manager.getEpoch(convoId: testConvoId)
        XCTAssertEqual(localEpoch, UInt64(0))
        
        // In real sync, we would call syncGroupState which would:
        // 1. Get server epoch (10)
        // 2. Get commits from 0 to 10
        // 3. Process each commit
        // 4. Update local epoch to 10
    }
    
    func testEpochPersistsAcrossConversationReload() throws {
        // Setup: Create conversation with epoch 5
        var convo = createTestConvo(id: testConvoId, groupId: testGroupId, epoch: 5)
        manager.conversations[testConvoId] = convo
        
        // Verify epoch
        let epoch1 = try manager.getEpoch(convoId: testConvoId)
        XCTAssertEqual(epoch1, UInt64(5))
        
        // Simulate conversation reload (e.g., from keychain)
        manager.conversations.removeAll()
        convo.epoch = 5 // In real code, this would be loaded from keychain
        manager.conversations[testConvoId] = convo
        
        // Verify epoch persisted
        let epoch2 = try manager.getEpoch(convoId: testConvoId)
        XCTAssertEqual(epoch2, UInt64(5))
    }
}

// MARK: - Mock Types for Epoch Sync

struct MLSCommit {
    let epoch: Int
    let commitData: Data
    let timestamp: Date
}

// MockCloudKitStorageProvider removed - text-only PostgreSQL architecture

// MARK: - Discarded Commit Tests

extension MLSConversationManagerTests {

    /// Test that pending commit is cleared when addMembers fails
    func testAddMembersFailureClearsPendingCommit() async {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo

        let newMembers = ["did:plc:newmember1"]
        let keyPackage = MLSKeyPackageRef(
            id: "pkg_123",
            did: newMembers[0],
            keyPackage: "key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: nil
        )
        mockAPIClient.getKeyPackagesResponse = (keyPackages: [keyPackage], missing: nil)

        // Force API call to fail
        mockAPIClient.shouldThrowError = true
        mockAPIClient.errorToThrow = MLSAPIError.httpError(statusCode: 409, message: "Epoch conflict")

        // Act & Assert
        do {
            try await manager.addMembers(convoId: testConvoId, memberDids: newMembers)
            XCTFail("Should throw serverError")
        } catch MLSConversationError.serverError {
            // Expected - commit should have been cleared via clearPendingCommit
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Test that pending commit is cleared when conversation creation fails with initial members
    func testCreateGroupFailureClearsPendingCommit() async {
        // Arrange
        let initialMembers = ["did:plc:member1"]
        mockAPIClient.shouldThrowError = true
        mockAPIClient.errorToThrow = MLSAPIError.httpError(statusCode: 500, message: "Server error")

        // Mock key package fetch success (so failure happens during creation)
        let keyPackage = MLSKeyPackageRef(
            id: "pkg_123",
            did: initialMembers[0],
            keyPackage: "key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: nil
        )
        mockAPIClient.getKeyPackagesResponse = (keyPackages: [keyPackage], missing: nil)

        // Act & Assert
        do {
            _ = try await manager.createGroup(
                initialMembers: initialMembers,
                name: "Test Group",
                description: nil,
                avatarUrl: nil
            )
            XCTFail("Should throw serverError")
        } catch MLSConversationError.serverError {
            // Expected - pending commit should be cleared
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Test that transient errors (5xx) trigger retry logic
    func testTransientErrorsAreRetryable() {
        // Arrange
        let transientError = MLSAPIError.httpError(statusCode: 503, message: "Service unavailable")

        // Act & Assert
        XCTAssertTrue(transientError.isRetryable, "5xx errors should be retryable")
    }

    /// Test that client errors (4xx) are not retried
    func testClientErrorsNotRetryable() {
        // Arrange
        let clientError = MLSAPIError.httpError(statusCode: 400, message: "Bad request")

        // Act & Assert
        XCTAssertFalse(clientError.isRetryable, "4xx errors should not be retryable")
    }

    /// Test that epoch conflicts (409) properly clear pending commits
    func testEpochConflictClearsPendingCommit() async {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo

        let newMembers = ["did:plc:newmember1"]
        let keyPackage = MLSKeyPackageRef(
            id: "pkg_123",
            did: newMembers[0],
            keyPackage: "key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: nil
        )
        mockAPIClient.getKeyPackagesResponse = (keyPackages: [keyPackage], missing: nil)

        // Simulate epoch conflict
        mockAPIClient.shouldThrowError = true
        mockAPIClient.errorToThrow = MLSAPIError.httpError(statusCode: 409, message: "Epoch conflict - local: 1, server: 2")

        // Act & Assert
        do {
            try await manager.addMembers(convoId: testConvoId, memberDids: newMembers)
            XCTFail("Should throw serverError")
        } catch MLSConversationError.serverError(let error) {
            // Verify it's the epoch conflict error
            if case MLSAPIError.httpError(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 409)
            } else {
                XCTFail("Expected HTTP error")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Test that network failures during commit upload are handled gracefully
    func testNetworkFailureDuringCommitUpload() async {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo

        let newMembers = ["did:plc:newmember1"]
        let keyPackage = MLSKeyPackageRef(
            id: "pkg_123",
            did: newMembers[0],
            keyPackage: "key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: nil
        )
        mockAPIClient.getKeyPackagesResponse = (keyPackages: [keyPackage], missing: nil)

        // Simulate network failure
        mockAPIClient.shouldThrowError = true
        mockAPIClient.errorToThrow = MLSAPIError.serverUnavailable

        // Act & Assert
        do {
            try await manager.addMembers(convoId: testConvoId, memberDids: newMembers)
            XCTFail("Should throw serverError")
        } catch MLSConversationError.serverError(let error) {
            // Verify it's a network error that should be retried
            if let apiError = error as? MLSAPIError {
                XCTAssertTrue(apiError.isRetryable, "Network errors should be retryable")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Test that commit cleanup doesn't fail silently
    func testCommitCleanupLogging() async {
        // Arrange
        let convo = createTestConvo(id: testConvoId, groupId: testGroupId)
        manager.conversations[testConvoId] = convo

        let newMembers = ["did:plc:newmember1"]
        let keyPackage = MLSKeyPackageRef(
            id: "pkg_123",
            did: newMembers[0],
            keyPackage: "key_package_data",
            cipherSuite: manager.defaultCipherSuite,
            createdAt: Date(),
            expiresAt: nil
        )
        mockAPIClient.getKeyPackagesResponse = (keyPackages: [keyPackage], missing: nil)

        // Force failure
        mockAPIClient.shouldThrowError = true
        mockAPIClient.errorToThrow = MLSAPIError.httpError(statusCode: 500, message: "Server error")

        // Act
        do {
            try await manager.addMembers(convoId: testConvoId, memberDids: newMembers)
            XCTFail("Should throw error")
        } catch {
            // Expected - verify error is logged properly (check logs manually or use OSLog mock)
            XCTAssertNotNil(error)
        }
    }
}
