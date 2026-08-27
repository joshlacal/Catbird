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

  @Test("Share search matches group name")
  func shareSearchMatchesGroupName() throws {
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
          memberCount: 3,
          memberLimit: 100,
          name: "Launch Room",
          unreadJoinRequestCount: nil
        )
      )
    )

    #expect(convo.matchesShareSearch("launch", currentUserDID: "did:plc:viewer"))
    #expect(convo.matchesShareSearch("ROOM", currentUserDID: "did:plc:viewer"))
    #expect(!convo.matchesShareSearch("zebra", currentUserDID: "did:plc:viewer"))
  }

  @Test("Share search matches any member, not just the first")
  func shareSearchMatchesAnyMember() throws {
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
          memberCount: 3,
          memberLimit: 100,
          name: "Launch Room",
          unreadJoinRequestCount: nil
        )
      )
    )

    // "Bob" is NOT the first non-self member — the old picker missed this.
    #expect(convo.matchesShareSearch("bob", currentUserDID: "did:plc:viewer"))
    #expect(convo.matchesShareSearch("alice.test", currentUserDID: "did:plc:viewer"))
  }

  @Test("Share search on direct convo matches other member only")
  func shareSearchDirectConvo() throws {
    let convo = try makeConversation(
      members: [
        makeProfile(did: "did:plc:viewer", handle: "viewer.test", displayName: "Viewer"),
        makeProfile(did: "did:plc:alice", handle: "alice.test", displayName: "Alice"),
      ],
      kind: .chatBskyConvoDefsDirectConvo(ChatBskyConvoDefs.DirectConvo())
    )

    #expect(convo.matchesShareSearch("alice", currentUserDID: "did:plc:viewer"))
    // Should not match on the current user's own name.
    #expect(!convo.matchesShareSearch("viewer", currentUserDID: "did:plc:viewer"))
    // Empty query matches everything (picker shows full list).
    #expect(convo.matchesShareSearch("", currentUserDID: "did:plc:viewer"))
  }

  @Test("Primary member resolves correctly for direct chats and group chats")
  func primaryMemberResolution() throws {
    let viewer = try makeProfile(did: "did:plc:viewer", handle: "viewer.test", displayName: "Viewer")
    let alice = try makeProfile(
      did: "did:plc:alice",
      handle: "alice.test",
      displayName: "Alice",
      kind: .chatBskyActorDefsGroupConvoMember(ChatBskyActorDefs.GroupConvoMember(addedBy: nil, role: .owner))
    )
    let bob = try makeProfile(did: "did:plc:bob", handle: "bob.test", displayName: "Bob")

    // Direct chat
    let directConvo = try makeConversation(
      members: [viewer, alice],
      kind: .chatBskyConvoDefsDirectConvo(ChatBskyConvoDefs.DirectConvo())
    )
    #expect(directConvo.primaryMember(currentUserDID: "did:plc:viewer")?.did.didString() == "did:plc:alice")

    // Group chat with owner
    let ownerGroupConvo = try makeConversation(
      members: [viewer, alice, bob],
      kind: .chatBskyConvoDefsGroupConvo(
        ChatBskyConvoDefs.GroupConvo(
          createdAt: ATProtocolDate(date: Date()),
          joinLink: nil,
          joinRequestCount: nil,
          lockStatus: .unlocked,
          lockStatusModerationOverride: false,
          memberCount: 3,
          memberLimit: 50,
          name: "Test Group",
          unreadJoinRequestCount: nil
        )
      )
    )
    #expect(ownerGroupConvo.primaryMember(currentUserDID: "did:plc:viewer")?.did.didString() == "did:plc:alice")
  }

  @Test("Direct conversation moderation block states: direct, list, and blockedBy")
  func directConversationModerationBlockStates() throws {
    let blockUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.graph.block/3k456")
    let listUri = try ATProtocolURI(uriString: "at://did:plc:mod/app.bsky.graph.list/list1")
    let listCid = try CID.parse("bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
    let listBasic = AppBskyGraphDefs.ListViewBasic(
      uri: listUri,
      cid: listCid,
      name: "Trolls List",
      purpose: .appbskygraphdefsmodlist,
      avatar: nil,
      listItemCount: 10,
      labels: nil,
      viewer: nil,
      indexedAt: nil
    )

    let viewer = try makeProfile(did: "did:plc:viewer", handle: "viewer.test")

    // 1. Direct block
    let blockedMember = try makeProfile(
      did: "did:plc:target",
      handle: "target.test",
      displayName: "Target",
      viewer: AppBskyActorDefs.ViewerState(
        muted: false,
        mutedOnlyReposts: nil,
        mutedOnlyQuoteposts: nil,
        mutedByList: nil,
        blockedBy: false,
        blocking: blockUri,
        blockingByList: nil,
        following: nil,
        followedBy: nil,
        knownFollowers: nil,
        activitySubscription: nil
      )
    )
    let directBlockConvo = try makeConversation(members: [viewer, blockedMember])
    let directBlockState = directBlockConvo.moderationBlockState(currentUserDID: "did:plc:viewer")
    #expect(directBlockState == .directBlock(did: "did:plc:target", handle: "target.test", displayName: "Target"))
    #expect(directBlockState.isBlocked)

    // 2. List block
    let listBlockedMember = try makeProfile(
      did: "did:plc:target",
      handle: "target.test",
      displayName: "Target",
      viewer: AppBskyActorDefs.ViewerState(
        muted: false,
        mutedOnlyReposts: nil,
        mutedOnlyQuoteposts: nil,
        mutedByList: nil,
        blockedBy: false,
        blocking: nil,
        blockingByList: listBasic,
        following: nil,
        followedBy: nil,
        knownFollowers: nil,
        activitySubscription: nil
      )
    )
    let listBlockConvo = try makeConversation(members: [viewer, listBlockedMember])
    let listBlockState = listBlockConvo.moderationBlockState(currentUserDID: "did:plc:viewer")
    #expect(listBlockState == .listBlock(did: "did:plc:target", handle: "target.test", displayName: "Target", list: listBasic))
    #expect(listBlockState.isBlocked)

    // 3. Blocked by
    let blockingMember = try makeProfile(
      did: "did:plc:target",
      handle: "target.test",
      displayName: "Target",
      viewer: AppBskyActorDefs.ViewerState(
        muted: false,
        mutedOnlyReposts: nil,
        mutedOnlyQuoteposts: nil,
        mutedByList: nil,
        blockedBy: true,
        blocking: nil,
        blockingByList: nil,
        following: nil,
        followedBy: nil,
        knownFollowers: nil,
        activitySubscription: nil
      )
    )
    let blockedByConvo = try makeConversation(members: [viewer, blockingMember])
    let blockedByState = blockedByConvo.moderationBlockState(currentUserDID: "did:plc:viewer")
    #expect(blockedByState == .blockedBy(did: "did:plc:target", handle: "target.test", displayName: "Target"))
    #expect(blockedByState.isBlocked)

    // 4. No block
    let normalMember = try makeProfile(
      did: "did:plc:target",
      handle: "target.test",
      displayName: "Target",
      viewer: AppBskyActorDefs.ViewerState(
        muted: false,
        mutedOnlyReposts: nil,
        mutedOnlyQuoteposts: nil,
        mutedByList: nil,
        blockedBy: false,
        blocking: nil,
        blockingByList: nil,
        following: nil,
        followedBy: nil,
        knownFollowers: nil,
        activitySubscription: nil
      )
    )
    let normalConvo = try makeConversation(members: [viewer, normalMember])
    let normalState = normalConvo.moderationBlockState(currentUserDID: "did:plc:viewer")
    #expect(normalState == .none)
    #expect(!normalState.isBlocked)
  }

  @Test("Group conversation moderation: owner blocked vs non-owner blocked")
  func groupConversationModerationBlocks() throws {
    let blockUri = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.graph.block/3k456")
    let viewer = try makeProfile(did: "did:plc:viewer", handle: "viewer.test")

    // Owner is blocked by current user -> group moderation block triggered
    let blockedOwner = try makeProfile(
      did: "did:plc:owner",
      handle: "owner.test",
      displayName: "Group Owner",
      viewer: AppBskyActorDefs.ViewerState(
        muted: false,
        mutedOnlyReposts: nil,
        mutedOnlyQuoteposts: nil,
        mutedByList: nil,
        blockedBy: false,
        blocking: blockUri,
        blockingByList: nil,
        following: nil,
        followedBy: nil,
        knownFollowers: nil,
        activitySubscription: nil
      ),
      kind: .chatBskyActorDefsGroupConvoMember(ChatBskyActorDefs.GroupConvoMember(addedBy: nil, role: .owner))
    )
    let normalMember = try makeProfile(did: "did:plc:alice", handle: "alice.test")

    let ownerBlockedGroup = try makeConversation(
      members: [viewer, blockedOwner, normalMember],
      kind: .chatBskyConvoDefsGroupConvo(
        ChatBskyConvoDefs.GroupConvo(
          createdAt: ATProtocolDate(date: Date()),
          joinLink: nil,
          joinRequestCount: nil,
          lockStatus: .unlocked,
          lockStatusModerationOverride: false,
          memberCount: 3,
          memberLimit: 50,
          name: "Owner Blocked Group",
          unreadJoinRequestCount: nil
        )
      )
    )
    let ownerBlockState = ownerBlockedGroup.moderationBlockState(currentUserDID: "did:plc:viewer")
    #expect(ownerBlockState == .directBlock(did: "did:plc:owner", handle: "owner.test", displayName: "Group Owner"))
    #expect(ownerBlockState.isBlocked)

    // Regular member is blocked by current user, but owner is not -> group composer NOT suppressed
    let cleanOwner = try makeProfile(
      did: "did:plc:owner",
      handle: "owner.test",
      displayName: "Group Owner",
      kind: .chatBskyActorDefsGroupConvoMember(ChatBskyActorDefs.GroupConvoMember(addedBy: nil, role: .owner))
    )
    let blockedRegularMember = try makeProfile(
      did: "did:plc:bob",
      handle: "bob.test",
      displayName: "Bob",
      viewer: AppBskyActorDefs.ViewerState(
        muted: false,
        mutedOnlyReposts: nil,
        mutedOnlyQuoteposts: nil,
        mutedByList: nil,
        blockedBy: false,
        blocking: blockUri,
        blockingByList: nil,
        following: nil,
        followedBy: nil,
        knownFollowers: nil,
        activitySubscription: nil
      ),
      kind: .chatBskyActorDefsGroupConvoMember(ChatBskyActorDefs.GroupConvoMember(addedBy: nil, role: .standard))
    )

    let nonOwnerBlockedGroup = try makeConversation(
      members: [viewer, cleanOwner, blockedRegularMember],
      kind: .chatBskyConvoDefsGroupConvo(
        ChatBskyConvoDefs.GroupConvo(
          createdAt: ATProtocolDate(date: Date()),
          joinLink: nil,
          joinRequestCount: nil,
          lockStatus: .unlocked,
          lockStatusModerationOverride: false,
          memberCount: 3,
          memberLimit: 50,
          name: "Non-Owner Blocked Group",
          unreadJoinRequestCount: nil
        )
      )
    )
    let nonOwnerBlockState = nonOwnerBlockedGroup.moderationBlockState(currentUserDID: "did:plc:viewer")
    #expect(nonOwnerBlockState == .none)
    #expect(!nonOwnerBlockState.isBlocked)
  }

  private func makeConversation(
    members: [ChatBskyActorDefs.ProfileViewBasic],
    kind: ChatBskyConvoDefs.ConvoViewKindUnion? = nil
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
    displayName: String? = nil,
    viewer: AppBskyActorDefs.ViewerState? = nil,
    kind: ChatBskyActorDefs.ProfileViewBasicKindUnion? = nil
  ) throws -> ChatBskyActorDefs.ProfileViewBasic {
    try ChatBskyActorDefs.ProfileViewBasic(
      did: DID(didString: did),
      handle: Handle(handleString: handle),
      displayName: displayName,
      avatar: nil,
      associated: nil,
      viewer: viewer,
      labels: nil,
      createdAt: nil,
      chatDisabled: nil,
      verification: nil,
      kind: kind
    )
  }
}
