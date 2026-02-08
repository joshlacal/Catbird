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

#if os(iOS)
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
#endif

extension AppBskyGraphDefs.ListView {
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

extension AppBskyGraphDefs.ListViewBasic {
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

// MARK: - Array Extensions for Unique Elements

extension Array {
    /// Returns an array with duplicate elements removed based on a key path
    func uniqued<T: Hashable>(by keyPath: KeyPath<Element, T>) -> [Element] {
        var seen = Set<T>()
        return filter { element in
            let key = element[keyPath: keyPath]
            if seen.contains(key) {
                return false
            } else {
                seen.insert(key)
                return true
            }
        }
    }
}
