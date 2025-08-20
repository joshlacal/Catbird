import SwiftUI
import Petrel
import NukeUI

#if os(iOS)

/// Profile row view specifically designed for chat contacts
struct ChatProfileRowView: View {
    let profile: ProfileDisplayable
    var isStartingConversation: Bool = false
    var showMessageIcon: Bool = true
    var onSelect: (() -> Void)?

    @Environment(AppState.self) private var appState
    @State private var isMessageable: Bool?
    @State private var isCheckingAvailability: Bool = false

    var body: some View {
        Button {
            onSelect?()
        } label: {
            HStack(spacing: 12) {
                // Avatar
                AsyncProfileImage(url: profile.finalAvatarURL(), size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName ?? "")
                        .appFont(AppTextRole.headline)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("@\(profile.handle.description)")
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        if isMessageable == false {
                            Text("• Chat Restricted")
                                .appFont(AppTextRole.caption)
                                .foregroundColor(.red)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                if isStartingConversation {
                    ProgressView()
                        .padding(.trailing, 4)
                } else if isCheckingAvailability {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.trailing, 4)
                } else if showMessageIcon && (isMessageable ?? true) {
                    Image(systemName: "message")
                        .foregroundColor(.accentColor)
                } else if isMessageable == false {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary)
                        .appFont(AppTextRole.caption)
                }
            }
            .contentShape(Rectangle())
            .opacity((isMessageable ?? true) ? 1.0 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(isStartingConversation || isMessageable == false)
        .task {
            await checkMessageability()
        }
    }

    /// Checks if the user can be messaged using authoritative server-side check
    private func checkMessageability() async {
        // First do a quick local check to avoid unnecessary server calls
        let localCheck = performLocalMessageabilityCheck()
        
        // If local check says definitely not messageable, don't bother with server check
        if localCheck == false {
            isMessageable = false
            return
        }
        
        // For potential messageability, verify with server
        await performServerMessageabilityCheck()
    }
    
    /// Performs local heuristic check for obvious non-messageability cases
    private func performLocalMessageabilityCheck() -> Bool? {
        // Check if chat is explicitly disabled for this profile
        if let profileView = profile as? AppBskyActorDefs.ProfileView {
            // Check if chat is available via associated chat settings
            
            let chatSetting = profileView.associated?.chat?.allowIncoming ?? "all"
            let profileFollowsMe = profileView.viewer?.followedBy != nil
            
            return canMessageLocally(chatSetting: chatSetting, profileFollowsMe: profileFollowsMe)
            
        } else if let profileViewBasic = profile as? AppBskyActorDefs.ProfileViewBasic {
            // Check if chat is available via associated chat settings
            
            let chatSetting = profileViewBasic.associated?.chat?.allowIncoming ?? "all"
            let profileFollowsMe = profileViewBasic.viewer?.followedBy != nil
            
            return canMessageLocally(chatSetting: chatSetting, profileFollowsMe: profileFollowsMe)
            
        } else if let chatProfile = profile as? ChatBskyActorDefs.ProfileViewBasic {
            // Chat disabled takes precedence
            if chatProfile.chatDisabled == true {
                return false
            }
            
            let chatSetting = chatProfile.associated?.chat?.allowIncoming ?? "all"
            let profileFollowsMe = chatProfile.viewer?.followedBy != nil
            
            return canMessageLocally(chatSetting: chatSetting, profileFollowsMe: profileFollowsMe)
        }
        
        // If we can't determine from profile type, assume messageable but verify with server
        return nil
    }
    
    /// Performs authoritative server-side messageability check
    private func performServerMessageabilityCheck() async {
        guard let chatManager = appState.chatManager as ChatManager?,
              let currentUserDID = try? await chatManager.client?.getDid() else {
            // If no chat manager or client, assume not messageable
            isMessageable = false
            return
        }
        
        // Extract profile DID
        let profileDID: String
        if let profileView = profile as? AppBskyActorDefs.ProfileView {
            profileDID = profileView.did.didString()
        } else if let profileViewBasic = profile as? AppBskyActorDefs.ProfileViewBasic {
            profileDID = profileViewBasic.did.didString()
        } else if let chatProfile = profile as? ChatBskyActorDefs.ProfileViewBasic {
            profileDID = chatProfile.did.didString()
        } else {
            isMessageable = false
            return
        }
        
        // Don't check messaging yourself
        if profileDID == currentUserDID {
            isMessageable = false
            return
        }
        
        isCheckingAvailability = true
        
        // Use the authoritative server check
        let (canChat, _) = await chatManager.checkConversationAvailability(members: [currentUserDID, profileDID])
        
        isCheckingAvailability = false
        isMessageable = canChat
    }

    /// Local heuristic check based on chat settings and follow relationships
    private func canMessageLocally(chatSetting: String, profileFollowsMe: Bool) -> Bool? {
        switch chatSetting {
        case "all":
            return true
        case "following":
            // User's setting is "following" - only people they follow can message them
            // So we need to check if this profile follows the current user
            return profileFollowsMe
        case "none":
            return false
        default:
            // Unknown setting, let server decide
            return nil
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
#endif
