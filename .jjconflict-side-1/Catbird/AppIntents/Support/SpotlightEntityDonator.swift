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

  private init() {}

  func donate(posts: [AppBskyFeedDefs.PostView]) {
    // Also seed the deadline-safe resolution store — Siri's onscreen-context
    // requests must resolve these without a network fetch.
    Task {
      await PostEntityStore.shared.store(views: posts)
    }
    index(posts.map { PostEntity(from: $0) })
  }

  func donate(profiles: [AppBskyActorDefs.ProfileViewDetailed]) {
    let entities = profiles.map { ProfileEntity(from: $0) }
    // Also seed the deadline-safe resolution store (see donate(posts:)).
    Task {
      await ProfileEntityStore.shared.store(entities: entities)
    }
    index(entities)
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

