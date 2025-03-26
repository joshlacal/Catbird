import SwiftUI
import Petrel

/// Enhanced row view for displaying profile information in search results
struct ProfileRowView: View {
    let profile: ProfileDisplayable
    @Environment(AppState.self) private var appState
    @State private var currentUserDid: String? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            // Profile avatar
            AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 44)
            
            // Profile info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(profile.displayName ?? "@\(profile.handle)")
                        .font(.headline)
                        .lineLimit(1)
                    
                    // Handle "Follows you" badge if available
                    if let profileView = profile as? AppBskyActorDefs.ProfileView,
                       let viewer = profileView.viewer, viewer.followedBy != nil {
                        followsBadge()
                    } else if let profileViewBasic = profile as? AppBskyActorDefs.ProfileViewBasic,
                              let viewer = profileViewBasic.viewer, viewer.followedBy != nil {
                        followsBadge()
                    }
                }
                
                Text("@\(profile.handle)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                // Description (only available in ProfileView)
                if let profileView = profile as? AppBskyActorDefs.ProfileView,
                   let description = profileView.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            
            Spacer()
            
            // Follow button if logged in and not self
            if let did = currentUserDid, did != profile.did {
                followButton()
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
        .task {
            // Fetch the DID asynchronously
            currentUserDid = try? await appState.atProtoClient?.getDid()
        }
    }
    
    // "Follows you" badge
    @ViewBuilder
    private func followsBadge() -> some View {
        Text("Follows you")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.1))
            )
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
