import Foundation

enum FeedRuleEngine {
    static func evaluate(
        _ candidate: FeedFilterCandidate,
        rules: [FeedFilterRule],
        semanticFeatures: PostSemanticFeatures?
    ) -> FeedFilterDecision {
        var pendingRuleIDs: [UUID] = []

        for rule in rules where rule.isEnabled {
            guard structurallyMatches(candidate, rule: rule) else { continue }

            if rule.requiresSemanticClassification {
                guard let semanticFeatures else {
                    pendingRuleIDs.append(rule.id)
                    continue
                }
                guard semanticallyMatches(semanticFeatures, groups: rule.semanticGroups) else {
                    continue
                }
            }

            switch rule.effectiveAction {
            case .collapse: return .collapsed(ruleID: rule.id)
            case .hide: return .hidden(ruleID: rule.id)
            }
        }

        return pendingRuleIDs.isEmpty ? .unaffected : .pending(ruleIDs: pendingRuleIDs)
    }

    private static func structurallyMatches(
        _ candidate: FeedFilterCandidate,
        rule: FeedFilterRule
    ) -> Bool {
        guard rule.postKinds.contains(candidate.kind) else { return false }

        let authoredMatch = rule.actorRoles.contains(.contentAuthor)
            && candidate.authorDID == rule.targetActorDID
        let repostMatch = rule.actorRoles.contains(.repostActor)
            && candidate.repostActorDID == rule.targetActorDID
        return authoredMatch || repostMatch
    }

    private static func semanticallyMatches(
        _ features: PostSemanticFeatures,
        groups: [SemanticPredicateGroup]
    ) -> Bool {
        groups.allSatisfy { group in
            group.alternatives.contains { predicate in
                switch predicate {
                case .topic(let topic):
                    return features.topics.contains {
                        $0.compare(topic, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    }
                case .tone(let tone):
                    return features.tones.contains(tone)
                case .behavior(let behavior):
                    return features.behaviors.contains(behavior)
                }
            }
        }
    }
}
