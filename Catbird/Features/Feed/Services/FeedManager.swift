import Foundation
import Petrel

/// Manager class responsible for fetching feed data based on specified fetch types
final class FeedManager {
    // MARK: - Properties
    
    private let client: ATProtoClient?
    var fetchType: FetchType
    
    // MARK: - Initialization
    
    init(client: ATProtoClient?, fetchType: FetchType = .timeline) {
        self.client = client
        self.fetchType = fetchType
    }
    
    // MARK: - Feed Fetching
    
    func fetchFeed(
        fetchType: FetchType,
        cursor: String?
    ) async throws -> ([AppBskyFeedDefs.FeedViewPost], String?) {
        guard let client = client else {
            throw FeedError.clientNotAvailable
        }
        
        let feedName = fetchType.displayName
        await MetricKitSignposts.beginFeedLoad(feedName: feedName)
        let perfSignpostId = PerformanceSignposts.beginFeedLoad(feedName: feedName)
        
        do {
            let result: ([AppBskyFeedDefs.FeedViewPost], String?)
            switch fetchType {
            case .timeline:
                result = try await fetchTimeline(client: client, cursor: cursor)
            case .list(let listUri):
                result = try await fetchListFeed(client: client, listUri: listUri, cursor: cursor)
            case .feed(let generatorUri):
                result = try await fetchCustomFeed(client: client, generatorUri: generatorUri, cursor: cursor)
            case .author(let did):
                result = try await fetchAuthorFeed(client: client, did: did, cursor: cursor)
            case .likes(let did):
                result = try await fetchAuthorLikes(client: client, did: did, cursor: cursor)
            }
            await MetricKitSignposts.endFeedLoad(feedName: feedName, postCount: result.0.count, success: true)
            PerformanceSignposts.endFeedLoad(id: perfSignpostId, postCount: result.0.count, success: true)
            return result
        } catch {
            await MetricKitSignposts.endFeedLoad(feedName: feedName, success: false)
            PerformanceSignposts.endFeedLoad(id: perfSignpostId, postCount: 0, success: false)
            throw error
        }
    }
    
    // MARK: - Specific Feed Fetchers
    
    private func fetchTimeline(
        client: ATProtoClient,
        cursor: String?
    ) async throws -> ([AppBskyFeedDefs.FeedViewPost], String?) {
        let params = AppBskyFeedGetTimeline.Parameters(
            algorithm: nil,
            limit: 50,
            cursor: cursor
        )
        
        let (responseCode, response) = try await client.app.bsky.feed.getTimeline(input: params)
        
        guard responseCode == 200, let response = response else {
            throw FeedError.requestFailed(statusCode: responseCode)
        }
        
        return (response.feed, response.cursor)
    }
        
    private func fetchListFeed(
        client: ATProtoClient,
        listUri: ATProtocolURI,
        cursor: String?
    ) async throws -> ([AppBskyFeedDefs.FeedViewPost], String?) {
        let params = AppBskyFeedGetListFeed.Parameters(
            list: listUri,
            limit: 50,
            cursor: cursor
        )
        
        let (responseCode, response) = try await client.app.bsky.feed.getListFeed(input: params)
        
        guard responseCode == 200, let response = response else {
            throw FeedError.requestFailed(statusCode: responseCode)
        }
        
        return (response.feed, response.cursor)
    }
    
    private func fetchCustomFeed(
        client: ATProtoClient,
        generatorUri: ATProtocolURI,
        cursor: String?
    ) async throws -> ([AppBskyFeedDefs.FeedViewPost], String?) {
        let params = AppBskyFeedGetFeed.Parameters(
            feed: generatorUri,
            limit: 50,
            cursor: cursor
        )
        
        let (responseCode, response) = try await client.app.bsky.feed.getFeed(input: params)
        
        guard responseCode == 200, let response = response else {
            throw FeedError.requestFailed(statusCode: responseCode)
        }
        
        return (response.feed, response.cursor)
    }
    
    private func fetchAuthorFeed(
        client: ATProtoClient,
        did: String,
        cursor: String?
    ) async throws -> ([AppBskyFeedDefs.FeedViewPost], String?) {
        let params = AppBskyFeedGetAuthorFeed.Parameters(
            actor: try ATIdentifier(string: did),
            limit: 50,
            cursor: cursor
        )
        
        let (responseCode, response) = try await client.app.bsky.feed.getAuthorFeed(input: params)
        
        guard responseCode == 200, let response = response else {
            throw FeedError.requestFailed(statusCode: responseCode)
        }
        
        return (response.feed, response.cursor)
    }
    
    private func fetchAuthorLikes(
        client: ATProtoClient,
        did: String,
        cursor: String?
    ) async throws -> ([AppBskyFeedDefs.FeedViewPost], String?) {
        let params = AppBskyFeedGetActorLikes.Parameters(
            actor: try ATIdentifier(string: did),
            limit: 50,
            cursor: cursor
        )
        
        let (responseCode, response) = try await client.app.bsky.feed.getActorLikes(input: params)
        
        guard responseCode == 200, let response = response else {
            throw FeedError.requestFailed(statusCode: responseCode)
        }
        
        return (response.feed, response.cursor)
    }
    
    // MARK: - Update Fetch Type
    
    func updateFetchType(_ newFetchType: FetchType) {
        self.fetchType = newFetchType
    }
}

// MARK: - Error Types

enum FeedError: LocalizedError {
    case clientNotAvailable
    case requestFailed(statusCode: Int)
    
    var errorDescription: String? {
        switch self {
        case .clientNotAvailable:
            return "ATProto client is not available"
        case .requestFailed(let statusCode):
            return "Feed request failed with status code: \(statusCode)"
        }
    }
}
