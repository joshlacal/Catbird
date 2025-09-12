import Foundation
import NaturalLanguage
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
                Role: You are a concise, neutral social feed summarizer for trending topics.
                Style: Respond as briefly as possible.
                Safety: If posts are unclear or off-topic, return a short generic description.
                Output rules:
                - Return exactly one sentence (max 22 words).
                - Output only the sentence, nothing else. No preamble, no explanation, no filler words.
                - Never include filler phrases such as "Sure!" or "Here is..." in your answers.
                - Wrap the sentence inside <output></output> tags and include nothing outside the tags.
                - Avoid hashtags, usernames, links, quotes, or emojis.
                """

                // Construct a compact prompt from sampled posts.
                let joined = sampleTexts
                    .map { "- \($0)" }
                    .joined(separator: "\n")

                let prompt = """
                Based on the following recent posts, write a one-sentence description of the trending topic "\(topic.displayName)":

                \(joined)

                Answer using the exact format: <output>Your single sentence here.</output>
                """

                let session = LanguageModelSession(model: model, instructions: {
                    Instructions {
                        instructions
                    }
                })

                // Keep the response short and deterministic.
                let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 64)

                let response = try await session.respond(to: Prompt(prompt), options: options)
                let raw = response.content
                let text = Self.extractOneSentence(from: raw)

                if let text, !text.isEmpty {
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

// MARK: - Post-processing helpers

extension TopicSummaryService {
    /// Extract exactly one sentence from model output, applying delimiter parsing and fallback cleanup.
    /// - The model is asked to wrap the sentence in <output>...</output> tags. Prefer that when present.
    /// - If tags are missing, trims known filler and returns the first sentence-like chunk.
    static func extractOneSentence(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Prefer extracting between <output>...</output>
        if let tagged = extractBetweenTags("output", in: trimmed), !tagged.isEmpty {
            return clampToSingleSentence(tagged)
        }

        // Fallback: remove common filler preambles then clamp to one sentence.
        let defillered = stripFiller(from: trimmed)
        return clampToSingleSentence(defillered)
    }

    /// Extracts content between <tag>...</tag> (case-sensitive); returns nil if not found.
    private static func extractBetweenTags(_ tag: String, in text: String) -> String? {
        let pattern = "<" + tag + ">([\\s\\S]*?)</" + tag + ">"
        if let range = text.range(of: pattern, options: [.regularExpression]) {
            let inner = text[range]
            // Use NSRegularExpression to pick capture group 1 for safety.
            do {
                let regex = try NSRegularExpression(pattern: pattern)
                let ns = NSString(string: String(inner))
                let full = NSRange(location: 0, length: ns.length)
                if let match = regex.firstMatch(in: String(inner), range: full), match.numberOfRanges > 1 {
                    let r1 = match.range(at: 1)
                    if let swiftRange = Range(r1, in: String(inner)) {
                        return String(String(inner)[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Removes typical helper phrases the model might add.
    private static func stripFiller(from text: String) -> String {
        // Common openings like "Sure!", "Here is/are", "Here’s", "Okay," etc.
        let pattern = #"^(?:Sure!?|Okay[,!]?|Here(?:'s| is| are)[^:]*:?)\s+"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// Returns a single-sentence string by extracting the first sentence robustly.
    private static func clampToSingleSentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return t }

        // 1) Prefer linguistic sentence segmentation to avoid cutting after initials like "E.".
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = t
        var firstSentence: String?
        tokenizer.enumerateTokens(in: t.startIndex..<t.endIndex) { range, _ in
            firstSentence = String(t[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return false // stop after first
        }
        if let s = firstSentence, !s.isEmpty {
            return s
        }

        // 2) Fallback: find first real sentence-ending punctuation, ignoring initials and common abbreviations.
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "vs", "etc", "e.g", "i.e", "u.s", "u.k"]
        var idxOpt: String.Index? = nil
        var i = t.startIndex
        while i < t.endIndex {
            let ch = t[i]
            if ch == "." || ch == "!" || ch == "?" {
                if ch == "." {
                    // Check for abbreviation or single-letter initial before the period.
                    let tokenStart = t[..<i].lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" })
                    let start = tokenStart.map { t.index(after: $0) } ?? t.startIndex
                    let token = t[start..<i]
                    let tokenStr = token.trimmingCharacters(in: .whitespacesAndNewlines)

                    // If single-letter like "E" or in known abbreviations, skip and continue.
                    if tokenStr.count == 1 {
                        i = t.index(after: i)
                        continue
                    }
                    if abbreviations.contains(tokenStr.lowercased()) {
                        i = t.index(after: i)
                        continue
                    }
                }
                idxOpt = i
                break
            }
            i = t.index(after: i)
        }
        if let idx = idxOpt {
            let end = t.index(after: idx)
            return String(t[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3) No terminal punctuation; cap to ~22 words as a safeguard.
        let words = t.split(separator: " ")
        if words.count <= 22 { return t }
        return words.prefix(22).joined(separator: " ")
    }
}
