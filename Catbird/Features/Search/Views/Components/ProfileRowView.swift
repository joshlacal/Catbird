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
            HStack(alignment: .top, spacing: DesignTokens.Spacing.base) {
                // Profile avatar
                AsyncProfileImage(
                    url: profile.finalAvatarURL(),
                    size: DesignTokens.Size.avatarLG,
                    labels: extractLabels(from: profile)
                )

                // Profile info
                VStack(alignment: .leading, spacing: 2) {
                    nameLine
                    handleLine
                    descriptionText
                }
                .frame(minHeight: DesignTokens.Size.avatarLG, alignment: .top)

                Spacer(minLength: DesignTokens.Spacing.sm)

                // Follow button if logged in and not self
                if let did = currentUserDid, did != profile.did.didString() {
                    followButton()
                        .padding(.top, 2)
                }
            }
            .foregroundColor(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, DesignTokens.Spacing.base)
        .padding(.horizontal, DesignTokens.Spacing.lg)
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
    
    // MARK: - Header lines

    @ViewBuilder
    private var nameLine: some View {
        HStack(spacing: 4) {
            Text(primaryName)
                .appFont(AppTextRole.headline)
                .fontWeight(.semibold)
                .lineLimit(1)

            if let badgeKind = VerificationBadge.kind(for: profile.verification, did: profile.did) {
                VerificationBadgeView(kind: badgeKind)
                    .font(.subheadline)
            }

            if let pronouns = profile.pronouns, !pronouns.isEmpty {
                Text(pronouns)
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                    .textScale(.secondary)
                    .padding(.vertical, 1)
                    .padding(.horizontal, 5)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var handleLine: some View {
        HStack(spacing: 6) {
            Text("@\(profile.handle)")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)

            if showsFollowsBadge {
                FollowsBadgeView()
            }
        }
    }

    @ViewBuilder
    private var descriptionText: some View {
        if let profileView = profile as? AppBskyActorDefs.ProfileView,
           let description = profileView.description, !description.isEmpty {
            Text(description)
                .multilineTextAlignment(.leading)
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .padding(.top, 4)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var primaryName: String {
        let display = profile.displayName ?? ""
        if display.isEmpty {
            return "@\(profile.handle)"
        }
        return display
    }

    private var showsFollowsBadge: Bool {
        if let profileView = profile as? AppBskyActorDefs.ProfileView,
           let viewer = profileView.viewer, viewer.followedBy != nil {
            return true
        }
        if let profileViewBasic = profile as? AppBskyActorDefs.ProfileViewBasic,
           let viewer = profileViewBasic.viewer, viewer.followedBy != nil {
            return true
        }
        return false
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
                buttonLabel("Following", color: .primary, backgroundColor: Color.secondary.opacity(0.15))
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
            .appFont(AppTextRole.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(color)
            .padding(.horizontal, DesignTokens.Spacing.base)
            .padding(.vertical, 7)
            .frame(minWidth: 88)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule()
                    .strokeBorder(outlined ? Color.secondary.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Capsule())
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

#Preview("Profile Row") {
  AsyncPreviewDataContent { appState in
    await PreviewData.myProfile(from: appState)
  } content: { _, profile in
    NavigationStack {
      List {
        ProfileRowView(profile: profile, path: .constant(NavigationPath()))
      }
    }
  }
}
