@testable import Catbird
import Foundation
import Petrel
import Testing

/// An open Bluesky chat rebuilds sender names and avatars only when its
/// conversation revision moves. These tests pin that member changes in the
/// conversation list move it, so a chat opened before its members arrived
/// hydrates as soon as they do.
@Suite("Chat member revisions")
@MainActor
struct ChatMemberRevisionTests {
  @Test("A conversation arriving in the list bumps its revision")
  func arrivalBumpsRevision() async throws {
    let manager = await makeManager()
    let before = manager.conversationRevision(for: "convo-1")

    manager.conversations = [try makeConversation(id: "convo-1", aliceName: "Alice")]

    #expect(manager.conversationRevision(for: "convo-1") != before)
  }

  @Test("A member profile change bumps only that conversation's revision")
  func memberChangeBumpsOnlyThatConversation() async throws {
    let manager = await makeManager()
    manager.conversations = [
      try makeConversation(id: "convo-1", aliceName: nil),
      try makeConversation(id: "convo-2", aliceName: "Alice"),
    ]
    let first = manager.conversationRevision(for: "convo-1")
    let second = manager.conversationRevision(for: "convo-2")

    manager.conversations = [
      try makeConversation(id: "convo-1", aliceName: "Alice"),
      try makeConversation(id: "convo-2", aliceName: "Alice"),
    ]

    #expect(manager.conversationRevision(for: "convo-1") != first)
    #expect(manager.conversationRevision(for: "convo-2") == second)
  }

  @Test("Replacing the list with identical members leaves revisions alone")
  func unchangedMembersDoNotBump() async throws {
    let manager = await makeManager()
    manager.conversations = [try makeConversation(id: "convo-1", aliceName: "Alice")]
    let before = manager.conversationRevision(for: "convo-1")

    manager.conversations = [try makeConversation(id: "convo-1", aliceName: "Alice", unreadCount: 3)]

    #expect(manager.conversationRevision(for: "convo-1") == before)
  }

  // MARK: - Helpers

  private func makeManager() async -> ChatManager {
    let client = await ATProtoClient(baseURL: URL(string: "https://member-revisions.invalid")!)
    return ChatManager(client: client, messagePageLoader: { _, _ in
      Issue.record("Unexpected message fetch")
      throw URLError(.badServerResponse)
    })
  }

  private func makeConversation(
    id: String,
    aliceName: String?,
    unreadCount: Int = 0
  ) throws -> ChatBskyConvoDefs.ConvoView {
    ChatBskyConvoDefs.ConvoView(
      id: id,
      rev: "rev-1",
      members: [
        try makeProfile(did: "did:plc:viewer", handle: "viewer.test", displayName: nil),
        try makeProfile(did: "did:plc:alice", handle: "alice.test", displayName: aliceName),
      ],
      lastMessage: nil,
      lastReaction: nil,
      muted: false,
      status: .accepted,
      unreadCount: unreadCount,
      kind: nil
    )
  }

  private func makeProfile(
    did: String,
    handle: String,
    displayName: String?
  ) throws -> ChatBskyActorDefs.ProfileViewBasic {
    try ChatBskyActorDefs.ProfileViewBasic(
      did: DID(didString: did),
      handle: Handle(handleString: handle),
      displayName: displayName,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      chatDisabled: nil,
      verification: nil,
      kind: nil
    )
  }
}
