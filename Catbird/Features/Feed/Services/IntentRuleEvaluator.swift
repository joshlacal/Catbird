//
//  IntentRuleEvaluator.swift
//  Catbird
//
//  Created for Catbird on-device intent controls.
//

import Foundation
import OSLog
import Petrel

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
@Generable
public struct PostIntentMatch: Sendable {
    @Guide(description: "The 0-based index of the post in the provided batch (e.g. 0, 1, 2...)")
    public var postIndex: Int

    @Guide(description: "The UUID string of the rule that matched this post, or empty string if no rule matches")
    public var ruleId: String

    @Guide(description: "True if the post content matches the intent rule's description")
    public var matches: Bool

    @Guide(description: "Confidence score between 0.0 and 1.0 (e.g. 0.85)")
    public var confidence: Double

    public init(postIndex: Int = 0, ruleId: String = "", matches: Bool = false, confidence: Double = 0.0) {
        self.postIndex = postIndex
        self.ruleId = ruleId
        self.matches = matches
        self.confidence = confidence
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
public struct BatchIntentResponse: Sendable {
    @Guide(description: "List of match verdicts for posts in the batch")
    public var verdicts: [PostIntentMatch]

    public init(verdicts: [PostIntentMatch] = []) {
        self.verdicts = verdicts
    }
}
#endif

/// In-memory LRU cache for post-intent rule evaluations.
actor IntentVerdictCache {
    static let shared = IntentVerdictCache()

    struct Key: Hashable, Sendable {
        let postURI: String
        let ruleId: UUID
        let ruleText: String
    }

    struct Value: Sendable {
        let matches: Bool
        let confidence: Double
        let rule: IntentRule
        let lastAccessed: Date
    }

    private var entries: [Key: Value] = [:]
    private let maxEntries = 2_000

    func verdict(for key: Key) -> Value? {
        guard var value = entries[key] else { return nil }
        value = Value(
            matches: value.matches,
            confidence: value.confidence,
            rule: value.rule,
            lastAccessed: Date()
        )
        entries[key] = value
        return value
    }

    func insert(_ value: Value, for key: Key) {
        if entries.count >= maxEntries {
            pruneLRU()
        }
        entries[key] = value
    }

    private func pruneLRU() {
        let sorted = entries.sorted { $0.value.lastAccessed < $1.value.lastAccessed }
        let toRemove = sorted.prefix(maxEntries / 4)
        for (k, _) in toRemove {
            entries.removeValue(forKey: k)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

/// Evaluates posts against natural language intent rules using Apple FoundationModels.
actor IntentRuleEvaluator {
    static let shared = IntentRuleEvaluator()

    private let logger = Logger(subsystem: "blue.catbird", category: "IntentRuleEvaluator")
    private let cache = IntentVerdictCache.shared
    private let batchSize = 10
    private let confidenceThreshold = 0.7

    private init() {}

    /// Evaluates a list of posts against enabled intent rules.
    /// Returns a dictionary mapping postURI to the matching IntentRule.
    func evaluate(
        posts: [CachedFeedViewPost],
        rules: [IntentRule]
    ) async -> [String: IntentRule] {
        let enabledRules = rules.filter(\.isEnabled)
        guard !enabledRules.isEmpty, !posts.isEmpty else { return [:] }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return await evaluateWithFoundationModels(posts: posts, rules: enabledRules)
        } else {
            logger.debug("FoundationModels unavailable on this OS version")
            return [:]
        }
        #else
        logger.debug("FoundationModels not available")
        return [:]
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func evaluateWithFoundationModels(
        posts: [CachedFeedViewPost],
        rules: [IntentRule]
    ) async -> [String: IntentRule] {
        let model = SystemLanguageModel(useCase: .contentTagging)
        guard case .available = model.availability else {
            logger.debug("SystemLanguageModel is not available; skipping intent evaluation")
            return [:]
        }

        var results: [String: IntentRule] = [:]
        var postsNeedingEvaluation: [(index: Int, post: CachedFeedViewPost, uri: String, text: String)] = []

        // 1. Check LRU cache first for all post-rule pairs
        for post in posts {
            let uri = postURI(from: post)
            var matchedRule: IntentRule? = nil
            var hasUncachedRule = false

            for rule in rules {
                let key = IntentVerdictCache.Key(postURI: uri, ruleId: rule.id, ruleText: rule.text)
                if let cached = await cache.verdict(for: key) {
                    if cached.matches && cached.confidence >= confidenceThreshold {
                        matchedRule = rule
                        break
                    }
                } else {
                    hasUncachedRule = true
                }
            }

            if let matchedRule {
                results[uri] = matchedRule
            } else if hasUncachedRule {
                let text = postText(from: post)
                if !text.isEmpty {
                    postsNeedingEvaluation.append((index: postsNeedingEvaluation.count, post: post, uri: uri, text: text))
                }
            }
        }

        guard !postsNeedingEvaluation.isEmpty else {
            return results
        }

        // 2. Batch posts in chunks of ~10
        let chunks = stride(from: 0, to: postsNeedingEvaluation.count, by: batchSize).map {
            Array(postsNeedingEvaluation[$0..<min($0 + batchSize, postsNeedingEvaluation.count)])
        }

        let ruleMap = Dictionary(uniqueKeysWithValues: rules.map { ($0.id.uuidString.lowercased(), $0) })
        let rulesInstructions = rules.map { "- [Rule ID: \($0.id.uuidString)] \($0.text) (Action: \($0.action.rawValue))" }.joined(separator: "\n")

        for chunk in chunks {
            do {
                let session = LanguageModelSession(
                    model: model,
                    instructions: """
                    You are an on-device content intent filter for social media timeline posts.
                    Evaluate whether each supplied post matches any of the active user rules.
                    Be objective, neutral, and accurate.
                    Only return a match if the post clearly corresponds to the user's intent rule (confidence >= 0.70).
                    If a post does not match any rule, matches should be false.
                    """
                )

                var promptText = "Active User Intent Rules:\n\(rulesInstructions)\n\nPosts to evaluate:\n"
                for (localIndex, item) in chunk.enumerated() {
                    promptText += "[Post \(localIndex)]: \(item.text)\n"
                }

                let options = GenerationOptions(temperature: 0, maximumResponseTokens: 600)

                let batchResponse: BatchIntentResponse = try await withThrowingTaskGroup(of: BatchIntentResponse.self) { group in
                    group.addTask {
                        let response = try await session.respond(
                            to: Prompt(promptText),
                            generating: BatchIntentResponse.self,
                            options: options
                        )
                        return response.content
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(5))
                        throw CancellationError()
                    }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                }

                // Process returned verdicts
                var matchedLocalIndices = Set<Int>()
                for verdict in batchResponse.verdicts {
                    guard verdict.postIndex >= 0 && verdict.postIndex < chunk.count else { continue }
                    let item = chunk[verdict.postIndex]
                    let cleanedRuleId = verdict.ruleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

                    if let rule = ruleMap[cleanedRuleId] {
                        let key = IntentVerdictCache.Key(postURI: item.uri, ruleId: rule.id, ruleText: rule.text)
                        let val = IntentVerdictCache.Value(
                            matches: verdict.matches,
                            confidence: verdict.confidence,
                            rule: rule,
                            lastAccessed: Date()
                        )
                        await cache.insert(val, for: key)
                        if verdict.matches && verdict.confidence >= confidenceThreshold {
                            matchedLocalIndices.insert(verdict.postIndex)
                            results[item.uri] = rule
                        }
                    }
                }

                // Cache negative verdicts for uncached items in this chunk
                for (localIndex, item) in chunk.enumerated() where !matchedLocalIndices.contains(localIndex) {
                    for rule in rules {
                        let key = IntentVerdictCache.Key(postURI: item.uri, ruleId: rule.id, ruleText: rule.text)
                        if await cache.verdict(for: key) == nil {
                            let val = IntentVerdictCache.Value(
                                matches: false,
                                confidence: 1.0,
                                rule: rule,
                                lastAccessed: Date()
                            )
                            await cache.insert(val, for: key)
                        }
                    }
                }
            } catch {
                logger.warning("Intent evaluation batch failed or timed out: \(error.localizedDescription)")
                // Graceful degradation: do not throw, show everything
            }
        }

        return results
    }
    #endif

    private func postURI(from post: CachedFeedViewPost) -> String {
        (try? post.feedViewPost.post.uri.uriString()) ?? post.id
    }

    private func postText(from post: CachedFeedViewPost) -> String {
        guard let fvp = try? post.feedViewPost,
              case .knownType(let record) = fvp.post.record,
              let postRecord = record as? AppBskyFeedPost else {
            return ""
        }
        return postRecord.text
    }
}

/// Main-actor coordinator for applying intent controls to timeline post arrays.
@MainActor
final class IntentControlCoordinator {
    static let shared = IntentControlCoordinator()

    private let logger = Logger(subsystem: "blue.catbird", category: "IntentControlCoordinator")

    private init() {}

    /// Applies intent rules to a timeline page of cached posts.
    /// Posts matching a .hide rule have `intentHiddenRuleText` set.
    /// Posts matching a .demote rule are moved toward the end of the loaded page.
    func applyIntentControls(
        to posts: [CachedFeedViewPost],
        accountDID: String?
    ) async -> [CachedFeedViewPost] {
        guard IntelligenceFeatureFlags.intentControlsEnabled,
              let accountDID = accountDID, !accountDID.isEmpty else {
            return posts
        }

        let rules = await IntentRuleStore.shared.rules(for: accountDID).filter(\.isEnabled)
        guard !rules.isEmpty else {
            return posts
        }

        let verdicts = await IntentRuleEvaluator.shared.evaluate(posts: posts, rules: rules)
        guard !verdicts.isEmpty else {
            return posts
        }

        var normalPosts: [CachedFeedViewPost] = []
        var demotedPosts: [CachedFeedViewPost] = []

        for post in posts {
            post.intentHiddenRuleText = nil
            post.isIntentDemoted = false
            let uri = (try? post.feedViewPost.post.uri.uriString()) ?? post.id
            if let matchingRule = verdicts[uri] {
                switch matchingRule.action {
                case .hide:
                    post.intentHiddenRuleText = matchingRule.text
                    normalPosts.append(post)
                case .demote:
                    post.isIntentDemoted = true
                    demotedPosts.append(post)
                }
            } else {
                normalPosts.append(post)
            }
        }

        logger.debug("Intent controls applied: \(posts.count) posts -> \(normalPosts.count) normal (\(normalPosts.filter { $0.intentHiddenRuleText != nil }.count) hidden placeholders), \(demotedPosts.count) demoted")
        return normalPosts + demotedPosts
    }
}
