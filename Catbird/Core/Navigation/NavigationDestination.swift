import Foundation
import Petrel

enum NavigationDestination: Hashable {
    case profile(String)  // DID or handle
    case post(ATProtocolURI)
    case hashtag(String)
    case timeline
    case feed(ATProtocolURI)
    case list(ATProtocolURI)
    case starterPack(ATProtocolURI)
    case conversation(String) // convoId
    case chatTab
    case repositoryBrowser
    case repositoryDetail(UUID) // RepositoryRecord ID
    case migrationWizard
    case migrationProgress(UUID) // MigrationOperation ID
    
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
        case .starterPack(let uri):
            hasher.combine("starterPack")
            hasher.combine(uri.uriString())
        case .conversation(let convoId):
            hasher.combine("conversation")
            hasher.combine(convoId)
        case .chatTab:
            hasher.combine("chatTab")
        case .repositoryBrowser:
            hasher.combine("repositoryBrowser")
        case .repositoryDetail(let id):
            hasher.combine("repositoryDetail")
            hasher.combine(id)
        case .migrationWizard:
            hasher.combine("migrationWizard")
        case .migrationProgress(let id):
            hasher.combine("migrationProgress")
            hasher.combine(id)
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
        case (.starterPack(let lhsUri), .starterPack(let rhsUri)):
            return lhsUri.uriString() == rhsUri.uriString()
        case (.conversation(let lhsId), .conversation(let rhsId)):
            return lhsId == rhsId
        case (.chatTab, .chatTab):
            return true
        case (.timeline, .timeline):
            return true
        case (.repositoryBrowser, .repositoryBrowser):
            return true
        case (.repositoryDetail(let lhsId), .repositoryDetail(let rhsId)):
            return lhsId == rhsId
        case (.migrationWizard, .migrationWizard):
            return true
        case (.migrationProgress(let lhsId), .migrationProgress(let rhsId)):
            return lhsId == rhsId
        default:
            return false
        }
    }
}
