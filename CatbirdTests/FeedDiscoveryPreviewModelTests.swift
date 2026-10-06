import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
struct FeedDiscoveryPreviewModelTests {
  @Test func onlySelectedFeedLoadsAndOlderSelectionCannotReplaceIt() async throws {
    let provider = ControlledPreviewProvider()
    let session = PreviewSessionBox(client: provider)
    let model = makeModel(provider: provider, session: session)
    let first = try feed("first")
    let second = try feed("second")
    let oldLoad = Task { await model.load(feed: first) }
    await provider.waitForRequests(1)
    #expect(provider.requestedURIs == [first.uri.uriString()])
    let newLoad = Task { await model.load(feed: second) }
    await provider.waitForRequests(2)
    #expect(model.posts.isEmpty)
    #expect(model.state == .loading)
    provider.succeed(1, posts: [try post("new")])
    await newLoad.value
    provider.succeed(0, posts: [try post("old")])
    await oldLoad.value
    #expect(model.selectedFeedURI == second.uri.uriString())
    #expect(model.posts.map { $0.post.uri.recordKey } == ["new"])
    #expect(model.state == .loaded)
    #expect(provider.requestedURIs.count == 2)
  }

  @Test(arguments: [false, true])
  func changedAccountOrClientRejectsPendingResponse(changeClient: Bool) async throws {
    let provider = ControlledPreviewProvider()
    let session = PreviewSessionBox(client: provider)
    let model = makeModel(provider: provider, session: session)
    let selected = try feed("selected")
    let load = Task { await model.load(feed: selected) }
    await provider.waitForRequests(1)
    let replacementClient = NSObject()
    session.value = FeedDiscoveryPreviewSession(
      accountDID: changeClient ? "one" : "two",
      clientIdentity: changeClient ? ObjectIdentifier(replacementClient) : ObjectIdentifier(provider))
    provider.succeed(0, posts: [try post("obsolete")])
    await load.value
    #expect(model.posts.isEmpty)
    #expect(model.state != .loaded)
    #expect(model.accountDID == "one")
    #expect(model.clientIdentity == ObjectIdentifier(provider))
  }

  @Test func dismissalCancelsAndRejectsTransportThatIgnoresCancellation() async throws {
    let provider = ControlledPreviewProvider()
    let model = makeModel(provider: provider, session: PreviewSessionBox(client: provider))
    let selected = try feed("selected")
    let load = Task { await model.load(feed: selected) }
    await provider.waitForRequests(1)
    model.cancel()
    provider.succeed(0, posts: [try post("obsolete")])
    await load.value
    #expect(model.state == .idle)
    #expect(model.posts.isEmpty)
    #expect(model.selectedFeedURI == nil)
  }

  @Test func owningTaskCancellationDoesNotPublishPostsOrAnError() async throws {
    let provider = ControlledPreviewProvider()
    let model = makeModel(provider: provider, session: PreviewSessionBox(client: provider))
    let selected = try feed("selected")
    let load = Task { await model.load(feed: selected) }
    await provider.waitForRequests(1)
    load.cancel()
    provider.succeed(0, posts: [try post("obsolete")])
    await load.value
    #expect(model.state == .idle)
    #expect(model.posts.isEmpty)
  }

  @Test func alreadyCancelledTaskDoesNotStartARequest() async throws {
    let provider = ControlledPreviewProvider()
    let model = makeModel(provider: provider, session: PreviewSessionBox(client: provider))
    let selected = try feed("selected")
    let load = Task { await model.load(feed: selected) }
    load.cancel()
    await load.value
    #expect(provider.requestedURIs.isEmpty)
    #expect(model.state == .idle)
  }

  @Test func retryInvalidatesOnlySelectedFeedAndCanResolveToEmpty() async throws {
    let provider = ControlledPreviewProvider()
    let model = makeModel(provider: provider, session: PreviewSessionBox(client: provider))
    let selected = try feed("selected")
    let load = Task { await model.load(feed: selected) }
    await provider.waitForRequests(1)
    provider.fail(0)
    await load.value
    guard case .failed = model.state else {
      Issue.record("A failed request should expose retryable failure state")
      return
    }
    let retry = Task { await model.load(feed: selected, forceRefresh: true) }
    await provider.waitForRequests(2)
    #expect(provider.invalidatedURIs == [selected.uri.uriString()])
    provider.succeed(1, posts: [])
    await retry.value
    #expect(model.state == .empty)
    #expect(model.posts.isEmpty)
  }

  @Test func filteredPreviewIsDifferentFromAnEmptyFeed() async throws {
    let provider = ControlledPreviewProvider()
    let session = PreviewSessionBox(client: provider)
    let model = FeedDiscoveryPreviewModel(provider: provider, currentSession: { session.value },
                                         filterPosts: { _ in [] })
    let selected = try feed("selected")
    let load = Task { await model.load(feed: selected) }
    await provider.waitForRequests(1)
    provider.succeed(0, posts: [try post("hidden")])
    await load.value
    #expect(model.state == .filtered)
    #expect(model.posts.isEmpty)
  }

  @Test func moderationRetainsVisiblePostsAndRemovesBlockedMutedAndHiddenPosts() async throws {
    let visible = try post("visible")
    let blocked = try post("blocked", viewer: #"{"blockedBy":true}"#)
    let muted = try post("muted", viewer: #"{"muted":true}"#)
    let hidden = try post("hidden")
    let settings = FeedTunerSettings(
      hideReplies: false, hideRepliesByUnfollowed: false, hideRepliesByLikeCount: nil,
      hideReposts: false, hideQuotePosts: false, hideNonPreferredLanguages: false,
      preferredLanguages: [], mutedUsers: [], blockedUsers: [], hideLinks: false,
      onlyTextPosts: false, onlyMediaPosts: false, contentLabelPreferences: [],
      hideAdultContent: true, hiddenPosts: [hidden.post.uri.uriString()], currentUserDid: "one")
    let result = await FeedDiscoveryPreviewModel.moderatedPosts([visible, blocked, muted, hidden], settings: settings)
    #expect(result.map { $0.post.uri.uriString() } == [visible.post.uri.uriString()])
  }

  private func makeModel(provider: ControlledPreviewProvider, session: PreviewSessionBox) -> FeedDiscoveryPreviewModel {
    FeedDiscoveryPreviewModel(provider: provider, currentSession: { session.value }, filterPosts: { $0 })
  }

  private func feed(_ name: String) throws -> AppBskyFeedDefs.GeneratorView {
    try JSONDecoder().decode(AppBskyFeedDefs.GeneratorView.self, from: Data("""
      {"uri":"at://did:plc:creator1234567890123456/app.bsky.feed.generator/\(name)",
       "cid":"bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
       "did":"did:plc:feedservice1234567890",
       "creator":{"did":"did:plc:creator1234567890123456","handle":"creator.test"},
       "displayName":"\(name)","indexedAt":"2026-01-01T00:00:00Z"}
      """.utf8))
  }

  private func post(_ name: String, viewer: String = "{}") throws -> AppBskyFeedDefs.FeedViewPost {
    try JSONDecoder().decode(AppBskyFeedDefs.FeedViewPost.self, from: Data("""
      {"post":{"uri":"at://did:plc:creator1234567890123456/app.bsky.feed.post/\(name)",
       "cid":"bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
       "author":{"did":"did:plc:creator1234567890123456","handle":"creator.test","viewer":\(viewer)},
       "record":{"$type":"app.bsky.feed.post","text":"\(name)","createdAt":"2026-01-01T00:00:00Z"},
       "indexedAt":"2026-01-01T00:00:00Z"}}
      """.utf8))
  }
}

@MainActor
private final class PreviewSessionBox {
  var value: FeedDiscoveryPreviewSession

  init(client: AnyObject) {
    value = FeedDiscoveryPreviewSession(accountDID: "one", clientIdentity: ObjectIdentifier(client))
  }
}

@MainActor
private final class ControlledPreviewProvider: FeedDiscoveryPreviewProviding {
  private(set) var requestedURIs: [String] = []
  private(set) var invalidatedURIs: [String] = []
  private var requests: [Int: CheckedContinuation<[AppBskyFeedDefs.FeedViewPost], any Error>] = [:]

  func fetchPreview(for feedURI: ATProtocolURI) async throws -> [AppBskyFeedDefs.FeedViewPost] {
    let index = requestedURIs.count
    requestedURIs.append(feedURI.uriString())
    // Deliberately ignores cancellation to exercise stale completion rejection.
    return try await withCheckedThrowingContinuation { requests[index] = $0 }
  }

  func invalidateCache(for feedURI: ATProtocolURI) async {
    invalidatedURIs.append(feedURI.uriString())
  }

  func waitForRequests(_ count: Int) async {
    for _ in 0..<1000 {
      if requestedURIs.count >= count { return }
      await Task.yield()
    }
    Issue.record("Expected \(count) preview requests, received \(requestedURIs.count)")
  }

  func succeed(_ index: Int, posts: [AppBskyFeedDefs.FeedViewPost]) {
    requests.removeValue(forKey: index)?.resume(returning: posts)
  }

  func fail(_ index: Int) {
    requests.removeValue(forKey: index)?.resume(throwing: NSError(domain: "test", code: 1))
  }
}
