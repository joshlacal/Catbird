import SwiftUI
import NukeUI
import Petrel

struct FollowedByView: View {
    let knownFollowers: [AppBskyActorDefs.ProfileView]
    /// Total number of followers the viewer also follows (may exceed the loaded page).
    let knownFollowersTotal: Int
    let totalFollowersCount: Int
    let profileDID: String
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var currentColorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    @Binding var path: NavigationPath
    
    private let maxAvatarsToShow = 3
    private let avatarSize: CGFloat = 24
    
    var body: some View {
        if !knownFollowers.isEmpty {
            Button {
                // Navigate to known followers list when tapped
                path.append(ProfileNavigationDestination.knownFollowers(profileDID))
            } label: {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        // Avatar stack
                        HStack(spacing: -8) {
                            ForEach(Array(knownFollowers.prefix(maxAvatarsToShow).enumerated()), id: \.element.did) { index, follower in
                                let avatarURL = follower.avatar.flatMap { URL(string: $0.uriString()) }
                                LazyImage(request: ImageRequestFactory.avatar(avatarURL, pointSize: avatarSize, scale: displayScale)) { state in
                                    if let image = state.image {
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Circle().fill(Color.secondary.opacity(0.3))
                                    }
                                }
                                .frame(width: avatarSize, height: avatarSize)
                                .clipShape(Circle())
                                .background(
                                    Circle()
                                        .stroke(Color.dynamicBackground(appState.themeManager, currentScheme: currentColorScheme), lineWidth: 2)
                                        .scaleEffect((avatarSize + 2) / avatarSize)
                                )
                                .zIndex(Double(maxAvatarsToShow - index))
                            }
                        }
                        .padding(.trailing, DesignTokens.Spacing.xs)
                        .accessibilityHidden(true)
                        
                        // Text description
                        Text(followedByText)
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Spacer()
                    }
                    .padding(.top, DesignTokens.Spacing.base)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Shows followers you know", comment: "Accessibility hint for the mutual followers summary row on a profile."))
        }
    }
    
    private var followedByText: String {
        let total = max(knownFollowersTotal, knownFollowers.count)
        let names = knownFollowers.prefix(2).map(name(for:))

        switch total {
        case 1:
            if let first = names.first {
                return String(
                    localized: "Followed by \(first)",
                    locale: locale,
                    comment: "Profile mutual followers summary for 1 person — %1$@ is the follower's display name or @handle."
                )
            }
            return String(
                localized: "Followed by someone you follow",
                locale: locale,
                comment: "Profile mutual followers summary when followed by 1 person you follow whose name is unavailable."
            )
        case 2 where names.count == 2:
            return String(
                localized: "Followed by \(names[0]) and \(names[1])",
                locale: locale,
                comment: "Profile mutual followers summary for 2 people — %1$@ is the first follower's name, %2$@ is the second follower's name."
            )
        default:
            if names.count == 2 {
                let others = total - 2
                return String(
                    localized: "Followed by \(names[0]), \(names[1]) and \(others) others you follow",
                    locale: locale,
                    comment: "Profile mutual followers summary — %1$@ is the first follower's name, %2$@ is the second follower's name, %3$lld is the count of additional mutual followers."
                )
            }
            let others = max(0, total - names.count)
            if let first = names.first {
                return String(
                    localized: "Followed by \(first) and \(others) others you follow",
                    locale: locale,
                    comment: "Profile mutual followers summary — %1$@ is the first follower's name, %2$lld is the count of additional mutual followers."
                )
            }
            return String(
                localized: "Followed by \(others) people you follow",
                locale: locale,
                comment: "Profile mutual followers summary when names are unavailable — %1$lld is the count of mutual followers."
            )
        }
    }

    private func name(for follower: AppBskyActorDefs.ProfileView) -> String {
        if let displayName = follower.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            return displayName
        }
        return "@\(follower.handle.description)"
    }
}

// #Preview {
//    @Previewable @Environment(AppState.self) var appState
//    let appState = appState
//    
//    // Create mock followers for preview
//    let mockFollowers = [
//        AppBskyActorDefs.ProfileView(
//            did: try! DID(didString: "did:plc:example1"),
//            handle: try! Handle(handleString: "alice.bsky.social"),
//            displayName: "Alice Smith",
//            description: nil,
//            avatar: nil,
//            associated: nil,
//            viewer: nil,
//            labels: [],
//            createdAt: nil
//        ),
//        AppBskyActorDefs.ProfileView(
//            did: try! DID(didString: "did:plc:example2"),
//            handle: try! Handle(handleString: "bob.bsky.social"),
//            displayName: "Bob Johnson",
//            description: nil,
//            avatar: nil,
//            associated: nil,
//            viewer: nil,
//            labels: [],
//            createdAt: nil
//        )
//    ]
//    
//    VStack {
//        FollowedByView(
//            knownFollowers: mockFollowers,
//            totalFollowersCount: 150,
//            profileDID: "did:plc:example",
//            path: .constant(NavigationPath())
//        )
//        .padding()
//        
//        Spacer()
//    }
//    .environment(appState)
// }
