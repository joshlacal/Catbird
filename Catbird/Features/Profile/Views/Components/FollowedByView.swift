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
                                LazyImage(url: URL(string: follower.avatar?.uriString() ?? "")) { state in
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
            .accessibilityHint("Shows followers you know")
        }
    }
    
    private var followedByText: String {
        let total = max(knownFollowersTotal, knownFollowers.count)
        let names = knownFollowers.prefix(2).map(name(for:))

        switch total {
        case 1:
            return "Followed by \(names.first ?? "someone you follow")"
        case 2 where names.count == 2:
            return "Followed by \(names[0]) and \(names[1])"
        default:
            if names.count == 2 {
                let others = total - 2
                return "Followed by \(names[0]), \(names[1]) and \(others.formatted()) other\(others == 1 ? "" : "s") you follow"
            }
            let others = max(0, total - names.count)
            let first = names.first ?? "someone"
            return "Followed by \(first) and \(others.formatted()) other\(others == 1 ? "" : "s") you follow"
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
