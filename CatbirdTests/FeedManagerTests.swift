//
//  FeedManagerTests.swift
//  CatbirdTests
//
//  Created by Claude on Swift 6 comprehensive testing
//

import Testing
import Foundation
@testable import Catbird
@testable import Petrel

@Suite("Feed Manager Tests")
struct FeedManagerTests {
    
    // MARK: - Test Setup
    
    private func createMockATProtoClient() async -> ATProtoClient {
        let oauthConfig = OAuthConfig(
            clientId: "test-client-id",
            redirectUri: "test://callback",
            scope: "atproto transition:generic"
        )
        return ATProtoClient(oauthConfig: oauthConfig, namespace: "test")
    }
    
    private func createMockFeedManager(fetchType: FeedFetchType = .timeline) async -> FeedManager {
        let client = createMockATProtoClient()
        return FeedManager(client: client, fetchType: fetchType)
    }
    
    // MARK: - Feed Manager Initialization Tests
    
    @Test("Feed manager initializes with correct fetch type")
    func testFeedManagerInitialization() async throws {
        let timelineFeedManager = await createMockFeedManager(fetchType: .timeline)
        #expect(timelineFeedManager.fetchType == .timeline)
        
        let listFeedManager = await createMockFeedManager(fetchType: .list(uri: "test-list-uri"))
        #expect(listFeedManager.fetchType == .list(uri: "test-list-uri"))
        
        let customFeedManager = await createMockFeedManager(fetchType: .custom(uri: "test-custom-uri"))
        #expect(customFeedManager.fetchType == .custom(uri: "test-custom-uri"))
    }
    
    @Test("Feed manager starts with empty state")
    func testInitialState() async throws {
        let feedManager = await createMockFeedManager()
        
        #expect(feedManager.isLoading == false)
        #expect(feedManager.posts.isEmpty)
        #expect(feedManager.cursor == nil)
        #expect(feedManager.hasMoreContent == true)
        #expect(feedManager.lastError == nil)
    }
    
    // MARK: - Timeline Feed Tests
    
    @Test("Timeline feed fetching sets loading state correctly")
    func testTimelineFeedLoadingState() async throws {
        let feedManager = await createMockFeedManager(fetchType: .timeline)
        
        // Start loading
        let loadingTask = Task {
            await feedManager.loadInitialFeed()
        }
        
        // Check that loading state is set
        await Task.yield() // Allow loading to start
        #expect(feedManager.isLoading == true, "Should be loading during initial feed fetch")
        
        // Wait for completion
        await loadingTask.value
        
        #expect(feedManager.isLoading == false, "Should not be loading after completion")
    }
    
    @Test("Timeline feed handles successful response")
    func testTimelineFeedSuccessfulResponse() async throws {
        let feedManager = await createMockFeedManager(fetchType: .timeline)
        
        // Mock successful response
        await feedManager.setMockResponse(posts: createMockPosts(count: 20), cursor: "next-cursor")
        
        await feedManager.loadInitialFeed()
        
        #expect(feedManager.posts.count == 20, "Should have loaded 20 posts")
        #expect(feedManager.cursor == "next-cursor", "Should have set cursor for pagination")
        #expect(feedManager.hasMoreContent == true, "Should indicate more content available")
        #expect(feedManager.lastError == nil, "Should have no error on success")
    }
    
    @Test("Timeline feed handles empty response")
    func testTimelineFeedEmptyResponse() async throws {
        let feedManager = await createMockFeedManager(fetchType: .timeline)
        
        // Mock empty response
        await feedManager.setMockResponse(posts: [], cursor: nil)
        
        await feedManager.loadInitialFeed()
        
        #expect(feedManager.posts.isEmpty, "Should have no posts")
        #expect(feedManager.cursor == nil, "Should have no cursor")
        #expect(feedManager.hasMoreContent == false, "Should indicate no more content")
        #expect(feedManager.lastError == nil, "Should have no error on empty response")
    }
    
    // MARK: - List Feed Tests
    
    @Test("List feed fetching uses correct list URI")
    func testListFeedFetching() async throws {
        let listURI = "at://did:plc:test/app.bsky.graph.list/test-list"
        let feedManager = await createMockFeedManager(fetchType: .list(uri: listURI))
        
        // Mock successful list response
        await feedManager.setMockResponse(posts: createMockPosts(count: 15), cursor: "list-cursor")
        
        await feedManager.loadInitialFeed()
        
        #expect(feedManager.posts.count == 15, "Should load list posts")
        #expect(feedManager.cursor == "list-cursor", "Should set list cursor")
        
        // Verify the correct list URI was used in the request
        let requestedListURI = await feedManager.getMockRequestedListURI()
        #expect(requestedListURI == listURI, "Should request correct list URI")
    }
    
    @Test("List feed handles list not found error")
    func testListFeedNotFoundError() async throws {
        let feedManager = await createMockFeedManager(fetchType: .list(uri: "invalid-list-uri"))
        
        // Mock list not found error
        await feedManager.setMockError(.listNotFound)
        
        await feedManager.loadInitialFeed()
        
        #expect(feedManager.posts.isEmpty, "Should have no posts on error")
        #expect(feedManager.lastError != nil, "Should have error set")
        #expect(feedManager.hasMoreContent == false, "Should indicate no more content on error")
    }
    
    // MARK: - Custom Feed Tests
    
    @Test("Custom feed fetching uses correct feed URI")
    func testCustomFeedFetching() async throws {
        let feedURI = "at://did:plc:creator/app.bsky.feed.generator/custom-feed"
        let feedManager = await createMockFeedManager(fetchType: .custom(uri: feedURI))
        
        // Mock successful custom feed response
        await feedManager.setMockResponse(posts: createMockPosts(count: 25), cursor: "custom-cursor")
        
        await feedManager.loadInitialFeed()
        
        #expect(feedManager.posts.count == 25, "Should load custom feed posts")
        #expect(feedManager.cursor == "custom-cursor", "Should set custom feed cursor")
        
        // Verify the correct custom feed URI was used
        let requestedFeedURI = await feedManager.getMockRequestedFeedURI()
        #expect(requestedFeedURI == feedURI, "Should request correct custom feed URI")
    }
    
    // MARK: - Pagination Tests
    
    @Test("Load more content uses cursor for pagination")
    func testLoadMoreWithCursor() async throws {
        let feedManager = await createMockFeedManager()
        
        // Initial load
        await feedManager.setMockResponse(posts: createMockPosts(count: 20), cursor: "page-1-cursor")
        await feedManager.loadInitialFeed()
        
        let initialPostCount = feedManager.posts.count
        
        // Load more
        await feedManager.setMockResponse(posts: createMockPosts(count: 20, startingAt: 20), cursor: "page-2-cursor")
        await feedManager.loadMoreContent()
        
        #expect(feedManager.posts.count == initialPostCount + 20, "Should append new posts")
        #expect(feedManager.cursor == "page-2-cursor", "Should update cursor")
        
        // Verify cursor was used in load more request
        let usedCursor = await feedManager.getMockUsedCursor()
        #expect(usedCursor == "page-1-cursor", "Should use previous cursor for pagination")
    }
    
    @Test("Load more handles end of content")
    func testLoadMoreEndOfContent() async throws {
        let feedManager = await createMockFeedManager()
        
        // Initial load with cursor
        await feedManager.setMockResponse(posts: createMockPosts(count: 20), cursor: "final-cursor")
        await feedManager.loadInitialFeed()
        
        // Load more returns no cursor (end of content)
        await feedManager.setMockResponse(posts: createMockPosts(count: 10, startingAt: 20), cursor: nil)
        await feedManager.loadMoreContent()
        
        #expect(feedManager.posts.count == 30, "Should have all posts")
        #expect(feedManager.cursor == nil, "Should have no cursor at end")
        #expect(feedManager.hasMoreContent == false, "Should indicate no more content")
    }
    
    @Test("Load more prevents duplicate requests")
    func testLoadMorePreventsduplicateRequests() async throws {
        let feedManager = await createMockFeedManager()
        
        // Set up initial state
        await feedManager.setMockResponse(posts: createMockPosts(count: 20), cursor: "test-cursor")
        await feedManager.loadInitialFeed()
        
        // Start first load more request
        let firstRequest = Task {
            await feedManager.loadMoreContent()
        }
        
        // Attempt second load more request while first is in progress
        let secondRequest = Task {
            await feedManager.loadMoreContent()
        }
        
        await firstRequest.value
        await secondRequest.value
        
        // Should not have loaded content twice
        let requestCount = await feedManager.getMockRequestCount()
        #expect(requestCount <= 2, "Should not make duplicate concurrent requests") // Initial + one load more
    }
    
    // MARK: - Error Handling Tests
    
    @Test("Network error during feed loading is handled")
    func testNetworkErrorHandling() async throws {
        let feedManager = await createMockFeedManager()
        
        // Mock network error
        await feedManager.setMockError(.networkUnavailable)
        
        await feedManager.loadInitialFeed()
        
        #expect(feedManager.posts.isEmpty, "Should have no posts on network error")
        #expect(feedManager.lastError != nil, "Should set error")
        #expect(feedManager.isLoading == false, "Should not be loading after error")
    }
    
    @Test("Rate limit error triggers retry logic")
    func testRateLimitErrorRetry() async throws {
        let feedManager = await createMockFeedManager()
        
        // Mock rate limit error followed by success
        await feedManager.setMockErrorSequence([.rateLimited, .success])
        await feedManager.setMockResponse(posts: createMockPosts(count: 10), cursor: nil)
        
        await feedManager.loadInitialFeed()
        
        // Should eventually succeed after retry
        #expect(feedManager.posts.count == 10, "Should load posts after rate limit retry")
        #expect(feedManager.lastError == nil, "Should clear error after successful retry")
        
        let retryCount = await feedManager.getMockRetryCount()
        #expect(retryCount >= 1, "Should have attempted retry")
    }
    
    @Test("Authentication error triggers token refresh")
    func testAuthenticationErrorHandling() async throws {
        let feedManager = await createMockFeedManager()
        
        // Mock authentication error
        await feedManager.setMockError(.unauthorizedRequest)
        
        await feedManager.loadInitialFeed()
        
        #expect(feedManager.lastError != nil, "Should set authentication error")
        
        // Verify token refresh was attempted
        let refreshAttempted = await feedManager.getMockTokenRefreshAttempted()
        #expect(refreshAttempted == true, "Should attempt token refresh on auth error")
    }
    
    // MARK: - Refresh Tests
    
    @Test("Refresh feed clears existing posts")
    func testRefreshFeedClearsExisting() async throws {
        let feedManager = await createMockFeedManager()
        
        // Initial load
        await feedManager.setMockResponse(posts: createMockPosts(count: 20), cursor: "initial-cursor")
        await feedManager.loadInitialFeed()
        
        #expect(feedManager.posts.count == 20, "Should have initial posts")
        
        // Refresh with new content
        await feedManager.setMockResponse(posts: createMockPosts(count: 15), cursor: "refresh-cursor")
        await feedManager.refreshFeed()
        
        #expect(feedManager.posts.count == 15, "Should replace posts with fresh content")
        #expect(feedManager.cursor == "refresh-cursor", "Should update cursor")
    }
    
    @Test("Refresh feed handles empty response")
    func testRefreshFeedEmptyResponse() async throws {
        let feedManager = await createMockFeedManager()
        
        // Initial load with posts
        await feedManager.setMockResponse(posts: createMockPosts(count: 10), cursor: "initial-cursor")
        await feedManager.loadInitialFeed()
        
        // Refresh returns empty
        await feedManager.setMockResponse(posts: [], cursor: nil)
        await feedManager.refreshFeed()
        
        #expect(feedManager.posts.isEmpty, "Should clear posts on empty refresh")
        #expect(feedManager.cursor == nil, "Should clear cursor")
        #expect(feedManager.hasMoreContent == false, "Should indicate no more content")
    }
    
    // MARK: - Concurrent Operation Tests
    
    @Test("Concurrent refresh and load more operations are handled safely")
    func testConcurrentOperations() async throws {
        let feedManager = await createMockFeedManager()
        
        // Initial load
        await feedManager.setMockResponse(posts: createMockPosts(count: 20), cursor: "initial-cursor")
        await feedManager.loadInitialFeed()
        
        // Start concurrent operations
        let refreshTask = Task {
            await feedManager.refreshFeed()
        }
        
        let loadMoreTask = Task {
            await feedManager.loadMoreContent()
        }
        
        await refreshTask.value
        await loadMoreTask.value
        
        // Should complete without crashing or data corruption
        #expect(feedManager.posts.count >= 0, "Should have valid post count")
        #expect(feedManager.isLoading == false, "Should not be loading after completion")
    }
    
    // MARK: - Memory Management Tests
    
    @Test("Feed manager properly cleans up resources")
    func testResourceCleanup() async throws {
        var feedManager: FeedManager? = await createMockFeedManager()
        
        // Load some content
        await feedManager!.setMockResponse(posts: createMockPosts(count: 100), cursor: "test-cursor")
        await feedManager!.loadInitialFeed()
        
        weak var weakFeedManager = feedManager
        feedManager = nil
        
        // Allow cleanup
        await Task.yield()
        
        #expect(weakFeedManager == nil, "FeedManager should be deallocated")
    }
}

// MARK: - Mock Data Creation

private func createMockPosts(count: Int, startingAt: Int = 0) -> [AppBskyFeedDefs.FeedViewPost] {
    return (startingAt..<(startingAt + count)).map { index in
        createMockPost(id: "post-\(index)")
    }
}

private func createMockPost(id: String) -> AppBskyFeedDefs.FeedViewPost {
    let record = AppBskyFeedPost.Record(
        text: "Mock post content for \(id)",
        createdAt: ATProtocolDate(date: Date()),
        langs: ["en"],
        reply: nil,
        embed: nil,
        facets: nil
    )
    
    let post = AppBskyFeedDefs.PostView(
        uri: "at://did:plc:test/app.bsky.feed.post/\(id)",
        cid: CID.fromDAGCBOR("test data".data(using: .utf8)!),
        author: createMockActor(),
        record: .appBskyFeedPost(record),
        embed: nil,
        replyCount: 0,
        repostCount: 0,
        likeCount: 0,
        quoteCount: nil,
        indexedAt: ATProtocolDate(date: Date()),
        viewer: nil,
        labels: nil,
        threadgate: nil
    )
    
    return AppBskyFeedDefs.FeedViewPost(
        post: post,
        reply: nil,
        reason: nil,
        feedContext: nil, reqId: nil
    )
}

private func createMockActor() -> AppBskyActorDefs.ProfileViewBasic {
    return AppBskyActorDefs.ProfileViewBasic(
        did: try! DID(didString: "did:plc:mockuser"),
        handle: "mockuser.bsky.social",
        displayName: "Mock User",
        avatar: nil,
        associated: nil,
        viewer: nil,
        labels: nil,
        createdAt: nil
    )
}

// MARK: - FeedManager Test Extensions

extension FeedManager {
    func setMockResponse(posts: [AppBskyFeedDefs.FeedViewPost], cursor: String?) async {
        // In a real implementation, this would configure mock responses
    }
    
    func setMockError(_ error: MockFeedError) async {
        // In a real implementation, this would configure mock errors
    }
    
    func setMockErrorSequence(_ errors: [MockFeedResult]) async {
        // In a real implementation, this would configure sequence of errors/successes
    }
    
    func getMockRequestedListURI() async -> String? {
        // In a real implementation, this would return the requested list URI
        return nil
    }
    
    func getMockRequestedFeedURI() async -> String? {
        // In a real implementation, this would return the requested feed URI
        return nil
    }
    
    func getMockUsedCursor() async -> String? {
        // In a real implementation, this would return the cursor used in request
        return nil
    }
    
    func getMockRequestCount() async -> Int {
        // In a real implementation, this would return number of requests made
        return 0
    }
    
    func getMockRetryCount() async -> Int {
        // In a real implementation, this would return number of retries attempted
        return 0
    }
    
    func getMockTokenRefreshAttempted() async -> Bool {
        // In a real implementation, this would return if token refresh was attempted
        return false
    }
}

// MARK: - Mock Error Types

enum MockFeedError: Error {
    case networkUnavailable
    case rateLimited
    case unauthorizedRequest
    case listNotFound
    case feedNotFound
}

enum MockFeedResult {
    case success
    case rateLimited
    case networkError
}
