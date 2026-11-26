//
//  EnhancedFollowButton.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel
import OSLog

/// A modernized follow button that uses the GraphManager
struct EnhancedFollowButton: View {
    let profile: AppBskyActorDefs.ProfileView
    @Environment(AppState.self) private var appState
    @State private var isFollowing = false
    @State private var isLoading = false
    private let logger = Logger(subsystem: "blue.catbird", category: "EnhancedFollowButton")
    
    var body: some View {
        FollowButton(
            state: isFollowing ? .following : .notFollowing,
            isLoading: isLoading,
            size: .compact
        ) {
            guard !isLoading else { return }
            Task {
                await toggleFollow()
            }
        }
        .onAppear {
            // Check if already following
            isFollowing = profile.viewer?.following != nil
        }
    }
    
    private func toggleFollow() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            if isFollowing {
                try await appState.unfollow(did: profile.did.didString())
                isFollowing = false
            } else {
                try await appState.follow(did: profile.did.didString())
                isFollowing = true
            }
        } catch {
            logger.error("Error toggling follow: \(error.localizedDescription)")
        }
    }
}

#Preview("Follow Button") {
  AsyncPreviewDataContent { appState in
    await PreviewData.suggestedProfiles(from: appState).first
  } content: { _, profile in
    EnhancedFollowButton(profile: profile)
  }
}
