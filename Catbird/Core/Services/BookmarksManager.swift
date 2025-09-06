//
//  BookmarksManager.swift
//  Catbird
//
//  Created by Claude on 9/5/24.
//

import Foundation
import Petrel
import OSLog

/// Actor for managing bookmark state and operations
/// Provides centralized bookmark management with thread-safe access
actor BookmarksManager {
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird", category: "BookmarksManager")
    
    /// Set of bookmarked post URIs for quick lookup
    private var bookmarkedPostUris: Set<String> = []
    
    /// Cache of bookmark URIs keyed by post URI for deletion
    private var bookmarkUrisCache: [String: ATProtocolURI] = [:]
    
    /// Shared singleton instance
    static let shared = BookmarksManager()
    
    private init() {}
    
    // MARK: - Bookmark Operations
    
    /// Creates a bookmark for the specified post
    /// - Parameters:
    ///   - postUri: The URI of the post to bookmark
    ///   - postCid: The CID of the post to bookmark
    ///   - client: The AT Protocol client to use
    /// - Returns: The bookmark URI if successful
    /// - Throws: BookmarkError on failure
    func createBookmark(postUri: ATProtocolURI, postCid: CID, client: ATProtoClient) async throws -> ATProtocolURI {
        let input = AppBskyBookmarkCreateBookmark.Input(uri: postUri, cid: postCid)
        
        let responseCode = try await client.app.bsky.bookmark.createBookmark(input: input)
        
        if responseCode == 200 {
            let postUriString = postUri.uriString()
            bookmarkedPostUris.insert(postUriString)
            
            // Note: The API only returns a response code, so we'll need to generate
            // a placeholder URI for tracking. The real URI will be obtained during refresh.
            let placeholderUri = try ATProtocolURI(uriString: "at://\(postUri.authority ?? "")/app.bsky.bookmark.bookmark/placeholder_\(Date().timeIntervalSince1970)")
            bookmarkUrisCache[postUriString] = placeholderUri
            
            logger.debug("Bookmark created successfully for post: \(postUriString)")
            return placeholderUri
        } else {
            logger.error("Failed to create bookmark, response code: \(responseCode)")
            throw BookmarkError.creationFailed(responseCode)
        }
    }
    
    /// Deletes a bookmark for the specified post
    /// - Parameters:
    ///   - postUri: The URI of the post to unbookmark
    ///   - client: The AT Protocol client to use
    /// - Throws: BookmarkError on failure
    func deleteBookmark(postUri: ATProtocolURI, client: ATProtoClient) async throws {
        let input = AppBskyBookmarkDeleteBookmark.Input(uri: postUri)
        
        let responseCode = try await client.app.bsky.bookmark.deleteBookmark(input: input)
        
        if responseCode == 200 {
            let postUriString = postUri.uriString()
            bookmarkedPostUris.remove(postUriString)
            bookmarkUrisCache.removeValue(forKey: postUriString)
            
            logger.debug("Bookmark deleted successfully for post: \(postUriString)")
        } else {
            logger.error("Failed to delete bookmark, response code: \(responseCode)")
            throw BookmarkError.deletionFailed(responseCode)
        }
    }
    
    /// Fetches bookmarks from the server
    /// - Parameters:
    ///   - client: The AT Protocol client to use
    ///   - limit: Maximum number of bookmarks to fetch
    ///   - cursor: Pagination cursor
    /// - Returns: Tuple of bookmark views and next cursor
    /// - Throws: BookmarkError on failure
    func fetchBookmarks(client: ATProtoClient, limit: Int = 50, cursor: String? = nil) async throws -> (bookmarks: [AppBskyBookmarkDefs.BookmarkView], cursor: String?) {
        let parameters = AppBskyBookmarkGetBookmarks.Parameters(limit: limit, cursor: cursor)
        
        let (responseCode, data) = try await client.app.bsky.bookmark.getBookmarks(input: parameters)
        
        if responseCode == 200, let response = data {
            // Update our cache with the fetched bookmarks
            for bookmark in response.bookmarks {
                let postUriString = bookmark.subject.uri.uriString()
                bookmarkedPostUris.insert(postUriString)
            }
            
            logger.debug("Fetched \(response.bookmarks.count) bookmarks")
            return (bookmarks: response.bookmarks, cursor: response.cursor)
        } else {
            logger.error("Failed to fetch bookmarks, response code: \(responseCode)")
            throw BookmarkError.fetchFailed(responseCode)
        }
    }
    
    // MARK: - State Queries
    
    /// Checks if a post is bookmarked
    /// - Parameter postUri: The URI of the post to check
    /// - Returns: True if the post is bookmarked
    func isBookmarked(postUri: String) -> Bool {
        return bookmarkedPostUris.contains(postUri)
    }
    
    /// Gets the bookmark URI for a post if it exists
    /// - Parameter postUri: The URI of the post
    /// - Returns: The bookmark URI if cached
    func getBookmarkUri(for postUri: String) -> ATProtocolURI? {
        return bookmarkUrisCache[postUri]
    }
    
    /// Updates the bookmark state for a post
    /// - Parameters:
    ///   - postUri: The URI of the post
    ///   - isBookmarked: Whether the post is bookmarked
    ///   - bookmarkUri: The bookmark URI if available
    func updateBookmarkState(postUri: String, isBookmarked: Bool, bookmarkUri: ATProtocolURI? = nil) {
        if isBookmarked {
            bookmarkedPostUris.insert(postUri)
            if let bookmarkUri = bookmarkUri {
                bookmarkUrisCache[postUri] = bookmarkUri
            }
        } else {
            bookmarkedPostUris.remove(postUri)
            bookmarkUrisCache.removeValue(forKey: postUri)
        }
    }
    
    /// Clears all bookmark cache
    func clearCache() {
        bookmarkedPostUris.removeAll()
        bookmarkUrisCache.removeAll()
        logger.debug("Bookmark cache cleared")
    }
}

// MARK: - BookmarkError

enum BookmarkError: Swift.Error, CustomStringConvertible {
    case creationFailed(Int)
    case deletionFailed(Int)
    case fetchFailed(Int)
    case missingClient
    case invalidUri
    
    var description: String {
        switch self {
        case .creationFailed(let code):
            return "Failed to create bookmark (HTTP \(code))"
        case .deletionFailed(let code):
            return "Failed to delete bookmark (HTTP \(code))"
        case .fetchFailed(let code):
            return "Failed to fetch bookmarks (HTTP \(code))"
        case .missingClient:
            return "AT Protocol client is not available"
        case .invalidUri:
            return "Invalid URI provided for bookmark operation"
        }
    }
}