import Foundation
import Petrel

actor SmartFilterCoordinator {
    static let shared = SmartFilterCoordinator()

    private let ruleStore = SmartFilterRuleStore.shared
    private let cache = PostSemanticFeatureCache.shared
    private var inFlightCIDs: Set<String> = []
    private var queuedJobs: [(FeedFilterCandidate, PostSemanticFeatureCache.Key)] = []
    private let modelGeneration = ProcessInfo.processInfo.operatingSystemVersionString

    func decisions(
        for slices: [FeedSlice],
        accountDID: String
    ) async -> [String: FeedFilterDecision] {
        guard IntelligenceFeatureFlags.smartFilterStructuralRulesEnabled else { return [:] }
        let rules = await ruleStore.rules(for: accountDID)
        guard !rules.isEmpty else { return [:] }

        let rulesByActor = Dictionary(grouping: rules) { $0.targetActorDID }
        var decisions: [String: FeedFilterDecision] = [:]

        for slice in slices {
            guard let candidate = Self.candidate(from: slice) else { continue }
            var relevantRules = rulesByActor[candidate.authorDID] ?? []
            if let repostActorDID = candidate.repostActorDID {
                relevantRules.append(contentsOf: rulesByActor[repostActorDID] ?? [])
            }
            guard !relevantRules.isEmpty else { continue }

            let classifierVersion = relevantRules.map(\.classifierVersion).max() ?? 1
            let key = PostSemanticFeatureCache.Key(
                accountDID: accountDID,
                cid: candidate.cid,
                classifierVersion: classifierVersion,
                modelGeneration: modelGeneration
            )
            let cachedFeatures = await cache.features(for: key)
            let decision = FeedRuleEngine.evaluate(
                candidate,
                rules: relevantRules,
                semanticFeatures: cachedFeatures
            )
            decisions[slice.id] = decision

            if case .pending = decision,
               IntelligenceFeatureFlags.smartFilterSemanticRulesEnabled {
                scheduleClassification(candidate, key: key)
            }
        }
        return decisions
    }

    private func scheduleClassification(
        _ candidate: FeedFilterCandidate,
        key: PostSemanticFeatureCache.Key
    ) {
        guard !inFlightCIDs.contains(candidate.cid),
              !queuedJobs.contains(where: { $0.0.cid == candidate.cid }) else { return }
        guard inFlightCIDs.count < 2 else {
            queuedJobs.append((candidate, key))
            return
        }
        startClassification(candidate, key: key)
    }

    private func startClassification(
        _ candidate: FeedFilterCandidate,
        key: PostSemanticFeatureCache.Key
    ) {
        inFlightCIDs.insert(candidate.cid)

        Task { [weak self] in
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                do {
                    let classifier = SystemPostSemanticClassifier()
                    let features = try await classifier.features(for: candidate)
                    await self?.cache.insert(features, for: key)
                    NotificationCenter.default.post(
                        name: .smartFilterFeaturesDidChange,
                        object: candidate.cid
                    )
                } catch {
                    // Fail open. A missing or rejected classification never hides content.
                }
            }
            #endif
            await self?.finished(candidate.cid)
        }
    }

    private func finished(_ cid: String) {
        inFlightCIDs.remove(cid)
        guard !queuedJobs.isEmpty else { return }
        let next = queuedJobs.removeFirst()
        startClassification(next.0, key: next.1)
    }

    nonisolated static func candidate(from slice: FeedSlice) -> FeedFilterCandidate? {
        guard let item = slice.items.last else { return nil }
        let kind: FeedFilterPostKind
        if slice.isRepost {
            kind = .repost
        } else if item.record.reply != nil {
            kind = .reply
        } else if let embed = item.record.embed {
            switch embed {
            case .appBskyEmbedRecord, .appBskyEmbedRecordWithMedia:
                kind = .quote
            default:
                kind = .original
            }
        } else {
            kind = .original
        }

        var repostActorDID: String?
        if case .appBskyFeedDefsReasonRepost(let reason) = slice.reason {
            repostActorDID = reason.by.did.didString()
        }

        return FeedFilterCandidate(
            cid: item.post.cid.string,
            authorDID: item.post.author.did.didString(),
            repostActorDID: repostActorDID,
            kind: kind,
            text: item.record.text,
            authoredAltText: authoredAltText(from: item.post.embed)
        )
    }

    nonisolated private static func authoredAltText(
        from embed: AppBskyFeedDefs.PostViewEmbedUnion?
    ) -> [String] {
        guard let embed else { return [] }
        switch embed {
        case .appBskyEmbedImagesView(let images):
            return images.images.map(\.alt).filter { !$0.isEmpty }
        case .appBskyEmbedGalleryView(let gallery):
            return gallery.items.compactMap { item in
                guard case .appBskyEmbedGalleryViewImage(let image) = item,
                      !image.alt.isEmpty else { return nil }
                return image.alt
            }
        case .appBskyEmbedVideoView(let video):
            return video.alt.map { [$0] } ?? []
        case .appBskyEmbedRecordWithMediaView(let value):
            switch value.media {
            case .appBskyEmbedImagesView(let images):
                return images.images.map(\.alt).filter { !$0.isEmpty }
            case .appBskyEmbedGalleryView(let gallery):
                return gallery.items.compactMap { item in
                    guard case .appBskyEmbedGalleryViewImage(let image) = item,
                          !image.alt.isEmpty else { return nil }
                    return image.alt
                }
            case .appBskyEmbedVideoView(let video):
                return video.alt.map { [$0] } ?? []
            default:
                return []
            }
        default:
            return []
        }
    }
}

extension Notification.Name {
    static let smartFilterFeaturesDidChange = Notification.Name("SmartFilterFeaturesDidChange")
}
