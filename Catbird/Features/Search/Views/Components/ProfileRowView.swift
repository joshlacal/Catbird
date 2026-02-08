import SwiftUI
import Petrel

/// Enhanced row view for displaying profile information in search results
struct ProfileRowView: View {
    let profile: ProfileDisplayable
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    @State private var currentUserDid: String?
    @State private var viewerStatus: ViewerStatus = .unknown
    
    private enum ViewerStatus {
        case unknown
        case notFollowing
        case following
        case blocking
    }
    
    var body: some View {
        Button(action: {
            path.append(NavigationDestination.profile(profile.did.didString()))
        }) {
            HStack(alignment: .top, spacing: 12) {
                // Profile avatar
                AsyncProfileImage(
                    url: profile.finalAvatarURL(),
                    size: 44,
                    labels: extractLabels(from: profile)
                )
                
                // Profile info
                VStack(alignment: .leading, spacing: 4) {
                    if profile.displayName?.isEmpty ?? true {
                        // Display handle if no display name
                        HStack(spacing: 4) {
                            
                        Text("@\(profile.handle)")
                            .appFont(AppTextRole.headline)
                            .lineLimit(1)
                        
                        if let pronouns = profile.pronouns, !pronouns.isEmpty {
                            Text("\(pronouns)")
                                .appFont(AppTextRole.subheadline)
                                .foregroundColor(.secondary)
                                .opacity(0.9)
                                .textScale(.secondary)
                                .padding(2)
                                .padding(.top, 2)
                                .padding(.bottom, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.secondary.opacity(0.1))
                                )
                            
                            
                        }
                    }
                        } else {
                            // Display display name if available
                            HStack(spacing: 4) {
                                Text(profile.displayName ?? profile.handle.description)
                                    .appFont(AppTextRole.headline)

                                if profile.verification?.verifiedStatus == "valid" {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.blue)
                                        .font(.caption)
                                }
                                
                                if let pronouns = profile.pronouns, !pronouns.isEmpty {
                                    Text("\(pronouns)")
                                        .appFont(AppTextRole.subheadline)
                                        .foregroundColor(.secondary)
                                        .opacity(0.9)
                                        .textScale(.secondary)
                                        .padding(1)
                                        .padding(.horizontal, 4)
                                        .padding(.bottom, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.secondary.opacity(0.1))
                                        )


                                }

                            }
                        }
                                            
                    HStack {
                        Text("@\(profile.handle)")
                            .appFont(AppTextRole.subheadline)
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
                            .appFont(AppTextRole.caption)
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
            .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .task {
            // Fetch the DID asynchronously
            currentUserDid = try? await appState.atProtoClient?.getDid()
            
            // Initialize viewer status
            if viewerStatus == .unknown {
                viewerStatus = getInitialViewerStatus()
            }
        }
        .onChange(of: profile.did) { _, _ in
            viewerStatus = getInitialViewerStatus()
        }
    }
    
    // Follow button with appropriate state
    @ViewBuilder
    private func followButton() -> some View {
        switch viewerStatus {
        case .blocking:
            Button {
                Task {
                    let previous = viewerStatus
                    viewerStatus = .notFollowing
                    do {
                        _ = try await appState.unblock(did: profile.did.didString())
                    } catch {
                        viewerStatus = previous
                    }
                }
            } label: {
                buttonLabel("Blocked", color: .white, backgroundColor: .red)
            }
            .buttonStyle(.plain)
            
        case .following:
            Button {
                Task {
                    let previous = viewerStatus
                    viewerStatus = .notFollowing
                    do {
                        _ = try await appState.unfollow(did: profile.did.didString())
                    } catch {
                        viewerStatus = previous
                    }
                }
            } label: {
                buttonLabel("Following", color: .accentColor, backgroundColor: .clear, outlined: true)
            }
            .buttonStyle(.plain)
            
        case .notFollowing, .unknown:
            Button {
                Task {
                    let previous = viewerStatus
                    viewerStatus = .following
                    do {
                        _ = try await appState.follow(did: profile.did.didString())
                    } catch {
                        viewerStatus = previous
                    }
                }
            } label: {
                buttonLabel("Follow", color: .white, backgroundColor: .accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private func getInitialViewerStatus() -> ViewerStatus {
        var viewer: AppBskyActorDefs.ViewerState?
        
        if let profileView = profile as? AppBskyActorDefs.ProfileView {
            viewer = profileView.viewer
        } else if let profileViewBasic = profile as? AppBskyActorDefs.ProfileViewBasic {
            viewer = profileViewBasic.viewer
        } else if let profileViewDetailed = profile as? AppBskyActorDefs.ProfileViewDetailed {
            viewer = profileViewDetailed.viewer
        }
        
        guard let viewer = viewer else { return .notFollowing }
        
        if viewer.blocking != nil { return .blocking }
        if viewer.following != nil { return .following }
        return .notFollowing
    }
    
    // Reusable button label
    @ViewBuilder
    private func buttonLabel(_ text: String, color: Color, backgroundColor: Color, outlined: Bool = false) -> some View {
        Text(text)
            .appFont(AppTextRole.caption)
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
    
    private func extractLabels(from profile: ProfileDisplayable) -> [ComAtprotoLabelDefs.Label]? {
        if let profileView = profile as? AppBskyActorDefs.ProfileView {
            return profileView.labels
        } else if let profileViewBasic = profile as? AppBskyActorDefs.ProfileViewBasic {
            return profileViewBasic.labels
        } else if let profileViewDetailed = profile as? AppBskyActorDefs.ProfileViewDetailed {
            return profileViewDetailed.labels
        }
        return nil
    }
}
