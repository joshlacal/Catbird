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
    func prefetchFeed(_ fetchType: FetchType) {
        guard let client = atProtoClient else { return }
        
        Task {
            do {
                let feedManager = FeedManager(client: client, fetchType: fetchType)
                let (posts, cursor) = try await feedManager.fetchFeed(fetchType: fetchType, cursor: nil)
                storePrefetchedFeed(posts, cursor: cursor, for: fetchType)
            } catch {
                logger.debug("Error prefetching feed: \(error)")
            }
        }
    }
    
    /// Sets the tabTappedAgain property to the specified tab index
    /// This triggers a scroll to top in the appropriate tab
    /// - Parameter tabIndex: The index of the tab that was tapped again
    func triggerScrollToTop(for tabIndex: Int) {
        tabTappedAgain = tabIndex
    }
}
