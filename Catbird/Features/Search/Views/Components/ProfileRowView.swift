import SwiftUI
import Petrel

/// Enhanced row view for displaying profile information in search results
struct ProfileRowView: View {
    let profile: ProfileDisplayable
    @Environment(AppState.self) private var appState
    @State private var currentUserDid: String?
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Profile avatar
            AsyncProfileImage(url: profile.finalAvatarURL(), size: 44)
            
            // Profile info
            VStack(alignment: .leading, spacing: 4) {
                    if profile.displayName?.isEmpty ?? true {
                        // Display handle if no display name
                        Text("@\(profile.handle)")
                            .font(.headline)
                            .lineLimit(1)
                    } else {
                        // Display display name if available
                        Text(profile.displayName ?? profile.handle.description)
                            .font(.headline)
                    }
                                        
                HStack {

                Text("@\(profile.handle)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    
                    // Handle "Follows you" badge if available
                    if let profileView = profile as? AppBskyActorDefs.ProfileView,
                       let viewer = profileView.viewer, viewer.followedBy != nil {
                        FollowsBadgeView()
                    } else if let profileViewBasic = profile as? AppBskyActorDefs.ProfileViewBasic,
                              let viewer = profileViewBasic.viewer, viewer.followedBy != nil {
                        FollowsBadgeView()
                    }

                }

                // Description (only available in ProfileView)
                if let profileView = profile as? AppBskyActorDefs.ProfileView,
                   let description = profileView.description, !description.isEmpty {
                    Text(description)
                        .multilineTextAlignment(.leading)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            Spacer()
            
            // Follow button if logged in and not self
            if let did = currentUserDid, did != profile.did.didString() {
                followButton()
            }
        }
        .padding(3)
//        .padding(.vertical, 12)
//        .padding(.horizontal)
        .task {
            // Fetch the DID asynchronously
            currentUserDid = try? await appState.atProtoClient?.getDid()
        }
    }
    
    // Follow button with appropriate state
    @ViewBuilder
    private func followButton() -> some View {
        // Determine button state from profile
        Group {
            if let profileView = profile as? AppBskyActorDefs.ProfileView,
               let viewer = profileView.viewer {
                buttonForViewerState(viewer)
            } else if let profileViewBasic = profile as? AppBskyActorDefs.ProfileViewBasic,
                      let viewer = profileViewBasic.viewer {
                buttonForViewerState(viewer)
            } else {
                // Default Follow button
                Button {
                    // Follow action when no viewer info
                } label: {
                    buttonLabel("Follow", color: .white, backgroundColor: .accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Helper function to generate the appropriate button based on viewer state
    @ViewBuilder
    private func buttonForViewerState(_ viewer: AppBskyActorDefs.ViewerState) -> some View {
        if viewer.blocking != nil {
            Button {
                // Unblock action
            } label: {
                buttonLabel("Blocked", color: .white, backgroundColor: .red)
            }
            .buttonStyle(.plain)
        } else if viewer.following != nil {
            Button {
                // Unfollow action
            } label: {
                buttonLabel("Following", color: .accentColor, backgroundColor: .clear, outlined: true)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                // Follow action
            } label: {
                buttonLabel("Follow", color: .white, backgroundColor: .accentColor)
            }
            .buttonStyle(.plain)
        }
    }
    
    // Reusable button label
    @ViewBuilder
    private func buttonLabel(_ text: String, color: Color, backgroundColor: Color, outlined: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(backgroundColor)
                    .overlay(
                        outlined ? Capsule().stroke(Color.accentColor, lineWidth: 1) : nil
                    )
            )
    }
}
