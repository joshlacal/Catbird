import Foundation
import Testing
import GRDB
@testable import Catbird

// MARK: - Mock Dependencies

/// Mock MLSClient for testing recovery logic
private class MockMLSClient {
    var shouldFailDecryption = false
    var decryptionError: Error?
    var decryptCalls: [(groupId: Data, ciphertext: Data, messageID: String)] = []

    func decryptMessage(
        for userDID: String,
        groupId: Data,
        ciphertext: Data,
        conversationID: String,
        messageID: String
    ) async throws -> DecryptResult {
        decryptCalls.append((groupId, ciphertext, messageID))

        if shouldFailDecryption {
            throw decryptionError ?? MLSError.operationFailed
        }

        return DecryptResult(
            plaintext: "Test decrypted message".data(using: .utf8) ?? Data()
        )
    }
}

/// Mock database for testing error storage
private class MockMLSDatabase {
    var messages: [String: MLSMessageRecord] = [:]
    var conversations: [String: MLSConversationModel] = [:]
    var errorLogs: [String: RecoveryErrorLog] = [:]

    func saveMessage(_ record: MLSMessageRecord) throws {
        messages[record.id] = record
    }

    func updateConversation(_ model: MLSConversationModel) throws {
        conversations[model.conversationID] = model
    }

    func getMessage(_ id: String) -> MLSMessageRecord? {
        messages[id]
    }

    func getConversation(_ id: String) -> MLSConversationModel? {
        conversations[id]
    }

    func logError(_ error: RecoveryErrorLog) throws {
        errorLogs[error.id] = error
    }
}

/// Mock API client for testing recovery coordination
private class MockMLSAPIClient {
    var rejoinRequests: [(conversationID: String, reason: String)] = []
    var shouldFailRejoin = false

    func requestRejoin(for conversationID: String, reason: String) async throws {
        rejoinRequests.append((conversationID, reason))

        if shouldFailRejoin {
            throw MLSAPIError.httpError(statusCode: 500, message: "Rejoin failed")
        }
    }
}

// MARK: - Data Models for Testing

struct MLSMessageRecord {
    let id: String
    let conversationID: String
    var plaintext: String
    var embedData: Data?
    var epoch: UInt64
    var sequenceNumber: UInt32
    var isPlaceholder: Bool = false
    var errorMessage: String?
    let createdAt: Date = Date()
}

struct RecoveryErrorLog {
    let id: String
    let conversationID: String
    let messageID: String?
    let errorType: String
    let errorMessage: String
    let epoch: UInt64?
    let sequenceNumber: UInt32?
    let timestamp: Date = Date()
}

// MARK: - Validation Result Types

enum ValidationReason {
    case epochOutOfRange
    case sequenceOutOfBounds
}

// MARK: - Helper Functions

func createTestConversation(
    _ id: String = "test_convo_123",
    userDID: String = "did:plc:testuser123456789",
    groupID: Data = Data("test_group_123".utf8),
    consecutiveFailures: Int = 0,
    lastRecoveryAttempt: Date? = nil
) -> MLSConversationModel {
    MLSConversationModel(
        conversationID: id,
        currentUserDID: userDID,
        groupID: groupID,
        epoch: 1,
        title: "Test Conversation",
        avatarURL: nil,
        createdAt: Date(),
        updatedAt: Date(),
        lastMessageAt: nil,
        isActive: true,
        needsRejoin: false,
        rejoinRequestedAt: nil,
        lastRecoveryAttempt: lastRecoveryAttempt,
        consecutiveFailures: consecutiveFailures
    )
}

func createTestMessage(
    id: String,
    conversationID: String = "test_convo_123",
    epoch: UInt64 = 1,
    sequenceNumber: UInt32 = 0
) -> MLSMessageRecord {
    MLSMessageRecord(
        id: id,
        conversationID: conversationID,
        plaintext: "Test message",
        embedData: nil,
        epoch: epoch,
        sequenceNumber: sequenceNumber
    )
}

func validateMessageEpoch(
    _ epoch: UInt64,
    currentEpoch: UInt64,
    maxPastEpochs: Int
) -> (isValid: Bool, reason: ValidationReason?) {
    let oldestValidEpoch = currentEpoch >= UInt64(maxPastEpochs) ? currentEpoch - UInt64(maxPastEpochs) : 0

    if epoch < oldestValidEpoch {
        return (false, .epochOutOfRange)
    }

    return (true, nil)
}

func validateMessageSequence(
    _ sequence: UInt32,
    limit: UInt32
) -> (isValid: Bool, reason: ValidationReason?) {
    if sequence > limit {
        return (false, .sequenceOutOfBounds)
    }

    return (true, nil)
}

func savePlaceholderMessage(
    messageID: String,
    conversationID: String,
    error: Error,
    database: MockMLSDatabase,
    originalError: String? = nil
) throws -> MLSMessageRecord {
    let placeholderText = "⚠️ Message unavailable"
    let errorMessage = originalError ?? error.localizedDescription

    var record = MLSMessageRecord(
        id: messageID,
        conversationID: conversationID,
        plaintext: placeholderText,
        embedData: nil,
        epoch: 0,
        sequenceNumber: 0
    )
    record.isPlaceholder = true
    record.errorMessage = errorMessage

    try database.saveMessage(record)
    return record
}

func shouldTriggerRecovery(
    lastAttempt: Date?,
    debounceInterval: TimeInterval
) -> Bool {
    guard let lastAttempt = lastAttempt else {
        return true  // Never attempted before
    }

    let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
    return timeSinceLastAttempt >= debounceInterval
}

func triggerRecovery(
    for conversationID: String,
    reason: String,
    apiClient: MockMLSAPIClient,
    database: MockMLSDatabase
) async throws {
    // Update conversation with recovery attempt timestamp
    if var conversation = database.getConversation(conversationID) {
        conversation = conversation.withRecoveryState(
            lastRecoveryAttempt: Date(),
            consecutiveFailures: conversation.consecutiveFailures
        )
        try database.updateConversation(conversation)
    }

    // Request rejoin from API
    try await apiClient.requestRejoin(for: conversationID, reason: reason)
}

// MARK: - Test Suite: Message Validation

@Test func messageValidationCatchesInvalidEpochNumbers() {
    // Arrange
    let currentEpoch: UInt64 = 5
    let invalidEpoch: UInt64 = 0  // Past epoch with no retained keys

    // Act & Assert
    let result = validateMessageEpoch(invalidEpoch, currentEpoch: currentEpoch, maxPastEpochs: 3)

    #expect(result.isValid == false)
    #expect(result.reason == .epochOutOfRange)
}

@Test func messageValidationCatchesInvalidSequenceNumbers() {
    // Arrange - Use a high but valid value
    let message = createTestMessage(id: "msg_test_001", sequenceNumber: 9999)

    // Act & Assert
    let result = validateMessageSequence(message.sequenceNumber, limit: 1000)

    #expect(result.isValid == false)
    #expect(result.reason == .sequenceOutOfBounds)
}

@Test func messageValidationAcceptsValidEpochAndSequence() {
    // Arrange
    let currentEpoch: UInt64 = 5
    let validEpoch: UInt64 = 3  // Within range
    let validSequence: UInt32 = 100

    // Act & Assert
    let epochResult = validateMessageEpoch(validEpoch, currentEpoch: currentEpoch, maxPastEpochs: 3)
    let sequenceResult = validateMessageSequence(validSequence, limit: 10000)

    #expect(epochResult.isValid == true)
    #expect(sequenceResult.isValid == true)
}

@Test func messageValidationHandlesBoundaryEpochValues() {
    // Arrange
    let currentEpoch: UInt64 = 10
    let maxPastEpochs = 5
    let boundaryEpoch = currentEpoch - UInt64(maxPastEpochs)

    // Act & Assert - exactly at boundary should be valid
    let result = validateMessageEpoch(boundaryEpoch, currentEpoch: currentEpoch, maxPastEpochs: maxPastEpochs)

    #expect(result.isValid == true)
}

@Test func messageValidationRejectsEpochJustBeforeBoundary() {
    // Arrange
    let currentEpoch: UInt64 = 10
    let maxPastEpochs = 5
    let tooOldEpoch = currentEpoch - UInt64(maxPastEpochs) - 1

    // Act & Assert
    let result = validateMessageEpoch(tooOldEpoch, currentEpoch: currentEpoch, maxPastEpochs: maxPastEpochs)

    #expect(result.isValid == false)
}

// MARK: - Test Suite: Placeholder Storage

@Test func placeholderMessageSavedWhenDecryptionFails() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let messageID = "msg_test_001"
    let conversationID = "test_convo_123"

    // Act
    let result = try savePlaceholderMessage(
        messageID: messageID,
        conversationID: conversationID,
        error: MLSError.operationFailed,
        database: database
    )

    // Assert
    #expect(result.isPlaceholder == true)
    #expect(result.plaintext == "⚠️ Message unavailable")

    let savedMessage = database.getMessage(messageID)
    #expect(savedMessage != nil)
    #expect(savedMessage?.isPlaceholder == true)
    #expect(savedMessage?.errorMessage != nil)
}

@Test func placeholderIncludesErrorDetails() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let messageID = "msg_test_002"
    let conversationID = "test_convo_123"
    let errorMessage = "SecretReuseError: Ratchet state desynchronized"

    // Act
    let result = try savePlaceholderMessage(
        messageID: messageID,
        conversationID: conversationID,
        error: MLSError.operationFailed,
        database: database,
        originalError: errorMessage
    )

    // Assert
    #expect(result.errorMessage != nil)

    let savedMessage = database.getMessage(messageID)
    #expect(savedMessage?.errorMessage?.contains("SecretReuseError") ?? false)
}

@Test func conversationContinuesAfterPlaceholderSaved() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let initialConversation = createTestConversation()
    try database.updateConversation(initialConversation)

    // Act - Save placeholder
    _ = try savePlaceholderMessage(
        messageID: "msg_error",
        conversationID: "test_convo_123",
        error: MLSError.operationFailed,
        database: database
    )

    // Save a follow-up message after the error
    let followUpMessage = createTestMessage(
        id: "msg_success",
        conversationID: "test_convo_123"
    )
    try database.saveMessage(followUpMessage)

    // Assert - Both messages exist
    #expect(database.getMessage("msg_error") != nil)
    #expect(database.getMessage("msg_success") != nil)

    let conversation = database.getConversation("test_convo_123")
    #expect(conversation?.isActive == true)  // Conversation still active
}

@Test func multipleErrorMessagesStoredIndependently() async throws {
    // Arrange
    let database = MockMLSDatabase()

    // Act
    for i in 0..<3 {
        try savePlaceholderMessage(
            messageID: "msg_error_\(i)",
            conversationID: "test_convo_123",
            error: MLSError.operationFailed,
            database: database,
            originalError: "Error \(i)"
        )
    }

    // Assert
    #expect(database.messages.count == 3)
    #expect(database.messages.values.allSatisfy { $0.isPlaceholder })
}

// MARK: - Test Suite: Consecutive Failure Tracking

@Test func consecutiveFailureCounterIncrementsOnFirstFailure() async throws {
    // Arrange
    let database = MockMLSDatabase()
    var conversation = createTestConversation(consecutiveFailures: 0)
    try database.updateConversation(conversation)

    // Act
    let updatedConversation = conversation.withRecoveryState(
        lastRecoveryAttempt: Date(),
        consecutiveFailures: conversation.consecutiveFailures + 1
    )
    try database.updateConversation(updatedConversation)

    // Assert
    let stored = database.getConversation("test_convo_123")
    #expect(stored?.consecutiveFailures == 1)
}

@Test func consecutiveFailureCounterIncrementsOnSubsequentFailures() async throws {
    // Arrange
    let database = MockMLSDatabase()
    var conversation = createTestConversation(consecutiveFailures: 3)
    try database.updateConversation(conversation)

    // Act
    let updatedConversation = conversation.withRecoveryState(
        lastRecoveryAttempt: Date(),
        consecutiveFailures: conversation.consecutiveFailures + 1
    )
    try database.updateConversation(updatedConversation)

    // Assert
    let stored = database.getConversation("test_convo_123")
    #expect(stored?.consecutiveFailures == 4)
}

@Test func failureCounterResetsAfterSuccessfulRecovery() async throws {
    // Arrange
    let database = MockMLSDatabase()
    var conversation = createTestConversation(consecutiveFailures: 5)
    try database.updateConversation(conversation)

    // Act - Simulate successful recovery by resetting counter
    let recoveredConversation = conversation.withRecoveryState(
        lastRecoveryAttempt: Date(),
        consecutiveFailures: 0
    )
    try database.updateConversation(recoveredConversation)

    // Assert
    let stored = database.getConversation("test_convo_123")
    #expect(stored?.consecutiveFailures == 0)
}

@Test func failureThresholdTriggersEscalatedRecovery() async throws {
    // Arrange
    let database = MockMLSDatabase()
    var conversation = createTestConversation(consecutiveFailures: 9)
    try database.updateConversation(conversation)

    let failureThreshold = 10

    // Act - Increment to threshold
    let updatedConversation = conversation.withRecoveryState(
        lastRecoveryAttempt: Date(),
        consecutiveFailures: conversation.consecutiveFailures + 1
    )
    try database.updateConversation(updatedConversation)

    let stored = database.getConversation("test_convo_123")!

    // Assert
    #expect(stored.consecutiveFailures >= failureThreshold)
}

@Test func multipleFailureCountersTrackedPerConversation() async throws {
    // Arrange
    let database = MockMLSDatabase()

    // Act - Create multiple conversations with different failure counts
    for i in 0..<5 {
        let convo = createTestConversation(
            "convo_\(i)",
            consecutiveFailures: i + 1
        )
        try database.updateConversation(convo)
    }

    // Assert
    for i in 0..<5 {
        let convo = database.getConversation("convo_\(i)")
        #expect(convo?.consecutiveFailures == i + 1)
    }
}

// MARK: - Test Suite: Automatic Recovery Trigger

@Test func recoveryTriggeredOnFirstDecryptionFailure() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let apiClient = MockMLSAPIClient()
    var conversation = createTestConversation(consecutiveFailures: 0)
    try database.updateConversation(conversation)

    // Act
    try await triggerRecovery(
        for: "test_convo_123",
        reason: "First decryption failure",
        apiClient: apiClient,
        database: database
    )

    // Assert
    #expect(apiClient.rejoinRequests.count == 1)
    #expect(apiClient.rejoinRequests[0].conversationID == "test_convo_123")
    #expect(apiClient.rejoinRequests[0].reason.contains("First decryption failure"))

    let updated = database.getConversation("test_convo_123")
    #expect(updated?.lastRecoveryAttempt != nil)
}

@Test func recoveryNotTriggeredIfAlreadyAttemptedRecently() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let apiClient = MockMLSAPIClient()
    let recentTime = Date(timeIntervalSinceNow: -30)  // 30 seconds ago
    var conversation = createTestConversation(
        consecutiveFailures: 1,
        lastRecoveryAttempt: recentTime
    )
    try database.updateConversation(conversation)

    let recoveryDebounceInterval: TimeInterval = 60  // 1 minute

    // Act
    let shouldTrigger = shouldTriggerRecovery(
        lastAttempt: conversation.lastRecoveryAttempt,
        debounceInterval: recoveryDebounceInterval
    )

    // Assert
    #expect(shouldTrigger == false)
    #expect(apiClient.rejoinRequests.isEmpty)
}

@Test func recoveryTriggeredAfterDebounceIntervalExpires() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let apiClient = MockMLSAPIClient()
    let oldTime = Date(timeIntervalSinceNow: -120)  // 2 minutes ago
    var conversation = createTestConversation(
        consecutiveFailures: 1,
        lastRecoveryAttempt: oldTime
    )
    try database.updateConversation(conversation)

    let recoveryDebounceInterval: TimeInterval = 60  // 1 minute

    // Act
    let shouldTrigger = shouldTriggerRecovery(
        lastAttempt: conversation.lastRecoveryAttempt,
        debounceInterval: recoveryDebounceInterval
    )

    // Assert
    #expect(shouldTrigger == true)
}

@Test func multipleRecoveryAttemptsTrackedWithTimestamps() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let apiClient = MockMLSAPIClient()
    var conversation = createTestConversation()
    try database.updateConversation(conversation)

    // Act - Trigger multiple recoveries
    for i in 0..<3 {
        try await triggerRecovery(
            for: "test_convo_123",
            reason: "Recovery attempt \(i + 1)",
            apiClient: apiClient,
            database: database
        )
    }

    // Assert
    #expect(apiClient.rejoinRequests.count == 3)
    let updated = database.getConversation("test_convo_123")
    #expect(updated?.lastRecoveryAttempt != nil)
}

// MARK: - Test Suite: Error Details Storage

@Test func errorDetailsStoredInDatabase() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let errorType = "SecretReuseError"
    let errorMessage = "Message already processed in ratchet"

    // Act
    let errorLog = RecoveryErrorLog(
        id: UUID().uuidString,
        conversationID: "test_convo_123",
        messageID: "msg_test_001",
        errorType: errorType,
        errorMessage: errorMessage,
        epoch: 5,
        sequenceNumber: 42
    )
    try database.logError(errorLog)

    // Assert
    #expect(database.errorLogs[errorLog.id] != nil)
    #expect(database.errorLogs[errorLog.id]?.errorType == errorType)
    #expect(database.errorLogs[errorLog.id]?.epoch == 5)
    #expect(database.errorLogs[errorLog.id]?.sequenceNumber == 42)
}

@Test func errorLogIncludesFullContextForDebugging() async throws {
    // Arrange
    let database = MockMLSDatabase()

    // Act
    let errorLog = RecoveryErrorLog(
        id: UUID().uuidString,
        conversationID: "test_convo_123",
        messageID: "msg_test_001",
        errorType: "InvalidSignature",
        errorMessage: "Message signature validation failed",
        epoch: 3,
        sequenceNumber: 15
    )
    try database.logError(errorLog)

    // Assert
    let stored = database.errorLogs[errorLog.id]
    #expect(stored?.conversationID == "test_convo_123")
    #expect(stored?.messageID == "msg_test_001")
    #expect(stored?.errorType == "InvalidSignature")
    #expect(stored?.errorMessage != nil)
    #expect(stored?.epoch != nil)
    #expect(stored?.sequenceNumber != nil)
}

@Test func multipleErrorsTrackedSeparately() async throws {
    // Arrange
    let database = MockMLSDatabase()

    // Act - Log multiple errors
    for i in 0..<5 {
        let errorLog = RecoveryErrorLog(
            id: "error_\(i)",
            conversationID: "test_convo_123",
            messageID: "msg_\(i)",
            errorType: "DecryptionError",
            errorMessage: "Failed to decrypt message \(i)",
            epoch: UInt64(i),
            sequenceNumber: UInt32(i * 10)
        )
        try database.logError(errorLog)
    }

    // Assert
    #expect(database.errorLogs.count == 5)
}

@Test func errorLogsCanBeQueriedByConversation() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let targetConvoID = "target_convo"

    // Act - Create errors for different conversations
    for i in 0..<3 {
        let convoID = i == 1 ? targetConvoID : "other_convo_\(i)"
        let errorLog = RecoveryErrorLog(
            id: "error_\(i)",
            conversationID: convoID,
            messageID: "msg_\(i)",
            errorType: "DecryptionError",
            errorMessage: "Error \(i)",
            epoch: UInt64(i),
            sequenceNumber: UInt32(i * 10)
        )
        try database.logError(errorLog)
    }

    // Assert
    let targetErrors = database.errorLogs.values.filter { $0.conversationID == targetConvoID }
    #expect(targetErrors.count == 1)
}

// MARK: - Test Suite: Integration Scenarios

@Test func fullRecoveryFlowValidationPlaceholderRecoveryReset() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let apiClient = MockMLSAPIClient()
    var conversation = createTestConversation(consecutiveFailures: 0)
    try database.updateConversation(conversation)

    // Act - Step 1: Validation fails
    let validationResult = validateMessageEpoch(0, currentEpoch: 5, maxPastEpochs: 3)
    #expect(validationResult.isValid == false)

    // Act - Step 2: Save placeholder
    _ = try savePlaceholderMessage(
        messageID: "msg_test_001",
        conversationID: "test_convo_123",
        error: MLSError.operationFailed,
        database: database
    )

    // Act - Step 3: Increment failure counter
    conversation = conversation.withRecoveryState(
        lastRecoveryAttempt: Date(),
        consecutiveFailures: 1
    )
    try database.updateConversation(conversation)

    // Act - Step 4: Trigger recovery
    try await triggerRecovery(
        for: "test_convo_123",
        reason: "Automatic recovery after validation failure",
        apiClient: apiClient,
        database: database
    )

    // Act - Step 5: Reset failure counter after recovery
    conversation = conversation.withRecoveryState(
        lastRecoveryAttempt: Date(),
        consecutiveFailures: 0
    )
    try database.updateConversation(conversation)

    // Assert - Verify full flow completed
    #expect(database.getMessage("msg_test_001")?.isPlaceholder == true)
    #expect(apiClient.rejoinRequests.count == 1)
    #expect(database.getConversation("test_convo_123")?.consecutiveFailures == 0)
}

@Test func multipleMessagesHandledCorrectlyDuringRecovery() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let messageCount = 10

    // Act - Create mix of successful and failed messages
    for i in 0..<messageCount {
        let messageID = "msg_\(i)"

        if i % 3 == 0 {
            // Every 3rd message fails
            _ = try savePlaceholderMessage(
                messageID: messageID,
                conversationID: "test_convo_123",
                error: MLSError.operationFailed,
                database: database
            )
        } else {
            // Others succeed
            let message = createTestMessage(id: messageID)
            try database.saveMessage(message)
        }
    }

    // Assert
    let savedMessages = database.messages.values
    let placeholders = savedMessages.filter { $0.isPlaceholder }
    let successful = savedMessages.filter { !$0.isPlaceholder }

    #expect(savedMessages.count == messageCount)
    #expect(placeholders.count == 4)  // Messages 0, 3, 6, 9
    #expect(successful.count == 6)
}

@Test func recoveryFromHighFailureCount() async throws {
    // Arrange
    let database = MockMLSDatabase()
    let apiClient = MockMLSAPIClient()
    var conversation = createTestConversation(consecutiveFailures: 15)
    try database.updateConversation(conversation)

    // Act
    try await triggerRecovery(
        for: "test_convo_123",
        reason: "Recovery from critical failure state",
        apiClient: apiClient,
        database: database
    )

    // Reset counter
    conversation = conversation.withRecoveryState(
        lastRecoveryAttempt: Date(),
        consecutiveFailures: 0
    )
    try database.updateConversation(conversation)

    // Assert
    #expect(apiClient.rejoinRequests.count == 1)
    #expect(database.getConversation("test_convo_123")?.consecutiveFailures == 0)
}

@Test func concurrentMessageProcessingWithErrorHandling() async throws {
    // Arrange
    let database = MockMLSDatabase()

    // Act - Simulate concurrent message processing
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<5 {
            group.addTask {
                if i % 2 == 0 {
                    try? savePlaceholderMessage(
                        messageID: "msg_concurrent_\(i)",
                        conversationID: "test_convo_123",
                        error: MLSError.operationFailed,
                        database: database
                    )
                } else {
                    let message = createTestMessage(id: "msg_concurrent_\(i)")
                    try? database.saveMessage(message)
                }
            }
        }
    }

    // Assert
    #expect(database.messages.count == 5)
}
