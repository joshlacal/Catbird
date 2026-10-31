import Testing
@testable import Catbird

@Suite("Trending image prefetch request ownership")
struct TopicPreviewImagePrefetchTests {
  private struct Request: Hashable {
    let url: String
    let resize: String
  }

  @Test("Same URL with different processors releases independently in both owner orders", arguments: [true, false])
  func resizeVariantsReleaseIndependently(searchFirst: Bool) {
    let card = Request(url: "https://cdn.example.test/shared.jpg", resize: "62x72")
    let avatar = Request(url: card.url, resize: "26x26")
    var ownership = TopicPreviewImagePrefetchOwnership<Request, Request>()
    #expect(ownership.append([card, card], owner: .timeline, identity: { $0 }) == [card])
    #expect(ownership.append([avatar], owner: .search, identity: { $0 }) == [avatar])
    let first: TopicPreviewPrefetchOwner = searchFirst ? .search : .timeline
    let last: TopicPreviewPrefetchOwner = searchFirst ? .timeline : .search
    #expect(ownership.remove(owner: first, identity: { $0 }) == [searchFirst ? avatar : card])
    #expect(ownership.remove(owner: last, identity: { $0 }) == [searchFirst ? card : avatar])
    #expect(ownership.requests.isEmpty)
  }

  @Test("Only an identical processed request stays retained for another owner", arguments: [true, false])
  func exactSharedVariantRetainsLastOwner(searchFirst: Bool) {
    let card = Request(url: "https://cdn.example.test/shared.jpg", resize: "62x72")
    let avatar = Request(url: card.url, resize: "26x26")
    var ownership = TopicPreviewImagePrefetchOwnership<Request, Request>()
    #expect(ownership.append([card], owner: .timeline, identity: { $0 }) == [card])
    // A later topic may use the same URL with a second processor for this owner.
    #expect(ownership.append([avatar, card], owner: .timeline, identity: { $0 }) == [avatar])
    #expect(ownership.append([avatar], owner: .search, identity: { $0 }) == [avatar])
    let first: TopicPreviewPrefetchOwner = searchFirst ? .search : .timeline
    let last: TopicPreviewPrefetchOwner = searchFirst ? .timeline : .search
    #expect(ownership.remove(owner: first, identity: { $0 }) == (searchFirst ? [] : [card]))
    #expect(ownership.remove(owner: last, identity: { $0 }) == (searchFirst ? [card, avatar] : [avatar]))
    #expect(ownership.requests.isEmpty)
  }

  @Test("Each owner remains bounded to thirty-six unique processed requests")
  func boundedOwnerRequests() {
    let cards = (0..<50).map { Request(url: "https://cdn.example.test/\($0).jpg", resize: "62x72") }
    var ownership = TopicPreviewImagePrefetchOwnership<Request, Request>()
    #expect(ownership.append(Array(repeating: cards[0], count: 50) + cards, owner: .search, identity: { $0 }) == Array(cards.prefix(36)))
    #expect(ownership.append(cards, owner: .search, identity: { $0 }).isEmpty)
    #expect(ownership.append(cards, owner: .timeline, identity: { $0 }).count == 36)
    #expect(ownership.requests.values.allSatisfy { $0.count == 36 })
    ownership.removeAll()
    #expect(ownership.requests.isEmpty)
  }
}
