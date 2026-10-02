//
//  MLSStorageTests.swift
//  CatbirdTests
//
//  Comprehensive tests for MLS Core Data storage
//

import XCTest
import CoreData
@testable import Catbird

@MainActor
final class MLSStorageTests: XCTestCase {
    
    var storage: MLSStorage!
    var testConversationID: String!
    var testGroupID: Data!
    
    override func setUp() async throws {
        try await super.setUp()
        storage = MLSStorage.shared
        testConversationID = UUID().uuidString
        testGroupID = Data(repeating: 0x01, count: 32)
    }
    
    override func tearDown() async throws {
        // Clean up test data
        if let conversation = try? storage.fetchConversation(byID: testConversationID) {
            try? storage.deleteConversation(conversation)
        }
        try await super.tearDown()
    }
    
    // MARK: - Conversation Tests
    
    func testCreateConversation() throws {
        let conversation = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0,
            title: "Test Conversation"
        )
        
        XCTAssertEqual(conversation.conversationID, testConversationID)
        XCTAssertEqual(conversation.groupID, testGroupID)
        XCTAssertEqual(conversation.epoch, 0)
        XCTAssertEqual(conversation.title, "Test Conversation")
        XCTAssertTrue(conversation.isActive)
        XCTAssertNotNil(conversation.createdAt)
    }
    
    func testFetchConversation() throws {
        _ = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        let fetched = try storage.fetchConversation(byID: testConversationID)
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.conversationID, testConversationID)
    }
    
    func testUpdateConversation() throws {
        let conversation = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        try storage.updateConversation(
            conversation,
            epoch: 1,
            title: "Updated Title",
            memberCount: 5
        )
        
        let updated = try storage.fetchConversation(byID: testConversationID)
        
        XCTAssertEqual(updated?.epoch, 1)
        XCTAssertEqual(updated?.title, "Updated Title")
        XCTAssertEqual(updated?.memberCount, 5)
    }
    
    func testDeleteConversation() throws {
        let conversation = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        try storage.deleteConversation(conversation)
        
        let fetched = try storage.fetchConversation(byID: testConversationID)
        XCTAssertNil(fetched)
    }
    
    func testFetchAllConversations() throws {
        let conv1ID = UUID().uuidString
        let conv2ID = UUID().uuidString
        
        _ = try storage.createConversation(
            conversationID: conv1ID,
            groupID: testGroupID,
            epoch: 0
        )
        
        _ = try storage.createConversation(
            conversationID: conv2ID,
            groupID: testGroupID,
            epoch: 0
        )
        
        let conversations = try storage.fetchAllConversations()
        
        XCTAssertGreaterThanOrEqual(conversations.count, 2)
        
        // Cleanup
        if let conv1 = try storage.fetchConversation(byID: conv1ID) {
            try storage.deleteConversation(conv1)
        }
        if let conv2 = try storage.fetchConversation(byID: conv2ID) {
            try storage.deleteConversation(conv2)
        }
    }
    
    // MARK: - Message Tests
    
    func testCreateMessage() throws {
        _ = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        let messageID = UUID().uuidString
        let content = Data("Hello, World!".utf8)
        
        let message = try storage.createMessage(
            messageID: messageID,
            conversationID: testConversationID,
            senderID: "did:example:alice",
            content: content,
            contentType: "text",
            epoch: 0,
            sequenceNumber: 1
        )
        
        XCTAssertEqual(message.messageID, messageID)
        XCTAssertEqual(message.senderID, "did:example:alice")
        XCTAssertEqual(message.content, content)
        XCTAssertEqual(message.contentType, "text")
        XCTAssertFalse(message.isDelivered)
        XCTAssertFalse(message.isRead)
    }
    
    func testFetchMessage() throws {
        _ = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        let messageID = UUID().uuidString
        _ = try storage.createMessage(
            messageID: messageID,
            conversationID: testConversationID,
            senderID: "did:example:alice",
            content: Data("Test".utf8),
            epoch: 0,
            sequenceNumber: 1
        )
        
        let fetched = try storage.fetchMessage(byID: messageID)
        
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.messageID, messageID)
    }
    
    func testUpdateMessage() throws {
        _ = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        let messageID = UUID().uuidString
        let message = try storage.createMessage(
            messageID: messageID,
            conversationID: testConversationID,
            senderID: "did:example:alice",
            content: Data("Test".utf8),
            epoch: 0,
            sequenceNumber: 1
        )
        
        try storage.updateMessage(
            message,
            isDelivered: true,
            isRead: true
        )
        
        let updated = try storage.fetchMessage(byID: messageID)
        
        XCTAssertTrue(updated?.isDelivered ?? false)
        XCTAssertTrue(updated?.isRead ?? false)
    }
    
    func testFetchMessages() throws {
        _ = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        // Create multiple messages
        for i in 1...5 {
            _ = try storage.createMessage(
                messageID: UUID().uuidString,
                conversationID: testConversationID,
                senderID: "did:example:alice",
                content: Data("Message \(i)".utf8),
                epoch: 0,
                sequenceNumber: Int64(i)
            )
        }
        
        let messages = try storage.fetchMessages(forConversationID: testConversationID)
        
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages.first?.sequenceNumber, 1)
        XCTAssertEqual(messages.last?.sequenceNumber, 5)
    }
    
    // MARK: - Member Tests
    
    func testCreateMember() throws {
        _ = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        let memberID = UUID().uuidString
        let member = try storage.createMember(
            memberID: memberID,
            conversationID: testConversationID,
            did: "did:example:alice",
            handle: "alice.bsky.social",
            displayName: "Alice",
            leafIndex: 0,
            role: "admin"
        )
        
        XCTAssertEqual(member.memberID, memberID)
        XCTAssertEqual(member.did, "did:example:alice")
        XCTAssertEqual(member.handle, "alice.bsky.social")
        XCTAssertEqual(member.displayName, "Alice")
        XCTAssertEqual(member.leafIndex, 0)
        XCTAssertEqual(member.role, "admin")
        XCTAssertTrue(member.isActive)
    }
    
    func testFetchMembers() throws {
        _ = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        // Create multiple members
        for i in 0..<3 {
            _ = try storage.createMember(
                memberID: UUID().uuidString,
                conversationID: testConversationID,
                did: "did:example:user\(i)",
                leafIndex: Int32(i)
            )
        }
        
        let members = try storage.fetchMembers(forConversationID: testConversationID)
        
        XCTAssertEqual(members.count, 3)
        XCTAssertEqual(members[0].leafIndex, 0)
        XCTAssertEqual(members[1].leafIndex, 1)
        XCTAssertEqual(members[2].leafIndex, 2)
    }
    
    func testUpdateMember() throws {
        _ = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        let memberID = UUID().uuidString
        let member = try storage.createMember(
            memberID: memberID,
            conversationID: testConversationID,
            did: "did:example:alice",
            leafIndex: 0
        )
        
        try storage.updateMember(
            member,
            handle: "alice.updated",
            role: "moderator",
            isActive: false
        )
        
        let updated = try storage.fetchMember(byID: memberID)
        
        XCTAssertEqual(updated?.handle, "alice.updated")
        XCTAssertEqual(updated?.role, "moderator")
        XCTAssertFalse(updated?.isActive ?? true)
        XCTAssertNotNil(updated?.removedAt)
    }
    
    // MARK: - Key Package Tests
    
    func testCreateKeyPackage() throws {
        let keyPackageID = UUID().uuidString
        let keyPackageData = Data(repeating: 0x02, count: 128)
        
        let keyPackage = try storage.createKeyPackage(
            keyPackageID: keyPackageID,
            keyPackageData: keyPackageData,
            cipherSuite: 1,
            ownerDID: "did:example:alice"
        )
        
        XCTAssertEqual(keyPackage.keyPackageID, keyPackageID)
        XCTAssertEqual(keyPackage.keyPackageData, keyPackageData)
        XCTAssertEqual(keyPackage.cipherSuite, 1)
        XCTAssertEqual(keyPackage.ownerDID, "did:example:alice")
        XCTAssertFalse(keyPackage.isUsed)
    }
    
    func testFetchAvailableKeyPackages() throws {
        let ownerDID = "did:example:alice"
        
        // Create multiple key packages
        for i in 1...3 {
            _ = try storage.createKeyPackage(
                keyPackageID: UUID().uuidString,
                keyPackageData: Data(repeating: UInt8(i), count: 128),
                cipherSuite: 1,
                ownerDID: ownerDID
            )
        }
        
        let available = try storage.fetchAvailableKeyPackages(forOwnerDID: ownerDID)
        
        XCTAssertGreaterThanOrEqual(available.count, 3)
        
        // Cleanup
        for kp in available {
            try storage.deleteKeyPackage(kp)
        }
    }
    
    func testMarkKeyPackageAsUsed() throws {
        _ = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        let keyPackageID = UUID().uuidString
        let keyPackage = try storage.createKeyPackage(
            keyPackageID: keyPackageID,
            keyPackageData: Data(repeating: 0x02, count: 128),
            cipherSuite: 1,
            ownerDID: "did:example:alice"
        )
        
        try storage.markKeyPackageAsUsed(keyPackage, conversationID: testConversationID)
        
        let updated = try storage.fetchKeyPackage(byID: keyPackageID)
        
        XCTAssertTrue(updated?.isUsed ?? false)
        XCTAssertNotNil(updated?.usedAt)
        XCTAssertNotNil(updated?.conversation)
    }
    
    // MARK: - Batch Operations Tests
    
    func testDeleteAllMessages() throws {
        _ = try storage.createConversation(
            conversationID: testConversationID,
            groupID: testGroupID,
            epoch: 0
        )
        
        // Create multiple messages
        for i in 1...5 {
            _ = try storage.createMessage(
                messageID: UUID().uuidString,
                conversationID: testConversationID,
                senderID: "did:example:alice",
                content: Data("Message \(i)".utf8),
                epoch: 0,
                sequenceNumber: Int64(i)
            )
        }
        
        try storage.deleteAllMessages(forConversationID: testConversationID)
        
        let messages = try storage.fetchMessages(forConversationID: testConversationID)
        
        XCTAssertEqual(messages.count, 0)
    }
    
    func testDeleteExpiredKeyPackages() throws {
        let ownerDID = "did:example:alice"
        
        // Create expired key package
        let expiredKP = try storage.createKeyPackage(
            keyPackageID: UUID().uuidString,
            keyPackageData: Data(repeating: 0x02, count: 128),
            cipherSuite: 1,
            ownerDID: ownerDID,
            expiresAt: Date().addingTimeInterval(-3600) // Expired 1 hour ago
        )
        
        // Create valid key package
        _ = try storage.createKeyPackage(
            keyPackageID: UUID().uuidString,
            keyPackageData: Data(repeating: 0x03, count: 128),
            cipherSuite: 1,
            ownerDID: ownerDID,
            expiresAt: Date().addingTimeInterval(3600) // Expires in 1 hour
        )
        
        try storage.deleteExpiredKeyPackages()
        
        let fetched = try storage.fetchKeyPackage(byID: expiredKP.keyPackageID!)
        
        XCTAssertNil(fetched)
        
        // Cleanup valid key packages
        let available = try storage.fetchAvailableKeyPackages(forOwnerDID: ownerDID)
        for kp in available {
            try storage.deleteKeyPackage(kp)
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testCreateMessageWithInvalidConversation() {
        XCTAssertThrowsError(
            try storage.createMessage(
                messageID: UUID().uuidString,
                conversationID: "nonexistent",
                senderID: "did:example:alice",
                content: Data("Test".utf8),
                epoch: 0,
                sequenceNumber: 1
            )
        ) { error in
            XCTAssertTrue(error is MLSStorageError)
        }
    }
    
    func testCreateMemberWithInvalidConversation() {
        XCTAssertThrowsError(
            try storage.createMember(
                memberID: UUID().uuidString,
                conversationID: "nonexistent",
                did: "did:example:alice",
                leafIndex: 0
            )
        ) { error in
            XCTAssertTrue(error is MLSStorageError)
        }
    }
}
