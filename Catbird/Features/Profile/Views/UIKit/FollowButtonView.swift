import SwiftUI
import Petrel
import os

// MARK: - Follow Button SwiftUI View
struct FollowButtonView: View {
  let profile: AppBskyActorDefs.ProfileViewDetailed
  let viewModel: ProfileViewModel
  let appState: AppState
  
  @State private var isFollowButtonLoading = false
  @State private var localIsFollowing: Bool = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "FollowButton")
  
  var body: some View {
    Group {
      if viewModel.isCurrentUser {
        editProfileButton
      } else {
        followButton
      }
    }
    .onAppear {
      localIsFollowing = profile.viewer?.following != nil
    }
    .onChange(of: profile) { _, newProfile in
      localIsFollowing = newProfile.viewer?.following != nil
    }
  }
  
  private var editProfileButton: some View {
    Button("Edit Profile") {
      // Handle edit profile action
    }
    .buttonStyle(.bordered)
    .foregroundColor(.accentColor)
  }
  
  @ViewBuilder
  private var followButton: some View {
    if isFollowButtonLoading {
      ProgressView()
        .scaleEffect(0.8)
        .frame(width: 80, height: 36)
    } else if profile.viewer?.blocking != nil {
      Button("Blocked") {
        // Handle unblock
      }
      .buttonStyle(.bordered)
      .foregroundColor(.red)
      .disabled(true)
    } else if localIsFollowing {
      Button("Following") {
        handleUnfollow()
      }
      .buttonStyle(.bordered)
      .foregroundColor(.accentColor)
    } else {
      Button("Follow") {
        handleFollow()
      }
      .buttonStyle(.borderedProminent)
    }
  }
  
  private func handleFollow() {
    guard !isFollowButtonLoading else { return }
    
    Task {
      isFollowButtonLoading = true
      localIsFollowing = true // Optimistic update
      
      do {
        let success = try await appState.follow(did: profile.did.didString())
        if success {
          try? await Task.sleep(for: .seconds(0.5))
          await viewModel.loadProfile()
        } else {
          localIsFollowing = false // Revert on failure
        }
      } catch {
        localIsFollowing = false // Revert on error
        logger.error("Follow failed: \(error.localizedDescription, privacy: .public)")
      }
      
      isFollowButtonLoading = false
    }
  }
  
  private func handleUnfollow() {
    guard !isFollowButtonLoading else { return }
    
    Task {
      isFollowButtonLoading = true
      localIsFollowing = false // Optimistic update
      
      do {
        let success = try await appState.unfollow(did: profile.did.didString())
        if success {
          try? await Task.sleep(for: .seconds(0.5))
          await viewModel.loadProfile()
        } else {
          localIsFollowing = true // Revert on failure
        }
      } catch {
        localIsFollowing = true // Revert on error
        logger.error("Unfollow failed: \(error.localizedDescription, privacy: .public)")
      }
      
      isFollowButtonLoading = false
    }
  }
}