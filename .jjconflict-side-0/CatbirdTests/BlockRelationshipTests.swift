import Testing
import Petrel
@testable import Catbird

@Suite("BlockRelationship")
struct BlockRelationshipTests {
  private func uri(_ s: String) -> ATProtocolURI {
    try! ATProtocolURI(uriString: s)
  }
  private var blockUri: ATProtocolURI { uri("at://did:plc:me/app.bsky.graph.block/3abc") }
  private var listUri: ATProtocolURI { uri("at://did:plc:me/app.bsky.graph.list/3list") }
  private var listRef: BlockRelationship.ListRef {
    .init(uri: listUri, name: "Photography Blocklist",
          listblockRecordUri: uri("at://did:plc:me/app.bsky.graph.listblock/3lb"))
  }

  @Test func directBlockOnly() {
    let r = BlockRelationship(blocking: blockUri, blockedBy: false, blockingByList: nil)
    #expect(r.direction == .youBlocked)
    #expect(r.sources == [.direct(recordUri: blockUri)])
    #expect(r.canReveal)
    #expect(r.canUnblockDirectly)
    #expect(r.statusText == "You blocked this account")
  }

  @Test func blockedYouOnly() {
    let r = BlockRelationship(blocking: nil, blockedBy: true, blockingByList: nil)
    #expect(r.direction == .blockedYou)
    #expect(r.sources.isEmpty)
    #expect(!r.canReveal)
    #expect(!r.canUnblockDirectly)
    #expect(r.statusText == "This account blocked you")
  }

  @Test func mutual() {
    let r = BlockRelationship(blocking: blockUri, blockedBy: true, blockingByList: nil)
    #expect(r.direction == .mutual)
    #expect(r.statusText == "You and this account have blocked each other")
  }

  @Test func listOnly() {
    let r = BlockRelationship(blocking: nil, blockedBy: nil, blockingByList: listRef)
    #expect(r.direction == .youBlocked)
    #expect(r.directBlockUri == nil)
    #expect(r.listRef?.name == "Photography Blocklist")
    #expect(r.statusText == "You blocked this account through Photography Blocklist")
  }

  @Test func directPlusListSimultaneously() {
    let r = BlockRelationship(blocking: blockUri, blockedBy: nil, blockingByList: listRef)
    #expect(r.direction == .youBlocked)
    #expect(r.sources.count == 2)
    #expect(r.directBlockUri == blockUri)   // list must never conceal the direct block
    #expect(r.statusText == "You blocked this account directly and through Photography Blocklist")
  }

  @Test func listPlusBlockedYou() {
    let r = BlockRelationship(blocking: nil, blockedBy: true, blockingByList: listRef)
    #expect(r.direction == .mutual)
    #expect(r.statusText == "You and this account have blocked each other. Your block comes from Photography Blocklist.")
  }

  @Test func removingListBlockLeavesDirect() {
    // Simulates state after the listblock record is deleted but the direct block remains.
    let r = BlockRelationship(blocking: blockUri, blockedBy: nil, blockingByList: nil)
    #expect(r.direction == .youBlocked)
    #expect(r.canUnblockDirectly)
  }

  @Test func noViewerState() {
    let r = BlockRelationship(viewer: nil)
    #expect(r.direction == .unknown)
    #expect(r.statusText == "Post blocked")
  }
}
