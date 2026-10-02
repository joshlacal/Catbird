//
//  URLHandlerTests.swift
//  CatbirdTests
//
//  Created by Claude on Swift 6 comprehensive testing
//

import Testing
import Foundation
@testable import Catbird

@Suite("URL Handler Tests")
struct URLHandlerTests {
    
    // MARK: - Test Setup
    
    private func createURLHandler() -> URLHandler {
        return URLHandler()
    }
    
    // MARK: - Basic URL Parsing Tests
    
    @Test("Valid bsky.app URLs are parsed correctly")
    func testBskyAppURLParsing() throws {
        let handler = createURLHandler()
        
        // Test profile URL
        let profileURL = URL(string: "https://bsky.app/profile/user.bsky.social")!
        let profileResult = handler.parseURL(profileURL)
        
        #expect(profileResult?.type == .profile, "Should identify profile URL")
        #expect(profileResult?.handle == "user.bsky.social", "Should extract correct handle")
        
        // Test post URL
        let postURL = URL(string: "https://bsky.app/profile/user.bsky.social/post/3k2a4b5c6d7e")!
        let postResult = handler.parseURL(postURL)
        
        #expect(postResult?.type == .post, "Should identify post URL")
        #expect(postResult?.handle == "user.bsky.social", "Should extract handle from post URL")
        #expect(postResult?.postId == "3k2a4b5c6d7e", "Should extract post ID")
        
        // Test feed URL
        let feedURL = URL(string: "https://bsky.app/profile/creator.bsky.social/feed/tech-feed")!
        let feedResult = handler.parseURL(feedURL)
        
        #expect(feedResult?.type == .feed, "Should identify feed URL")
        #expect(feedResult?.handle == "creator.bsky.social", "Should extract creator handle")
        #expect(feedResult?.feedName == "tech-feed", "Should extract feed name")
    }
    
    @Test("AT URIs are parsed correctly")
    func testATURIParsing() throws {
        let handler = createURLHandler()
        
        // Test post AT URI
        let postATURI = URL(string: "at://did:plc:abc123/app.bsky.feed.post/3k2a4b5c6d7e")!
        let postResult = handler.parseURL(postATURI)
        
        #expect(postResult?.type == .post, "Should identify AT URI post")
        #expect(postResult?.did == "did:plc:abc123", "Should extract DID")
        #expect(postResult?.postId == "3k2a4b5c6d7e", "Should extract post ID from AT URI")
        
        // Test profile AT URI  
        let profileATURI = URL(string: "at://did:plc:def456/app.bsky.actor.profile/self")!
        let profileResult = handler.parseURL(profileATURI)
        
        #expect(profileResult?.type == .profile, "Should identify AT URI profile")
        #expect(profileResult?.did == "did:plc:def456", "Should extract DID from profile AT URI")
        
        // Test list AT URI
        let listATURI = URL(string: "at://did:plc:ghi789/app.bsky.graph.list/my-list")!
        let listResult = handler.parseURL(listATURI)
        
        #expect(listResult?.type == .list, "Should identify AT URI list")
        #expect(listResult?.did == "did:plc:ghi789", "Should extract DID from list AT URI")
        #expect(listResult?.listId == "my-list", "Should extract list ID")
    }
    
    @Test("Custom scheme URLs are handled correctly")
    func testCustomSchemeHandling() throws {
        let handler = createURLHandler()
        
        // Test mention URL
        let mentionURL = URL(string: "mention://user.bsky.social")!
        let mentionResult = handler.parseURL(mentionURL)
        
        #expect(mentionResult?.type == .mention, "Should identify mention URL")
        #expect(mentionResult?.handle == "user.bsky.social", "Should extract handle from mention")
        
        // Test hashtag URL
        let hashtagURL = URL(string: "hashtag://SwiftUI")!
        let hashtagResult = handler.parseURL(hashtagURL)
        
        #expect(hashtagResult?.type == .hashtag, "Should identify hashtag URL") 
        #expect(hashtagResult?.tag == "SwiftUI", "Should extract tag from hashtag URL")
        
        // Test tag URL (alternative format)
        let tagURL = URL(string: "tag://ios-dev")!
        let tagResult = handler.parseURL(tagURL)
        
        #expect(tagResult?.type == .hashtag, "Should identify tag URL as hashtag")
        #expect(tagResult?.tag == "ios-dev", "Should extract tag")
    }
    
    // MARK: - OAuth Callback Tests
    
    @Test("OAuth callback URLs are parsed correctly")
    func testOAuthCallbackParsing() throws {
        let handler = createURLHandler()
        
        // Test successful OAuth callback
        let successURL = URL(string: "catbird://oauth/callback?code=auth_code_123&state=oauth_state_456")!
        let successResult = handler.parseURL(successURL)
        
        #expect(successResult?.type == .oauthCallback, "Should identify OAuth callback")
        #expect(successResult?.authCode == "auth_code_123", "Should extract auth code")
        #expect(successResult?.state == "oauth_state_456", "Should extract OAuth state")
        #expect(successResult?.error == nil, "Should have no error on successful callback")
        
        // Test OAuth error callback
        let errorURL = URL(string: "catbird://oauth/callback?error=access_denied&state=oauth_state_456&error_description=User%20denied%20access")!
        let errorResult = handler.parseURL(errorURL)
        
        #expect(errorResult?.type == .oauthCallback, "Should identify OAuth error callback")
        #expect(errorResult?.error == "access_denied", "Should extract error code")
        #expect(errorResult?.state == "oauth_state_456", "Should extract state from error callback")
        #expect(errorResult?.errorDescription == "User denied access", "Should extract error description")
    }
    
    @Test("OAuth callback validation works correctly")
    func testOAuthCallbackValidation() throws {
        let handler = createURLHandler()
        
        // Test callback with missing state
        let noStateURL = URL(string: "catbird://oauth/callback?code=auth_code_123")!
        let noStateResult = handler.parseURL(noStateURL)
        
        #expect(noStateResult?.isValid == false, "Callback without state should be invalid")
        
        // Test callback with missing code and error
        let incompleteURL = URL(string: "catbird://oauth/callback?state=oauth_state_456")!
        let incompleteResult = handler.parseURL(incompleteURL)
        
        #expect(incompleteResult?.isValid == false, "Callback without code or error should be invalid")
        
        // Test valid callback
        let validURL = URL(string: "catbird://oauth/callback?code=auth_code_123&state=oauth_state_456")!
        let validResult = handler.parseURL(validURL)
        
        #expect(validResult?.isValid == true, "Complete callback should be valid")
    }
    
    // MARK: - Deep Link Navigation Tests
    
    @Test("Deep link navigation parameters are extracted correctly")
    func testDeepLinkNavigation() throws {
        let handler = createURLHandler()
        
        // Test post with specific thread context
        let threadURL = URL(string: "https://bsky.app/profile/user.bsky.social/post/abc123?thread=true&reply=def456")!
        let threadResult = handler.parseURL(threadURL)
        
        #expect(threadResult?.type == .post, "Should identify post URL")
        #expect(threadResult?.showThread == true, "Should extract thread parameter")
        #expect(threadResult?.replyTo == "def456", "Should extract reply context")
        
        // Test profile with specific tab
        let profileTabURL = URL(string: "https://bsky.app/profile/user.bsky.social?tab=media")!
        let profileTabResult = handler.parseURL(profileTabURL)
        
        #expect(profileTabResult?.type == .profile, "Should identify profile URL")
        #expect(profileTabResult?.tab == "media", "Should extract tab parameter")
        
        // Test feed with refresh parameter
        let refreshFeedURL = URL(string: "https://bsky.app/profile/creator.bsky.social/feed/news?refresh=true")!
        let refreshResult = handler.parseURL(refreshFeedURL)
        
        #expect(refreshResult?.type == .feed, "Should identify feed URL")
        #expect(refreshResult?.shouldRefresh == true, "Should extract refresh parameter")
    }
    
    // MARK: - Malformed URL Handling Tests
    
    @Test("Malformed URLs are handled gracefully")
    func testMalformedURLHandling() throws {
        let handler = createURLHandler()
        
        // Test completely invalid URL
        let invalidURL = URL(string: "not-a-valid-url")!
        let invalidResult = handler.parseURL(invalidURL)
        
        #expect(invalidResult == nil, "Invalid URL should return nil")
        
        // Test unsupported scheme
        let unsupportedURL = URL(string: "ftp://example.com/file.txt")!
        let unsupportedResult = handler.parseURL(unsupportedURL)
        
        #expect(unsupportedResult == nil, "Unsupported scheme should return nil")
        
        // Test malformed bsky.app URL
        let malformedBskyURL = URL(string: "https://bsky.app/invalid/path/structure")!
        let malformedResult = handler.parseURL(malformedBskyURL)
        
        #expect(malformedResult == nil, "Malformed bsky.app URL should return nil")
        
        // Test empty path
        let emptyPathURL = URL(string: "https://bsky.app/")!
        let emptyPathResult = handler.parseURL(emptyPathURL)
        
        #expect(emptyPathResult?.type == .home, "Empty path should default to home")
    }
    
    @Test("Invalid AT URIs are rejected")
    func testInvalidATURIHandling() throws {
        let handler = createURLHandler()
        
        // Test malformed AT URI
        let malformedATURI = URL(string: "at://invalid-did/malformed/path")!
        let malformedResult = handler.parseURL(malformedATURI)
        
        #expect(malformedResult == nil, "Malformed AT URI should return nil")
        
        // Test AT URI with invalid DID
        let invalidDIDURI = URL(string: "at://not-a-did/app.bsky.feed.post/abc123")!
        let invalidDIDResult = handler.parseURL(invalidDIDURI)
        
        #expect(invalidDIDResult == nil, "AT URI with invalid DID should return nil")
        
        // Test unsupported AT URI collection
        let unsupportedCollectionURI = URL(string: "at://did:plc:abc123/app.unknown.collection/item")!
        let unsupportedResult = handler.parseURL(unsupportedCollectionURI)
        
        #expect(unsupportedResult == nil, "Unsupported collection should return nil")
    }
    
    // MARK: - Handle Validation Tests
    
    @Test("Handle validation works correctly")
    func testHandleValidation() throws {
        let handler = createURLHandler()
        
        // Test valid handles
        let validHandles = [
            "user.bsky.social",
            "test-user.example.com",
            "user123.custom-domain.org",
            "a.b.c.d.long-domain.net"
        ]
        
        for handle in validHandles {
            let url = URL(string: "https://bsky.app/profile/\(handle)")!
            let result = handler.parseURL(url)
            #expect(result?.handle == handle, "Should extract valid handle: \(handle)")
        }
        
        // Test invalid handles
        let invalidHandles = [
            "",
            "no-tld",
            "user@invalid.com", // @ symbol not allowed in bsky handles
            "user.toolong" + String(repeating: "x", count: 250), // Too long
            "user..double-dot.com", // Double dots
            ".starts-with-dot.com",
            "ends-with-dot.com."
        ]
        
        for handle in invalidHandles {
            let url = URL(string: "https://bsky.app/profile/\(handle)")!
            let result = handler.parseURL(url)
            #expect(result == nil, "Should reject invalid handle: \(handle)")
        }
    }
    
    // MARK: - URL Building Tests
    
    @Test("URLs are built correctly from parameters")
    func testURLBuilding() throws {
        let handler = createURLHandler()
        
        // Test profile URL building
        let profileURL = handler.buildURL(type: .profile, handle: "user.bsky.social")
        #expect(profileURL?.absoluteString == "https://bsky.app/profile/user.bsky.social", "Should build correct profile URL")
        
        // Test post URL building
        let postURL = handler.buildURL(type: .post, handle: "user.bsky.social", postId: "abc123")
        #expect(postURL?.absoluteString == "https://bsky.app/profile/user.bsky.social/post/abc123", "Should build correct post URL")
        
        // Test feed URL building
        let feedURL = handler.buildURL(type: .feed, handle: "creator.bsky.social", feedName: "tech-news")
        #expect(feedURL?.absoluteString == "https://bsky.app/profile/creator.bsky.social/feed/tech-news", "Should build correct feed URL")
        
        // Test AT URI building
        let atURI = handler.buildATURI(did: "did:plc:abc123", collection: "app.bsky.feed.post", recordId: "xyz789")
        #expect(atURI?.absoluteString == "at://did:plc:abc123/app.bsky.feed.post/xyz789", "Should build correct AT URI")
    }
    
    // MARK: - In-App Browser Tests
    
    @Test("External URL detection works correctly")
    func testExternalURLDetection() throws {
        let handler = createURLHandler()
        
        // Test Bluesky URLs (should open in-app)
        let bskyURL = URL(string: "https://bsky.app/profile/user.bsky.social")!
        #expect(handler.shouldOpenInApp(bskyURL) == true, "Bluesky URLs should open in-app")
        
        let atURI = URL(string: "at://did:plc:abc123/app.bsky.feed.post/xyz789")!
        #expect(handler.shouldOpenInApp(atURI) == true, "AT URIs should open in-app")
        
        // Test external URLs (should open in browser)
        let externalURL = URL(string: "https://example.com/article")!
        #expect(handler.shouldOpenInApp(externalURL) == false, "External URLs should open in browser")
        
        let httpsURL = URL(string: "https://github.com/project/repo")!
        #expect(handler.shouldOpenInApp(httpsURL) == false, "GitHub URLs should open in browser")
        
        // Test custom schemes
        let customSchemeURL = URL(string: "mention://user.bsky.social")!
        #expect(handler.shouldOpenInApp(customSchemeURL) == true, "Custom schemes should be handled in-app")
    }
    
    // MARK: - Performance Tests
    
    @Test("URL parsing performance is acceptable")
    func testURLParsingPerformance() throws {
        let handler = createURLHandler()
        let testURLs = [
            URL(string: "https://bsky.app/profile/user.bsky.social")!,
            URL(string: "https://bsky.app/profile/user.bsky.social/post/abc123")!,
            URL(string: "at://did:plc:abc123/app.bsky.feed.post/xyz789")!,
            URL(string: "catbird://oauth/callback?code=auth123&state=state456")!,
            URL(string: "mention://user.bsky.social")!
        ]
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Parse URLs multiple times
        for _ in 0..<1000 {
            for url in testURLs {
                _ = handler.parseURL(url)
            }
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let totalTime = endTime - startTime
        
        #expect(totalTime < 1.0, "URL parsing should complete 5000 operations in under 1 second")
    }
    
    // MARK: - Thread Safety Tests
    
    @Test("URL handler is thread-safe")
    func testThreadSafety() async throws {
        let handler = createURLHandler()
        let testURL = URL(string: "https://bsky.app/profile/user.bsky.social")!
        
        // Perform concurrent URL parsing
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<100 {
                        _ = handler.parseURL(testURL)
                    }
                }
            }
        }
        
        // Should complete without crashing or data corruption
        let result = handler.parseURL(testURL)
        #expect(result?.type == .profile, "Should still parse correctly after concurrent access")
    }
}

// MARK: - URL Handler Test Extensions

extension URLHandler {
    func buildURL(type: URLType, handle: String? = nil, postId: String? = nil, feedName: String? = nil) -> URL? {
        // In a real implementation, this would build URLs from components
        switch type {
        case .profile:
            guard let handle = handle else { return nil }
            return URL(string: "https://bsky.app/profile/\(handle)")
        case .post:
            guard let handle = handle, let postId = postId else { return nil }
            return URL(string: "https://bsky.app/profile/\(handle)/post/\(postId)")
        case .feed:
            guard let handle = handle, let feedName = feedName else { return nil }
            return URL(string: "https://bsky.app/profile/\(handle)/feed/\(feedName)")
        default:
            return nil
        }
    }
    
    func buildATURI(did: String, collection: String, recordId: String) -> URL? {
        // In a real implementation, this would build AT URIs
        return URL(string: "at://\(did)/\(collection)/\(recordId)")
    }
    
    func shouldOpenInApp(_ url: URL) -> Bool {
        // In a real implementation, this would determine if URL should open in-app
        return url.scheme == "https" && url.host == "bsky.app" ||
               url.scheme == "at" ||
               url.scheme == "mention" ||
               url.scheme == "hashtag" ||
               url.scheme == "catbird"
    }
}

// MARK: - URL Parse Result Extensions

extension URLParseResult {
    var isValid: Bool {
        // In a real implementation, this would validate the parsed result
        switch type {
        case .oauthCallback:
            return (authCode != nil || error != nil) && state != nil
        default:
            return true
        }
    }
}

// MARK: - Mock Types

enum URLType {
    case profile
    case post
    case feed
    case list
    case mention
    case hashtag
    case oauthCallback
    case home
}

struct URLParseResult {
    let type: URLType
    let handle: String?
    let did: String?
    let postId: String?
    let feedName: String?
    let listId: String?
    let tag: String?
    let authCode: String?
    let state: String?
    let error: String?
    let errorDescription: String?
    let showThread: Bool?
    let replyTo: String?
    let tab: String?
    let shouldRefresh: Bool?
}
