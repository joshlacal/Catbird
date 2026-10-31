import Foundation

/// Canonical Settings destination plus an optional stable control anchor.
public struct SettingsRoute: RawRepresentable, Hashable, Sendable, CaseIterable {
    public let target: SettingsTarget
    public init(target: SettingsTarget) { self.target = target }
    public var rawValue: String { target.screen.rawValue + (target.control.map { "/" + $0.rawValue } ?? "") }
    public init?(rawValue: String) {
        let components = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = components.first, let screen = SettingsScreenID(rawValue: first) else { return nil }
        let control = components.count == 2 ? SettingsControlID(rawValue: components[1]) : nil
        if let control, !SettingsCatalog.entries.contains(where: { $0.target == SettingsTarget(screen: screen, control: control) }) { return nil }
        self.init(target: SettingsTarget(screen: screen, control: control))
    }
    public static var allCases: [SettingsRoute] { SettingsScreenID.allCases.map { SettingsRoute(target: .init(screen: $0)) } }
    public static let home = SettingsRoute(target: .init(screen: .home))
    public static let language = SettingsRoute(target: .init(screen: .language))
    public static let accessibility = SettingsRoute(target: .init(screen: .accessibility))
    public static let appearance = SettingsRoute(target: .init(screen: .appearance))
    public static let account = SettingsRoute(target: .init(screen: .accountSecurity))
    public static let privacyAndSecurity = SettingsRoute(target: .init(screen: .privacyInteractions))
    public static let contentAndMedia = SettingsRoute(target: .init(screen: .mediaLinks))
    public static let about = SettingsRoute(target: .init(screen: .helpAbout))
    public static let notifications = SettingsRoute(target: .init(screen: .notifications))
    public static let moderation = SettingsRoute(target: .init(screen: .moderation))
    public static let followingFeed = SettingsRoute(target: .init(screen: .feedFiltering))
    public static let savedFeeds = SettingsRoute(target: .init(screen: .feedLibrary))
    public static let interests = SettingsRoute(target: .init(screen: .interests))
    public static let appIcon = SettingsRoute(target: .init(screen: .appIcon))
    // Legacy unsupported URLs return safely to Settings, never advertise an editor.
    public static let appPasswords = home
    public static let intentControls = home

    public init?(routePath: String) {
        let clean = routePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch clean {
        case "", "app-passwords", "intent-controls", "intent": self = .home
        case "privacy-and-security/activity": self.init(target: .init(screen: .activityPrivacy))
        case "notifications/activity": self.init(target: .init(screen: .activitySubscriptions))
        case "privacy-and-security", "privacy": self = .privacyAndSecurity
        case "content-and-media", "content": self = .contentAndMedia
        case "notifications/settings": self = .notifications
        case "following-feed": self = .followingFeed
        case "saved-feeds": self = .savedFeeds
        case "app-icon": self = .appIcon
        case "external-embeds": self.init(target: .init(screen: .externalMedia))
        case "automation-label": self.init(target: .init(screen: .automationLabel))
        case "account": self = .account
        case "about": self = .about
        default:
            guard let route = SettingsRoute(rawValue: clean) else { return nil }
            self = route
        }
    }
}
