import Foundation
import Petrel

/// Fast avatar URL resolution avoiding redundant URLComponents parsing and string copying
private func resolveAvatarURL(from uri: URI?) -> URL? {
    guard let uri else { return nil }
    let rawString = uri.uriString()
    guard !rawString.isEmpty else { return nil }
    
    // Fast path: if a Bluesky CDN plain avatar, rewrite to thumbnail directly
    if rawString.contains("cdn.bsky.app") && rawString.contains("/img/avatar/plain/") {
        let rewritten = rawString.replacingOccurrences(
            of: "/img/avatar/plain/",
            with: "/img/avatar_thumbnail/plain/"
        )
        return URL(string: rewritten)
    }
    return uri.url ?? URL(string: rawString)
}

extension AppBskyActorDefs.ProfileViewBasic {
    /// Returns the final avatar URL, modifying it if necessary.
    func finalAvatarURL() -> URL? {
        resolveAvatarURL(from: self.avatar)
    }
}

extension AppBskyActorDefs.ProfileView {
    func finalAvatarURL() -> URL? {
        resolveAvatarURL(from: self.avatar)
    }
}

extension AppBskyActorDefs.ProfileViewDetailed {
    func finalAvatarURL() -> URL? {
        resolveAvatarURL(from: self.avatar)
    }
}

extension ChatBskyActorDefs.ProfileViewBasic {
    func finalAvatarURL() -> URL? {
        resolveAvatarURL(from: self.avatar)
    }
}

extension AppBskyGraphDefs.ListView {
    func finalAvatarURL() -> URL? {
        resolveAvatarURL(from: self.avatar)
    }
}

extension AppBskyGraphDefs.ListViewBasic {
    func finalAvatarURL() -> URL? {
        resolveAvatarURL(from: self.avatar)
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
