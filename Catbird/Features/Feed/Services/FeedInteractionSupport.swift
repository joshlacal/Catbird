//
//  FeedInteractionSupport.swift
//  Catbird
//
//  Decides which feeds accept interaction feedback ("Show More/Less Like This",
//  seen/like/repost/reply/quote events) and where that feedback is sent.
//

import Foundation
import Petrel
import SwiftUI

/// The custom feed a piece of interaction feedback belongs to, and the feed
/// generator service that receives it.
struct FeedInteractionTarget: Hashable, Sendable {
  let feedURI: String
  let generatorDID: String
}

/// What a feed generator declares about interaction feedback, as of `fetchedAt`.
struct FeedGeneratorInteractionInfo: Equatable, Sendable {
  let feedURI: String
  let generatorDID: String?
  let acceptsInteractions: Bool
  let fetchedAt: Date
}

enum FeedInteractionPolicy {
  /// Bluesky's own feeds take feedback without declaring `acceptsInteractions`
  /// (Discover and Video, production and staging), matching the official app.
  static let feedbackFeedURIs: Set<String> = [
    "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/whats-hot",
    "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/thevids",
    "at://did:plc:yofh3kx63drvfljkibw5zuxo/app.bsky.feed.generator/whats-hot",
    "at://did:plc:yofh3kx63drvfljkibw5zuxo/app.bsky.feed.generator/thevids"
  ]

  /// The feedback target for a feed, or nil when the feed does not accept feedback.
  /// Only custom feeds whose generator info is known qualify; timelines, lists,
  /// author feeds and feeds still loading their generator info never do.
  static func target(
    for fetchType: FetchType,
    info: FeedGeneratorInteractionInfo?
  ) -> FeedInteractionTarget? {
    guard case .feed(let uri) = fetchType, let info else { return nil }
    let feedURI = uri.uriString()
    guard info.feedURI == feedURI,
          let generatorDID = info.generatorDID, !generatorDID.isEmpty,
          feedbackFeedURIs.contains(feedURI) || info.acceptsInteractions
    else { return nil }
    return FeedInteractionTarget(feedURI: feedURI, generatorDID: generatorDID)
  }
}

/// Recently fetched feed generator info, so revisiting a feed knows at once
/// whether it accepts feedback instead of waiting for the network.
@MainActor
final class FeedGeneratorInfoCache {
  static let timeToLive: TimeInterval = 60 * 60

  private var entries: [String: FeedGeneratorInteractionInfo] = [:]
  private let now: () -> Date

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  /// Fresh info for a feed URI, or nil when it is unknown or older than the TTL.
  func info(for feedURI: String) -> FeedGeneratorInteractionInfo? {
    guard let entry = entries[feedURI] else { return nil }
    guard now().timeIntervalSince(entry.fetchedAt) < Self.timeToLive else {
      entries[feedURI] = nil
      return nil
    }
    return entry
  }

  /// Records a generator view under the feed URI it was requested with.
  @discardableResult
  func store(
    _ view: AppBskyFeedDefs.GeneratorView,
    forFeedURI feedURI: String? = nil
  ) -> FeedGeneratorInteractionInfo {
    let info = FeedGeneratorInteractionInfo(
      feedURI: feedURI ?? view.uri.uriString(),
      generatorDID: view.did.didString(),
      acceptsInteractions: view.acceptsInteractions ?? false,
      fetchedAt: now()
    )
    entries[info.feedURI] = info
    return info
  }

  func store(_ views: [AppBskyFeedDefs.GeneratorView]) {
    for view in views {
      store(view)
    }
  }
}

// MARK: - Environment

struct FeedInteractionTargetKey: EnvironmentKey {
  static let defaultValue: FeedInteractionTarget? = nil
}

extension EnvironmentValues {
  /// Set only by feed cells whose feed accepts feedback. Posts shown anywhere
  /// else (profiles, search, hashtags, threads) see nil and send nothing.
  var feedInteractionTarget: FeedInteractionTarget? {
    get { self[FeedInteractionTargetKey.self] }
    set { self[FeedInteractionTargetKey.self] = newValue }
  }
}
