import Foundation

enum SmartFilterCompilerError: LocalizedError, Equatable {
    case emptyRule
    case unsupportedIntent

    var errorDescription: String? {
        switch self {
        case .emptyRule:
            return "Enter what you want Catbird to filter."
        case .unsupportedIntent:
            return "Catbird cannot represent that rule reliably yet. Try replies, reposts, quote posts, a topic, or an expressed tone."
        }
    }
}

enum SmartFilterRuleCompiler {
    /// A conservative, offline compiler for common rules. The intelligence agent
    /// can propose the same schema, but it is never allowed to invent operations.
    static func compileDeterministically(
        _ rawText: String,
        accountDID: String,
        targetActorDID: String
    ) throws -> FeedFilterRule {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SmartFilterCompilerError.emptyRule }
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        let action: FeedFilterAction = normalized.contains("collapse") ? .collapse : .hide
        var roles: Set<FeedFilterActorRole> = [.contentAuthor]
        var kinds: Set<FeedFilterPostKind> = []
        var alternatives: [SemanticPredicate] = []

        if normalized.contains("repost") {
            roles = [.repostActor]
            kinds.insert(.repost)
        }
        if normalized.contains("quote post") || normalized.contains("quotes from") {
            kinds.insert(.quote)
        }
        if normalized.contains("repl") {
            kinds.insert(.reply)
        }

        let toneTerms: [(String, SemanticTone)] = [
            ("angry", .anger), ("anger", .anger),
            ("hostile", .hostility), ("hostility", .hostility),
            ("contempt", .contempt), ("distress", .distress),
            ("sad", .sadness), ("fear", .fear),
        ]
        for (term, tone) in toneTerms where normalized.contains(term) {
            let predicate = SemanticPredicate.tone(tone)
            if !alternatives.contains(predicate) { alternatives.append(predicate) }
        }

        let behaviorTerms: [(String, ObservablePostBehavior)] = [
            ("insult", .personalInsult), ("fighting", .activeConflict),
            ("conflict", .activeConflict), ("sarcas", .sarcasm),
            ("solicit", .solicitation),
        ]
        for (term, behavior) in behaviorTerms where normalized.contains(term) {
            let predicate = SemanticPredicate.behavior(behavior)
            if !alternatives.contains(predicate) { alternatives.append(predicate) }
        }

        if let topic = topicPhrase(in: text) {
            alternatives.append(.topic(topic))
        }

        guard !kinds.isEmpty || !alternatives.isEmpty else {
            throw SmartFilterCompilerError.unsupportedIntent
        }
        if kinds.isEmpty {
            kinds = [.original, .reply, .quote]
        }

        return FeedFilterRule(
            accountDID: accountDID,
            rawText: text,
            targetActorDID: targetActorDID,
            actorRoles: roles,
            postKinds: kinds,
            semanticGroups: alternatives.isEmpty ? [] : [SemanticPredicateGroup(alternatives: alternatives)],
            action: action
        )
    }

    static func confirmationSummary(for rule: FeedFilterRule, actorName: String) -> String {
        let action = rule.effectiveAction == .hide ? "Hide" : "Collapse"
        let kinds = rule.postKinds.map(\.rawValue).sorted().joined(separator: ", ")
        let role = rule.actorRoles == [.repostActor] ? "reposted by" : "written by"
        let semantic = rule.semanticGroups.isEmpty ? "" : " when the semantic conditions match"
        return "In Home: \(action) \(kinds) posts \(role) \(actorName)\(semantic)."
    }

    private static func topicPhrase(in text: String) -> String? {
        let patterns = ["talking about ", "posts about ", "discussion of "]
        let lowered = text.lowercased()
        guard let marker = patterns.first(where: { lowered.contains($0) }),
              let range = lowered.range(of: marker) else { return nil }
        var topic = String(text[range.upperBound...])
        for suffix in [" from this person", " from them", " by this person"] {
            if let suffixRange = topic.lowercased().range(of: suffix) {
                topic = String(topic[..<suffixRange.lowerBound])
            }
        }
        topic = topic.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return topic.isEmpty ? nil : topic
    }
}
