//
//  SpotlightEntityDonator.swift
//  Catbird
//
//  Donates App Intents entities (posts, profiles) to the Spotlight semantic
//  index so Apple Intelligence, Siri, and Spotlight search can find Catbird
//  content. Fire-and-forget: donation failures are logged, never surfaced —
//  indexing is an enhancement, not a dependency, of any calling feature.
//

import AppIntents
import CoreSpotlight
import Foundation
import OSLog
import Petrel

@available(iOS 18.0, *)
actor SpotlightEntityDonator {
  static let shared = SpotlightEntityDonator()

  private let logger = Logger(subsystem: "blue.catbird", category: "SpotlightDonation")

  /// Insertion-ordered dedup memory so repeated feed refreshes don't re-index
  /// the same entities; evicts oldest once `capacity` is reached.
  private var donatedIDs = Set<String>()
  private var donationOrder: [String] = []
  private let capacity = 2000

  /// Per-call cap: feeds can hand over hundreds of posts on a fast scroll.
  private let batchLimit = 50

  /// Bumped when the set of posts eligible for Spotlight changes. Installs that
  /// indexed under an older scope have their stale post entries purged once.
  private static let postIndexScopeVersion = 2
  private static let postIndexScopeKey = "spotlightPostIndexScopeVersion"
  private var postIndexScopeChecked = false

  private init() {}

  // MARK: - Posts

  /// Feed pipeline entry point. Every post is seeded into the deadline-safe
  /// resolution store so Siri's onscreen-context requests ("like this post")
  /// resolve without a network fetch, but only posts the account has engaged
  /// with — authored, liked, reposted, or bookmarked — reach Spotlight. Indexing
  /// every scrolled-past post floods search with strangers' content.
  func donateFeed(posts: [AppBskyFeedDefs.PostView], viewerDID: String?) async {
    await PostEntityStore.shared.store(views: posts)
    await purgeLegacyPostIndexIfNeeded()
    let engaged = posts.filter { post in
      post.author.did.didString() == viewerDID
        || post.viewer?.like != nil
        || post.viewer?.repost != nil
        || post.viewer?.bookmarked == true
    }
    index(engaged.map { PostEntity(from: $0) })
  }

  /// Indexes posts the account deliberately engaged with, such as the anchor
  /// of a thread it opened.
  func donate(posts: [AppBskyFeedDefs.PostView]) async {
    await PostEntityStore.shared.store(views: posts)
    await purgeLegacyPostIndexIfNeeded()
    index(posts.map { PostEntity(from: $0) })
  }

  /// Indexes a post the account just liked, reposted, or bookmarked. The post
  /// was rendered before the interaction, so its view is already in the store.
  func donateEngagement(postURI: String) async {
    let entities = await PostEntityStore.shared.entities(for: [postURI])
    guard !entities.isEmpty else { return }
    await purgeLegacyPostIndexIfNeeded()
    index(entities)
  }

  /// Earlier builds indexed every feed post. Removes those entries once so only
  /// engaged posts remain searchable.
  private func purgeLegacyPostIndexIfNeeded() async {
    guard !postIndexScopeChecked else { return }
    postIndexScopeChecked = true
    let defaults = UserDefaults.standard
    guard defaults.integer(forKey: Self.postIndexScopeKey) < Self.postIndexScopeVersion else {
      return
    }
    do {
      try await CSSearchableIndex.default().deleteAppEntities(ofType: PostEntity.self)
      defaults.set(Self.postIndexScopeVersion, forKey: Self.postIndexScopeKey)
      // Anything indexed while the purge was in flight was deleted with it;
      // forget it so the next donation indexes it again.
      donatedIDs.removeAll()
      donationOrder.removeAll()
      logger.info("Purged Spotlight posts indexed under the previous scope")
    } catch {
      postIndexScopeChecked = false
      logger.warning("Spotlight legacy post purge failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Profiles

  func donate(profiles: [AppBskyActorDefs.ProfileViewDetailed]) {
    let entities = profiles.map { ProfileEntity(from: $0) }
    // Also seed the deadline-safe resolution store (see donate(posts:)).
    Task {
      await ProfileEntityStore.shared.store(entities: entities)
    }
    index(entities)
  }

  /// Removes every indexed post and profile so a signed-out or removed account's
  /// content stops appearing in Spotlight. Content is indexed again as it's viewed.
  func removeAll() async {
    donatedIDs.removeAll()
    donationOrder.removeAll()
    do {
      try await CSSearchableIndex.default().deleteAppEntities(ofType: PostEntity.self)
      try await CSSearchableIndex.default().deleteAppEntities(ofType: ProfileEntity.self)
    } catch {
      logger.warning("Spotlight removal failed: \(error.localizedDescription)")
    }
  }

  private func index<Entity: IndexedEntity>(_ entities: [Entity]) where Entity.ID == String {
    let fresh = Array(entities.filter { !donatedIDs.contains($0.id) }.prefix(batchLimit))
    guard !fresh.isEmpty else { return }
    for entity in fresh {
      remember(entity.id)
    }

    Task {
      do {
        try await CSSearchableIndex.default().indexAppEntities(fresh)
      } catch {
        self.logger.warning(
          "Spotlight donation failed for \(fresh.count) entities: \(error.localizedDescription)")
      }
    }
  }

  private func remember(_ id: String) {
    guard donatedIDs.insert(id).inserted else { return }
    donationOrder.append(id)
    if donationOrder.count > capacity {
      let evicted = donationOrder.removeFirst()
      donatedIDs.remove(evicted)
    }
  }
}

