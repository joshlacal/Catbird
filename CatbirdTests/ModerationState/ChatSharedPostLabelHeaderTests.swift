import Foundation
import Petrel
import Testing

@testable import Catbird

/// A shared post's confirmation request goes out through the production client and carries the
/// account's atproto-accept-labelers header, so its labels come from the labelers the policy trusts.
/// Until the header and the policy agree, shared posts stay covered; a failed first preferences read
/// recovers through the card's retry.
@Suite("DM shared-post label header", .serialized)
@MainActor
struct ChatSharedPostLabelHeaderTests {
  private typealias Fixtures = ModerationStateFixtures
  private typealias Store = ChatRecordEmbedStore

  private func makeScope(for account: ModerationStateAccount, labelers: [String]) -> Store.Scope {
    Store.Scope(
      context: Store.Context(
        account: account.did, state: ObjectIdentifier(account.appState), client: ObjectIdentifier(account.client)),
      labelers: labelers)
  }

  private func makeSource(for account: ModerationStateAccount, scope: Store.Scope) -> Store.Source {
    Store.Source(
      scope: scope,
      currentScope: {
        Store.coveredLabelers(for: account.appState).map { Store.Scope(context: scope.context, labelers: $0) }
      },
      fetch: Store.postsLoader(client: account.client))
  }

  @Test("The confirmation request carries the subscribed labelers and its record is gated by them")
  func confirmationRequestCarriesSubscribedLabelers() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("dmshare"))
    account.server.publishLabeler(did: Fixtures.customLabelerDID)
    account.server.setPreferences(adultContentEnabled: false, labelerDIDs: [Fixtures.customLabelerDID])
    let post = ModerationStatePosts.json(labeled: Fixtures.customLabelValue, source: Fixtures.customLabelerDID)
    account.server.setPosts([post])
    let uri = try #require(post["uri"] as? String)

    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    await account.appState.awaitModerationDefinitionsLoad()

    let labelers = try #require(Store.coveredLabelers(for: account.appState))
    #expect(labelers == [Fixtures.blueskyModerationDID, Fixtures.customLabelerDID].sorted())
    let scope = makeScope(for: account, labelers: labelers)
    let record = try await Store().load(uri: uri, source: makeSource(for: account, scope: scope))

    let requests = account.server.requests(forPath: "app.bsky.feed.getPosts")
    #expect(requests.count == 1)
    #expect(requests.first?.requestedURIs == [uri])
    #expect(requests.first?.acceptLabelers
      == "\(Fixtures.blueskyModerationDID);redact, \(Fixtures.customLabelerDID)")
    guard case .appBskyEmbedRecordViewRecord(let view) = record else {
      Issue.record("getPosts must yield a post record")
      return
    }
    #expect(PostModerationPresentation.make(quoted: view, policy: account.appState.moderationPolicy).concealsBody)
    #expect(!Store.awaitsLabelDefinitions(
      record, policy: account.appState.moderationPolicy,
      definitionsLoading: account.appState.isLoadingModerationDefinitions))
  }

  @Test("Shared posts wait for the header on a first sign-in")
  func sharedPostsWaitForTheHeaderOnFirstSignIn() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("dmfirst"))
    account.server.setPreferences(adultContentEnabled: false)

    #expect(account.appState.preferencesManager.appliedAcceptLabelerDIDs == nil)
    #expect(Store.coveredLabelers(for: account.appState) == nil)

    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)

    #expect(Store.coveredLabelers(for: account.appState) == [Fixtures.blueskyModerationDID])
  }

  @Test("A shared post carrying a new labeler's label stays covered until that labeler's definitions load")
  func labelsWaitForTheirLabelersDefinitions() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("dmdefs"))
    account.server.publishLabeler(did: Fixtures.customLabelerDID)
    account.server.setServicesDelay(0.5)
    account.server.setPreferences(adultContentEnabled: false, labelerDIDs: [Fixtures.customLabelerDID])
    let record = Store.viewRecord(
      from: try ModerationStatePosts.post(labeled: Fixtures.customLabelValue, source: Fixtures.customLabelerDID))

    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)

    #expect(Store.coveredLabelers(for: account.appState) != nil)
    #expect(account.appState.isLoadingModerationDefinitions)
    #expect(Store.awaitsLabelDefinitions(
      record, policy: account.appState.moderationPolicy,
      definitionsLoading: account.appState.isLoadingModerationDefinitions))

    await account.appState.awaitModerationDefinitionsLoad()

    #expect(!account.appState.isLoadingModerationDefinitions)
    #expect(!Store.awaitsLabelDefinitions(
      record, policy: account.appState.moderationPolicy,
      definitionsLoading: account.appState.isLoadingModerationDefinitions))
    guard case .appBskyEmbedRecordViewRecord(let view) = record else {
      Issue.record("The fixture must be a post record")
      return
    }
    #expect(PostModerationPresentation.make(quoted: view, policy: account.appState.moderationPolicy).concealsBody)
  }

  @Test("Retrying a shared post after a failed first preferences read applies the header")
  func retryRecoversAFailedFirstRead() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("dmoffline"))
    account.server.setPreferences(adultContentEnabled: false, labelerDIDs: [Fixtures.customLabelerDID])
    account.server.setPreferencesStatus(400)
    await #expect(throws: (any Error).self) {
      try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    }
    #expect(Store.coveredLabelers(for: account.appState) == nil)
    guard case .error = account.appState.preferencesManager.state else {
      Issue.record("A failed read must leave preferences in the error state the card offers Retry for")
      return
    }

    account.server.setPreferencesStatus(200)
    await Store().resolveLabelScope(appState: account.appState)

    #expect(Store.coveredLabelers(for: account.appState)
      == [Fixtures.blueskyModerationDID, Fixtures.customLabelerDID].sorted())
  }

  @Test("Retrying re-applies the header from confirmed preferences without reading the server")
  func retryReappliesTheHeaderLocally() async throws {
    let harness = try ModerationStateHarness()
    defer { harness.tearDown() }
    let account = try await harness.makeAccount(did: Fixtures.uniqueDID("dmreapply"))
    account.server.setPreferences(adultContentEnabled: false, labelerDIDs: [Fixtures.customLabelerDID])
    try await account.appState.preferencesManager.fetchPreferences(forceRefresh: true)
    // A client replacement clears the applied header until its unawaited re-seed runs.
    account.appState.preferencesManager.updateClient(account.client)
    #expect(Store.coveredLabelers(for: account.appState) == nil)
    let reads = account.server.requests(forPath: "app.bsky.actor.getPreferences").count

    await Store().resolveLabelScope(appState: account.appState)

    #expect(Store.coveredLabelers(for: account.appState)
      == [Fixtures.blueskyModerationDID, Fixtures.customLabelerDID].sorted())
    #expect(account.server.requests(forPath: "app.bsky.actor.getPreferences").count == reads)
  }
}
