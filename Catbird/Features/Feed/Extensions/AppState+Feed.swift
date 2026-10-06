//
//  AppState+Feed.swift
//  Catbird
//
//  Created by Josh LaCalamito on 1/31/25.
//

import Foundation
import Petrel

/// Feed-related extensions for AppState
extension AppState {
    /// Creates a feed manager with the specified fetch type
    /// - Parameter fetchType: The type of feed to fetch
    /// - Returns: A configured FeedManager or nil if the client is not available
    func createFeedManager(fetchType: FetchType) -> FeedManager? {
        return FeedManager(client: atProtoClient, fetchType: fetchType)
    }
    
    /// Prefetches a feed for faster initial loading
    /// - Parameter fetchType: The type of feed to prefetch
    @MainActor
    func prefetchFeed(_ fetchType: FetchType) {
        guard let client = atProtoClient else { return }
        
        startAccountTask { [self] in
            do {
                let feedManager = FeedManager(client: client, fetchType: fetchType)
                let (posts, cursor) = try await feedManager.fetchFeed(fetchType: fetchType, cursor: nil)
                await storePrefetchedFeed(posts, cursor: cursor, for: fetchType)
            } catch {
                logger.debug("Error prefetching feed: \(error)")
            }
        }
    }
}

extension SceneNavigationContext {
  /// Scroll-to-top requests belong to the tab in this window.
  func triggerScrollToTop(for tabIndex: Int) {
    tabTappedAgain = tabIndex
  }
}
