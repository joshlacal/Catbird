import Foundation

public enum SettingsRoute: String, Hashable, Sendable, CaseIterable {
    case language = "language"
    case accessibility = "accessibility"
    case appearance = "appearance"
    case account = "account"
    case privacyAndSecurity = "privacy-and-security"
    case contentAndMedia = "content-and-media"
    case about = "about"
    case notifications = "notifications"
    case moderation = "moderation"
    case followingFeed = "following-feed"
    case savedFeeds = "saved-feeds"
    case appPasswords = "app-passwords"
    case interests = "interests"
    case appIcon = "app-icon"
    case intentControls = "intent-controls"

    public init?(routePath: String) {
        let clean = routePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch clean {
        case "language":
            self = .language
        case "accessibility":
            self = .accessibility
        case "appearance":
            self = .appearance
        case "account":
            self = .account
        case "privacy-and-security", "privacy", "privacy-and-security/activity":
            self = .privacyAndSecurity
        case "content-and-media", "content":
            self = .contentAndMedia
        case "about":
            self = .about
        case "notifications", "notifications/settings", "notifications/activity":
            self = .notifications
        case "moderation":
            self = .moderation
        case "following-feed":
            self = .followingFeed
        case "saved-feeds":
            self = .savedFeeds
        case "app-passwords":
            self = .appPasswords
        case "interests":
            self = .interests
        case "app-icon":
            self = .appIcon
        case "intent-controls", "intent":
            self = .intentControls
        default:
            if let match = SettingsRoute(rawValue: clean) {
                self = match
            } else {
                return nil
            }
        }
    }
}
