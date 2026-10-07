import Foundation
import Petrel
import Testing

@testable import Catbird

@Suite("Moderation policy feed refiltering", .serialized)
@MainActor
struct ModerationPolicyFeedTests {
  private typealias Fixtures = ModerationStateFixtures

  /// The notification is delivered on the main queue, so give it a few turns to arrive. Returns whether
  /// the model was loading at any point while waiting.
  @discardableResult
  private func waitUntil(model: FeedModel, _ condition: () -> Bool) async throws -> Bool {
    var sawLoading = model.isLoading
    for _ in 0..<100 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
      sawLoading = sawLoading || model.isLoading
    }
    return sawLoading
  }

  private func timelineRequests(_ account: ModerationStateAccount) -> Int {
    account.server.requests(forPath: "app.bsky.feed.getTimeline").count
  }

  @Test("A policy change re-filters the loaded posts without reloading the feed")
  func policyChangeRefiltersLoadedPosts() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("feedrefilter"))
    account.server.setPreferences(adultContentEnabled: true)
    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)

    // The feed manager talks to the fake server, so a reload could not go unnoticed.
    let feedManager = FeedManager(client: account.client, fetchType: .timeline)
    // Positive control: a timeline fetch through this manager is recorded by the server.
    _ = try? await feedManager.fetchFeed(fetchType: .timeline, cursor: nil)
    let timelineRequestsBefore = timelineRequests(account)
    #expect(timelineRequestsBefore == 1)

    let model = FeedModel(feedManager: feedManager, appState: account.appState)
    let adult = try ModerationStatePosts.cachedFeedPost(labeled: "porn", slug: "adult")
    let plain = try ModerationStatePosts.cachedFeedPost(labeled: nil, slug: "plain")
    model.posts = [adult, plain]
    let requestsBefore = account.server.requests.count

    // The server turns adult content off. The poll's fetch changes the policy, and the feed drops the
    // post the new policy hides.
    account.server.setPreferences(adultContentEnabled: false)
    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    var sawLoading = try await waitUntil(model: model) { model.posts.count == 1 }
    // A reload started by the change would show up as a timeline request or a loading feed shortly after.
    try await Task.sleep(for: .milliseconds(250))
    sawLoading = sawLoading || model.isLoading

    #expect(model.posts.map(\.id) == [plain.id])
    #expect(timelineRequests(account) == timelineRequestsBefore)
    #expect(!sawLoading)
    // Only the fetch itself and the label-definitions refresh touched the network.
    let allowed: Set<String> = ["/xrpc/app.bsky.actor.getPreferences", "/xrpc/app.bsky.labeler.getServices"]
    let paths = Set(account.server.requests.dropFirst(requestsBefore).map { $0.path })
    #expect(paths.isSubset(of: allowed))
  }

  @Test("A policy change for another account leaves the loaded posts alone")
  func otherAccountPolicyChangeIsIgnored() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("feedowner"))
    account.server.setPreferences(adultContentEnabled: false)
    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    let model = FeedModel(feedManager: FeedManager(client: account.client, fetchType: .timeline), appState: account.appState)
    let adult = try ModerationStatePosts.cachedFeedPost(labeled: "porn", slug: "adultother")
    model.posts = [adult]

    NotificationCenter.default.post(
      name: .moderationPolicyDidChange, object: nil, userInfo: ["accountDID": "did:plc:someoneelse"])
    try await Task.sleep(for: .milliseconds(100))

    #expect(model.posts.map(\.id) == [adult.id])
  }
}
