import Foundation

enum FeedFilterActorRole: String, Codable, CaseIterable, Sendable {
    case contentAuthor
    case repostActor
}

enum FeedFilterPostKind: String, Codable, CaseIterable, Sendable {
    case original
    case reply
    case quote
    case repost
}

enum FeedFilterAction: String, Codable, CaseIterable, Sendable {
    case collapse
    case hide
}

enum SemanticTone: String, Codable, CaseIterable, Sendable {
    case anger
    case hostility
    case contempt
    case distress
    case sadness
    case fear
    case positive
    case neutral
}

enum ObservablePostBehavior: String, Codable, CaseIterable, Sendable {
    case hostility
    case personalInsult
    case activeConflict
    case sarcasm
    case solicitation
}

enum SemanticPredicate: Codable, Hashable, Sendable {
    case topic(String)
    case tone(SemanticTone)
    case behavior(ObservablePostBehavior)

    var requiresCollapse: Bool {
        if case .behavior = self { return true }
        return false
    }
}

struct SemanticPredicateGroup: Codable, Hashable, Sendable {
    let alternatives: [SemanticPredicate]

    init(alternatives: [SemanticPredicate]) {
        self.alternatives = Array(alternatives.prefix(6))
    }
}

struct FeedFilterRule: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let accountDID: String
    let rawText: String
    let targetActorDID: String
    let actorRoles: Set<FeedFilterActorRole>
    let postKinds: Set<FeedFilterPostKind>
    let semanticGroups: [SemanticPredicateGroup]
    let action: FeedFilterAction
    let compilerVersion: Int
    let classifierVersion: Int
    var isEnabled: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        accountDID: String,
        rawText: String,
        targetActorDID: String,
        actorRoles: Set<FeedFilterActorRole>,
        postKinds: Set<FeedFilterPostKind>,
        semanticGroups: [SemanticPredicateGroup] = [],
        action: FeedFilterAction,
        compilerVersion: Int = 1,
        classifierVersion: Int = 1,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.accountDID = accountDID
        self.rawText = rawText
        self.targetActorDID = targetActorDID
        self.actorRoles = actorRoles
        self.postKinds = postKinds
        self.semanticGroups = Array(semanticGroups.prefix(4))
        self.action = action
        self.compilerVersion = compilerVersion
        self.classifierVersion = classifierVersion
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    /// Broad behavioral judgments are intentionally never allowed to silently hide.
    var effectiveAction: FeedFilterAction {
        semanticGroups.lazy.flatMap(\.alternatives).contains(where: \.requiresCollapse)
            ? .collapse
            : action
    }

    var requiresSemanticClassification: Bool { !semanticGroups.isEmpty }
}

struct FeedFilterCandidate: Hashable, Sendable {
    let cid: String
    let authorDID: String
    let repostActorDID: String?
    let kind: FeedFilterPostKind
    let text: String
    let authoredAltText: [String]
}

struct PostSemanticFeatures: Codable, Hashable, Sendable {
    var topics: Set<String>
    var tones: Set<SemanticTone>
    var behaviors: Set<ObservablePostBehavior>

    init(
        topics: Set<String> = [],
        tones: Set<SemanticTone> = [],
        behaviors: Set<ObservablePostBehavior> = []
    ) {
        self.topics = topics
        self.tones = tones
        self.behaviors = behaviors
    }
}

enum FeedFilterDecision: Equatable, Sendable {
    case unaffected
    case pending(ruleIDs: [UUID])
    case collapsed(ruleID: UUID)
    case hidden(ruleID: UUID)
}
