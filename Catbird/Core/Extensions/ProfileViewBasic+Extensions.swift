import Foundation
import Petrel

extension AppBskyActorDefs.ProfileViewBasic {
    /// Returns the final avatar URL, modifying it if necessary.
    func finalAvatarURL() -> URL? {
        guard let avatarURLString = self.avatar?.uriString(),
              let avatarURL = URL(string: avatarURLString) else { return nil }
        
        // Modify the URL if it matches specific criteria
        if avatarURL.host == "cdn.bsky.app" && avatarURL.path.contains("/img/avatar/plain/") {
            let finalURLString = avatarURLString.replacingOccurrences(of: "/img/avatar/plain/", with: "/img/avatar_thumbnail/plain/")
            return URL(string: finalURLString)
        } else {
            return avatarURL
        }
    }
    
}

extension AppBskyActorDefs.ProfileView {
    func finalAvatarURL() -> URL? {
        guard let avatarURLString = self.avatar?.uriString(),
              let avatarURL = URL(string: avatarURLString) else { return nil }
        
        // Modify the URL if it matches specific criteria
        if avatarURL.host == "cdn.bsky.app" && avatarURL.path.contains("/img/avatar/plain/") {
            let finalURLString = avatarURLString.replacingOccurrences(of: "/img/avatar/plain/", with: "/img/avatar_thumbnail/plain/")
            return URL(string: finalURLString)
        } else {
            return avatarURL
        }
    }

}

extension AppBskyActorDefs.ProfileViewDetailed {
    func finalAvatarURL() -> URL? {
        guard let avatarURLString = self.avatar?.uriString(),
              let avatarURL = URL(string: avatarURLString) else { return nil }
        
        // Modify the URL if it matches specific criteria
        if avatarURL.host == "cdn.bsky.app" && avatarURL.path.contains("/img/avatar/plain/") {
            let finalURLString = avatarURLString.replacingOccurrences(of: "/img/avatar/plain/", with: "/img/avatar_thumbnail/plain/")
            return URL(string: finalURLString)
        } else {
            return avatarURL
        }
    }

}

extension ChatBskyActorDefs.ProfileViewBasic {
    func finalAvatarURL() -> URL? {
        guard let avatarURLString = self.avatar?.uriString(),
              let avatarURL = URL(string: avatarURLString) else { return nil }
        
        // Modify the URL if it matches specific criteria
        if avatarURL.host == "cdn.bsky.app" && avatarURL.path.contains("/img/avatar/plain/") {
            let finalURLString = avatarURLString.replacingOccurrences(of: "/img/avatar/plain/", with: "/img/avatar_thumbnail/plain/")
            return URL(string: finalURLString)
        } else {
            return avatarURL
        }
    }

}
