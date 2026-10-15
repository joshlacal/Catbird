#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// A moderation policy change only re-filters the feed's posts (`FeedModel`); a post that stays
/// in the feed but gains or loses a label must move between its native cell and the hosted row.
@Suite("Native feed rows follow the moderation policy", .serialized)
@MainActor
struct NativeFeedRowModerationPolicyTests {
  private typealias Fixtures = ModerationStateFixtures

  @Test("A policy change moves a post between the native cell and the hosted row")
  func policyChangeReclassifiesVisibleRows() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("nativerowpolicy"))
    let appState = account.appState
    let labeler = Fixtures.customLabelerDID
    account.server.publishLabeler(did: labeler)
    // Not subscribed to the labeler: its content-blurring label is ignored.
    try await Self.serverSubscribes(to: [], account: account)

    let post = try Self.cachedPost(labeledBy: labeler)
    let before = Self.classification(of: post, appState: appState)
    #expect(before == .native, "\(before)")

    let host = try NativeFeedRowControllerHost(appState: appState, posts: [post])
    defer { host.tearDown() }
    await host.controller.performUpdate()
    _ = try await host.waitForPostCell(NativeFeedPostCell.self)

    // Subscribing makes the label blur the post's content: the row must be the hosted one.
    try await Self.serverSubscribes(to: [labeler], account: account)
    let subscribed = Self.classification(of: post, appState: appState)
    #expect(subscribed == .hosted(.moderation), "\(subscribed)")
    _ = try await host.waitForPostCell(FeedPostCollectionViewCell.self)

    // And back to the native cell once the label no longer applies.
    try await Self.serverSubscribes(to: [], account: account)
    let unsubscribed = Self.classification(of: post, appState: appState)
    #expect(unsubscribed == .native, "\(unsubscribed)")
    _ = try await host.waitForPostCell(NativeFeedPostCell.self)
  }

  // MARK: - Helpers

  /// The server changes the account's labeler subscriptions and the app fetches them, as the
  /// preferences poll does. A forced fetch within a few seconds of the last one reuses that read
  /// unless the preference session changed, so the fetch starts a new session with the same client.
  private static func serverSubscribes(to labelers: [String], account: ModerationStateAccount) async throws {
    account.server.setPreferences(adultContentEnabled: false, labelerDIDs: labelers)
    account.appState.preferencesManager.updateClient(account.client)
    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    await account.appState.awaitModerationDefinitionsLoad()
  }

  private static func cachedPost(labeledBy labeler: String) throws -> CachedFeedViewPost {
    let json = ["post": ModerationStatePosts.json(labeled: Fixtures.customLabelValue, source: labeler, slug: "nativerow")]
    let item = try JSONDecoder().decode(
      AppBskyFeedDefs.FeedViewPost.self, from: JSONSerialization.data(withJSONObject: json))
    return try #require(CachedFeedViewPost(from: item, feedType: "timeline"))
  }

  private static func classification(of post: CachedFeedViewPost, appState: AppState) -> NativeFeedRowSupport {
    guard let item = try? post.feedViewPost else { return .hosted(.decodeFailed) }
    let moderation = PostModerationPresentation.make(
      post: item.post, policy: appState.moderationPolicy, surface: .contentList, listFilterExemptDID: nil)
    let settings = NativeFeedRowSupport.Settings(
      isEnabled: true, deviceLanguageCode: Locale.current.language.baseLanguageCode?.lowercased() ?? "en",
      preferredContentLanguages: Set(appState.appSettings.contentLanguages),
      showLanguageIndicators: appState.appSettings.showLanguageIndicators,
      showReadingTimeEstimates: appState.appSettings.showReadingTimeEstimates)
    return NativeFeedRowSupport.classify(post, moderation: moderation, settings: settings)
  }
}
#endif
