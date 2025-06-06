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
    func toggleLike() async throws {
        try await postViewModel.toggleLike()
    }
    
    /// Toggle repost status for the post with optimistic updates
    /// - Returns: True if the operation was successful
    func toggleRepost() async throws {
        try await postViewModel.toggleRepost()
    }
    
    /// Share the post using system share sheet or to chat
    /// - Parameter post: The post to share
    @MainActor
    func share(post: AppBskyFeedDefs.PostView) async {
        // Build a Bluesky URL that can be opened in any Bluesky client
        let username = post.author.handle  // Fixed from did to handle
        let recordKey = post.uri.recordKey ?? ""
        let shareURL = URL(string: "https://bsky.app/profile/\(username)/post/\(recordKey)")
        
        guard let url = shareURL else { return }
        
        #if os(iOS)
        // Create custom activity for sharing to chat
        let shareToChat = ShareToChatActivity(post: post, appState: appState)
        
        let activityViewController = UIActivityViewController(
            activityItems: [url, ShareablePost(post: post)],
            applicationActivities: [shareToChat]
        )
        
        // Get the current active window scene to present the share sheet
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityViewController, animated: true)
        }
        #endif
    }
    
    /// Create a quote post (repost with comment)
    /// - Parameter text: The text for the quote
    /// - Returns: True if the operation was successful
    func createQuotePost(text: String) async throws -> Bool {
        return try await postViewModel.createQuotePost(text: text)
    }
}
