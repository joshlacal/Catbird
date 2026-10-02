import Testing
@testable import Catbird

@Suite("BlockConfirmation")
struct BlockConfirmationTests {
  @Test func blockMessage() {
    #expect(
      BlockConfirmation.blockMessage(handle: "alice.bsky.social")
        == "Block @alice.bsky.social? You won't see each other's posts, and they won't be able to follow you."
    )
  }

  @Test func unblockMessage() {
    #expect(
      BlockConfirmation.unblockMessage(handle: "alice.bsky.social")
        == "Unblock @alice.bsky.social? They will be able to interact with you again."
    )
  }
}
