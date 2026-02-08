//
//  MLSKeychainManagerTests.swift
//  CatbirdTests
//
//  Tests for MLS Keychain management
//

import XCTest
@testable import Catbird

final class MLSKeychainManagerTests: XCTestCase {
    
    var keychainManager: MLSKeychainManager!
    var testConversationID: String!
    var testKeyPackageID: String!
    
    override func setUp() {
        super.setUp()
        keychainManager = MLSKeychainManager.shared
        testConversationID = "test-conversation-\(UUID().uuidString)"
        testKeyPackageID = "test-keypackage-\(UUID().uuidString)"
    }
    
    override func tearDown() {
        // Clean up test data
        try? keychainManager.deleteAllKeys(forConversationID: testConversationID)
        try? keychainManager.deleteHPKEPrivateKey(forKeyPackageID: testKeyPackageID)
        super.tearDown()
    }
    
    // MARK: - Group State Tests
    
    func testStoreAndRetrieveGroupState() throws {
        let testData = Data("test group state".utf8)
        
        try keychainManager.storeGroupState(testData, forConversationID: testConversationID)
        
        let retrieved = try keychainManager.retrieveGroupState(forConversationID: testConversationID)
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, testData)
    }
    
    func testDeleteGroupState() throws {
        let testData = Data("test group state".utf8)
        
        try keychainManager.storeGroupState(testData, forConversationID: testConversationID)
        try keychainManager.deleteGroupState(forConversationID: testConversationID)
        
        let retrieved = try keychainManager.retrieveGroupState(forConversationID: testConversationID)
        
        XCTAssertNil(retrieved)
    }
    
    // MARK: - Private Key Tests
    
    func testStoreAndRetrievePrivateKey() throws {
        let testKey = Data(repeating: 0x01, count: 32)
        let epoch: Int64 = 5
        
        try keychainManager.storePrivateKey(
            testKey,
            forConversationID: testConversationID,
            epoch: epoch
        )
        
        let retrieved = try keychainManager.retrievePrivateKey(
            forConversationID: testConversationID,
            epoch: epoch
        )
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, testKey)
    }
    
    func testDeletePrivateKey() throws {
        let testKey = Data(repeating: 0x01, count: 32)
        let epoch: Int64 = 5
        
        try keychainManager.storePrivateKey(
            testKey,
            forConversationID: testConversationID,
            epoch: epoch
        )
        
        try keychainManager.deletePrivateKey(
            forConversationID: testConversationID,
            epoch: epoch
        )
        
        let retrieved = try keychainManager.retrievePrivateKey(
            forConversationID: testConversationID,
            epoch: epoch
        )
        
        XCTAssertNil(retrieved)
    }
    
    func testDeletePrivateKeysBeforeEpoch() throws {
        // Store keys for epochs 0-4
        for epoch in 0..<5 {
            let testKey = Data(repeating: UInt8(epoch), count: 32)
            try keychainManager.storePrivateKey(
                testKey,
                forConversationID: testConversationID,
                epoch: Int64(epoch)
            )
        }
        
        // Delete keys before epoch 3
        try keychainManager.deletePrivateKeys(
            forConversationID: testConversationID,
            beforeEpoch: 3
        )
        
        // Check that epoch 0-2 are deleted
        let epoch0 = try keychainManager.retrievePrivateKey(
            forConversationID: testConversationID,
            epoch: 0
        )
        let epoch1 = try keychainManager.retrievePrivateKey(
            forConversationID: testConversationID,
            epoch: 1
        )
        let epoch2 = try keychainManager.retrievePrivateKey(
            forConversationID: testConversationID,
            epoch: 2
        )
        
        // Check that epoch 3-4 still exist
        let epoch3 = try keychainManager.retrievePrivateKey(
            forConversationID: testConversationID,
            epoch: 3
        )
        let epoch4 = try keychainManager.retrievePrivateKey(
            forConversationID: testConversationID,
            epoch: 4
        )
        
        XCTAssertNil(epoch0)
        XCTAssertNil(epoch1)
        XCTAssertNil(epoch2)
        XCTAssertNotNil(epoch3)
        XCTAssertNotNil(epoch4)
    }
    
    // MARK: - Signature Key Tests
    
    func testStoreAndRetrieveSignatureKey() throws {
        let testKey = Data(repeating: 0x02, count: 32)
        
        try keychainManager.storeSignatureKey(testKey, forConversationID: testConversationID)
        
        let retrieved = try keychainManager.retrieveSignatureKey(forConversationID: testConversationID)
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, testKey)
    }
    
    func testDeleteSignatureKey() throws {
        let testKey = Data(repeating: 0x02, count: 32)
        
        try keychainManager.storeSignatureKey(testKey, forConversationID: testConversationID)
        try keychainManager.deleteSignatureKey(forConversationID: testConversationID)
        
        let retrieved = try keychainManager.retrieveSignatureKey(forConversationID: testConversationID)
        
        XCTAssertNil(retrieved)
    }
    
    // MARK: - Encryption Key Tests
    
    func testStoreAndRetrieveEncryptionKey() throws {
        let testKey = Data(repeating: 0x03, count: 32)
        
        try keychainManager.storeEncryptionKey(testKey, forConversationID: testConversationID)
        
        let retrieved = try keychainManager.retrieveEncryptionKey(forConversationID: testConversationID)
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, testKey)
    }
    
    // MARK: - Epoch Secrets Tests
    
    func testStoreAndRetrieveEpochSecrets() throws {
        let testSecrets = Data(repeating: 0x04, count: 64)
        let epoch: Int64 = 10
        
        try keychainManager.storeEpochSecrets(
            testSecrets,
            forConversationID: testConversationID,
            epoch: epoch
        )
        
        let retrieved = try keychainManager.retrieveEpochSecrets(
            forConversationID: testConversationID,
            epoch: epoch
        )
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, testSecrets)
    }
    
    // MARK: - HPKE Key Tests
    
    func testStoreAndRetrieveHPKEPrivateKey() throws {
        let testKey = Data(repeating: 0x05, count: 32)
        
        try keychainManager.storeHPKEPrivateKey(testKey, forKeyPackageID: testKeyPackageID)
        
        let retrieved = try keychainManager.retrieveHPKEPrivateKey(forKeyPackageID: testKeyPackageID)
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, testKey)
    }
    
    func testDeleteHPKEPrivateKey() throws {
        let testKey = Data(repeating: 0x05, count: 32)
        
        try keychainManager.storeHPKEPrivateKey(testKey, forKeyPackageID: testKeyPackageID)
        try keychainManager.deleteHPKEPrivateKey(forKeyPackageID: testKeyPackageID)
        
        let retrieved = try keychainManager.retrieveHPKEPrivateKey(forKeyPackageID: testKeyPackageID)
        
        XCTAssertNil(retrieved)
    }
    
    // MARK: - Batch Operations Tests
    
    func testDeleteAllKeys() throws {
        // Store multiple keys
        try keychainManager.storeGroupState(Data("test".utf8), forConversationID: testConversationID)
        try keychainManager.storeSignatureKey(Data(repeating: 0x01, count: 32), forConversationID: testConversationID)
        try keychainManager.storeEncryptionKey(Data(repeating: 0x02, count: 32), forConversationID: testConversationID)
        try keychainManager.storePrivateKey(Data(repeating: 0x03, count: 32), forConversationID: testConversationID, epoch: 0)
        
        // Delete all keys
        try keychainManager.deleteAllKeys(forConversationID: testConversationID)
        
        // Verify all are deleted
        XCTAssertNil(try keychainManager.retrieveGroupState(forConversationID: testConversationID))
        XCTAssertNil(try keychainManager.retrieveSignatureKey(forConversationID: testConversationID))
        XCTAssertNil(try keychainManager.retrieveEncryptionKey(forConversationID: testConversationID))
        XCTAssertNil(try keychainManager.retrievePrivateKey(forConversationID: testConversationID, epoch: 0))
    }
    
    // MARK: - Archive Tests
    
    func testArchiveAndRetrieveKey() throws {
        let testKey = Data(repeating: 0x06, count: 32)
        let epoch: Int64 = 5
        
        try keychainManager.archiveKey(
            testKey,
            type: "signature",
            conversationID: testConversationID,
            epoch: epoch
        )
        
        let retrieved = try keychainManager.retrieveArchivedKey(
            type: "signature",
            conversationID: testConversationID,
            epoch: epoch
        )
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, testKey)
    }
    
    // MARK: - Utility Tests
    
    func testGenerateSecureRandomKey() throws {
        let key1 = try keychainManager.generateSecureRandomKey(length: 32)
        let key2 = try keychainManager.generateSecureRandomKey(length: 32)
        
        XCTAssertEqual(key1.count, 32)
        XCTAssertEqual(key2.count, 32)
        XCTAssertNotEqual(key1, key2) // Should be different random keys
    }
    
    func testVerifyKeychainAccess() throws {
        XCTAssertNoThrow(try keychainManager.verifyKeychainAccess())
    }
    
    // MARK: - Update Tests
    
    func testUpdateExistingKey() throws {
        let originalKey = Data(repeating: 0x01, count: 32)
        let updatedKey = Data(repeating: 0x02, count: 32)
        
        try keychainManager.storeSignatureKey(originalKey, forConversationID: testConversationID)
        
        var retrieved = try keychainManager.retrieveSignatureKey(forConversationID: testConversationID)
        XCTAssertEqual(retrieved, originalKey)
        
        // Store again should update
        try keychainManager.storeSignatureKey(updatedKey, forConversationID: testConversationID)
        
        retrieved = try keychainManager.retrieveSignatureKey(forConversationID: testConversationID)
        XCTAssertEqual(retrieved, updatedKey)
    }
    
    // MARK: - Multiple Conversations Tests
    
    func testMultipleConversations() throws {
        let conversationID1 = "test-conv-1"
        let conversationID2 = "test-conv-2"
        
        let key1 = Data(repeating: 0x01, count: 32)
        let key2 = Data(repeating: 0x02, count: 32)
        
        try keychainManager.storeSignatureKey(key1, forConversationID: conversationID1)
        try keychainManager.storeSignatureKey(key2, forConversationID: conversationID2)
        
        let retrieved1 = try keychainManager.retrieveSignatureKey(forConversationID: conversationID1)
        let retrieved2 = try keychainManager.retrieveSignatureKey(forConversationID: conversationID2)
        
        XCTAssertEqual(retrieved1, key1)
        XCTAssertEqual(retrieved2, key2)
        
        // Cleanup
        try keychainManager.deleteAllKeys(forConversationID: conversationID1)
        try keychainManager.deleteAllKeys(forConversationID: conversationID2)
    }
    
    // MARK: - Current Epoch Tests
    
    func testStoreAndRetrieveCurrentEpoch() throws {
        let epoch = 42
        
        try keychainManager.storeCurrentEpoch(epoch, forConversationID: testConversationID)
        
        let retrieved = try keychainManager.retrieveCurrentEpoch(forConversationID: testConversationID)
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, epoch)
    }
    
    func testRetrieveNonexistentCurrentEpoch() throws {
        let retrieved = try keychainManager.retrieveCurrentEpoch(forConversationID: "nonexistent-conversation")
        
        XCTAssertNil(retrieved, "Should return nil for nonexistent epoch")
    }
    
    func testUpdateCurrentEpoch() throws {
        // Store initial epoch
        try keychainManager.storeCurrentEpoch(0, forConversationID: testConversationID)
        
        let retrieved1 = try keychainManager.retrieveCurrentEpoch(forConversationID: testConversationID)
        XCTAssertEqual(retrieved1, 0)
        
        // Update to new epoch
        try keychainManager.storeCurrentEpoch(5, forConversationID: testConversationID)
        
        let retrieved2 = try keychainManager.retrieveCurrentEpoch(forConversationID: testConversationID)
        XCTAssertEqual(retrieved2, 5)
        
        // Update again
        try keychainManager.storeCurrentEpoch(10, forConversationID: testConversationID)
        
        let retrieved3 = try keychainManager.retrieveCurrentEpoch(forConversationID: testConversationID)
        XCTAssertEqual(retrieved3, 10)
    }
    
    func testDeleteCurrentEpoch() throws {
        try keychainManager.storeCurrentEpoch(42, forConversationID: testConversationID)
        
        // Verify stored
        let retrieved1 = try keychainManager.retrieveCurrentEpoch(forConversationID: testConversationID)
        XCTAssertEqual(retrieved1, 42)
        
        // Delete
        try keychainManager.deleteCurrentEpoch(forConversationID: testConversationID)
        
        // Verify deleted
        let retrieved2 = try keychainManager.retrieveCurrentEpoch(forConversationID: testConversationID)
        XCTAssertNil(retrieved2)
    }
    
    func testCurrentEpochZeroValue() throws {
        // Test that epoch 0 is stored and retrieved correctly
        try keychainManager.storeCurrentEpoch(0, forConversationID: testConversationID)
        
        let retrieved = try keychainManager.retrieveCurrentEpoch(forConversationID: testConversationID)
        
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved, 0)
    }
    
    func testCurrentEpochLargeValue() throws {
        // Test large epoch values
        let largeEpoch = Int.max - 1
        
        try keychainManager.storeCurrentEpoch(largeEpoch, forConversationID: testConversationID)
        
        let retrieved = try keychainManager.retrieveCurrentEpoch(forConversationID: testConversationID)
        
        XCTAssertEqual(retrieved, largeEpoch)
    }
    
    func testCurrentEpochIsolationBetweenConversations() throws {
        let conversationID1 = "conversation-1-\(UUID().uuidString)"
        let conversationID2 = "conversation-2-\(UUID().uuidString)"
        
        let epoch1 = 10
        let epoch2 = 20
        
        try keychainManager.storeCurrentEpoch(epoch1, forConversationID: conversationID1)
        try keychainManager.storeCurrentEpoch(epoch2, forConversationID: conversationID2)
        
        let retrieved1 = try keychainManager.retrieveCurrentEpoch(forConversationID: conversationID1)
        let retrieved2 = try keychainManager.retrieveCurrentEpoch(forConversationID: conversationID2)
        
        XCTAssertEqual(retrieved1, epoch1)
        XCTAssertEqual(retrieved2, epoch2)
        
        // Cleanup
        try keychainManager.deleteAllKeys(forConversationID: conversationID1)
        try keychainManager.deleteAllKeys(forConversationID: conversationID2)
    }
    
    func testCurrentEpochPersistenceAfterCleanup() throws {
        // Store epoch
        try keychainManager.storeCurrentEpoch(42, forConversationID: testConversationID)
        
        // Store some other data
        let testData = Data("test".utf8)
        try keychainManager.storeGroupState(testData, forConversationID: testConversationID)
        
        // Cleanup should include epoch deletion
        try keychainManager.deleteAllKeys(forConversationID: testConversationID)
        
        // Verify epoch was deleted
        let retrieved = try keychainManager.retrieveCurrentEpoch(forConversationID: testConversationID)
        XCTAssertNil(retrieved, "Epoch should be deleted as part of cleanup")
    }
    
    func testCurrentEpochIncrement() throws {
        // Simulate epoch increments during group operations
        for expectedEpoch in 0...10 {
            try keychainManager.storeCurrentEpoch(expectedEpoch, forConversationID: testConversationID)
            
            let retrieved = try keychainManager.retrieveCurrentEpoch(forConversationID: testConversationID)
            XCTAssertEqual(retrieved, expectedEpoch, "Epoch \(expectedEpoch) should be stored correctly")
        }
    }
}
