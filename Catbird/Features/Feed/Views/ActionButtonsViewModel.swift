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
        
        // Only pass ShareablePost which handles both URL and post data
        let activityViewController = UIActivityViewController(
            activityItems: [ShareablePost(post: post)],
            applicationActivities: [shareToChat]
        )
        
        // Customize the order of activities to show Share to Chat first
        activityViewController.completionWithItemsHandler = { activityType, completed, returnedItems, error in
            // Handle completion if needed
        }
        
        // Get the current active window scene to present the share sheet
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
           let window = windowScene.windows.first(where: { $0.isKeyWindow }),
           let rootViewController = window.rootViewController {
            
            // Find the topmost presented view controller
            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }
            
            // Configure iPad popover anchor to avoid runtime crash
            if let popover = activityViewController.popoverPresentationController {
                popover.sourceView = topController.view
                popover.sourceRect = CGRect(
                    x: topController.view.bounds.midX,
                    y: topController.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = []
            }

            topController.present(activityViewController, animated: true)
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
