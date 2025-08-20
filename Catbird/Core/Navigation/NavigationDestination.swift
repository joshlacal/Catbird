import Foundation
import Petrel

enum NavigationDestination: Hashable {
    case profile(String)  // DID or handle
    case post(ATProtocolURI)
    case hashtag(String)
    case timeline
    case feed(ATProtocolURI)
    case list(ATProtocolURI)
    case createList
    case editList(ATProtocolURI)
    case listManager
    case listDiscovery
    case listFeed(ATProtocolURI)
    case listMembers(ATProtocolURI)
    case starterPack(ATProtocolURI)
    #if os(iOS)
    case conversation(String) // convoId
    case chatTab
    #endif
    
    func hash(into hasher: inout Hasher) {
        switch self {
        case .profile(let did):
            hasher.combine("profile")
            hasher.combine(did)
        case .post(let uri):
            hasher.combine("post")
            hasher.combine(uri.uriString())
        case .hashtag(let tag):
            hasher.combine("hashtag")
            hasher.combine(tag)
        case .timeline:
            hasher.combine("timeline")
        case .feed(let uri):
            hasher.combine("feed")
            hasher.combine(uri.uriString())
        case .list(let uri):
            hasher.combine("list")
            hasher.combine(uri.uriString())
        case .createList:
            hasher.combine("createList")
        case .editList(let uri):
            hasher.combine("editList")
            hasher.combine(uri.uriString())
        case .listManager:
            hasher.combine("listManager")
        case .listDiscovery:
            hasher.combine("listDiscovery")
        case .listFeed(let uri):
            hasher.combine("listFeed")
            hasher.combine(uri.uriString())
        case .listMembers(let uri):
            hasher.combine("listMembers")
            hasher.combine(uri.uriString())
        case .starterPack(let uri):
            hasher.combine("starterPack")
            hasher.combine(uri.uriString())
        #if os(iOS)
        case .conversation(let convoId):
            hasher.combine("conversation")
            hasher.combine(convoId)
        case .chatTab:
            hasher.combine("chatTab")
        #endif
        }
    }
    
    static func == (lhs: NavigationDestination, rhs: NavigationDestination) -> Bool {
        switch (lhs, rhs) {
        case (.profile(let lhsDid), .profile(let rhsDid)):
            return lhsDid == rhsDid
        case (.post(let lhsUri), .post(let rhsUri)):
            return lhsUri.uriString() == rhsUri.uriString()
        case (.hashtag(let lhsTag), .hashtag(let rhsTag)):
            return lhsTag == rhsTag
        case (.feed(let lhsUri), .feed(let rhsUri)):
            return lhsUri.uriString() == rhsUri.uriString()
        case (.list(let lhsUri), .list(let rhsUri)):
            return lhsUri.uriString() == rhsUri.uriString()
        case (.createList, .createList):
            return true
        case (.editList(let lhsUri), .editList(let rhsUri)):
            return lhsUri.uriString() == rhsUri.uriString()
        case (.listManager, .listManager):
            return true
        case (.listDiscovery, .listDiscovery):
            return true
        case (.listFeed(let lhsUri), .listFeed(let rhsUri)):
            return lhsUri.uriString() == rhsUri.uriString()
        case (.listMembers(let lhsUri), .listMembers(let rhsUri)):
            return lhsUri.uriString() == rhsUri.uriString()
        case (.starterPack(let lhsUri), .starterPack(let rhsUri)):
            return lhsUri.uriString() == rhsUri.uriString()
        #if os(iOS)
        case (.conversation(let lhsId), .conversation(let rhsId)):
            return lhsId == rhsId
        case (.chatTab, .chatTab):
            return true
        #endif
        case (.timeline, .timeline):
            return true
        default:
            return false
        }
    }
}
