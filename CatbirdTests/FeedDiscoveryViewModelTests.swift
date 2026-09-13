import Foundation
import Petrel
import Testing
@testable import Catbird

@MainActor
struct FeedDiscoveryViewModelTests {
  @Test func replacingProviderRejectsPriorResponseAndRetainsUsefulResults() async throws {
    let old = ControlledDiscoveryProvider()
    let replacement = ControlledDiscoveryProvider()
    let model = FeedDiscoveryViewModel(provider: old, accountDID: "one")
    model.load()
    await old.waitForRequests(1)
    old.succeed(0, feeds: [try feed("useful")])
    await settle()
    model.refresh()
    await old.waitForRequests(2)
    model.updateAccount(provider: replacement, accountDID: "one")
    #expect(model.items.map(\.displayName) == ["useful"])
    await replacement.waitForRequests(1)
    replacement.succeed(0, feeds: [try feed("replacement")])
    await settle()
    old.succeed(1, feeds: [try feed("obsolete")])
    await settle()
    #expect(model.items.map(\.displayName) == ["replacement"])
  }

  @Test func olderQueryCannotReplaceNewerQuery() async throws {
    let provider = ControlledDiscoveryProvider()
    let model = FeedDiscoveryViewModel(provider: provider, accountDID: "one")
    model.query = "old"
    model.submit()
    await provider.waitForRequests(1)
    model.query = "new"
    model.submit()
    await provider.waitForRequests(2)
    provider.succeed(1, feeds: [try feed("new")], cursor: "new-page")
    await settle()
    provider.succeed(0, feeds: [try feed("old")], cursor: "old-page")
    await settle()
    #expect(model.items.map(\.displayName) == ["new"])
    #expect(model.cursor == "new-page")
  }

  @Test func clearingQueryRestoresBrowse() async throws {
    let provider = ControlledDiscoveryProvider()
    let model = FeedDiscoveryViewModel(provider: provider, accountDID: "one", initialQuery: " birds ")
    model.load()
    await provider.waitForRequests(1)
    #expect(provider.queries[0] == "birds")
    provider.succeed(0, feeds: [try feed("birds")])
    await settle()
    model.query = ""
    await provider.waitForRequests(2)
    #expect(provider.queries[1] == nil)
    provider.succeed(1, feeds: [try feed("popular")])
    await settle()
    #expect(model.resultQuery.isEmpty)
    #expect(model.items.map(\.displayName) == ["popular"])
  }

  @Test func accountChangeRejectsPriorResponse() async throws {
    let provider = ControlledDiscoveryProvider()
    let model = FeedDiscoveryViewModel(provider: provider, accountDID: "one")
    model.load()
    await provider.waitForRequests(1)
    model.updateAccount(provider: provider, accountDID: "two")
    await provider.waitForRequests(2)
    provider.succeed(1, feeds: [try feed("two")])
    await settle()
    provider.succeed(0, feeds: [try feed("one")])
    await settle()
    #expect(model.items.map(\.displayName) == ["two"])
  }

  @Test func pagingDeduplicatesURIs() async throws {
    let provider = ControlledDiscoveryProvider()
    let model = FeedDiscoveryViewModel(provider: provider, accountDID: "one")
    model.load()
    await provider.waitForRequests(1)
    provider.succeed(0, feeds: [try feed("a"), try feed("a")], cursor: "next")
    await settle()
    model.loadMore()
    model.loadMore()
    await provider.waitForRequests(2)
    #expect(provider.queries.count == 2)
    provider.succeed(1, feeds: [try feed("a"), try feed("b")], cursor: "next")
    await settle()
    #expect(model.items.map(\.displayName) == ["a", "b"])
    #expect(model.cursor == nil)
  }

  @Test func pagingFailureRetainsItemsAndCursor() async throws {
    let provider = ControlledDiscoveryProvider()
    let model = FeedDiscoveryViewModel(provider: provider, accountDID: "one")
    model.load()
    await provider.waitForRequests(1)
    provider.succeed(0, feeds: [try feed("a")], cursor: "next")
    await settle()
    model.loadMore()
    await provider.waitForRequests(2)
    provider.fail(1)
    await settle()
    #expect(model.items.count == 1)
    #expect(model.cursor == "next")
    #expect(model.pagingError != nil)
    #expect(model.initialError == nil && model.refreshError == nil)
    model.retry()
    await provider.waitForRequests(3)
    #expect(provider.cursors[2] == "next")
    provider.succeed(2, feeds: [try feed("b")])
    await settle()
    #expect(model.items.count == 2 && model.pagingError == nil)
  }

  @Test func cancelledSearchDoesNotShowError() async {
    let provider = ControlledDiscoveryProvider()
    let model = FeedDiscoveryViewModel(provider: provider, accountDID: "one")
    model.load()
    await provider.waitForRequests(1)
    model.cancel()
    provider.fail(0)
    await settle()
    #expect(model.initialError == nil && model.refreshError == nil)
    #expect(!model.isInitialLoading)
  }

  @Test func refreshFailureRetainsUsefulResults() async throws {
    let provider = ControlledDiscoveryProvider()
    let model = FeedDiscoveryViewModel(provider: provider, accountDID: "one")
    model.load()
    await provider.waitForRequests(1)
    provider.fail(0)
    await settle()
    #expect(model.initialError != nil)
    model.retry()
    await provider.waitForRequests(2)
    provider.succeed(1, feeds: [try feed("a")])
    await settle()
    model.refresh()
    await provider.waitForRequests(3)
    provider.fail(2)
    await settle()
    #expect(model.items.count == 1 && model.refreshError != nil)
    #expect(model.initialError == nil && model.pagingError == nil)
  }

  private func settle() async { for _ in 0..<20 { await Task.yield() } }

  private func feed(_ name: String) throws -> AppBskyFeedDefs.GeneratorView {
    try JSONDecoder().decode(AppBskyFeedDefs.GeneratorView.self, from: Data("""
      {"uri":"at://did:plc:creator1234567890123456/app.bsky.feed.generator/\(name)",
       "cid":"bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku",
       "did":"did:plc:feedservice1234567890",
       "creator":{"did":"did:plc:creator1234567890123456","handle":"creator.test"},
       "displayName":"\(name)","indexedAt":"2026-01-01T00:00:00Z"}
      """.utf8))
  }
}

@MainActor
private final class ControlledDiscoveryProvider: FeedDiscoveryProviding {
  private(set) var queries: [String?] = []
  private(set) var cursors: [String?] = []
  private var requests: [Int: CheckedContinuation<FeedDiscoveryPage, any Error>] = [:]

  func page(query: String?, cursor: String?) async throws -> FeedDiscoveryPage {
    let index = queries.count
    queries.append(query)
    cursors.append(cursor)
    // Deliberately ignores cancellation so the model must reject stale completions.
    return try await withCheckedThrowingContinuation { requests[index] = $0 }
  }

  func waitForRequests(_ count: Int) async {
    for _ in 0..<1000 {
      if queries.count >= count { return }
      await Task.yield()
    }
    Issue.record("Expected \(count) requests, received \(queries.count)")
  }

  func succeed(_ index: Int, feeds: [AppBskyFeedDefs.GeneratorView], cursor: String? = nil) {
    requests.removeValue(forKey: index)?.resume(returning: FeedDiscoveryPage(feeds: feeds, cursor: cursor))
  }

  func fail(_ index: Int) {
    requests.removeValue(forKey: index)?.resume(throwing: NSError(domain: "test", code: 1))
  }
}
