import Foundation
import OSLog
import Petrel

enum BlueskyAgentError: LocalizedError {
    case foundationModelsUnavailable
    case modelUnavailable
    case missingClient
    case invalidThreadURI(String)
    case emptyResult(String)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .foundationModelsUnavailable:
            return "Foundation Models are not available on this platform."
        case .modelUnavailable:
            return "The on-device language model is unavailable or not ready."
        case .missingClient:
            return "An authenticated Bluesky client is required before issuing agent requests."
        case .invalidThreadURI(let value):
            return "The supplied thread identifier is invalid: \(value)."
        case .emptyResult(let context):
            return "No data was returned for \(context)."
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 15.0, *)
actor BlueskyIntelligenceAgent {
    private let logger = Logger(subsystem: "blue.catbird", category: "BlueskyIntelligenceAgent")

    private var client: ATProtoClient?
    private var model: SystemLanguageModel?
    private var session: LanguageModelSession?
    private var cachedTools: [any Tool]?

    init(client: ATProtoClient? = nil) {
        self.client = client
    }

    func updateClient(_ client: ATProtoClient?) {
        self.client = client
        session = nil
        cachedTools = nil
    }

    func resetContext() {
        session = nil
    }

    func respond(
        to prompt: String,
        temperature: Double = 0.25,
        maxResponseTokens: Int = 512
    ) async throws -> String {
        guard let client else { throw BlueskyAgentError.missingClient }

        let session = try await ensureSession(using: client)
        let options = GenerationOptions(
            temperature: temperature,
            maximumResponseTokens: maxResponseTokens
        )

        let response = try await session.respond(to: Prompt(prompt), options: options)
        return response.content
    }

    /// Streams a response token-by-token for real-time display
    func streamResponse(
        to prompt: String,
        temperature: Double = 0.25,
        maxResponseTokens: Int = 512
    ) async throws -> LanguageModelSession.ResponseStream<String> {
        guard let client else { throw BlueskyAgentError.missingClient }

        let session = try await ensureSession(using: client)
        let options = GenerationOptions(
            temperature: temperature,
            maximumResponseTokens: maxResponseTokens
        )
        return session.streamResponse(options: options, prompt: { Prompt(prompt) })
    }

    func summarizeThread(at uri: ATProtocolURI, maxSentences: Int = 3) async throws -> String {
        guard let client else { throw BlueskyAgentError.missingClient }

        let session = try await ensureSession(using: client)
        let prompt = """
        You are preparing a concise, factual summary of a Bluesky conversation thread.
        Use the `fetch_thread` tool to gather the full parent chain and replies for \(uri.uriString()).
        Then respond with at most \(maxSentences) sentences that describe the discussion chronologically, referencing participants by @handle.
        Include timestamps when the tool output provides them, note key parent posts when relevant, and avoid speculation or value judgments.
        Return plain text only — no headings, bullet points, or markdown fences.
        """

        let options = GenerationOptions(
            temperature: 0.3,
            maximumResponseTokens: 500
        )

        var lastError: Error?
        for attempt in 1...3 {
            do {
                let response = try await session.respond(to: Prompt(prompt), options: options)
                let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !content.isEmpty && !content.contains("No data was returned") {
                    return content
                }
                
                logger.warning("Thread summarization attempt \(attempt) returned empty or error content")
                lastError = BlueskyAgentError.emptyResult("thread summary (attempt \(attempt))")
                
                if attempt < 3 {
                    try await Task.sleep(for: .milliseconds(500 * attempt))
                }
            } catch let error as BlueskyAgentError {
                if case .emptyResult(let context) = error, context.contains("deleted or unavailable") {
                    logger.info("Thread unavailable (400 error), not retrying")
                    throw error
                }
                
                logger.warning("Thread summarization attempt \(attempt) failed: \(error.localizedDescription)")
                lastError = error
                
                if attempt < 3 {
                    try await Task.sleep(for: .milliseconds(500 * attempt))
                }
            } catch {
                logger.warning("Thread summarization attempt \(attempt) failed: \(error.localizedDescription)")
                lastError = error
                
                if attempt < 3 {
                    try await Task.sleep(for: .milliseconds(500 * attempt))
                }
            }
        }
        
        throw lastError ?? BlueskyAgentError.emptyResult("thread summary after 3 attempts")
    }

    // MARK: - Session lifecycle

    private func ensureSession(using client: ATProtoClient) async throws -> LanguageModelSession {
        if let session { return session }

        guard let model = prepareModel() else {
            throw BlueskyAgentError.modelUnavailable
        }

        let tools = await prepareTools(using: client)
        let newSession = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: { Instructions { Self.instructionsText } }
        )

        newSession.prewarm(promptPrefix: Prompt("You are the Bluesky client app \"Catbird\"'s agent."))
        session = newSession
        return newSession
    }

    private func prepareModel() -> SystemLanguageModel? {
        if let model { return model }

        let candidate = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        switch candidate.availability {
        case .available:
            model = candidate
            return candidate
        default:
            logger.debug("Language model unavailable: \(String(describing: candidate.availability))")
            return nil
        }
    }

    private func prepareTools(using client: ATProtoClient) async -> [any Tool] {
        if let cachedTools { return cachedTools }
        let context = ToolContext(client: client, logger: logger)
        let tools: [any Tool] = [
            ThreadFetchTool(context: context),
            PostSearchTool(context: context),
            FeedSearchTool(context: context),
            ProfileSearchTool(context: context)
        ]
        cachedTools = tools
        return tools
    }

    private static let instructionsText = """
    Role: You are Catbird's on-device Bluesky agent. Help the user by combining analysis and tool calls.

    Behavioral guardrails:
    - Prefer concise answers grounded in the latest tool output.
    - When asked to summarise a thread, call `fetch_thread` to retrieve context first.
    - For discovery or insight questions, call `search_posts`, `search_feeds`, or `search_profiles` as appropriate before answering.
    - Never fabricate Bluesky data. If tools return nothing, state that plainly.
    - Stay neutral and fact-focused; avoid speculation, opinion, or editorialising.
    - When referencing posts, include the @handle (and display name if available). Use timestamps or ordering hints from tool output when helpful.
    - Preserve privacy: all interactions stay on-device, so avoid telling users to contact cloud services.

    Response style:
    - Use short paragraphs or bullet lists when appropriate.
    - Attribute quotes or facts to handles when available.
    - For requested summaries, keep within the requested sentence count and emphasise what was actually said.
    - Clearly separate analysis from raw excerpts when helpful.
    """
}

// MARK: - Tool infrastructure

@available(iOS 26.0, macOS 15.0, *)
private struct ToolContext: @unchecked Sendable {
    let client: ATProtoClient
    let logger: Logger
}

@available(iOS 26.0, macOS 15.0, *)
private enum ToolFormatter {
    static func summarize(
        post: AppBskyFeedDefs.PostView,
        depth: Int = 0,
        prefix: String? = nil,
        maxLength: Int = 400
    ) -> String? {
        guard case .knownType(let value) = post.record else {
            logger.debug("Post record is not a known type: \(post.record.textRepresentation)")
            return nil
        }
        
        guard let feedPost = value as? AppBskyFeedPost else {
            logger.debug("Post record known type cannot be cast to AppBskyFeedPost. Type: \(type(of: value))")
            return nil
        }

        let sanitized = sanitize(feedPost.text, limit: maxLength)
        guard !sanitized.isEmpty else {
            logger.debug("Post text is empty after sanitization")
            return nil
        }

        let handle = post.author.handle.description
        let display = post.author.displayName ?? handle
        let timestamp = timestampFormatter.string(from: feedPost.createdAt.date)
        let indent = String(repeating: "  ", count: max(depth, 0))
        let prefixSegment = prefix.map { "[\($0.uppercased())] " } ?? ""
        let engagement = formattedEngagement(for: post)
        return "\(indent)\(timestamp) @\(handle) (\(display)) \(prefixSegment)\(sanitized)\(engagement)"
    }

    static func summarize(generator: AppBskyFeedDefs.GeneratorView, limit: Int = 240) -> String {
        let creatorHandle = generator.creator.handle.description
        let creatorName = generator.creator.displayName ?? creatorHandle
        let likes = generator.likeCount.map { " | Likes: \($0)" } ?? ""
        let description = generator.description.map { sanitize($0, limit: limit) } ?? ""
        if description.isEmpty {
            return "• \(generator.displayName) by @\(creatorHandle) (\(creatorName))\(likes)"
        }
        return "• \(generator.displayName) by @\(creatorHandle) (\(creatorName))\(likes) — \(description)"
    }

    static func summarize(profile: AppBskyActorDefs.ProfileView, limit: Int = 240) -> String {
        let handle = profile.handle.description
        let displayName = profile.displayName ?? handle
        let description = profile.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sanitized = description.isEmpty ? "" : " — \(sanitize(description, limit: limit))"
        return "• @\(handle) (\(displayName))\(sanitized)"
    }

    private static func sanitize(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        let index = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return collapsed[..<index].trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone]
        return formatter
    }()

    private static func formattedEngagement(for post: AppBskyFeedDefs.PostView) -> String {
        let counts: [(String, Int?)] = [
            ("↻", post.repostCount),
            ("♡", post.likeCount),
            ("↩︎", post.replyCount)
        ]
        let formatted = counts.compactMap { symbol, value -> String? in
            guard let value, value > 0 else { return nil }
            return "\(symbol)\(value)"
        }
        guard !formatted.isEmpty else { return "" }
        return " [\(formatted.joined(separator: ", "))]"
    }
}

// MARK: - Tools

@available(iOS 26.0, macOS 15.0, *)
private struct ThreadFetchTool: Tool {
    typealias Output = String

    let name = "fetch_thread"
    let description = "Loads a Bluesky conversation thread and returns a compact textual transcript."
    private let context: ToolContext

    init(context: ToolContext) {
        self.context = context
    }

    @Generable
    struct Arguments {
        @Guide(description: "The at:// URI of the post to inspect.")
        let uri: String

        @Guide(description: "Maximum number of reply levels to include (API maximum is 20)", .range(4 ... 20))
        let limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        context.logger.debug("fetch_thread invoked: uri=\(arguments.uri), limit=\(arguments.limit ?? 20)")
        
        guard let uri = try? ATProtocolURI(uriString: arguments.uri) else {
            context.logger.error("Invalid URI format: \(arguments.uri)")
            throw BlueskyAgentError.invalidThreadURI(arguments.uri)
        }

        let limit = min(arguments.limit ?? 20, 20)
        let params = AppBskyUnspeccedGetPostThreadV2.Parameters(
            anchor: uri,
            above: true,
            below: limit
        )
        
        context.logger.debug("Fetching thread for URI: \(uri.uriString()), above=true, below=\(limit)")
        
        let (code, output) = try await context.client.app.bsky.unspecced.getPostThreadV2(input: params)
        
        guard (200 ... 299).contains(code) else {
            context.logger.error("Failed to fetch thread: code=\(code), URI=\(uri.uriString())")
            
            if code == 400 {
                throw BlueskyAgentError.emptyResult("thread (post may be deleted or unavailable)")
            }
            
            throw BlueskyAgentError.emptyResult("thread fetch (status \(code))")
        }
        
        guard let threadData = output else {
            context.logger.error("Thread fetch returned nil output despite success code")
            throw BlueskyAgentError.emptyResult("thread (no data in response)")
        }
        
        // Check if thread array is empty
        guard !threadData.thread.isEmpty else {
            context.logger.error("Thread data returned empty array for URI: \(uri.uriString())")
            throw BlueskyAgentError.emptyResult("thread (empty array)")
        }

        let segments = flatten(threadData: threadData, limit: limit)
        guard !segments.isEmpty else {
            context.logger.error("Thread flattening produced no segments for URI: \(uri.uriString()), thread items: \(threadData.thread.count)")
            throw BlueskyAgentError.emptyResult("thread (no valid posts after parsing)")
        }

        return segments.joined(separator: "\n")
    }

    private func flatten(threadData: AppBskyUnspeccedGetPostThreadV2.Output, limit: Int) -> [String] {
        var lines: [String] = []
        var remaining = limit
        var skippedItems = 0

        func append(post: AppBskyFeedDefs.PostView, depth: Int, prefix: String?) {
            guard remaining > 0 else { return }
            if let summary = ToolFormatter.summarize(post: post, depth: depth, prefix: prefix) {
                lines.append(summary)
                remaining -= 1
            } else {
                skippedItems += 1
                context.logger.debug("Skipped post at depth \(depth): no summary generated")
            }
        }

        // Sort thread items by depth (parents first, then main post, then replies)
        let sortedItems = threadData.thread.sorted { $0.depth < $1.depth }
        
        context.logger.debug("Flattening thread: \(sortedItems.count) total items, limit=\(limit)")
        
        // Count different item types
        var postCount = 0
        var notFoundCount = 0
        var blockedCount = 0
        var noAuthCount = 0
        var unexpectedCount = 0
        
        for item in sortedItems {
            switch item.value {
            case .appBskyUnspeccedDefsThreadItemPost:
                postCount += 1
            case .appBskyUnspeccedDefsThreadItemNotFound:
                notFoundCount += 1
            case .appBskyUnspeccedDefsThreadItemBlocked:
                blockedCount += 1
            case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
                noAuthCount += 1
            case .unexpected:
                unexpectedCount += 1
            }
        }
        
        context.logger.debug("Thread items breakdown: posts=\(postCount), notFound=\(notFoundCount), blocked=\(blockedCount), noAuth=\(noAuthCount), unexpected=\(unexpectedCount)")
        
        // Process parent posts (depth < 0)
        let parentItems = sortedItems.filter { $0.depth < 0 }
        for (offset, item) in parentItems.enumerated() where remaining > 0 {
            if case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost) = item.value {
                append(post: threadItemPost.post, depth: offset, prefix: "parent")
            }
        }
        
        // Process main post (depth = 0)
        if let mainItem = sortedItems.first(where: { $0.depth == 0 }), remaining > 0 {
            if case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost) = mainItem.value {
                append(post: threadItemPost.post, depth: parentItems.count, prefix: "focus")
            } else {
                context.logger.error("Main post (depth=0) is not a valid post item")
            }
        } else {
            context.logger.error("No main post found at depth=0")
        }
        
        // Process reply posts (depth > 0)
        let replyItems = sortedItems.filter { $0.depth > 0 }
        for item in replyItems where remaining > 0 {
            if case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost) = item.value {
                let prefix = item.depth == 1 ? "reply" : nil
                append(post: threadItemPost.post, depth: parentItems.count + item.depth, prefix: prefix)
            }
        }
        
        context.logger.debug("Thread flattening complete: generated \(lines.count) summaries, skipped \(skippedItems) items")
        
        return lines
    }
}

@available(iOS 26.0, macOS 15.0, *)
private struct PostSearchTool: Tool {
    typealias Output = String

    let name = "search_posts"
    let description = "Searches Bluesky posts and returns concise matches with author context."
    private let context: ToolContext

    init(context: ToolContext) { self.context = context }

    @Generable
    struct Arguments {
        @Guide(description: "Free text query to search for.")
        let query: String

        @Guide(description: "Maximum number of posts to return", .range(1 ... 25))
        let limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let limit = arguments.limit ?? 10
        let params = AppBskyFeedSearchPosts.Parameters(q: arguments.query, limit: limit)
        let (code, output) = try await context.client.app.bsky.feed.searchPosts(input: params)
        guard (200 ... 299).contains(code), let posts = output?.posts, !posts.isEmpty else {
            throw BlueskyAgentError.emptyResult("post search")
        }

        let summaries = posts.prefix(limit).compactMap { ToolFormatter.summarize(post: $0) }
        guard !summaries.isEmpty else {
            throw BlueskyAgentError.emptyResult("post search")
        }

        return "Results for \(arguments.query):\n" + summaries.joined(separator: "\n")
    }
}

@available(iOS 26.0, macOS 15.0, *)
private struct FeedSearchTool: Tool {
    typealias Output = String

    let name = "search_feeds"
    let description = "Finds noteworthy feed generators that match a query."
    private let context: ToolContext

    init(context: ToolContext) { self.context = context }

    @Generable
    struct Arguments {
        @Guide(description: "Keyword to match feed titles or descriptions.")
        let query: String

        @Guide(description: "Maximum feeds to include", .range(1 ... 25))
        let limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let limit = arguments.limit ?? 10
        let params = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(limit: limit, query: arguments.query)
        let (code, output) = try await context.client.app.bsky.unspecced.getPopularFeedGenerators(input: params)
        guard (200 ... 299).contains(code), let feeds = output?.feeds, !feeds.isEmpty else {
            throw BlueskyAgentError.emptyResult("feed search")
        }

        let summaries = feeds.prefix(limit).map { ToolFormatter.summarize(generator: $0) }
        return "Feed generators for \(arguments.query):\n" + summaries.joined(separator: "\n")
    }
}

@available(iOS 26.0, macOS 15.0, *)
private struct ProfileSearchTool: Tool {
    typealias Output = String

    let name = "search_profiles"
    let description = "Finds Bluesky profiles that match a search term."
    private let context: ToolContext

    init(context: ToolContext) { self.context = context }

    @Generable
    struct Arguments {
        @Guide(description: "Search term or handle to look up.")
        let query: String

        @Guide(description: "Maximum profiles to include", .range(1 ... 25))
        let limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        let limit = arguments.limit ?? 10
        let params = AppBskyActorSearchActors.Parameters(term: arguments.query, limit: limit)
        let (code, output) = try await context.client.app.bsky.actor.searchActors(input: params)
        guard (200 ... 299).contains(code), let actors = output?.actors, !actors.isEmpty else {
            throw BlueskyAgentError.emptyResult("profile search")
        }

        let summaries = actors.prefix(limit).map { ToolFormatter.summarize(profile: $0) }
        return "Profiles for \(arguments.query):\n" + summaries.joined(separator: "\n")
    }
}

#endif
