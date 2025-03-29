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
        Button {
            Task {
                await toggleFollow()
            }
        } label: {
            Text(isFollowing ? "Following" : "Follow")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(isFollowing ? .secondary : .white)
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(
                    Capsule()
                        .fill(isFollowing ? Color.gray.opacity(0.2) : Color.accentColor)
                )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .overlay {
            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(isFollowing ? .secondary : .white)
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

