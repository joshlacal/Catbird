@testable import Catbird
import Foundation
import Petrel
import Testing

struct BlueskyConversationDisplayTests {
  @Test("Group conversation display uses group metadata")
  func groupConversationDisplayUsesGroupMetadata() throws {
    let convo = try makeConversation(
      members: [
        makeProfile(did: "did:plc:viewer", handle: "viewer.test"),
        makeProfile(did: "did:plc:alice", handle: "alice.test", displayName: "Alice"),
        makeProfile(did: "did:plc:bob", handle: "bob.test", displayName: "Bob"),
      ],
      kind: .chatBskyConvoDefsGroupConvo(
        ChatBskyConvoDefs.GroupConvo(
          createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000)),
          joinLink: nil,
          joinRequestCount: nil,
          lockStatus: .unlocked,
          lockStatusModerationOverride: false,
          memberCount: 4,
          memberLimit: 100,
          name: "Launch Room",
          unreadJoinRequestCount: nil
        )
      )
    )

    #expect(convo.isGroupConversation)
    #expect(convo.displayTitle(currentUserDID: "did:plc:viewer") == "Launch Room")
    #expect(convo.displaySubtitle(currentUserDID: "did:plc:viewer") == "4 members")
  }

  @Test("Direct conversation display uses other member")
  func directConversationDisplayUsesOtherMember() throws {
    let convo = try makeConversation(
      members: [
        makeProfile(did: "did:plc:viewer", handle: "viewer.test", displayName: "Viewer"),
        makeProfile(did: "did:plc:alice", handle: "alice.test", displayName: "Alice"),
      ],
      kind: .chatBskyConvoDefsDirectConvo(ChatBskyConvoDefs.DirectConvo())
    )

    #expect(!convo.isGroupConversation)
    #expect(convo.displayTitle(currentUserDID: "did:plc:viewer") == "Alice")
    #expect(convo.displaySubtitle(currentUserDID: "did:plc:viewer") == "@alice.test")
  }

  @Test("Deleted direct member display stays explicit")
  func deletedDirectMemberDisplayStaysExplicit() throws {
    let convo = try makeConversation(
      members: [
        makeProfile(did: "did:plc:viewer", handle: "viewer.test", displayName: "Viewer"),
        makeProfile(did: "did:plc:deleted", handle: "missing.invalid"),
      ],
      kind: .chatBskyConvoDefsDirectConvo(ChatBskyConvoDefs.DirectConvo())
    )

    #expect(convo.displayTitle(currentUserDID: "did:plc:viewer") == "Deleted Account")
    #expect(convo.displaySubtitle(currentUserDID: "did:plc:viewer") == nil)
  }

  private func makeConversation(
    members: [ChatBskyActorDefs.ProfileViewBasic],
    kind: ChatBskyConvoDefs.ConvoViewKindUnion?
  ) throws -> ChatBskyConvoDefs.ConvoView {
    ChatBskyConvoDefs.ConvoView(
      id: "convo-1",
      rev: "rev-1",
      members: members,
      lastMessage: nil,
      lastReaction: nil,
      muted: false,
      status: .accepted,
      unreadCount: 0,
      kind: kind
    )
  }

  private func makeProfile(
    did: String,
    handle: String,
    displayName: String? = nil
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
