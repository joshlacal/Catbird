@testable import Catbird
import Foundation
import Petrel
import Testing

struct BlueskySystemMessageTests {
  private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("System message data cases parse with correct text, icon and attributes")
  func testSystemMessageDataParsing() throws {
    let aliceDID = try DID(didString: "did:plc:alice")
    let bobDID = try DID(didString: "did:plc:bob")

    let aliceProfile = ChatBskyActorDefs.ProfileViewBasic(
      did: aliceDID,
      handle: try Handle(handleString: "alice.bsky.social"),
      displayName: "Alice",
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      chatDisabled: nil,
      verification: nil,
      kind: nil
    )
    let profiles = ["did:plc:alice": aliceProfile]

    // 1. Add member
    let addMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_add",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataAddMember(
        ChatBskyConvoDefs.SystemMessageDataAddMember(
          member: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID),
          role: ChatBskyActorDefs.MemberRole(rawValue: "admin"),
          addedBy: ChatBskyConvoDefs.SystemMessageReferredUser(did: bobDID)
        )
      )
    )
    let addAdapter = BlueskyMessageAdapter(systemMessageView: addMsg, relatedProfiles: profiles)
    #expect(addAdapter.isSystemMessage)
    #expect(addAdapter.text.contains("Alice was added as an admin"))
    #expect(addAdapter.systemEvent?.iconName == "person.badge.plus")
    #expect(addAdapter.systemEvent?.actionTarget == .profile(did: "did:plc:alice"))
    // 2. Remove member
    let removeMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_remove",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataRemoveMember(
        ChatBskyConvoDefs.SystemMessageDataRemoveMember(
          member: ChatBskyConvoDefs.SystemMessageReferredUser(did: bobDID),
          removedBy: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID)
        )
      )
    )
    let removeAdapter = BlueskyMessageAdapter(systemMessageView: removeMsg, relatedProfiles: profiles)
    #expect(removeAdapter.text.contains("Alice removed did:plc:bob"))
    #expect(removeAdapter.systemEvent?.iconName == "person.badge.minus")
    #expect(removeAdapter.systemEvent?.actionTarget == .profile(did: "did:plc:bob"))
    // 3. Member join
    let joinMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_join",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataMemberJoin(
        ChatBskyConvoDefs.SystemMessageDataMemberJoin(
          member: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID),
          role: ChatBskyActorDefs.MemberRole(rawValue: "member"),
          approvedBy: nil
        )
      )
    )
    let joinAdapter = BlueskyMessageAdapter(systemMessageView: joinMsg, relatedProfiles: profiles)
    #expect(joinAdapter.text.contains("Alice joined the group"))
    #expect(joinAdapter.systemEvent?.actionTarget == .profile(did: "did:plc:alice"))
    // 4. Member leave
    let leaveMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_leave",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataMemberLeave(
        ChatBskyConvoDefs.SystemMessageDataMemberLeave(
          member: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID)
        )
      )
    )
    let leaveAdapter = BlueskyMessageAdapter(systemMessageView: leaveMsg, relatedProfiles: profiles)
    #expect(leaveAdapter.text.contains("Alice left the group"))
    #expect(leaveAdapter.systemEvent?.actionTarget == .profile(did: "did:plc:alice"))
    // 5. Lock convo
    let lockMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_lock",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataLockConvo(
        ChatBskyConvoDefs.SystemMessageDataLockConvo(
          lockedBy: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID)
        )
      )
    )
    let lockAdapter = BlueskyMessageAdapter(systemMessageView: lockMsg, relatedProfiles: profiles)
    #expect(lockAdapter.text.contains("Alice locked the chat"))
    #expect(lockAdapter.systemEvent?.iconName == "lock.fill")
    #expect(lockAdapter.systemEvent?.actionTarget == .profile(did: "did:plc:alice"))
    // 6. Unlock convo
    let unlockMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_unlock",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataUnlockConvo(
        ChatBskyConvoDefs.SystemMessageDataUnlockConvo(
          unlockedBy: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID)
        )
      )
    )
    let unlockAdapter = BlueskyMessageAdapter(systemMessageView: unlockMsg, relatedProfiles: profiles)
    #expect(unlockAdapter.text.contains("Alice unlocked the chat"))
    #expect(unlockAdapter.systemEvent?.actionTarget == .profile(did: "did:plc:alice"))
    // 7. Lock permanently / end
    let endMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_end",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataLockConvoPermanently(
        ChatBskyConvoDefs.SystemMessageDataLockConvoPermanently(
          lockedBy: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID)
        )
      )
    )
    let endAdapter = BlueskyMessageAdapter(systemMessageView: endMsg, relatedProfiles: profiles)
    #expect(endAdapter.text.contains("Alice ended the chat"))
    #expect(endAdapter.systemEvent?.actionTarget == .profile(did: "did:plc:alice"))
    // 8. Edit group
    let editMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_edit",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataEditGroup(
        ChatBskyConvoDefs.SystemMessageDataEditGroup(
          oldName: "Old Group",
          newName: "New Group"
        )
      )
    )
    let editAdapter = BlueskyMessageAdapter(systemMessageView: editMsg, relatedProfiles: profiles)
    #expect(editAdapter.text.contains("Group name changed to \"New Group\""))
    #expect(editAdapter.systemEvent?.actionTarget == nil)
    // 9. Join links
    // 9. Join link created
    let linkCreateMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_link1",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataCreateJoinLink(
        ChatBskyConvoDefs.SystemMessageDataCreateJoinLink()
      )
    )
    let linkCreateAdapter = BlueskyMessageAdapter(systemMessageView: linkCreateMsg)
    #expect(linkCreateAdapter.text == "Join link created")
    #expect(linkCreateAdapter.systemEvent?.actionTarget == .inviteLink)
    // 10. Join link edited
    let linkEditMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_link2",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataEditJoinLink(
        ChatBskyConvoDefs.SystemMessageDataEditJoinLink()
      )
    )
    let linkEditAdapter = BlueskyMessageAdapter(systemMessageView: linkEditMsg)
    #expect(linkEditAdapter.text == "Join link updated")
    #expect(linkEditAdapter.systemEvent?.actionTarget == .inviteLink)
    // 11. Join link enabled
    let linkEnableMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_link3",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataEnableJoinLink(
        ChatBskyConvoDefs.SystemMessageDataEnableJoinLink()
      )
    )
    let linkEnableAdapter = BlueskyMessageAdapter(systemMessageView: linkEnableMsg)
    #expect(linkEnableAdapter.text == "Join link enabled")
    #expect(linkEnableAdapter.systemEvent?.actionTarget == .inviteLink)
    // 12. Join link disabled
    let linkDisableMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_link4",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataDisableJoinLink(
        ChatBskyConvoDefs.SystemMessageDataDisableJoinLink()
      )
    )
    let linkDisableAdapter = BlueskyMessageAdapter(systemMessageView: linkDisableMsg)
    #expect(linkDisableAdapter.text == "Join link disabled")
    #expect(linkDisableAdapter.systemEvent?.actionTarget == .inviteLink)
  }
  @Test("Grouping keeps 1 to 3 events separate")
  func testGroupingSmallClusters() throws {
    let aliceDID = try DID(didString: "did:plc:alice")
    let items = (1...3).map { i in
      let msg = ChatBskyConvoDefs.SystemMessageView(
        id: "sys_\(i)",
        rev: "1",
        sentAt: ATProtocolDate(date: baseDate.addingTimeInterval(Double(i * 10))),
        data: .chatBskyConvoDefsSystemMessageDataMemberJoin(
          ChatBskyConvoDefs.SystemMessageDataMemberJoin(
            member: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID),
            role: ChatBskyActorDefs.MemberRole(rawValue: "member"),
            approvedBy: nil
          )
        )
      )
      return BlueskyMessageAdapter(systemMessageView: msg)
    }

    let grouped = BlueskySystemMessageGrouper.group(messages: items)
    #expect(grouped.count == 3)
    #expect(!grouped[0].isSystemGroup)
    #expect(!grouped[1].isSystemGroup)
    #expect(!grouped[2].isSystemGroup)
  }

  @Test("Grouping collapses 4 or more consecutive events into a stable group")
  func testGroupingLargeClusters() throws {
    let aliceDID = try DID(didString: "did:plc:alice")
    let items = (1...5).map { i in
      let msg = ChatBskyConvoDefs.SystemMessageView(
        id: "sys_\(i)",
        rev: "1",
        sentAt: ATProtocolDate(date: baseDate.addingTimeInterval(Double(i * 10))),
        data: .chatBskyConvoDefsSystemMessageDataMemberJoin(
          ChatBskyConvoDefs.SystemMessageDataMemberJoin(
            member: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID),
            role: ChatBskyActorDefs.MemberRole(rawValue: "member"),
            approvedBy: nil
          )
        )
      )
      return BlueskyMessageAdapter(systemMessageView: msg)
    }

    // When collapsed
    let groupedCollapsed = BlueskySystemMessageGrouper.group(messages: items, expandedGroupIDs: [])
    #expect(groupedCollapsed.count == 1)
    #expect(groupedCollapsed[0].isSystemGroup)
    #expect(groupedCollapsed[0].id == "sysgroup_sys_1")
    #expect(groupedCollapsed[0].text == "5 chat updates")
    #expect(groupedCollapsed[0].systemGroupEvents?.count == 5)

    // When expanded
    let groupedExpanded = BlueskySystemMessageGrouper.group(messages: items, expandedGroupIDs: ["sysgroup_sys_1"])
    #expect(groupedExpanded.count == 6) // Group header + 5 individual items
    #expect(groupedExpanded[0].isSystemGroup)
    #expect(groupedExpanded[0].isExpanded)

    // When a 6th event is appended, group ID remains stable
    let extraMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_6",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate.addingTimeInterval(60)),
      data: .chatBskyConvoDefsSystemMessageDataMemberJoin(
        ChatBskyConvoDefs.SystemMessageDataMemberJoin(
          member: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID),
          role: ChatBskyActorDefs.MemberRole(rawValue: "member"),
          approvedBy: nil
        )
      )
    )
    let itemsWithAppended = items + [BlueskyMessageAdapter(systemMessageView: extraMsg)]
    let groupedWithAppended = BlueskySystemMessageGrouper.group(messages: itemsWithAppended, expandedGroupIDs: [])
    #expect(groupedWithAppended.count == 1)
    #expect(groupedWithAppended[0].id == "sysgroup_sys_1")
    #expect(groupedWithAppended[0].text == "6 chat updates")
  }

  @Test("Grouping splits across user messages and across calendar days")
  func testGroupingSplits() throws {
    let aliceDID = try DID(didString: "did:plc:alice")
    let makeSys = { (id: String, date: Date) in
      BlueskyMessageAdapter(
        systemMessageView: ChatBskyConvoDefs.SystemMessageView(
          id: id,
          rev: "1",
          sentAt: ATProtocolDate(date: date),
          data: .chatBskyConvoDefsSystemMessageDataMemberJoin(
            ChatBskyConvoDefs.SystemMessageDataMemberJoin(
              member: ChatBskyConvoDefs.SystemMessageReferredUser(did: aliceDID),
              role: ChatBskyActorDefs.MemberRole(rawValue: "member"),
              approvedBy: nil
            )
          )
        )
      )
    }

    let makeUserMsg = { (id: String, date: Date) in
      BlueskyMessageAdapter(
        messageView: ChatBskyConvoDefs.MessageView(
          id: id,
          rev: "1",
          text: "User message",
          facets: nil,
          embed: nil,
          reactions: nil,
          replyTo: nil,
          sender: ChatBskyConvoDefs.MessageViewSender(did: aliceDID),
          sentAt: ATProtocolDate(date: date)
        ),
        currentUserDID: "did:plc:viewer"
      )
    }

    // 2 sys events, 1 user message, 2 sys events on same day -> total 5 items, neither sys cluster >= 4
    let stream1 = [
      makeSys("s1", baseDate),
      makeSys("s2", baseDate.addingTimeInterval(10)),
      makeUserMsg("u1", baseDate.addingTimeInterval(20)),
      makeSys("s3", baseDate.addingTimeInterval(30)),
      makeSys("s4", baseDate.addingTimeInterval(40)),
    ]
    let grouped1 = BlueskySystemMessageGrouper.group(messages: stream1)
    #expect(grouped1.count == 5)

    // 2 sys events on day 1, 2 sys events on day 2 -> total 4 items, neither cluster >= 4
    let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: baseDate)!
    let stream2 = [
      makeSys("s1", baseDate),
      makeSys("s2", baseDate.addingTimeInterval(10)),
      makeSys("s3", nextDay),
      makeSys("s4", nextDay.addingTimeInterval(10)),
    ]
    let grouped2 = BlueskySystemMessageGrouper.group(messages: stream2)
    #expect(grouped2.count == 4)
  }

  @Test("System event action targets resolve correctly for all event kinds")
  func testSystemEventActionTargets() throws {
    let memberDID = try DID(didString: "did:plc:member")
    let adminDID = try DID(didString: "did:plc:admin")

    // Member removed with 2 DIDs targets the removed member, not nil or remover
    let removeMsg = ChatBskyConvoDefs.SystemMessageView(
      id: "sys_rm",
      rev: "1",
      sentAt: ATProtocolDate(date: baseDate),
      data: .chatBskyConvoDefsSystemMessageDataRemoveMember(
        ChatBskyConvoDefs.SystemMessageDataRemoveMember(
          member: ChatBskyConvoDefs.SystemMessageReferredUser(did: memberDID),
          removedBy: ChatBskyConvoDefs.SystemMessageReferredUser(did: adminDID)
        )
      )
    )
    let removeAdapter = BlueskyMessageAdapter(systemMessageView: removeMsg)
    #expect(removeAdapter.systemEvent?.actionTarget == .profile(did: "did:plc:member"))
    #expect(removeAdapter.systemEvent?.referencedDIDs.count == 2)

    // All join link events target inviteLink
    let joinLinkDatas: [ChatBskyConvoDefs.SystemMessageViewDataUnion] = [
      .chatBskyConvoDefsSystemMessageDataCreateJoinLink(ChatBskyConvoDefs.SystemMessageDataCreateJoinLink()),
      .chatBskyConvoDefsSystemMessageDataEditJoinLink(ChatBskyConvoDefs.SystemMessageDataEditJoinLink()),
      .chatBskyConvoDefsSystemMessageDataEnableJoinLink(ChatBskyConvoDefs.SystemMessageDataEnableJoinLink()),
      .chatBskyConvoDefsSystemMessageDataDisableJoinLink(ChatBskyConvoDefs.SystemMessageDataDisableJoinLink())
    ]

    for (index, linkData) in joinLinkDatas.enumerated() {
      let linkMsg = ChatBskyConvoDefs.SystemMessageView(
        id: "sys_link_\(index)",
        rev: "1",
        sentAt: ATProtocolDate(date: baseDate),
        data: linkData
      )
      let linkAdapter = BlueskyMessageAdapter(systemMessageView: linkMsg)
      #expect(linkAdapter.systemEvent?.actionTarget == .inviteLink)
      #expect(linkAdapter.systemEvent?.referencedDIDs.isEmpty == true)
    }
  }
}
