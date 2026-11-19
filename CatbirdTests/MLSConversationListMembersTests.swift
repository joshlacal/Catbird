import Testing
@testable import Catbird

/// A chat-list row names the other person even before they have written anything.
@Suite("MLS Conversation List Members Tests")
struct MLSConversationListMembersTests {
  private let me = "did:plc:meeeeeeeeeeeeeeeeeeeeeee"
  private let them = "did:plc:themmmmmmmmmmmmmmmmmmmmm"
  private let gone = "did:plc:goneeeeeeeeeeeeeeeeeeeee"

  @Test("A conversation with no messages still lists the group's members")
  func noMessagesStillHasMembers() {
    let members = MLSConversationListMembers.memberDIDs(groupMembers: [me, them], recentSenders: [])
    #expect(members == [me, them])
  }

  @Test("When only you have written, the other member is still listed")
  func onlyOwnMessages() {
    let members = MLSConversationListMembers.memberDIDs(groupMembers: [me, them], recentSenders: [me, me])
    #expect(members == [me, them])
  }

  @Test("A sender who is no longer a member is kept after the current members")
  func formerMemberIsKept() {
    let members = MLSConversationListMembers.memberDIDs(groupMembers: [me, them], recentSenders: [gone, them])
    #expect(members == [me, them, gone])
  }

  @Test("The same DID in a different letter case is one person")
  func caseInsensitive() {
    let members = MLSConversationListMembers.memberDIDs(
      groupMembers: [them], recentSenders: [them.uppercased(), me])
    #expect(members == [them, me])
  }

  @Test("With no member list, recent senders are used as before")
  func fallsBackToSenders() {
    let members = MLSConversationListMembers.memberDIDs(groupMembers: [], recentSenders: [them, me, them])
    #expect(members == [them, me])
  }
}
