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

  /// Whether each post seen in a feed or thread may be indexed, keyed by URI and valid only
  /// under `verdictPolicy`. Engagement donations receive a URI, not the labeled post, so they
  /// rely on this record; a post without a current verdict is not indexed.
  private var postVerdicts: [String: Bool] = [:]
  private var verdictOrder: [String] = []
  private var verdictPolicy: ModerationPolicy?

  /// Bumped when the set of posts eligible for Spotlight changes. Installs that
  /// indexed under an older scope have their stale post entries purged once.
  private static let postIndexScopeVersion = 2
  private static let postIndexScopeKey = "spotlightPostIndexScopeVersion"
  private var postIndexScopeChecked = false

  private init() {}

  // MARK: - Posts

  /// Feed pipeline entry point. Posts are seeded into the deadline-safe
  /// resolution store so Siri's onscreen-context requests ("like this post")
  /// resolve without a network fetch, but only posts the account has engaged
  /// with — authored, liked, reposted, or bookmarked — reach Spotlight. Indexing
  /// every scrolled-past post floods search with strangers' content. Moderation
  /// applies to both: posts feeds drop are not seeded, and moderated posts are
  /// not indexed. Before the account's policy is confirmed nothing is seeded or
  /// indexed here; rendered posts still seed the store from `PostView`.
  func donateFeed(posts: [AppBskyFeedDefs.PostView], viewerDID: String?) async {
    let activePolicy: ModerationPolicy? = await activeModerationPolicy()
    guard let policy = activePolicy, policy.accountDID == viewerDID else { return }
    let listed: [AppBskyFeedDefs.PostView] = posts.filter { post in
      SpotlightDonationModeration.isListed(post, policy: policy)
    }
    await PostEntityStore.shared.store(views: listed)
    await purgeLegacyPostIndexIfNeeded()
    recordVerdicts(for: posts, policy: policy)
    let indexable: [AppBskyFeedDefs.PostView] = SpotlightDonationModeration.indexableFeedPosts(
      posts, viewerDID: viewerDID, policy: policy)
    index(indexable.map { PostEntity(from: $0) })
  }

  /// Indexes posts the account deliberately engaged with, such as the anchor
  /// of a thread it opened, unless moderation keeps them out of Spotlight. The
  /// resolution store, persisted to the App Group with the text and the author
  /// avatar URL, is seeded under the same policy, and only once the account's
  /// policy is confirmed.
  func donate(posts: [AppBskyFeedDefs.PostView]) async {
    guard let policy = await activeModerationPolicy() else { return }
    let indexable = SpotlightDonationModeration.storablePosts(posts, policy: policy)
    await PostEntityStore.shared.store(views: indexable)
    await purgeLegacyPostIndexIfNeeded()
    recordVerdicts(for: posts, policy: policy)
    index(indexable.map { PostEntity(from: $0) })
  }

  /// Indexes a post the account just liked, reposted, or bookmarked. The post
  /// was rendered before the interaction, so its view is already in the store.
  /// It is indexed only when this donator saw the post under the current
  /// moderation policy and that policy allows it.
  func donateEngagement(postURI: String) async {
    guard let policy = await activeModerationPolicy(), policy == verdictPolicy,
      postVerdicts[postURI] == true
    else { return }
    let entities = await PostEntityStore.shared.entities(for: [postURI])
    guard !entities.isEmpty else { return }
    await purgeLegacyPostIndexIfNeeded()
    index(entities)
  }

  /// Records whether each post may be indexed under `policy`, replacing every
  /// verdict made under an earlier policy.
  private func recordVerdicts(for posts: [AppBskyFeedDefs.PostView], policy: ModerationPolicy) {
    if verdictPolicy != policy {
      postVerdicts.removeAll()
      verdictOrder.removeAll()
      verdictPolicy = policy
    }
    for post in posts {
      let id = post.uri.uriString()
      if postVerdicts.updateValue(SpotlightDonationModeration.allowsPost(post, policy: policy), forKey: id) == nil {
        verdictOrder.append(id)
        if verdictOrder.count > capacity {
          postVerdicts.removeValue(forKey: verdictOrder.removeFirst())
        }
      }
    }
  }

  /// The active account's moderation policy once its preferences are confirmed
  /// with the server; `nil` means nothing may be indexed yet.
  private func activeModerationPolicy() async -> ModerationPolicy? {
    await MainActor.run {
      guard let appState = AppStateManager.shared.lifecycle.appState else { return nil }
      let policy = appState.moderationPolicy
      guard policy.isConfirmed, policy.accountDID == appState.userDID else { return nil }
      return policy
    }
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

  /// Seeds the resolution store with profiles the account opened and indexes
  /// them in Spotlight, both only for profiles moderation allows (no list
  /// filter, no profile or avatar blur) under the account's confirmed policy.
  func donate(profiles: [AppBskyActorDefs.ProfileViewDetailed]) async {
    guard let policy = await activeModerationPolicy() else { return }
    let indexable = SpotlightDonationModeration.storableProfiles(profiles, policy: policy)
    // Also seed the deadline-safe resolution store (see donate(posts:)).
    await ProfileEntityStore.shared.store(entities: indexable.map { ProfileEntity(from: $0) })
    index(indexable.map { ProfileEntity(from: $0) })
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


// MARK: - Moderation

/// Which posts and profiles may enter the Spotlight index under the account's
/// moderation policy. An index entry shows the text and the avatar with no
/// warning or reveal control, so anything moderation filters or blurs in a
/// list, its media, or the avatar it carries stays out.
enum SpotlightDonationModeration {
  /// Whether a feed post may seed the on-screen resolution store: feeds drop
  /// posts whose list context filters them, so those are never on screen.
  static func isListed(_ post: AppBskyFeedDefs.PostView, policy: ModerationPolicy) -> Bool {
    !policy.decide(post: post).ui(.contentList).filter
  }

  /// Whether a post may be indexed: no list filter or blur, no media blur, and
  /// no blur on the author avatar the entry shows.
  static func allowsPost(_ post: AppBskyFeedDefs.PostView, policy: ModerationPolicy) -> Bool {
    let decision = policy.decide(post: post)
    let list = decision.ui(.contentList)
    return !list.filter && !list.blur && !decision.ui(.contentMedia).blur && !decision.ui(.avatar).blur
  }

  /// Whether a profile may be indexed: no profile-list filter and no blur on
  /// the profile view or the avatar.
  static func allowsProfile(_ profile: some ModerationAccountSubject, policy: ModerationPolicy) -> Bool {
    let decision = policy.decide(profile: profile)
    return !decision.ui(.profileList).filter && !decision.ui(.profileView).blur && !decision.ui(.avatar).blur
  }

  /// The posts a deliberate engagement (opening a thread) may seed into the
  /// persisted resolution store and index: the `allowsPost` rule, applied
  /// before anything is written.
  static func storablePosts(_ posts: [AppBskyFeedDefs.PostView], policy: ModerationPolicy) -> [AppBskyFeedDefs.PostView] {
    posts.filter { allowsPost($0, policy: policy) }
  }

  /// The profiles an opened profile may seed into the persisted resolution
  /// store and index: the `allowsProfile` rule, applied before anything is written.
  static func storableProfiles<Profile: ModerationAccountSubject>(
    _ profiles: [Profile], policy: ModerationPolicy
  ) -> [Profile] {
    profiles.filter { allowsProfile($0, policy: policy) }
  }

  /// The feed posts to index: those the viewer authored, liked, reposted or
  /// bookmarked, and that moderation allows.
  static func indexableFeedPosts(
    _ posts: [AppBskyFeedDefs.PostView], viewerDID: String?, policy: ModerationPolicy
  ) -> [AppBskyFeedDefs.PostView] {
    posts.filter { post in
      let engaged = post.author.did.didString() == viewerDID
        || post.viewer?.like != nil
        || post.viewer?.repost != nil
        || post.viewer?.bookmarked == true
      return engaged && allowsPost(post, policy: policy)
    }
  }
}
