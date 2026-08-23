import Foundation

enum CopilotContext: Codable, Hashable, Sendable {
    case topic(name: String, description: String?, link: String)
    case post(uri: String, authorDID: String, text: String)
    case thread(anchorURI: String)
    case profile(did: String, handle: String, displayName: String?)
    case feed(uri: String?, name: String)
    case search(query: String)

    var promptDescription: String {
        switch self {
        case .topic(let name, let description, let link):
            return "Trending topic: \(name)\nService description: \(description ?? "Unavailable")\nLink: \(link)"
        case .post(let uri, let authorDID, let text):
            return "Post: \(uri)\nAuthor DID: \(authorDID)\nAuthored text: \(text)"
        case .thread(let anchorURI):
            return "Thread anchor: \(anchorURI)"
        case .profile(let did, let handle, let displayName):
            return "Profile: @\(handle) (\(displayName ?? handle))\nDID: \(did)"
        case .feed(let uri, let name):
            return "Feed: \(name)\nURI: \(uri ?? "Home")"
        case .search(let query):
            return "Search query: \(query)"
        }
    }
}

enum CopilotModelRoute: String, Codable, Sendable {
    case onDevice
    case privateCloudCompute
}

enum CopilotProposal: Codable, Hashable, Identifiable, Sendable {
    case follow(actorDID: String)
    case unfollow(actorDID: String)
    case mute(actorDID: String)
    case unmute(actorDID: String)
    case muteThread(uri: String)
    case saveFeed(uri: String)
    case unsaveFeed(uri: String)
    case createSmartFilter(FeedFilterRule)
    case toggleSmartFilter(id: UUID, enabled: Bool)
    case preparePostDraft(text: String)

    var id: String {
        switch self {
        case .follow(let value): "follow:\(value)"
        case .unfollow(let value): "unfollow:\(value)"
        case .mute(let value): "mute:\(value)"
        case .unmute(let value): "unmute:\(value)"
        case .muteThread(let value): "mute-thread:\(value)"
        case .saveFeed(let value): "save-feed:\(value)"
        case .unsaveFeed(let value): "unsave-feed:\(value)"
        case .createSmartFilter(let rule): "smart-filter:\(rule.id)"
        case .toggleSmartFilter(let id, let enabled): "toggle-filter:\(id):\(enabled)"
        case .preparePostDraft(let text): "draft:\(text.hashValue)"
        }
    }
}

struct CopilotConversation: Codable, Identifiable, Sendable {
    let id: UUID
    let accountDID: String
    let context: CopilotContext
    var turns: [CopilotStoredTurn]
    var updatedAt: Date
}

struct CopilotStoredTurn: Codable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    let createdAt: Date
}

enum CopilotTurnEvent: Sendable {
    case textDelta(String)
    case source(label: String, uri: String?)
    case proposal(CopilotProposal)
    case route(CopilotModelRoute)
    case completed
    case failed(String)
}
