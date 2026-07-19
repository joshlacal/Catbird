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
}
