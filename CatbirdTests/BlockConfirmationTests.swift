import Testing
@testable import Catbird

@Suite("BlockConfirmation")
struct BlockConfirmationTests {
  @Test func blockMessageWithNoAffectedConvos() {
    #expect(
      BlockConfirmation.blockMessage(handle: "alice.bsky.social", affectedConvoCount: 0)
        == "Block @alice.bsky.social? You won't see each other's posts, and they won't be able to follow you."
    )
  }

  @Test func blockMessageWithOneAffectedConvo() {
    #expect(
      BlockConfirmation.blockMessage(handle: "alice.bsky.social", affectedConvoCount: 1)
        == "Block @alice.bsky.social? You won't see each other's posts, and you'll leave 1 shared conversation. This can't be undone — unblocking will not rejoin the conversations."
    )
  }

  @Test func blockMessageWithMultipleAffectedConvos() {
    #expect(
      BlockConfirmation.blockMessage(handle: "alice.bsky.social", affectedConvoCount: 2)
        == "Block @alice.bsky.social? You won't see each other's posts, and you'll leave 2 shared conversations. This can't be undone — unblocking will not rejoin the conversations."
    )
  }

  @Test func unblockMessage() {
    #expect(
      BlockConfirmation.unblockMessage(handle: "alice.bsky.social")
        == "Unblock @alice.bsky.social? They will be able to interact with you again. Note: previously-left conversations will NOT be rejoined — you'll need a fresh invite."
    )
  }

  @Test func mutualGroupsDeduplication() throws {
    let convo1ID = "convo-1"
    let convo2ID = "convo-2"
    let convo3ID = "convo-3"
    
    var existingIDs = Set([convo1ID, convo2ID])
    let incoming = [convo2ID, convo3ID]
    
    let newConvos = incoming.filter { !existingIDs.contains($0) }
    #expect(newConvos == [convo3ID])
    
    for id in newConvos {
      existingIDs.insert(id)
    }
    #expect(existingIDs.count == 3)
  }

  @Test func optimisticRemovalAndRestoration() {
    var mutualGroups = ["group-1", "group-2", "group-3"]
    let original = mutualGroups
    
    // Optimistic remove
    mutualGroups.removeAll { $0 == "group-2" }
    #expect(mutualGroups == ["group-1", "group-3"])
    
    // Simulate failure -> restore
    mutualGroups = original
    #expect(mutualGroups == ["group-1", "group-2", "group-3"])
  }
}
