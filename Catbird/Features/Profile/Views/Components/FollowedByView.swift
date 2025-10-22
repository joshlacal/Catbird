import SwiftUI
import NukeUI
import Petrel

struct FollowedByView: View {
    let knownFollowers: [AppBskyActorDefs.ProfileView]
    let totalFollowersCount: Int
    let profileDID: String
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var currentColorScheme
    @Binding var path: NavigationPath
    
    private let maxAvatarsToShow = 3
    private let avatarSize: CGFloat = 24
    
    var body: some View {
        if !knownFollowers.isEmpty {
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
                                    .stroke(Color.systemBackground, lineWidth: 2)
                                    .scaleEffect((avatarSize + 2) / avatarSize)
                            )
                            .zIndex(Double(maxAvatarsToShow - index))
                        }
                    }
                    
                    // Text description
                    Text(followedByText)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Navigate to known followers list when tapped
                path.append(ProfileNavigationDestination.knownFollowers(profileDID))
            }
        }
    }
    
    private var followedByText: String {
        let namedFollowers = knownFollowers.prefix(2)
        // The remaining count should be based on total known followers we have, not total followers
        let additionalKnownFollowers = max(0, knownFollowers.count - 2)
        
        if knownFollowers.count == 1 {
            let name = namedFollowers.first?.displayName ?? namedFollowers.first?.handle.description ?? "Someone"
            return "Followed by \(name)"
        } else if knownFollowers.count == 2 {
            let firstName = namedFollowers.first?.displayName ?? namedFollowers.first?.handle.description ?? "Someone"
            let secondName = Array(namedFollowers)[1].displayName ?? Array(namedFollowers)[1].handle.description ?? "Someone"
            return "Followed by \(firstName) and \(secondName)"
        } else {
            let firstName = namedFollowers.first?.displayName ?? namedFollowers.first?.handle.description ?? "Someone"
            return "Followed by \(firstName) and \(additionalKnownFollowers.formatted()) other\(additionalKnownFollowers == 1 ? "" : "s") you follow"
        }
    }
}

// #Preview {
//    let appState = AppState.shared
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
