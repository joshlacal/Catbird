import Testing
import Foundation
@testable import Catbird
@testable import Petrel

@Suite("Feed Manager Tests")
struct FeedManagerActualTests {
    
    // MARK: - Test Setup
    
    private func createMockATProtoClient() async -> ATProtoClient {
        let oauthConfig = OAuthConfig(
            clientId: "test-client-id",
            redirectUri: "test://callback",
            scope: "atproto transition:generic"
        )
        return ATProtoClient(oauthConfig: oauthConfig, namespace: "test")
    }
    
    private func createTestFeedManager(fetchType: FetchType = .timeline) async -> FeedManager {
        let client = await createMockATProtoClient()
        return FeedManager(client: client, fetchType: fetchType)
    }
    
    // MARK: - Initialization Tests
    
    @Test("Feed manager initializes with correct fetch type")
    func testFeedManagerInitialization() async throws {
        let timelineFeedManager = await createTestFeedManager(fetchType: .timeline)
        #expect(timelineFeedManager.fetchType == .timeline, "Should initialize with timeline fetch type")
        
        let authorFeedManager = await createTestFeedManager(fetchType: .author("did:plc:test"))
        #expect(authorFeedManager.fetchType == .author("did:plc:test"), "Should initialize with author fetch type")
    }
    
    @Test("Feed manager can be created without client")
    func testFeedManagerWithoutClient() {
        let feedManager = FeedManager(client: nil, fetchType: .timeline)
        #expect(feedManager.fetchType == .timeline, "Should initialize with correct fetch type even without client")
    }
    
    // MARK: - FetchType Tests
    
    @Test("FetchType provides correct identifiers")
    func testFetchTypeIdentifiers() throws {
        #expect(FetchType.timeline.identifier == "timeline", "Timeline should have correct identifier")
        
        let testDID = "did:plc:test123"
        #expect(FetchType.author(testDID).identifier == "author:\(testDID)", "Author feed should have correct identifier")
        #expect(FetchType.likes(testDID).identifier == "likes:\(testDID)", "Likes feed should have correct identifier")
        
        let testURI = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.feed.generator/test-feed")
        #expect(FetchType.feed(testURI).identifier == "feed:\(testURI.uriString())", "Custom feed should have correct identifier")
        
        let listURI = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.graph.list/test-list")
        #expect(FetchType.list(listURI).identifier == "list:\(listURI.uriString())", "List feed should have correct identifier")
    }
    
    @Test("FetchType provides correct display names")
    func testFetchTypeDisplayNames() throws {
        #expect(FetchType.timeline.displayName == "Timeline", "Timeline should have correct display name")
        
        let testDID = "did:plc:test123"
        #expect(FetchType.author(testDID).displayName == "Posts by \(testDID)", "Author feed should have correct display name")
        #expect(FetchType.likes(testDID).displayName == "Likes by \(testDID)", "Likes feed should have correct display name")
        
        let testURI = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.feed.generator/test-feed")
        #expect(FetchType.feed(testURI).displayName.contains("Custom Feed"), "Custom feed should have correct display name")
        
        let listURI = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.graph.list/test-list")
        #expect(FetchType.list(listURI).displayName.contains("List"), "List feed should have correct display name")
    }
    
    @Test("FetchType scroll position preservation settings")
    func testFetchTypeScrollPreservation() throws {
        #expect(FetchType.timeline.shouldPreserveScrollPosition == true, "Timeline should preserve scroll position")
        
        let testDID = "did:plc:test123"
        #expect(FetchType.author(testDID).shouldPreserveScrollPosition == true, "Author feed should preserve scroll position")
        #expect(FetchType.likes(testDID).shouldPreserveScrollPosition == true, "Likes feed should preserve scroll position")
        
        let testURI = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.feed.generator/test-feed")
        #expect(FetchType.feed(testURI).shouldPreserveScrollPosition == true, "Custom feed should preserve scroll position")
        
        let listURI = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.graph.list/test-list")
        #expect(FetchType.list(listURI).shouldPreserveScrollPosition == true, "List feed should preserve scroll position")
    }
    
    @Test("FetchType chronological ordering settings")
    func testFetchTypeChronologicalOrdering() throws {
        #expect(FetchType.timeline.isChronological == true, "Timeline should be chronological")
        
        let testDID = "did:plc:test123"
        #expect(FetchType.author(testDID).isChronological == true, "Author feed should be chronological")
        #expect(FetchType.likes(testDID).isChronological == false, "Likes feed should not be chronological")
        
        let testURI = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.feed.generator/test-feed")
        #expect(FetchType.feed(testURI).isChronological == false, "Custom feed should not be chronological")
        
        let listURI = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.graph.list/test-list")
        #expect(FetchType.list(listURI).isChronological == false, "List feed should not be chronological")
    }
    
    @Test("FetchType equality works correctly")
    func testFetchTypeEquality() throws {
        // Test same types are equal
        #expect(FetchType.timeline == FetchType.timeline, "Same timeline types should be equal")
        
        let testDID = "did:plc:test123"
        #expect(FetchType.author(testDID) == FetchType.author(testDID), "Same author types should be equal")
        
        // Test different DIDs are not equal
        #expect(FetchType.author("did:plc:test1") != FetchType.author("did:plc:test2"), "Different author types should not be equal")
        
        // Test different types are not equal
        #expect(FetchType.timeline != FetchType.author(testDID), "Different fetch types should not be equal")
        
        // Test URI-based types
        let testURI1 = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.feed.generator/feed1")
        let testURI2 = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.feed.generator/feed2")
        
        #expect(FetchType.feed(testURI1) == FetchType.feed(testURI1), "Same feed URIs should be equal")
        #expect(FetchType.feed(testURI1) != FetchType.feed(testURI2), "Different feed URIs should not be equal")
    }
    
    @Test("FetchType is Hashable")
    func testFetchTypeHashable() throws {
        var fetchTypeSet: Set<FetchType> = []
        
        fetchTypeSet.insert(.timeline)
        fetchTypeSet.insert(.author("did:plc:test"))
        fetchTypeSet.insert(.likes("did:plc:test"))
        
        #expect(fetchTypeSet.count == 3, "Should store 3 different fetch types")
        
        // Insert duplicate
        fetchTypeSet.insert(.timeline)
        #expect(fetchTypeSet.count == 3, "Should not add duplicate timeline")
        
        // Test contains
        #expect(fetchTypeSet.contains(.timeline), "Should contain timeline")
        #expect(fetchTypeSet.contains(.author("did:plc:test")), "Should contain author feed")
        #expect(!fetchTypeSet.contains(.author("did:plc:other")), "Should not contain different author")
    }
    
    @Test("FetchType CustomStringConvertible provides descriptions")
    func testFetchTypeDescriptions() throws {
        #expect(FetchType.timeline.description == "Timeline", "Timeline should have correct description")
        
        let testDID = "did:plc:test123"
        #expect(FetchType.author(testDID).description.contains("Author Feed"), "Author feed should contain 'Author Feed' in description")
        #expect(FetchType.likes(testDID).description.contains("Likes Feed"), "Likes feed should contain 'Likes Feed' in description")
        
        let testURI = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.feed.generator/test-feed")
        #expect(FetchType.feed(testURI).description.contains("Custom Feed"), "Custom feed should contain 'Custom Feed' in description")
        
        let listURI = try ATProtocolURI(uriString: "at://did:plc:test/app.bsky.graph.list/test-list")
        #expect(FetchType.list(listURI).description.contains("List Feed"), "List feed should contain 'List Feed' in description")
    }
    
    // MARK: - Error Handling Tests
    
    @Test("Feed manager handles client not available error")
    func testClientNotAvailableError() async throws {
        let feedManager = FeedManager(client: nil, fetchType: .timeline)
        
        do {
            _ = try await feedManager.fetchFeed(fetchType: .timeline, cursor: nil)
            #expect(false, "Should throw error when client is not available")
        } catch {
            #expect(error is FeedError, "Should throw FeedError")
            if let feedError = error as? FeedError {
                #expect(feedError == .clientNotAvailable, "Should throw clientNotAvailable error")
            }
        }
    }
    
    // MARK: - Fetch Type Validation Tests
    
    @Test("Feed manager can switch fetch types")
    func testFetchTypeSwitching() async throws {
        let feedManager = await createTestFeedManager(fetchType: .timeline)
        
        #expect(feedManager.fetchType == .timeline, "Should start with timeline")
        
        feedManager.fetchType = .author("did:plc:test")
        #expect(feedManager.fetchType == .author("did:plc:test"), "Should switch to author feed")
        
        feedManager.fetchType = .likes("did:plc:test")
        #expect(feedManager.fetchType == .likes("did:plc:test"), "Should switch to likes feed")
    }
    
    // MARK: - Memory Management Tests
    
    @Test("Feed manager memory management")
    func testFeedManagerMemoryManagement() async throws {
        var feedManager: FeedManager? = await createTestFeedManager()
        
        weak var weakFeedManager = feedManager
        #expect(weakFeedManager != nil, "Should have weak reference")
        
        feedManager = nil
        
        // Allow cleanup
        await Task.yield()
        
        #expect(weakFeedManager == nil, "Should deallocate when no strong references")
    }
    
    // MARK: - Thread Safety Tests
    
    @Test("Feed manager is thread-safe for property access")
    func testThreadSafety() async throws {
        let feedManager = await createTestFeedManager()
        
        // Test concurrent access to fetchType property
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { @Sendable in
                    _ = feedManager.fetchType
                    feedManager.fetchType = .author("did:plc:test\(i)")
                }
            }
        }
        
        // Should complete without crashing
        #expect(feedManager.fetchType != nil, "Should maintain valid fetch type after concurrent access")
    }
    
    // MARK: - Performance Tests
    
    @Test("FetchType operations are performant")
    func testFetchTypePerformance() throws {
        let fetchTypes: [FetchType] = [
            .timeline,
            .author("did:plc:test1"),
            .author("did:plc:test2"),
            .likes("did:plc:test1"),
            .likes("did:plc:test2")
        ]
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Perform operations on fetch types
        for _ in 0..<1000 {
            for fetchType in fetchTypes {
                _ = fetchType.identifier
                _ = fetchType.displayName
                _ = fetchType.description
                _ = fetchType.shouldPreserveScrollPosition
                _ = fetchType.isChronological
            }
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime
        
        #expect(duration < 1.0, "FetchType operations should complete quickly")
    }
}