//
//  FeedPostViewModel.swift
//  Catbird
//
//  Created by Claude on 7/18/25.
//
//  @Observable ViewModel for individual feed posts that persists across cell reuse
//

import Foundation
import SwiftUI
import Petrel
import os

@Observable
final class FeedPostViewModel {
    // MARK: - Properties
    
    /// The current post data
    private(set) var post: CachedFeedViewPost
    
    /// UI state that persists across cell reuse
    var isBookmarked = false
    var showingReplySheet = false
    var showingRepostSheet = false
    var showingShareSheet = false
    
    /// Interaction state
    private(set) var isLikeInProgress = false
    private(set) var isRepostInProgress = false
    private(set) var isBookmarkInProgress = false
    
    /// Cached computed properties for performance
    private var _displayText: String?
    private var _hasContentWarning: Bool?
    
    // MARK: - Dependencies
    
    private weak var appState: AppState?
    private let logger = Logger(subsystem: "blue.catbird", category: "PostViewModel")
    
    // MARK: - Initialization
    
    init(post: CachedFeedViewPost, appState: AppState? = nil) {
        self.post = post
        self.appState = appState
        
        // Initialize bookmark state from preferences
        self.isBookmarked = false // TODO: Implement bookmark checking
        
        logger.debug("FeedPostViewModel initialized for post: \(post.id)")
    }
    
    // MARK: - Data Updates
    
    /// Updates the post data while preserving UI state
    func updatePost(_ newPost: CachedFeedViewPost) {
        guard newPost.id == post.id else {
            logger.error("Attempted to update FeedPostViewModel with different post ID")
            return
        }
        
        // Clear cached properties if content changed
        let oldText = extractTextFromRecord(post.feedViewPost.post.record)
        let newText = extractTextFromRecord(newPost.feedViewPost.post.record)
        if oldText != newText {
            _displayText = nil
            _hasContentWarning = nil
        }
        
        post = newPost
        
        // Update bookmark state from preferences
        // TODO: Implement bookmark checking
        
        logger.debug("FeedPostViewModel updated for post: \(self.post.id)")
    }
    
    // MARK: - Computed Properties
    
    /// Display text with caching for performance
    var displayText: String {
        if let cached = _displayText {
            return cached
        }
        
        let text = extractTextFromRecord(post.feedViewPost.post.record)
        _displayText = text
        return text
    }
    
    /// Whether the post has content warnings
    var hasContentWarning: Bool {
        if let cached = _hasContentWarning {
            return cached
        }
        
        let hasWarning = false // TODO: Implement content warning detection
        _hasContentWarning = hasWarning
        return hasWarning
    }
    
    
    /// Current like state from PostShadowManager
    var isLiked: Bool {
        // Check viewer state first, then shadow state
        if let likeUri = post.feedViewPost.post.viewer?.like {
            return likeUri != nil
        }
        return false
    }
    
    /// Current repost state from PostShadowManager
    var isReposted: Bool {
        // Check viewer state first, then shadow state
        if let repostUri = post.feedViewPost.post.viewer?.repost {
            return repostUri != nil
        }
        return false
    }
    
    /// Current like count from PostShadowManager
    var likeCount: Int {
        post.feedViewPost.post.likeCount ?? 0
    }
    
    /// Current repost count from PostShadowManager
    var repostCount: Int {
        post.feedViewPost.post.repostCount ?? 0
    }
    
    /// Current reply count from PostShadowManager
    var replyCount: Int {
        post.feedViewPost.post.replyCount ?? 0
    }
    
    // MARK: - UI Actions
    
    /// Shows the reply sheet
    func showReplySheet() {
        showingReplySheet = true
        logger.debug("Showing reply sheet for post: \(self.post.id)")
    }
    
    /// Shows the repost sheet
    func showRepostSheet() {
        showingRepostSheet = true
        logger.debug("Showing repost sheet for post: \(self.post.id)")
    }
    
    /// Shows the share sheet
    func showShareSheet() {
        showingShareSheet = true
        logger.debug("Showing share sheet for post: \(self.post.id)")
    }
    
    // MARK: - Post Interactions
    
    /// Toggles the like state of the post
    @MainActor
    func toggleLike() async {
        guard let appState = appState,
              !isLikeInProgress else { return }
        
        isLikeInProgress = true
        defer { isLikeInProgress = false }
        
        // TODO: Implement like/unlike functionality
        // For now, just update the shadow state
        let postUri = post.feedViewPost.post.uri.uriString()
        let currentlyLiked = isLiked
        await appState.postShadowManager.setLiked(postUri: postUri, isLiked: !currentlyLiked)
        
        logger.debug("Like toggled for post: \(self.post.id)")
    }
    
    /// Toggles the repost state of the post
    @MainActor
    func toggleRepost() async {
        guard let appState = appState,
              !isRepostInProgress else { return }
        
        isRepostInProgress = true
        defer { isRepostInProgress = false }
        
        // TODO: Implement repost/unrepost functionality
        // For now, just update the shadow state
        let postUri = post.feedViewPost.post.uri.uriString()
        let currentlyReposted = isReposted
        await appState.postShadowManager.setReposted(postUri: postUri, isReposted: !currentlyReposted)
        
        logger.debug("Repost toggled for post: \(self.post.id)")
    }
    
    /// Toggles the bookmark state of the post
    @MainActor
    func toggleBookmark() async {
        guard !isBookmarkInProgress else { return }
        
        isBookmarkInProgress = true
        defer { isBookmarkInProgress = false }
        
        // TODO: Implement bookmark functionality
        isBookmarked.toggle()
        logger.debug("Bookmark toggled for post: \(self.post.id)")
    }
    
    // MARK: - Navigation
    
    /// Navigates to the post detail view
    func navigateToPost(navigationPath: Binding<NavigationPath>) {
        navigationPath.wrappedValue.append(NavigationDestination.post(post.feedViewPost.post.uri))
        logger.debug("Navigating to post: \(self.post.id)")
    }
    
    /// Navigates to the author's profile
    func navigateToProfile(navigationPath: Binding<NavigationPath>) {
        navigationPath.wrappedValue.append(NavigationDestination.profile(post.feedViewPost.post.author.did.didString()))
        logger.debug("Navigating to profile: \(self.post.feedViewPost.post.author.handle)")
    }
    
    // MARK: - Cleanup
    
    /// Clears cached properties for memory management
    func clearCache() {
        _displayText = nil
        _hasContentWarning = nil
    }
    
    // MARK: - Helper Methods
    
    /// Extracts text from AT Protocol record
    private func extractTextFromRecord(_ record: ATProtocolValueContainer) -> String {
            if case let .knownType(aTProtocolValue) = record {
                if let postRecord = aTProtocolValue as? AppBskyFeedPost {
                    // Return text content if available
                    return postRecord.text
                }
            }
        return ""
    }
}

// MARK: - Equatable

extension FeedPostViewModel: Equatable {
    static func == (lhs: FeedPostViewModel, rhs: FeedPostViewModel) -> Bool {
        lhs.post.id == rhs.post.id
    }
}

// MARK: - Hashable

extension FeedPostViewModel: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(post.id)
    }
}
