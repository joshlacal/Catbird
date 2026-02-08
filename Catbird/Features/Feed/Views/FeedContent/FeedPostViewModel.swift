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
    var showingReportSheet = false
    var showingMuteSheet = false
    var isBlurred = false
    var showingFullText = false
    
    /// Interaction state
    private(set) var isLikeInProgress = false
    private(set) var isRepostInProgress = false
    private(set) var isBookmarkInProgress = false
    private(set) var isMuteInProgress = false
    private(set) var isBlockInProgress = false
    
    /// Performance tracking
    private(set) var interactionCount = 0
    private(set) var lastInteractionTime: Date?
    
    /// Cached computed properties for performance
    private var _displayText: String?
    private var _truncatedText: String?
    private var _hasContentWarning: Bool?
    private var _authorDisplayName: String?
    private var _timeAgoString: String?
    private var _hasMedia: Bool?
    private var _isThread: Bool?

    /// Cached decoded FeedViewPost to avoid repeated JSON parsing
    private var _cachedFeedViewPost: AppBskyFeedDefs.FeedViewPost?
    
    // MARK: - Dependencies
    
    private weak var appState: AppState?
    private let logger = Logger(subsystem: "blue.catbird", category: "PostViewModel")
    
    // MARK: - Initialization

    init(post: CachedFeedViewPost, appState: AppState? = nil) {
        self.post = post
        self.appState = appState

        // Initialize bookmark state from preferences
        self.isBookmarked = checkBookmarkState()

        // Initialize content warning state
        if hasContentWarning {
            self.isBlurred = true
        }

        logger.debug("FeedPostViewModel initialized for post: \(post.id)")
    }

    /// Accessor for feedViewPost from the cached post (with caching to avoid repeated JSON parsing)
    private var feedViewPost: AppBskyFeedDefs.FeedViewPost? {
        if let cached = _cachedFeedViewPost {
            return cached
        }
        let decoded = try? post.feedViewPost
        _cachedFeedViewPost = decoded
        return decoded
    }
    
    // MARK: - Data Updates
    
    /// Updates the post data while preserving UI state
    func updatePost(_ newPost: CachedFeedViewPost) {
        guard newPost.id == post.id else {
            logger.error("Attempted to update FeedPostViewModel with different post ID")
            return
        }

        // Clear cached FeedViewPost since we're getting new data
        _cachedFeedViewPost = nil

        // Clear cached properties if content changed
        if let oldPost = feedViewPost,
           let newFVP = try? newPost.feedViewPost {
            let oldText = extractTextFromRecord(oldPost.post.record)
            let newText = extractTextFromRecord(newFVP.post.record)
            if oldText != newText {
                clearAllCache()
            }
        }

        post = newPost
        
        // Update bookmark state from preferences
        self.isBookmarked = checkBookmarkState()
        
        logger.debug("FeedPostViewModel updated for post: \(self.post.id)")
    }
    
    // MARK: - Computed Properties
    
    /// Display text with caching for performance
    var displayText: String {
        if let cached = _displayText {
            return cached
        }

        let text = extractTextFromRecord(feedViewPost?.post.record)
        _displayText = text
        return text
    }
    
    /// Truncated display text for feed views
    var truncatedText: String {
        if let cached = _truncatedText {
            return cached
        }
        
        let text = displayText
        let maxLength = 280
        let truncated = text.count > maxLength 
            ? String(text.prefix(maxLength)) + "..."
            : text
        _truncatedText = truncated
        return truncated
    }
    
    /// Whether the post has content warnings
    var hasContentWarning: Bool {
        if let cached = _hasContentWarning {
            return cached
        }
        
        let hasWarning = detectContentWarning()
        _hasContentWarning = hasWarning
        return hasWarning
    }
    
    /// Author display name with caching
    var authorDisplayName: String {
        if let cached = _authorDisplayName {
            return cached
        }

        guard let fvp = feedViewPost else {
            _authorDisplayName = "Unknown"
            return "Unknown"
        }

        let name = fvp.post.author.displayName ?? fvp.post.author.handle.description
        _authorDisplayName = name
        return name
    }
    
    /// Time ago string with caching
    var timeAgoString: String {
        if let cached = _timeAgoString {
            return cached
        }

        guard let fvp = feedViewPost else {
            _timeAgoString = "now"
            return "now"
        }

        let timeAgo = formatTimeAgo(from: fvp.post.indexedAt.iso8601String)
        _timeAgoString = timeAgo
        return timeAgo
    }

    /// Whether the post has media content
    var hasMedia: Bool {
        if let cached = _hasMedia {
            return cached
        }

        guard let fvp = feedViewPost else {
            _hasMedia = false
            return false
        }

        let hasMediaContent = fvp.post.embed != nil
        _hasMedia = hasMediaContent
        return hasMediaContent
    }

    /// Whether this is part of a thread
    var isThread: Bool {
        if let cached = _isThread {
            return cached
        }

        guard let fvp = feedViewPost else {
            _isThread = false
            return false
        }

        let isThreadPost = fvp.reply != nil
        _isThread = isThreadPost
        return isThreadPost
    }


    /// Current like state from PostShadowManager
    var isLiked: Bool {
        guard let viewer = feedViewPost?.post.viewer else {
            return false
        }
        return viewer.like != nil
    }

    /// Current repost state from PostShadowManager
    var isReposted: Bool {
        guard let viewer = feedViewPost?.post.viewer else {
            return false
        }
        return viewer.repost != nil
    }

    /// Current like count from PostShadowManager
    var likeCount: Int {
        feedViewPost?.post.likeCount ?? 0
    }

    /// Current repost count from PostShadowManager
    var repostCount: Int {
        feedViewPost?.post.repostCount ?? 0
    }

    /// Current reply count from PostShadowManager
    var replyCount: Int {
        feedViewPost?.post.replyCount ?? 0
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
        trackInteraction()
        logger.debug("Showing share sheet for post: \(self.post.id)")
    }
    
    /// Shows the report sheet
    func showReportSheet() {
        showingReportSheet = true
        trackInteraction()
        logger.debug("Showing report sheet for post: \(self.post.id)")
    }
    
    /// Shows the mute sheet
    func showMuteSheet() {
        showingMuteSheet = true
        trackInteraction()
        logger.debug("Showing mute sheet for post: \(self.post.id)")
    }
    
    /// Toggles content blur state
    func toggleContentBlur() {
        isBlurred.toggle()
        trackInteraction()
        logger.debug("Content blur toggled for post: \(self.post.id)")
    }
    
    /// Toggles full text display
    func toggleFullText() {
        showingFullText.toggle()
        trackInteraction()
        logger.debug("Full text display toggled for post: \(self.post.id)")
    }
    
    // MARK: - Post Interactions
    
    /// Toggles the like state of the post
    @MainActor
    func toggleLike() async {
        guard let appState = appState,
              !isLikeInProgress else { return }

        isLikeInProgress = true
        defer { isLikeInProgress = false }

        trackInteraction()

        // Perform actual like/unlike operation
        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost when toggling like for: \(self.post.id, privacy: .public)")
            return
        }

        let postUri = fvp.post.uri.uriString()
        let currentlyLiked = isLiked
        let newLikedState = !currentlyLiked
        
        // Update shadow state optimistically
        await appState.postShadowManager.setLiked(postUri: postUri, isLiked: newLikedState)
        
        // Perform server operation
        do {
            if newLikedState {
                try await performLike()
            } else {
                try await performUnlike()
            }
        } catch {
            // Rollback shadow state on error
            await appState.postShadowManager.setLiked(postUri: postUri, isLiked: currentlyLiked)
            logger.error("Like operation failed: \(error.localizedDescription)")
        }
        
        logger.debug("Like toggled for post: \(self.post.id)")
    }
    
    /// Toggles the repost state of the post
    @MainActor
    func toggleRepost() async {
        guard let appState = appState,
              !isRepostInProgress else { return }

        isRepostInProgress = true
        defer { isRepostInProgress = false }

        trackInteraction()

        // Perform actual repost/unrepost operation
        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost when toggling repost for: \(self.post.id, privacy: .public)")
            return
        }

        let postUri = fvp.post.uri.uriString()
        let currentlyReposted = isReposted
        let newRepostedState = !currentlyReposted
        
        // Update shadow state optimistically
        await appState.postShadowManager.setReposted(postUri: postUri, isReposted: newRepostedState)
        
        // Perform server operation
        do {
            if newRepostedState {
                try await performRepost()
            } else {
                try await performUnrepost()
            }
        } catch {
            // Rollback shadow state on error
            await appState.postShadowManager.setReposted(postUri: postUri, isReposted: currentlyReposted)
            logger.error("Repost operation failed: \(error.localizedDescription)")
        }
        
        logger.debug("Repost toggled for post: \(self.post.id)")
    }
    
    /// Toggles the bookmark state of the post
    @MainActor
    func toggleBookmark() async {
        guard let appState = appState,
              !isBookmarkInProgress else { return }

        isBookmarkInProgress = true
        defer { isBookmarkInProgress = false }

        trackInteraction()

        // Perform actual bookmark operation
        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost when toggling bookmark for: \(self.post.id, privacy: .public)")
            return
        }

        let postUri = fvp.post.uri
        let postCid = fvp.post.cid
        let currentlyBookmarked = isBookmarked
        let newBookmarkState = !currentlyBookmarked
        
        // Update local state optimistically
        isBookmarked = newBookmarkState
        
        // Update shadow state optimistically
        await appState.postShadowManager.setBookmarked(postUri: postUri.uriString(), isBookmarked: newBookmarkState)
        
        // Perform server operation
        do {
            guard let client = appState.atProtoClient else {
                throw PostInteractionError.clientUnavailable
            }
            
            if newBookmarkState {
                _ = try await appState.bookmarksManager.createBookmark(
                    postUri: postUri,
                    postCid: postCid,
                    client: client
                )
            } else {
                try await appState.bookmarksManager.deleteBookmark(
                    postUri: postUri,
                    client: client
                )
            }
        } catch {
            // Rollback on error
            isBookmarked = currentlyBookmarked
            await appState.postShadowManager.setBookmarked(postUri: postUri.uriString(), isBookmarked: currentlyBookmarked)
            logger.error("Bookmark operation failed: \(error.localizedDescription)")
        }
        
        logger.debug("Bookmark toggled for post: \(self.post.id)")
    }
    
    /// Mutes the post author
    @MainActor
    func muteAuthor() async {
        guard appState != nil,
              !isMuteInProgress else { return }

        isMuteInProgress = true
        defer { isMuteInProgress = false }

        trackInteraction()

        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost when muting author for: \(self.post.id, privacy: .public)")
            return
        }
        do {
            try await performMuteAuthor()
            logger.debug("Successfully muted author: \(fvp.post.author.handle)")
        } catch {
            logger.error("Mute operation failed: \(error.localizedDescription)")
        }
    }

    /// Blocks the post author
    @MainActor
    func blockAuthor() async {
        guard appState != nil,
              !isBlockInProgress else { return }

        isBlockInProgress = true
        defer { isBlockInProgress = false }

        trackInteraction()

        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost when blocking author for: \(self.post.id, privacy: .public)")
            return
        }
        do {
            try await performBlockAuthor()
            logger.debug("Successfully blocked author: \(fvp.post.author.handle)")
        } catch {
            logger.error("Block operation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Navigation

    /// Navigates to the post detail view
    func navigateToPost(navigationPath: Binding<NavigationPath>) {
        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost when navigating to post for: \(self.post.id, privacy: .public)")
            return
        }

        navigationPath.wrappedValue.append(NavigationDestination.post(fvp.post.uri))
        logger.debug("Navigating to post: \(self.post.id)")
    }

    /// Navigates to the author's profile
    func navigateToProfile(navigationPath: Binding<NavigationPath>) {
        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost when navigating to profile for: \(self.post.id, privacy: .public)")
            return
        }

        navigationPath.wrappedValue.append(NavigationDestination.profile(fvp.post.author.did.didString()))
        logger.debug("Navigating to profile: \(fvp.post.author.handle)")
    }
    
    // MARK: - Cleanup
    
    /// Clears cached properties for memory management
    func clearCache() {
        clearAllCache()
    }
    
    /// Clears all cached properties
    private func clearAllCache() {
        _cachedFeedViewPost = nil
        _displayText = nil
        _truncatedText = nil
        _hasContentWarning = nil
        _authorDisplayName = nil
        _timeAgoString = nil
        _hasMedia = nil
        _isThread = nil
    }
    
    /// Tracks user interaction for analytics
    private func trackInteraction() {
        interactionCount += 1
        lastInteractionTime = Date()
    }
    
    // MARK: - Helper Methods
    
    /// Extracts text from AT Protocol record
    private func extractTextFromRecord(_ record: ATProtocolValueContainer?) -> String {
        guard let record else { return "" }

        if case let .knownType(value) = record,
           let postRecord = value as? AppBskyFeedPost {
            return postRecord.text
        }

        return ""
    }
    
    /// Checks the current bookmark state from viewer state and shadow manager
    private func checkBookmarkState() -> Bool {
        guard let fvp = feedViewPost else { return false }

        // Check viewer state first (server state)
        if let bookmarked = fvp.post.viewer?.bookmarked {
            return bookmarked
        }

        // No shadow state fallback needed since we use optimistic updates elsewhere
        return false
    }

    /// Detects if the post has content warnings based on labels
    private func detectContentWarning() -> Bool {
        guard let fvp = feedViewPost else { return false }

        // Check post labels - these apply to both the post and embedded content
        if let labels = fvp.post.labels,
           !labels.isEmpty {
            return ContentLabelManager<AnyView>.getContentVisibility(labels: labels) == .warn
        }
        
        return false
    }
    
    
    /// Formats date as time ago string
    private func formatTimeAgo(from iso8601String: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let date = formatter.date(from: iso8601String) else {
            return "now"
        }
        
        let now = Date()
        let interval = now.timeIntervalSince(date)
        
        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d"
        } else {
            let weeks = Int(interval / 604800)
            return "\(weeks)w"
        }
    }
    
    /// Performs the actual like operation on the server
    private func performLike() async throws {
        guard let client = appState?.atProtoClient else {
            throw PostInteractionError.clientUnavailable
        }

        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost while performing like for: \(self.post.id, privacy: .public)")
            throw PostInteractionError.clientUnavailable
        }

        let postRef = ComAtprotoRepoStrongRef(
            uri: fvp.post.uri,
            cid: fvp.post.cid
        )
        
        let like = AppBskyFeedLike(
            subject: postRef,
            createdAt: ATProtocolDate(date: Date()),
            via: nil
        )
        
        let (responseCode, _) = try await client.com.atproto.repo.createRecord(
            input: ComAtprotoRepoCreateRecord.Input(
                repo: ATIdentifier(string: try client.getDid()),
                collection: try NSID(nsidString: "app.bsky.feed.like"),
                record: ATProtocolValueContainer.knownType(like)
            )
        )
        
        guard responseCode >= 200 && responseCode < 300 else {
            throw PostInteractionError.serverError(responseCode)
        }

        logger.debug("Successfully liked post: \(self.post.id)")
    }

    /// Performs the actual unlike operation on the server
    private func performUnlike() async throws {
        guard let client = appState?.atProtoClient else {
            throw PostInteractionError.clientUnavailable
        }

        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost while performing unlike for: \(self.post.id, privacy: .public)")
            throw PostInteractionError.clientUnavailable
        }

        guard let likeUri = fvp.post.viewer?.like else {
            throw PostInteractionError.clientUnavailable
        }
        
        // Parse the like URI to get the record key
        let likeURI = likeUri.uriString()
        guard let recordKey = likeURI.components(separatedBy: "/").last else {
            throw PostInteractionError.invalidURI
        }
        
        let (responseCode, _) = try await client.com.atproto.repo.deleteRecord(
            input: ComAtprotoRepoDeleteRecord.Input(
                repo: ATIdentifier(string: try client.getDid()),
                collection: try NSID(nsidString: "app.bsky.feed.like"),
                rkey: RecordKey(keyString: recordKey)
            )
        )
        
        guard responseCode >= 200 && responseCode < 300 else {
            throw PostInteractionError.serverError(responseCode)
        }

        logger.debug("Successfully unliked post: \(self.post.id)")
    }

    /// Performs the actual repost operation on the server
    private func performRepost() async throws {
        guard let client = appState?.atProtoClient else {
            throw PostInteractionError.clientUnavailable
        }

        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost while performing repost for: \(self.post.id, privacy: .public)")
            throw PostInteractionError.clientUnavailable
        }

        let postRef = ComAtprotoRepoStrongRef(
            uri: fvp.post.uri,
            cid: fvp.post.cid
        )
        
        let repost = AppBskyFeedRepost(
            subject: postRef,
            createdAt: ATProtocolDate(date: Date()),
            via: nil
        )
        
        let (responseCode, _) = try await client.com.atproto.repo.createRecord(
            input: ComAtprotoRepoCreateRecord.Input(
                repo: ATIdentifier(string: try client.getDid()),
                collection: try NSID(nsidString: "app.bsky.feed.repost"),
                record: ATProtocolValueContainer.knownType(repost)
            )
        )
        
        guard responseCode >= 200 && responseCode < 300 else {
            throw PostInteractionError.serverError(responseCode)
        }
        
        logger.debug("Successfully reposted post: \(self.post.id)")
    }

    /// Performs the actual unrepost operation on the server
    private func performUnrepost() async throws {
        guard let client = appState?.atProtoClient else {
            throw PostInteractionError.clientUnavailable
        }

        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost while performing unrepost for: \(self.post.id, privacy: .public)")
            throw PostInteractionError.clientUnavailable
        }

        guard let repostUri = fvp.post.viewer?.repost else {
            throw PostInteractionError.clientUnavailable
        }
        
        // Parse the repost URI to get the record key
        let repostURI = repostUri.uriString()
        guard let recordKey = repostURI.components(separatedBy: "/").last else {
            throw PostInteractionError.invalidURI
        }
        
        let (responseCode, _) = try await client.com.atproto.repo.deleteRecord(
            input: ComAtprotoRepoDeleteRecord.Input(
                repo: ATIdentifier(string: try client.getDid()),
                collection: try NSID(nsidString: "app.bsky.feed.repost"),
                rkey: RecordKey(keyString: recordKey)
            )
        )
        
        guard responseCode >= 200 && responseCode < 300 else {
            throw PostInteractionError.serverError(responseCode)
        }

        logger.debug("Successfully unreposted post: \(self.post.id)")
    }
    
    /// Performs the actual mute operation on the server
    private func performMuteAuthor() async throws {
        guard let client = appState?.atProtoClient else {
            throw PostInteractionError.clientUnavailable
        }

        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost while muting author for: \(self.post.id, privacy: .public)")
            throw PostInteractionError.clientUnavailable
        }

        let authorDID = fvp.post.author.did

        let (responseCode) = try await client.app.bsky.graph.muteActor(
            input: AppBskyGraphMuteActor.Input(actor: ATIdentifier.did(authorDID))
        )

        guard responseCode >= 200 && responseCode < 300 else {
            throw PostInteractionError.serverError(responseCode)
        }

        logger.debug("Successfully muted author: \(fvp.post.author.handle)")
    }
    
    /// Performs the actual block operation on the server
    private func performBlockAuthor() async throws {
        guard let client = appState?.atProtoClient else {
            throw PostInteractionError.clientUnavailable
        }

        guard let fvp = feedViewPost else {
            logger.error("Missing feedViewPost while blocking author for: \(self.post.id, privacy: .public)")
            throw PostInteractionError.clientUnavailable
        }

        let blockRecord = AppBskyGraphBlock(
            subject: fvp.post.author.did,
            createdAt: ATProtocolDate(date: Date())
        )

        let (responseCode, _) = try await client.com.atproto.repo.createRecord(
            input: ComAtprotoRepoCreateRecord.Input(
                repo: ATIdentifier(string: try client.getDid()),
                collection: try NSID(nsidString: "app.bsky.graph.block"),
                record: ATProtocolValueContainer.knownType(blockRecord)
            )
        )

        guard responseCode >= 200 && responseCode < 300 else {
            throw PostInteractionError.serverError(responseCode)
        }

        logger.debug("Successfully blocked author: \(fvp.post.author.handle)")
    }
}

// MARK: - Errors

enum PostInteractionError: LocalizedError {
    case clientUnavailable
    case serverError(Int)
    case invalidURI
    case moderationFailed
    case networkError
    case rateLimited
    case unauthorized
    
    var errorDescription: String? {
        switch self {
        case .clientUnavailable:
            return "AT Protocol client is not available"
        case .serverError(let code):
            return "Server error: \(code)"
        case .invalidURI:
            return "Invalid URI format"
        case .moderationFailed:
            return "Moderation action failed"
        case .networkError:
            return "Network connection error"
        case .rateLimited:
            return "Too many requests - please try again later"
        case .unauthorized:
            return "Authentication required"
        }
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
