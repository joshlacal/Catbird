//
//  PostInteractionSettingsState.swift
//  Catbird
//

import Foundation
import Petrel

/// Represents post interaction settings, including threadgate (reply rules)
/// and postgate (quote embedding rules).
public struct PostInteractionSettingsState: Equatable, Sendable {
    public var threadgate: ThreadgateSettings
    public var allowQuotes: Bool

    public init(
        threadgate: ThreadgateSettings = ThreadgateSettings(),
        allowQuotes: Bool = true
    ) {
        self.threadgate = threadgate
        self.allowQuotes = allowQuotes
    }

    public var isCustom: Bool {
        !threadgate.allowEverybody || !allowQuotes
    }

    /// Converts threadgate settings to rules for AppBskyFeedThreadgate.
    /// Returns nil if allowEverybody is true, empty array if allowNobody is true.
    public func toThreadgateAllowRules() -> [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? {
        if threadgate.allowEverybody {
            return nil
        }
        if threadgate.allowNobody {
            return []
        }
        return threadgate.toAllowUnions()
    }

    /// Converts allowQuotes setting to embeddingRules for AppBskyFeedPostgate.
    /// When allowQuotes is false, includes AppBskyFeedPostgate.DisableRule.
    public func toPostgateEmbeddingRules() -> [AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion]? {
        if !allowQuotes {
            return [.appBskyFeedPostgateDisableRule(AppBskyFeedPostgate.DisableRule())]
        }
        return nil
    }

    /// Summary string formatted for chips and accessory bars.
    public var summary: String {
        let replySummary = ComposerChipsStrip.threadgateSummary(threadgate)
        if allowQuotes {
            return replySummary
        } else {
            if threadgate.allowEverybody {
                return "No quotes"
            } else {
                return "\(replySummary) · No quotes"
            }
        }
    }
}

extension PostInteractionSettingsState {
    /// Pure helper to convert from existing server records into interaction state.
    public init(threadgateRecord: AppBskyFeedThreadgate?, postgateRecord: AppBskyFeedPostgate?) {
        var tg = ThreadgateSettings()
        if let record = threadgateRecord {
            var allowEverybody = false
            var allowNobody = false
            var allowMentioned = false
            var allowFollowing = false
            var allowFollowers = false
            var allowLists = false
            var selectedLists: [String] = []
            if let allowRules = record.allow {
                if allowRules.isEmpty {
                    allowNobody = true
                } else {
                    for rule in allowRules {
                        switch rule {
                        case .appBskyFeedThreadgateMentionRule:
                            allowMentioned = true
                        case .appBskyFeedThreadgateFollowingRule:
                            allowFollowing = true
                        case .appBskyFeedThreadgateFollowerRule:
                            allowFollowers = true
                        case let .appBskyFeedThreadgateListRule(listRule):
                            allowLists = true
                            selectedLists.append(listRule.list.uriString())
                        case .unexpected:
                            break
                        }
                    }
                }
            } else {
                allowEverybody = true
            }
            tg.allowEverybody = allowEverybody
            tg.allowNobody = allowNobody
            tg.allowMentioned = allowMentioned
            tg.allowFollowing = allowFollowing
            tg.allowFollowers = allowFollowers
            tg.allowLists = allowLists
            tg.selectedLists = selectedLists
        } else {
            tg.allowEverybody = true
        }

        var quotesAllowed = true
        if let postgate = postgateRecord, let rules = postgate.embeddingRules {
            for rule in rules {
                if case .appBskyFeedPostgateDisableRule = rule {
                    quotesAllowed = false
                    break
                }
            }
        }

        self.threadgate = tg
        self.allowQuotes = quotesAllowed
    }

    /// Merges updated interaction settings into an existing Threadgate record, preserving hidden replies and createdAt.
    public static func mergeThreadgate(
        existing: AppBskyFeedThreadgate?,
        postURI: ATProtocolURI,
        settings: PostInteractionSettingsState,
        createdAt: ATProtocolDate = ATProtocolDate(date: Date())
    ) -> AppBskyFeedThreadgate {
        let allowRules = settings.toThreadgateAllowRules()
        let preservedHidden = existing?.hiddenReplies
        let recordCreatedAt = existing?.createdAt ?? createdAt
        return AppBskyFeedThreadgate(
            post: postURI,
            allow: allowRules,
            createdAt: recordCreatedAt,
            hiddenReplies: preservedHidden
        )
    }

    /// Merges updated interaction settings into an existing Postgate record, preserving detached embedding URIs and createdAt.
    public static func mergePostgate(
        existing: AppBskyFeedPostgate?,
        postURI: ATProtocolURI,
        settings: PostInteractionSettingsState,
        createdAt: ATProtocolDate = ATProtocolDate(date: Date())
    ) -> AppBskyFeedPostgate {
        let embeddingRules = settings.toPostgateEmbeddingRules()
        let preservedDetached = existing?.detachedEmbeddingUris
        let recordCreatedAt = existing?.createdAt ?? createdAt
        return AppBskyFeedPostgate(
            createdAt: recordCreatedAt,
            post: postURI,
            detachedEmbeddingUris: preservedDetached,
            embeddingRules: embeddingRules
        )
    }
}
