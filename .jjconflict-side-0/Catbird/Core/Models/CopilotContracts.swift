import Foundation

enum CopilotContext: Codable, Hashable, Sendable {
    case topic(name: String, description: String?, link: String)
    case post(uri: String, cid: String?, authorDID: String, text: String)
    case thread(anchorURI: String)
    case profile(did: String, handle: String, displayName: String?)
    case feed(uri: String?, name: String)
    case search(query: String)
    case smartFilter(id: UUID, name: String)

    var promptDescription: String {
        switch self {
        case .topic(let name, let description, let link):
            return "Trending topic: \(name)\nService description: \(description ?? "Unavailable")\nLink: \(link)"
        case .post(let uri, let cid, let authorDID, let text):
            return "Post: \(uri)\nCID: \(cid ?? "Unavailable")\nAuthor DID: \(authorDID)\nAuthored text: \(text)"
        case .thread(let anchorURI):
            return "Thread anchor: \(anchorURI)"
        case .profile(let did, let handle, let displayName):
            return "Profile: @\(handle) (\(displayName ?? handle))\nDID: \(did)"
        case .feed(let uri, let name):
            return "Feed: \(name)\nURI: \(uri ?? "Home")"
        case .search(let query):
            return "Search query: \(query)"
        case .smartFilter(let id, let name):
            return "Smart filter: \(name)\nFilter ID: \(id.uuidString)"
        }
    }

    func matchesHistoryContext(_ other: CopilotContext) -> Bool {
        switch (self, other) {
        case (.post(let uri1, let cid1, let authorDID1, _), .post(let uri2, let cid2, let authorDID2, _)):
            guard uri1 == uri2, authorDID1 == authorDID2 else { return false }
            if let cid1, let cid2 {
                return cid1 == cid2
            }
            return true
        default:
            return self == other
        }
    }
}

enum CopilotModelRoute: String, Codable, Sendable {
    case onDevice
    case privateCloudCompute
}

enum CopilotProposalDisposition: String, Codable, Hashable, Sendable {
    case inlineConfirmation
    case dedicatedFlow
}

enum CopilotProposal: Codable, Hashable, Identifiable, Sendable {
    case followActor(actorDID: String)
    case unfollowActor(actorDID: String)
    case muteActor(actorDID: String)
    case unmuteActor(actorDID: String)
    case blockActor(actorDID: String)
    case unblockActor(actorDID: String)
    case reportActor(actorDID: String)
    case addActorToList(actorDID: String)
    case likePost(uri: String, cid: String)
    case unlikePost(uri: String, cid: String)
    case repostPost(uri: String, cid: String)
    case unrepostPost(uri: String, cid: String)
    case bookmarkPost(uri: String, cid: String)
    case unbookmarkPost(uri: String, cid: String)
    case hidePost(uri: String, cid: String)
    case unhidePost(uri: String, cid: String)
    case prepareReply(uri: String, cid: String, text: String)
    case prepareQuote(uri: String, cid: String, text: String)
    case reportPost(uri: String, cid: String)
    case deletePost(uri: String, cid: String)
    case muteThread(uri: String)
    case unmuteThread(uri: String)
    case saveFeed(uri: String)
    case unsaveFeed(uri: String)
    case pinFeed(uri: String)
    case unpinFeed(uri: String)
    case createSmartFilter(FeedFilterRule)
    case setSmartFilterEnabled(id: UUID, enabled: Bool)
    case preparePostDraft(text: String)

    var disposition: CopilotProposalDisposition {
        switch self {
        case .followActor,
             .unfollowActor,
             .muteActor,
             .unmuteActor,
             .likePost, .unlikePost,
             .repostPost, .unrepostPost,
             .bookmarkPost, .unbookmarkPost,
             .hidePost, .unhidePost,
             .muteThread, .unmuteThread,
             .saveFeed, .unsaveFeed,
             .pinFeed, .unpinFeed,
             .createSmartFilter,
             .setSmartFilterEnabled:
            return .inlineConfirmation
        case .blockActor, .unblockActor,
             .reportActor, .addActorToList,
             .prepareReply, .prepareQuote,
             .reportPost, .deletePost,
             .preparePostDraft:
            return .dedicatedFlow
        }
    }

    var id: String {
        switch self {
        case .followActor(let value): "follow:\(value)"
        case .unfollowActor(let value): "unfollow:\(value)"
        case .muteActor(let value): "mute:\(value)"
        case .unmuteActor(let value): "unmute:\(value)"
        case .blockActor(let value): "block:\(value)"
        case .unblockActor(let value): "unblock:\(value)"
        case .reportActor(let value): "report-actor:\(value)"
        case .addActorToList(let value): "add-to-list:\(value)"
        case .likePost(let uri, let cid): "like:\(uri):\(cid)"
        case .unlikePost(let uri, let cid): "unlike:\(uri):\(cid)"
        case .repostPost(let uri, let cid): "repost:\(uri):\(cid)"
        case .unrepostPost(let uri, let cid): "unrepost:\(uri):\(cid)"
        case .bookmarkPost(let uri, let cid): "bookmark:\(uri):\(cid)"
        case .unbookmarkPost(let uri, let cid): "unbookmark:\(uri):\(cid)"
        case .hidePost(let uri, let cid): "hide:\(uri):\(cid)"
        case .unhidePost(let uri, let cid): "unhide:\(uri):\(cid)"
        case .prepareReply(let uri, let cid, let text): "reply:\(uri):\(cid):\(text)"
        case .prepareQuote(let uri, let cid, let text): "quote:\(uri):\(cid):\(text)"
        case .reportPost(let uri, let cid): "report-post:\(uri):\(cid)"
        case .deletePost(let uri, let cid): "delete-post:\(uri):\(cid)"
        case .muteThread(let value): "mute-thread:\(value)"
        case .unmuteThread(let value): "unmute-thread:\(value)"
        case .saveFeed(let value): "save-feed:\(value)"
        case .unsaveFeed(let value): "unsave-feed:\(value)"
        case .pinFeed(let value): "pin-feed:\(value)"
        case .unpinFeed(let value): "unpin-feed:\(value)"
        case .createSmartFilter(let rule): "smart-filter:\(rule.id)"
        case .setSmartFilterEnabled(let id, let enabled): "filter:\(id):\(enabled)"
        case .preparePostDraft(let text): "draft:\(text)"
        }
    }
}

struct CopilotConversation: Codable, Identifiable, Sendable {
    let id: UUID
    let accountDID: String
    let context: CopilotContext
    var turns: [CopilotStoredTurn]
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        accountDID: String,
        context: CopilotContext,
        turns: [CopilotStoredTurn] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountDID = accountDID
        self.context = context
        self.turns = turns
        self.updatedAt = updatedAt
    }
}

struct CopilotSource: Codable, Hashable, Sendable {
    let label: String
    let uri: String?

    init(label: String, uri: String? = nil) {
        self.label = label
        self.uri = uri
    }
}

struct CopilotStoredTurn: Codable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date
    var tokenCount: Int?
    var route: CopilotModelRoute?
    var proposal: CopilotProposal?
    var sources: [CopilotSource]?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        tokenCount: Int? = nil,
        route: CopilotModelRoute? = nil,
        proposal: CopilotProposal? = nil,
        sources: [CopilotSource]? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.tokenCount = tokenCount
        self.route = route
        self.proposal = proposal
        self.sources = sources
    }
}

enum CopilotTurnEvent: Sendable {
    case textDelta(String)
    case responseReset
    case source(CopilotSource)
    case proposal(CopilotProposal)
    case route(CopilotModelRoute)
    case contextTrimmed(removedTurnCount: Int)
    case completed
    case failed(String)
}
