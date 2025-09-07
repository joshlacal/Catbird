import Foundation
import OSLog
import Petrel

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Summarizes a trending topic using recent posts from its linked feed.
/// Uses Apple Intelligence on-device Foundation Models when available (iOS 26+).
actor TopicSummaryService {
    static let shared = TopicSummaryService()

    private let logger = Logger(subsystem: "blue.catbird", category: "TopicSummaryService")

    // In-memory cache to avoid repeated generation during a session.
    // Keyed by the topic link path (stable across the UI session).
    private var cache: [String: String] = [:]

    /// Returns a concise one-sentence description for a trending topic, or nil if unavailable.
    /// - Parameters:
    ///   - topic: Trend view from Petrel.
    ///   - appState: App state for accessing ATProto client.
    func summary(for topic: AppBskyUnspeccedDefs.TrendView, appState: AppState) async -> String? {
        let key = topic.link
        if let cached = cache[key] { return cached }
        logger.info("[Summary] Begin for topic: \(topic.displayName, privacy: .public)")

        guard let client = appState.atProtoClient else {
            logger.info("[Summary] No ATProto client; skip")
            return nil
        }

        // Resolve feed URI from topic.link
        guard let feedURI = await resolveFeedURI(from: topic.link, appState: appState) else {
            logger.info("[Summary] Could not resolve feed URI for link: \(topic.link, privacy: .public)")
            return nil
        }

        // Fetch a small sample of posts from the feed.
        let sampleTexts: [String]
        do {
            sampleTexts = try await fetchSamplePostTexts(from: feedURI, client: client, limit: 12)
        } catch {
            logger.error("[Summary] Failed to fetch posts: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard !sampleTexts.isEmpty else {
            logger.info("[Summary] No sample texts for topic: \(topic.displayName, privacy: .public)")
            return nil
        }
        logger.info("[Summary] Sample texts count: \(sampleTexts.count, privacy: .public)")

        // Generate the short description using Foundation Models if available.
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 15.0, *) {
            // Check availability of the model first.
            let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            switch model.availability {
            case .available:
                break
            default:
                logger.info("[Summary] Model unavailable: \(String(describing: model.availability), privacy: .public)")
                return nil
            }

            do {
                // Prefetch resources to reduce latency on first-generation.
                LanguageModelSession(model: model, instructions: {
                    Instructions {
                        ""
                    }
                })
                    .prewarm(promptPrefix: nil)

                let instructions = """
                You are a concise, neutral social feed summarizer.
                Summarize what people are discussing about the topic using one sentence (max 22 words).
                Avoid hashtags, usernames, links, and quotes. Focus on the main subject and sentiment.
                If posts are unclear or off-topic, return a short generic description.
                """

                // Construct a compact prompt from sampled posts.
                let joined = sampleTexts
                    .map { "- \($0)" }
                    .joined(separator: "\n")

                let prompt = """
                Based on the following recent posts, write a one-sentence description of the trending topic "\(topic.displayName)":

                \(joined)

                Provide exactly one sentence only, no emojis. Return only the sentence, no other text.
                """

                let session = LanguageModelSession(model: model, instructions: {
                    Instructions {
                        instructions
                    }
                })

                let response = try await session.respond(to: Prompt(prompt))
                let text = response.content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                if !text.isEmpty {
                    cache[key] = text
                    logger.info("[Summary] Completed for topic: \(topic.displayName, privacy: .public)")
                    return text
                }
            } catch {
                // Model failed or refused; do not provide a summary.
                logger.error("[Summary] Summarization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif

        return nil
    }

    // MARK: - Helpers

    private func resolveFeedURI(from linkPath: String, appState: AppState) async -> ATProtocolURI? {
        // Expected path pattern: /profile/<host>/feed/<rkey>
        // Normalize leading/trailing slashes before splitting.
        let trimmed = linkPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmed.split(separator: "/").map(String.init)
        guard components.count >= 4,
              components[0] == "profile",
              components[2] == "feed" else {
            return nil
        }

        let host = components[1]
        let rkey = components[3]

        // Special-case trending.bsky.app DID used in URLHandler.
        let did: String
        if host == "trending.bsky.app" {
            did = "did:plc:qrz3lhbyuxbeilrc6nekdqme"
        } else {
            do {
                did = try await appState.atProtoClient?.resolveHandleToDID(handle: host) ?? host
            } catch {
                logger.error("Failed to resolve host to DID: \(host, privacy: .public) error=\(error.localizedDescription)")
                did = host
            }
        }

        do {
            return try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.generator/\(rkey)")
        } catch {
            logger.error("Failed to build feed URI: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchSamplePostTexts(
        from feedURI: ATProtocolURI,
        client: ATProtoClient,
        limit: Int
    ) async throws -> [String] {
        let fm = FeedManager(client: client, fetchType: .feed(feedURI))
        let (posts, _) = try await fm.fetchFeed(fetchType: .feed(feedURI), cursor: nil)

        // Take up to limit posts, extract plain text, trim and sanitize.
        var texts: [String] = []
        texts.reserveCapacity(min(limit, posts.count))

        for post in posts.prefix(limit) {
            guard case .knownType(let record) = post.post.record,
                  let feedPost = record as? AppBskyFeedPost
            else { continue }

            var text = feedPost.text
            text = sanitize(text)
            if !text.isEmpty {
                // Cap length to keep prompt compact.
                let capped = String(text.prefix(220))
                texts.append(capped)
            }
        }

        return texts
    }

    private func sanitize(_ text: String) -> String {
        // Remove URLs, handles, and collapse whitespace to keep prompt crisp.
        let urlPattern = #"https?://\S+"#
        let handlePattern = #"@\S+"#

        let noURLs = text.replacingOccurrences(of: urlPattern, with: "", options: .regularExpression)
        let noHandles = noURLs.replacingOccurrences(of: handlePattern, with: "", options: .regularExpression)
        let collapsed = noHandles.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

extension TopicSummaryService {
    /// Precompute and cache summaries for the first `max` topics.
    func primeSummaries(for topics: [AppBskyUnspeccedDefs.TrendView], appState: AppState, max: Int = 5) async {
        let slice = Array(topics.prefix(max))
        logger.info("[Summary] Prime start for \(slice.count, privacy: .public) topics")
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 15.0, *) {
            let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            logger.info("[Summary] Preflight model availability: \(String(describing: model.availability), privacy: .public)")
        } else {
            logger.info("[Summary] Preflight: OS below iOS 26 / macOS 15, skipping model")
        }
        #else
        logger.info("[Summary] Preflight: FoundationModels not available at compile time")
        #endif
        for topic in slice {
            logger.info("[Summary] Prime invoking summary for: \(topic.displayName, privacy: .public)")
            let result = await summary(for: topic, appState: appState)
            logger.info("[Summary] Prime result for \(topic.displayName, privacy: .public): \(result ?? "<nil>", privacy: .public)")
        }
        logger.info("[Summary] Prime done")
    }
}
