//
//  MLSKeyCleanupTests.swift
//  CatbirdTests
//
//  Tests for MLS key material cleanup functionality
//

import Testing
import CoreData
@testable import Catbird

@MainActor
struct MLSKeyCleanupTests {

  // MARK: - Test Setup

  private func createTestStorage() -> MLSStorage {
    MLSStorage.shared
  }

  private func createTestConversation(storage: MLSStorage, id: String = "test-convo") async throws -> MLSConversation {
    try storage.createConversation(
      conversationID: id,
      groupID: Data("test-group-\(id)".utf8),
      epoch: 0,
      title: "Test Conversation"
    )
  }

  private func cleanupTestData(storage: MLSStorage) async throws {
    let conversations = try storage.fetchAllConversations(activeOnly: false)
    for conversation in conversations {
      try storage.deleteConversation(conversation)
    }
  }

  // MARK: - Epoch Key Recording Tests

  @Test("Record epoch key creates entry in storage")
  func recordEpochKey() async throws {
    let storage = createTestStorage()
    let conversation = try await createTestConversation(storage: storage, id: "epoch-test-1")

    defer {
      Task {
        try? await cleanupTestData(storage: storage)
      }
    }

    try await storage.recordEpochKey(conversationID: conversation.conversationID!, epoch: 1)

    let epochKeys = try storage.fetchEpochKeys(forConversationID: conversation.conversationID!)
    #expect(epochKeys.count == 1)
    #expect(epochKeys.first?.epoch == 1)
    #expect(epochKeys.first?.conversationID == conversation.conversationID!)
  }

  @Test("Record multiple epoch keys for same conversation")
  func recordMultipleEpochKeys() async throws {
    let storage = createTestStorage()
    let conversation = try await createTestConversation(storage: storage, id: "epoch-test-2")

    defer {
      Task {
        try? await cleanupTestData(storage: storage)
      }
    }

    for epoch in 1...5 {
      try await storage.recordEpochKey(conversationID: conversation.conversationID!, epoch: Int64(epoch))
    }

    let epochKeys = try storage.fetchEpochKeys(forConversationID: conversation.conversationID!)
    #expect(epochKeys.count == 5)

    let epochs = epochKeys.map { $0.epoch }.sorted()
    #expect(epochs == [1, 2, 3, 4, 5])
  }

  // MARK: - Epoch Key Cleanup Tests

  @Test("Delete old epoch keys keeps specified number")
  func deleteOldEpochKeysKeepsLast() async throws {
    let storage = createTestStorage()
    let conversation = try await createTestConversation(storage: storage, id: "cleanup-test-1")

    defer {
      Task {
        try? await cleanupTestData(storage: storage)
      }
    }

    for epoch in 1...10 {
      try await storage.recordEpochKey(conversationID: conversation.conversationID!, epoch: Int64(epoch))
    }

    try await storage.deleteOldEpochKeys(conversationID: conversation.conversationID!, keepLast: 3)

    let activeKeys = try storage.fetchEpochKeys(forConversationID: conversation.conversationID!, activeOnly: true)
    #expect(activeKeys.count == 3)

    let activeEpochs = activeKeys.map { $0.epoch }.sorted()
    #expect(activeEpochs == [8, 9, 10])
  }

  @Test("Delete old epoch keys with keepLast 0 deletes all")
  func deleteOldEpochKeepsNone() async throws {
    let storage = createTestStorage()
    let conversation = try await createTestConversation(storage: storage, id: "cleanup-test-2")

    defer {
      Task {
        try? await cleanupTestData(storage: storage)
      }
    }

    for epoch in 1...5 {
      try await storage.recordEpochKey(conversationID: conversation.conversationID!, epoch: Int64(epoch))
    }

    try await storage.deleteOldEpochKeys(conversationID: conversation.conversationID!, keepLast: 0)

    let activeKeys = try storage.fetchEpochKeys(forConversationID: conversation.conversationID!, activeOnly: true)
    #expect(activeKeys.count == 0)
  }

  @Test("Delete old epoch keys marks keys for deletion")
  func deleteOldEpochKeysMarksForDeletion() async throws {
    let storage = createTestStorage()
    let conversation = try await createTestConversation(storage: storage, id: "cleanup-test-3")

    defer {
      Task {
        try? await cleanupTestData(storage: storage)
      }
    }

    for epoch in 1...5 {
      try await storage.recordEpochKey(conversationID: conversation.conversationID!, epoch: Int64(epoch))
    }

    try await storage.deleteOldEpochKeys(conversationID: conversation.conversationID!, keepLast: 2)

    let allKeys = try storage.fetchEpochKeys(forConversationID: conversation.conversationID!, activeOnly: false)
    let markedKeys = allKeys.filter { $0.deletedAt != nil }

    #expect(markedKeys.count == 3)
  }

  // MARK: - Message Key Cleanup Tests

  @Test("Cleanup message keys deletes old messages")
  func cleanupMessageKeys() async throws {
    let storage = createTestStorage()
    let conversation = try await createTestConversation(storage: storage, id: "message-cleanup-1")

    defer {
      Task {
        try? await cleanupTestData(storage: storage)
      }
    }

    let calendar = Calendar.current
    let now = Date()
    let oldDate = calendar.date(byAdding: .day, value: -40, to: now)!
    let recentDate = calendar.date(byAdding: .day, value: -10, to: now)!

    let oldMessage = try storage.createMessage(
      messageID: "old-message",
      conversationID: conversation.conversationID!,
      senderID: "sender1",
      content: Data("old".utf8),
      epoch: 1,
      sequenceNumber: 1
    )
    oldMessage.timestamp = oldDate

    let recentMessage = try storage.createMessage(
      messageID: "recent-message",
      conversationID: conversation.conversationID!,
      senderID: "sender2",
      content: Data("recent".utf8),
      epoch: 2,
      sequenceNumber: 2
    )
    recentMessage.timestamp = recentDate

    try storage.saveContext()

    let threshold = calendar.date(byAdding: .day, value: -30, to: now)!
    try await storage.cleanupMessageKeys(olderThan: threshold)

    let messages = try storage.fetchMessages(forConversationID: conversation.conversationID!)
    #expect(messages.count == 1)
    #expect(messages.first?.messageID == "recent-message")
  }

  // MARK: - Permanent Deletion Tests

  @Test("Delete marked epoch keys permanently removes them")
  func deleteMarkedEpochKeys() async throws {
    let storage = createTestStorage()
    let conversation = try await createTestConversation(storage: storage, id: "permanent-delete-1")

    defer {
      Task {
        try? await cleanupTestData(storage: storage)
      }
    }

    for epoch in 1...5 {
      try await storage.recordEpochKey(conversationID: conversation.conversationID!, epoch: Int64(epoch))
    }

    try await storage.deleteOldEpochKeys(conversationID: conversation.conversationID!, keepLast: 2)

    let beforeDeletion = try storage.fetchEpochKeys(forConversationID: conversation.conversationID!, activeOnly: false)
    #expect(beforeDeletion.count == 5)

    try await storage.deleteMarkedEpochKeys()

    let afterDeletion = try storage.fetchEpochKeys(forConversationID: conversation.conversationID!, activeOnly: false)
    #expect(afterDeletion.count == 2)
  }

  // MARK: - Configuration Tests

  @Test("Configuration validates max past epochs warning")
  func configurationValidatesMaxPastEpochs() async throws {
    let config = MLSConfiguration(maxPastEpochs: 10)
    config.validate()
    #expect(config.maxPastEpochs == 10)
  }

  @Test("Configuration default values are reasonable")
  func configurationDefaults() async throws {
    let config = MLSConfiguration.default
    #expect(config.maxPastEpochs == 2)
    #expect(config.messageKeyRetentionDays == 30)
    #expect(config.enableAutomaticCleanup == true)
  }

  @Test("Configuration max forward secrecy deletes immediately")
  func configurationMaxForwardSecrecy() async throws {
    let config = MLSConfiguration.maxForwardSecrecy
    #expect(config.maxPastEpochs == 0)
    #expect(config.messageKeyRetentionDays == 7)
  }

  @Test("Configuration message key cleanup threshold calculates correctly")
  func configurationMessageKeyThreshold() async throws {
    let config = MLSConfiguration(messageKeyRetentionDays: 30)
    let threshold = config.messageKeyCleanupThreshold
    let expectedDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!

    let difference = abs(threshold.timeIntervalSince(expectedDate))
    #expect(difference < 1.0)
  }

  // MARK: - Cascade Deletion Tests

  @Test("Deleting conversation cascades to epoch keys")
  func conversationDeletionCascades() async throws {
    let storage = createTestStorage()
    let conversation = try await createTestConversation(storage: storage, id: "cascade-test-1")

    defer {
      Task {
        try? await cleanupTestData(storage: storage)
      }
    }

    for epoch in 1...3 {
      try await storage.recordEpochKey(conversationID: conversation.conversationID!, epoch: Int64(epoch))
    }

    let beforeDeletion = try storage.fetchEpochKeys(forConversationID: conversation.conversationID!)
    #expect(beforeDeletion.count == 3)

    try storage.deleteConversation(conversation)

    let afterDeletion = try storage.fetchEpochKeys(forConversationID: conversation.conversationID!)
    #expect(afterDeletion.count == 0)
  }
}
