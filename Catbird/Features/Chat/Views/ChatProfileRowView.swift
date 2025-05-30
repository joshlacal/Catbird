import SwiftUI
import Petrel
import NukeUI

/// Profile row view specifically designed for chat contacts
struct ChatProfileRowView: View {
    let profile: ProfileDisplayable
    var isStartingConversation: Bool = false
    var showMessageIcon: Bool = true
    var onSelect: (() -> Void)?

    @Environment(AppState.self) private var appState
    @State private var isMessageable: Bool = true

    var body: some View {
        Button {
            onSelect?()
        } label: {
            HStack(spacing: 12) {
                // Avatar
                AsyncProfileImage(url: profile.finalAvatarURL(), size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName ?? "")
                        .font(.headline)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("@\(profile.handle.description)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        if !isMessageable {
                            Text("• Chat Restricted")
                                .font(.caption)
                                .foregroundColor(.red)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                if isStartingConversation {
                    ProgressView()
                        .padding(.trailing, 4)
                } else if showMessageIcon && isMessageable {
                    Image(systemName: "message")
                        .foregroundColor(.accentColor)
                } else if !isMessageable {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
            .opacity(isMessageable ? 1.0 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(isStartingConversation || !isMessageable)
        .task {
            checkMessageability()
        }
    }

    /// Checks if the user can be messaged based on their settings and relationship with current user
    private func checkMessageability() {
        // Extract chat settings from profile's associated field
        if let profileView = profile as? AppBskyActorDefs.ProfileView {
            updateMessageabilityStatus(profileView: profileView)
        } else if let profileViewBasic = profile as? AppBskyActorDefs.ProfileViewBasic {
            updateMessageabilityStatus(profileViewBasic: profileViewBasic)
        } else {
            // Default to not messageable if we can't determine
            isMessageable = false
        }
    }

    private func updateMessageabilityStatus(profileView: AppBskyActorDefs.ProfileView) {
        // Get chat settings
        let chatSetting = profileView.associated?.chat?.allowIncoming ?? "none"
        let isFollowingMe = profileView.viewer?.followedBy != nil
        let amFollowing = profileView.viewer?.following != nil

        isMessageable = canMessage(chatSetting: chatSetting, isFollowingMe: isFollowingMe, amFollowing: amFollowing)
    }

    private func updateMessageabilityStatus(profileViewBasic: AppBskyActorDefs.ProfileViewBasic) {
        // Get chat settings
        let chatSetting = profileViewBasic.associated?.chat?.allowIncoming ?? "none"
        let isFollowingMe = profileViewBasic.viewer?.followedBy != nil
        let amFollowing = profileViewBasic.viewer?.following != nil

        isMessageable = canMessage(chatSetting: chatSetting, isFollowingMe: isFollowingMe, amFollowing: amFollowing)
    }

    private func canMessage(chatSetting: String, isFollowingMe: Bool, amFollowing: Bool) -> Bool {
        switch chatSetting {
        case "all":
            return true
        case "following":
            return isFollowingMe
        case "none", _:
            return false
        }
    }
}

// MARK: - Preview
#Preview {
    VStack {
        // Placeholder for preview
        Text("ChatProfileRowView Preview")
            .padding()
    }
}
