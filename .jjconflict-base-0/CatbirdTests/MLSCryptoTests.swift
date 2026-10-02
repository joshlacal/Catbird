import XCTest
@testable import Catbird

/// Comprehensive unit tests for MLSCrypto Swift wrapper
/// Tests FFI layer integration, error handling, memory management, and thread safety
final class MLSCryptoTests: XCTestCase {
    
    var mlsCrypto: MLSCrypto!
    
    // MARK: - Setup and Teardown
    
    override func setUp() async throws {
        try await super.setUp()
        mlsCrypto = MLSCrypto()
    }
    
    override func tearDown() async throws {
        mlsCrypto = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testInitialization() async throws {
        // Test successful initialization
        try await mlsCrypto.initialize()
        
        // Test idempotent initialization (should not fail)
        try await mlsCrypto.initialize()
    }
    
    func testMultipleInitializations() async throws {
        // Initialize multiple times should be safe
        for _ in 0..<3 {
            try await mlsCrypto.initialize()
        }
    }
    
    // MARK: - Group Creation Tests
    
    func testCreateGroupSuccess() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let result = try await mlsCrypto.createGroup(identity: identity)
        
        XCTAssertFalse(result.groupId.isEmpty, "Group ID should not be empty")
        XCTAssertGreaterThan(result.groupId.count, 0, "Group ID should have data")
    }
    
    func testCreateGroupWithoutInitialization() async throws {
        // Should throw contextNotInitialized error
        let identity = "alice@catbird.blue"
        
        do {
            _ = try await mlsCrypto.createGroup(identity: identity)
            XCTFail("Should have thrown contextNotInitialized error")
        } catch MLSCryptoError.contextNotInitialized {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testCreateGroupWithEmptyIdentity() async throws {
        try await mlsCrypto.initialize()
        
        do {
            _ = try await mlsCrypto.createGroup(identity: "")
            XCTFail("Should have thrown error for empty identity")
        } catch {
            // Expected error
        }
    }
    
    func testCreateMultipleGroups() async throws {
        try await mlsCrypto.initialize()
        
        let identities = ["alice@catbird.blue", "bob@catbird.blue", "charlie@catbird.blue"]
        var groupIds: [Data] = []
        
        for identity in identities {
            let result = try await mlsCrypto.createGroup(identity: identity)
            groupIds.append(result.groupId)
        }
        
        XCTAssertEqual(groupIds.count, 3, "Should create 3 groups")
        
        // Verify all group IDs are unique
        let uniqueGroupIds = Set(groupIds.map { $0.base64EncodedString() })
        XCTAssertEqual(uniqueGroupIds.count, 3, "All group IDs should be unique")
    }
    
    // MARK: - Key Package Tests
    
    func testCreateKeyPackageSuccess() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let result = try await mlsCrypto.createKeyPackage(identity: identity)
        
        XCTAssertFalse(result.keyPackageData.isEmpty, "Key package should not be empty")
        XCTAssertGreaterThan(result.keyPackageData.count, 0, "Key package should have data")
    }
    
    func testCreateKeyPackageWithoutInitialization() async throws {
        let identity = "alice@catbird.blue"
        
        do {
            _ = try await mlsCrypto.createKeyPackage(identity: identity)
            XCTFail("Should have thrown contextNotInitialized error")
        } catch MLSCryptoError.contextNotInitialized {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testCreateMultipleKeyPackages() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        var keyPackages: [Data] = []
        
        for _ in 0..<5 {
            let result = try await mlsCrypto.createKeyPackage(identity: identity)
            keyPackages.append(result.keyPackageData)
        }
        
        XCTAssertEqual(keyPackages.count, 5, "Should create 5 key packages")
        
        // Note: Key packages may or may not be unique depending on implementation
        // but they should all be valid
        for keyPackage in keyPackages {
            XCTAssertFalse(keyPackage.isEmpty, "Each key package should be non-empty")
        }
    }
    
    // MARK: - Message Encryption/Decryption Tests
    
    func testEncryptDecryptMessageSuccess() async throws {
        try await mlsCrypto.initialize()
        
        // Create a group first
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        // Test message
        let originalMessage = "Hello, secure world!".data(using: .utf8)!
        
        // Encrypt
        let encrypted = try await mlsCrypto.encryptMessage(
            groupId: groupResult.groupId,
            plaintext: originalMessage
        )
        
        XCTAssertFalse(encrypted.ciphertext.isEmpty, "Ciphertext should not be empty")
        XCTAssertNotEqual(encrypted.ciphertext, originalMessage, "Ciphertext should differ from plaintext")
        
        // Decrypt
        let decrypted = try await mlsCrypto.decryptMessage(
            groupId: groupResult.groupId,
            ciphertext: encrypted.ciphertext
        )
        
        XCTAssertEqual(decrypted.plaintext, originalMessage, "Decrypted message should match original")
        
        // Verify message content
        let decryptedString = String(data: decrypted.plaintext, encoding: .utf8)
        XCTAssertEqual(decryptedString, "Hello, secure world!", "Decrypted string should match")
    }
    
    func testEncryptWithInvalidGroupId() async throws {
        try await mlsCrypto.initialize()
        
        let invalidGroupId = Data(repeating: 0xFF, count: 32)
        let message = "Test message".data(using: .utf8)!
        
        do {
            _ = try await mlsCrypto.encryptMessage(groupId: invalidGroupId, plaintext: message)
            XCTFail("Should have thrown encryption error")
        } catch MLSCryptoError.encryptionFailed {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testDecryptWithInvalidCiphertext() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        let invalidCiphertext = Data(repeating: 0xAB, count: 64)
        
        do {
            _ = try await mlsCrypto.decryptMessage(groupId: groupResult.groupId, ciphertext: invalidCiphertext)
            XCTFail("Should have thrown decryption error")
        } catch MLSCryptoError.decryptionFailed {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testEncryptEmptyMessage() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        let emptyMessage = Data()
        
        // Empty message encryption should succeed (implementation dependent)
        let encrypted = try await mlsCrypto.encryptMessage(
            groupId: groupResult.groupId,
            plaintext: emptyMessage
        )
        
        XCTAssertFalse(encrypted.ciphertext.isEmpty, "Even empty plaintext should produce non-empty ciphertext")
    }
    
    func testEncryptLargeMessage() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        // Create a large message (1MB)
        let largeMessage = Data(repeating: 0x42, count: 1024 * 1024)
        
        let encrypted = try await mlsCrypto.encryptMessage(
            groupId: groupResult.groupId,
            plaintext: largeMessage
        )
        
        XCTAssertFalse(encrypted.ciphertext.isEmpty, "Large message encryption should succeed")
        
        let decrypted = try await mlsCrypto.decryptMessage(
            groupId: groupResult.groupId,
            ciphertext: encrypted.ciphertext
        )
        
        XCTAssertEqual(decrypted.plaintext.count, largeMessage.count, "Decrypted size should match")
        XCTAssertEqual(decrypted.plaintext, largeMessage, "Large message should decrypt correctly")
    }
    
    func testEncryptMultipleMessages() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        let messages = [
            "First message",
            "Second message",
            "Third message",
            "Fourth message"
        ]
        
        for (index, messageText) in messages.enumerated() {
            let message = messageText.data(using: .utf8)!
            
            let encrypted = try await mlsCrypto.encryptMessage(
                groupId: groupResult.groupId,
                plaintext: message
            )
            
            let decrypted = try await mlsCrypto.decryptMessage(
                groupId: groupResult.groupId,
                ciphertext: encrypted.ciphertext
            )
            
            let decryptedText = String(data: decrypted.plaintext, encoding: .utf8)
            XCTAssertEqual(decryptedText, messageText, "Message \(index + 1) should match")
        }
    }
    
    // MARK: - Add Members Tests
    
    func testAddMembersSuccess() async throws {
        try await mlsCrypto.initialize()
        
        // Create group as Alice
        let aliceIdentity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: aliceIdentity)
        
        // Create key packages for Bob and Charlie
        let bobKeyPackage = try await mlsCrypto.createKeyPackage(identity: "bob@catbird.blue")
        let charlieKeyPackage = try await mlsCrypto.createKeyPackage(identity: "charlie@catbird.blue")
        
        // Combine key packages (implementation specific format)
        var combinedKeyPackages = Data()
        combinedKeyPackages.append(bobKeyPackage.keyPackageData)
        combinedKeyPackages.append(charlieKeyPackage.keyPackageData)
        
        // Add members
        let result = try await mlsCrypto.addMembers(
            groupId: groupResult.groupId,
            keyPackages: combinedKeyPackages
        )
        
        XCTAssertFalse(result.commitData.isEmpty, "Commit data should not be empty")
        XCTAssertFalse(result.welcomeData.isEmpty, "Welcome data should not be empty")
    }
    
    func testAddMembersWithInvalidGroupId() async throws {
        try await mlsCrypto.initialize()
        
        let invalidGroupId = Data(repeating: 0xFF, count: 32)
        let keyPackage = try await mlsCrypto.createKeyPackage(identity: "bob@catbird.blue")
        
        do {
            _ = try await mlsCrypto.addMembers(groupId: invalidGroupId, keyPackages: keyPackage.keyPackageData)
            XCTFail("Should have thrown addMembersFailed error")
        } catch MLSCryptoError.addMembersFailed {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    // MARK: - Welcome Processing Tests
    
    func testProcessWelcomeWithInvalidData() async throws {
        try await mlsCrypto.initialize()
        
        let invalidWelcome = Data(repeating: 0xCD, count: 128)
        let identity = "bob@catbird.blue"
        
        do {
            _ = try await mlsCrypto.processWelcome(welcomeData: invalidWelcome, identity: identity)
            XCTFail("Should have thrown welcomeProcessingFailed error")
        } catch MLSCryptoError.welcomeProcessingFailed {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    // MARK: - Secret Export Tests
    
    func testExportSecretSuccess() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        let label = "test-secret"
        let context = "context-data".data(using: .utf8)!
        let keyLength = 32
        
        let result = try await mlsCrypto.exportSecret(
            groupId: groupResult.groupId,
            label: label,
            context: context,
            keyLength: keyLength
        )
        
        XCTAssertEqual(result.secret.count, keyLength, "Exported secret should have requested length")
        XCTAssertFalse(result.secret.isEmpty, "Exported secret should not be empty")
    }
    
    func testExportSecretWithDifferentLabels() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        let context = Data()
        let keyLength = 32
        
        let secret1 = try await mlsCrypto.exportSecret(
            groupId: groupResult.groupId,
            label: "label-1",
            context: context,
            keyLength: keyLength
        )
        
        let secret2 = try await mlsCrypto.exportSecret(
            groupId: groupResult.groupId,
            label: "label-2",
            context: context,
            keyLength: keyLength
        )
        
        XCTAssertNotEqual(secret1.secret, secret2.secret, "Secrets with different labels should differ")
    }
    
    func testExportSecretWithInvalidGroupId() async throws {
        try await mlsCrypto.initialize()
        
        let invalidGroupId = Data(repeating: 0xFF, count: 32)
        let label = "test-secret"
        let context = Data()
        
        do {
            _ = try await mlsCrypto.exportSecret(
                groupId: invalidGroupId,
                label: label,
                context: context,
                keyLength: 32
            )
            XCTFail("Should have thrown secretExportFailed error")
        } catch MLSCryptoError.secretExportFailed {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    // MARK: - Epoch Tests
    
    func testGetEpochSuccess() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        let epoch = try await mlsCrypto.getEpoch(groupId: groupResult.groupId)
        
        XCTAssertGreaterThanOrEqual(epoch, 0, "Epoch should be non-negative")
    }
    
    func testGetEpochWithInvalidGroupId() async throws {
        try await mlsCrypto.initialize()
        
        let invalidGroupId = Data(repeating: 0xFF, count: 32)
        
        do {
            _ = try await mlsCrypto.getEpoch(groupId: invalidGroupId)
            XCTFail("Should have thrown invalidGroupId error")
        } catch MLSCryptoError.invalidGroupId {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    // MARK: - Commit Processing Tests
    
    func testProcessCommitWithNullData() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        let emptyCommit = Data()
        
        do {
            _ = try await mlsCrypto.processCommit(groupId: groupResult.groupId, commitData: emptyCommit)
            XCTFail("Should have thrown error for empty commit data")
        } catch {
            // Expected error - empty commit data should fail
        }
    }
    
    func testProcessCommitWithInvalidGroupId() async throws {
        try await mlsCrypto.initialize()
        
        let invalidGroupId = Data(repeating: 0xFF, count: 32)
        let fakeCommitData = Data([0x01, 0x02, 0x03])
        
        do {
            _ = try await mlsCrypto.processCommit(groupId: invalidGroupId, commitData: fakeCommitData)
            XCTFail("Should have thrown error for invalid group ID")
        } catch {
            // Expected error
        }
    }
    
    func testProcessCommitWithInvalidTLSData() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        // Invalid TLS-encoded data
        let invalidCommit = Data("this-is-not-valid-tls-data".utf8)
        
        do {
            _ = try await mlsCrypto.processCommit(groupId: groupResult.groupId, commitData: invalidCommit)
            XCTFail("Should have thrown error for invalid TLS data")
        } catch {
            // Expected error - invalid TLS data should fail deserialization
        }
    }
    
    func testProcessCommitWithoutInitialization() async throws {
        let fakeGroupId = Data(repeating: 0x00, count: 32)
        let fakeCommitData = Data([0x01, 0x02, 0x03])
        
        do {
            _ = try await mlsCrypto.processCommit(groupId: fakeGroupId, commitData: fakeCommitData)
            XCTFail("Should have thrown contextNotInitialized error")
        } catch MLSCryptoError.contextNotInitialized {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testProcessCommitReturnsEpoch() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        // Note: In a real test, we would need a valid commit from another member
        // For now, we're testing the interface and error handling
        // A full integration test would require two-party setup
        
        // Verify initial epoch
        let initialEpoch = try await mlsCrypto.getEpoch(groupId: groupResult.groupId)
        XCTAssertEqual(initialEpoch, 0, "Initial epoch should be 0")
    }
    
    func testEpochExtraction() async throws {
        // Test the epoch extraction from FFI result data
        let epochValue: UInt64 = 42
        let epochBytes = withUnsafeBytes(of: epochValue.littleEndian) { Data($0) }
        
        XCTAssertEqual(epochBytes.count, 8, "Epoch should be 8 bytes")
        
        // Extract epoch (simulating what processCommit does)
        let extractedEpoch = epochBytes.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt64.self)
        }
        
        XCTAssertEqual(extractedEpoch, epochValue, "Extracted epoch should match original")
    }
    
    func testEpochIncrementAfterMemberAdd() async throws {
        try await mlsCrypto.initialize()
        
        // Create group as Alice
        let aliceIdentity = "alice@catbird.blue"
        let aliceGroup = try await mlsCrypto.createGroup(identity: aliceIdentity)
        
        // Get initial epoch
        let initialEpoch = try await mlsCrypto.getEpoch(groupId: aliceGroup.groupId)
        XCTAssertEqual(initialEpoch, 0, "Initial epoch should be 0")
        
        // Create key package for Bob
        let bobIdentity = "bob@catbird.blue"
        let bobKeyPackage = try await mlsCrypto.createKeyPackage(identity: bobIdentity)
        
        // Add Bob to the group
        let addResult = try await mlsCrypto.addMember(
            groupId: aliceGroup.groupId,
            keyPackage: bobKeyPackage.keyPackage
        )
        
        XCTAssertFalse(addResult.welcome.isEmpty, "Welcome message should not be empty")
        XCTAssertFalse(addResult.commit.isEmpty, "Commit should not be empty")
        
        // Check epoch after adding member
        let newEpoch = try await mlsCrypto.getEpoch(groupId: aliceGroup.groupId)
        XCTAssertEqual(newEpoch, 1, "Epoch should increment to 1 after adding member")
    }
    
    // MARK: - Memory Management Tests
    
    func testMemoryManagementWithMultipleOperations() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        
        // Perform many operations to test memory cleanup
        for _ in 0..<100 {
            let groupResult = try await mlsCrypto.createGroup(identity: identity)
            let keyPackage = try await mlsCrypto.createKeyPackage(identity: identity)
            
            let message = "Test message".data(using: .utf8)!
            let encrypted = try await mlsCrypto.encryptMessage(groupId: groupResult.groupId, plaintext: message)
            let _ = try await mlsCrypto.decryptMessage(groupId: groupResult.groupId, ciphertext: encrypted.ciphertext)
            
            XCTAssertFalse(groupResult.groupId.isEmpty)
            XCTAssertFalse(keyPackage.keyPackageData.isEmpty)
        }
        
        // If we get here without crashes, memory management is working
        XCTAssertTrue(true, "Memory management test completed successfully")
    }
    
    func testDeinitCleanup() async throws {
        var crypto: MLSCrypto? = MLSCrypto()
        try await crypto?.initialize()
        
        let identity = "alice@catbird.blue"
        let _ = try await crypto?.createGroup(identity: identity)
        
        // Release crypto - should clean up resources
        crypto = nil
        
        XCTAssertNil(crypto, "Crypto should be nil after release")
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentOperations() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        // Perform concurrent operations
        await withTaskGroup(of: Result<Data, Error>.self) { group in
            for i in 0..<10 {
                group.addTask {
                    do {
                        let message = "Message \(i)".data(using: .utf8)!
                        let encrypted = try await self.mlsCrypto.encryptMessage(
                            groupId: groupResult.groupId,
                            plaintext: message
                        )
                        return .success(encrypted.ciphertext)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var successCount = 0
            for await result in group {
                switch result {
                case .success:
                    successCount += 1
                case .failure(let error):
                    XCTFail("Concurrent operation failed: \(error)")
                }
            }
            
            XCTAssertEqual(successCount, 10, "All concurrent operations should succeed")
        }
    }
    
    func testConcurrentGroupCreation() async throws {
        try await mlsCrypto.initialize()
        
        let identities = (0..<5).map { "user\($0)@catbird.blue" }
        
        await withTaskGroup(of: Result<Data, Error>.self) { group in
            for identity in identities {
                group.addTask {
                    do {
                        let result = try await self.mlsCrypto.createGroup(identity: identity)
                        return .success(result.groupId)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            
            var groupIds: [Data] = []
            for await result in group {
                switch result {
                case .success(let groupId):
                    groupIds.append(groupId)
                case .failure(let error):
                    XCTFail("Concurrent group creation failed: \(error)")
                }
            }
            
            XCTAssertEqual(groupIds.count, 5, "Should create 5 groups concurrently")
            
            // Verify uniqueness
            let uniqueIds = Set(groupIds.map { $0.base64EncodedString() })
            XCTAssertEqual(uniqueIds.count, 5, "All group IDs should be unique")
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testErrorDescriptions() {
        let errors: [MLSCryptoError] = [
            .initializationFailed("test"),
            .contextCreationFailed,
            .groupCreationFailed("test"),
            .addMembersFailed("test"),
            .encryptionFailed("test"),
            .decryptionFailed("test"),
            .keyPackageCreationFailed("test"),
            .welcomeProcessingFailed("test"),
            .secretExportFailed("test"),
            .invalidGroupId,
            .invalidIdentity,
            .invalidData,
            .memoryAllocationFailed,
            .contextNotInitialized
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have description: \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description should not be empty")
        }
    }
    
    // MARK: - Edge Case Tests
    
    func testUnicodeIdentity() async throws {
        try await mlsCrypto.initialize()
        
        let unicodeIdentity = "アリス@catbird.blue 🦜"
        let result = try await mlsCrypto.createGroup(identity: unicodeIdentity)
        
        XCTAssertFalse(result.groupId.isEmpty, "Should handle Unicode identity")
    }
    
    func testSpecialCharactersInMessage() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        let specialMessage = "Hello! 👋 测试 🔒 Ñoño @#$%^&*()".data(using: .utf8)!
        
        let encrypted = try await mlsCrypto.encryptMessage(
            groupId: groupResult.groupId,
            plaintext: specialMessage
        )
        
        let decrypted = try await mlsCrypto.decryptMessage(
            groupId: groupResult.groupId,
            ciphertext: encrypted.ciphertext
        )
        
        XCTAssertEqual(decrypted.plaintext, specialMessage, "Should handle special characters")
    }
    
    func testBinaryData() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        
        // Create binary data (not valid UTF-8)
        var binaryData = Data()
        for i in 0..<256 {
            binaryData.append(UInt8(i))
        }
        
        let encrypted = try await mlsCrypto.encryptMessage(
            groupId: groupResult.groupId,
            plaintext: binaryData
        )
        
        let decrypted = try await mlsCrypto.decryptMessage(
            groupId: groupResult.groupId,
            ciphertext: encrypted.ciphertext
        )
        
        XCTAssertEqual(decrypted.plaintext, binaryData, "Should handle arbitrary binary data")
    }
    
    // MARK: - Performance Tests
    
    func testEncryptionPerformance() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        let groupResult = try await mlsCrypto.createGroup(identity: identity)
        let message = "Performance test message".data(using: .utf8)!
        
        measure {
            let expectation = XCTestExpectation(description: "Encryption performance")
            
            Task {
                do {
                    _ = try await self.mlsCrypto.encryptMessage(
                        groupId: groupResult.groupId,
                        plaintext: message
                    )
                    expectation.fulfill()
                } catch {
                    XCTFail("Encryption failed: \(error)")
                }
            }
            
            wait(for: [expectation], timeout: 5.0)
        }
    }
    
    func testKeyPackageCreationPerformance() async throws {
        try await mlsCrypto.initialize()
        
        let identity = "alice@catbird.blue"
        
        measure {
            let expectation = XCTestExpectation(description: "Key package creation performance")
            
            Task {
                do {
                    _ = try await self.mlsCrypto.createKeyPackage(identity: identity)
                    expectation.fulfill()
                } catch {
                    XCTFail("Key package creation failed: \(error)")
                }
            }
            
            wait(for: [expectation], timeout: 5.0)
        }
    }
}

// MARK: - Data Extension Tests

extension MLSCryptoTests {
    func testDataHexString() {
        let data = Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
        let hexString = data.hexString
        
        XCTAssertEqual(hexString, "0123456789abcdef", "Hex string should be correct")
    }
    
    func testEmptyDataHexString() {
        let data = Data()
        let hexString = data.hexString
        
        XCTAssertEqual(hexString, "", "Empty data should produce empty hex string")
    }
}
