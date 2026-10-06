//
//  ActionButtonViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import Petrel
import Foundation
import Observation
import SwiftUI

/// ViewModel to handle post interaction actions like liking, reposting, and sharing
@Observable final class ActionButtonViewModel {
    // MARK: - Properties
    
    /// The unique identifier for the post
    let postId: String
    
    /// The post view model that handles actual interactions
    private let postViewModel: PostViewModel
    
    /// Reference to the app state
    let appState: AppState
    // MARK: - Initialization
    
    /// Initialize the view model
    /// - Parameters:
    ///   - postId: The post URI string
    ///   - postViewModel: The post view model
    ///   - appState: The app state
    init(postId: String, postViewModel: PostViewModel, appState: AppState) {
        self.postId = postId
        self.appState = appState
        self.postViewModel = postViewModel
    }
    
    // MARK: - Interaction Methods
    
    /// Toggle like status for the post with optimistic updates
    /// - Returns: True if the operation was successful
    func toggleLike(feedInteractionTarget: FeedInteractionTarget? = nil) async throws {
        try await postViewModel.toggleLike(feedInteractionTarget: feedInteractionTarget)
    }
    
    /// Toggle repost status for the post with optimistic updates
    /// - Returns: True if the operation was successful
    func toggleRepost(feedInteractionTarget: FeedInteractionTarget? = nil) async throws {
        guard try await postViewModel.toggleRepost(feedInteractionTarget: feedInteractionTarget) else {
            throw PostViewModel.PostViewModelError.requestFailed
        }
    }
    /// One URL source for Copy Link, native sharing and chat handoffs.
    static func shareURL(for post: AppBskyFeedDefs.PostView) -> URL? {
        shareURL(handle: post.author.handle.description, did: post.author.did.didString(), recordKey: post.uri.recordKey)
    }

    static func shareURL(handle: String, did: String, recordKey: String?) -> URL? {
        guard let recordKey, !recordKey.isEmpty else { return nil }
        let identifier = handle.isEmpty || handle == "handle.invalid" ? did : handle
        guard !identifier.isEmpty else { return nil }
        return URL(string: "https://bsky.app")?
            .appendingPathComponent("profile")
            .appendingPathComponent(identifier)
            .appendingPathComponent("post")
            .appendingPathComponent(recordKey)
    }

    /// Create a quote post (repost with comment)
    /// - Parameter text: The text for the quote
    /// - Returns: True if the operation was successful
    func createQuotePost(text: String) async throws -> Bool {
        return try await postViewModel.createQuotePost(text: text)
    }
}
