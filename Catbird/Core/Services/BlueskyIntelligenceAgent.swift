import Foundation
import OSLog
import CoreGraphics
import Petrel

enum BlueskyAgentError: LocalizedError {
    case foundationModelsUnavailable
    case modelUnavailable
    case missingClient
    case notAThread
    case invalidThreadURI(String)
    case emptyResult(String)
    case contextLimitExceeded(limit: Int, required: Int)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .foundationModelsUnavailable:
            return "Foundation Models are not available on this platform."
        case .modelUnavailable:
            return "The on-device language model is unavailable or not ready."
        case .missingClient:
            return "An authenticated Bluesky client is required before issuing agent requests."
        case .notAThread:
            return "Thread summarization requires a post with visible thread context."
        case .invalidThreadURI:
            return "Choose a Bluesky post or supply a valid Bluesky post link."
        case .emptyResult(let context):
            return "No data was returned for \(context)."
        case .contextLimitExceeded(let limit, let required):
            return "The prompt and context require \(required) tokens, which exceeds the limit of \(limit)."
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}

/// Deterministic input and transcript bounds shared by the read tools.
enum AskCatbirdToolPolicy {
    // Two reads return at most 512 tokens each; the remaining headroom covers
    // tool-call framing. Runtime context errors remain explicit.
    static let onDeviceToolResultTokenReserve = 1536

    static func postURI(_ input: String) throws -> ATProtocolURI {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let link = URLComponents(string: trimmed),
           link.scheme?.lowercased() == "https", link.host?.lowercased() == "bsky.app",
           link.user == nil, link.password == nil, link.port == nil {
            let parts = link.path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 4, parts[0] == "profile", parts[2] == "post" else {
                throw BlueskyAgentError.invalidThreadURI(input)
            }
            candidate = "at://\(parts[1])/app.bsky.feed.post/\(parts[3])"
        } else {
            candidate = trimmed
        }
        guard candidate.range(of: #"^at://[^/\s?#]+/app\.bsky\.feed\.post/[^/\s?#]+$"#,
                              options: .regularExpression) != nil,
              let uri = try? ATProtocolURI(uriString: candidate) else {
            throw BlueskyAgentError.invalidThreadURI(input)
        }
        return uri
    }

    /// Keep the anchor first, then the nearest context; distant parents cannot
    /// consume the entire response budget before the requested post appears.
    static func precedes(depth: Int, otherDepth: Int) -> Bool {
        if depth == 0 { return otherDepth != 0 }
        if otherDepth == 0 { return false }
        if depth.magnitude != otherDepth.magnitude { return depth.magnitude < otherDepth.magnitude }
        return depth < otherDepth
    }
}

/// Shared bounded metadata representation for search and thread neighbors.
enum AskCatbirdPostFormatter {
    struct SearchResult: Encodable {
        let posts: [CopilotPostEvidence]
        let coverage: String
    }

    static func hasContent(_ evidence: CopilotPostEvidence) -> Bool {
        !(evidence.selectedPost.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !evidence.selectedPost.media.isEmpty || evidence.selectedPost.quotedPostURI != nil
    }

    static func compact(_ evidence: CopilotPostEvidence, textLimit: Int = 200) -> CopilotPostEvidence {
        func bounded(_ original: CopilotPostEvidence.Post) -> CopilotPostEvidence.Post {
            var post = original
            if let text = post.text, text.count > textLimit {
                post.text = String(text.prefix(textLimit))
                post.textTruncated = true
            }
            post.media = post.media.map { original in
                var media = original
                if let alt = media.altText, alt.count > 200 {
                    media.altText = String(alt.prefix(200)); media.truncatedFields.append("altText")
                }
                if let description = media.description, description.count > 200 {
                    media.description = String(description.prefix(200)); media.truncatedFields.append("description")
                }
                // Read tools expose metadata; explicit image candidates come only from selected context.
                media.thumbnailURL = nil
                media.imageURL = nil
                return media
            }
            return post
        }
        return .init(selectedPost: bounded(evidence.selectedPost),
                     quotedPosts: evidence.quotedPosts.map(bounded), coverage: evidence.coverage)
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
actor BlueskyIntelligenceAgent {
    static let historyHeader = "Previous conversation turns (assistant answers are not factual evidence):"

    private var client: ATProtoClient?
    private var model: SystemLanguageModel?
    private var session: LanguageModelSession?
    private var cachedTools: [any Tool]?
    private var cachedInstructionsTokens: Int?
    private var cachedToolTokens: [[CopilotTurnPlan.ToolKind]: Int] = [:]
    private var turnGeneration = CopilotTurnGeneration()
    private let turnHooks: CopilotTurnHooks?
    private var activeTurnTask: Task<Void, Never>?

    init(client: ATProtoClient? = nil, turnHooks: CopilotTurnHooks? = nil) {
        self.client = client
        self.turnHooks = turnHooks
    }

    func updateClient(_ client: ATProtoClient?) {
        activeTurnTask?.cancel()
        _ = turnGeneration.advance()
        self.client = client
        session = nil
        cachedTools = nil
    }

    func resetContext() {
        activeTurnTask?.cancel()
        _ = turnGeneration.advance()
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


    /// Compiles only Catbird's bounded Smart Filter grammar. The returned rule
    /// remains a proposal and must be confirmed by the user before persistence.
    nonisolated func compileSmartFilterProposal(
        _ text: String,
        accountDID: String,
        targetActorDID: String
    ) throws -> FeedFilterRule {
        try SmartFilterRuleCompiler.compileDeterministically(
            text,
            accountDID: accountDID,
            targetActorDID: targetActorDID
        )
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

    func streamTurn(
        conversationID: UUID,
        accountDID: String,
        prompt: String,
        context: CopilotContext,
        history: [CopilotStoredTurn],
        route: CopilotModelRoute = .onDevice,
        selectedImageID: String? = nil,
        currentClient: ATProtoClient?,
        imageAuthorization: CopilotImageAuthorization = .denied
    ) -> AsyncThrowingStream<CopilotTurnEvent, Error> {
        // Client replacement and generation invalidation happen atomically on this
        // actor before any turn work can suspend or reuse the previous client.
        updateClient(currentClient)
        let generation = turnGeneration.advance()
        let turnClient = currentClient
        return AsyncThrowingStream { continuation in
            let producerTask = Task {
                do {
                    try turnGeneration.check(generation)
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    if route == .privateCloudCompute,
                       let reason = CopilotCloudAvailability.unavailableReason {
                        throw CopilotCloudUnavailableError(reason: reason)
                    }
                    guard let client = turnClient else {
                        throw BlueskyAgentError.missingClient
                    }

                    var usedPCC = false
                    if route == .privateCloudCompute {
                        if #available(iOS 27.0, macOS 27.0, *) {
                            let cloudModel = PrivateCloudComputeLanguageModel()
                            if cloudModel.isAvailable, let tokenizerModel = prepareModel() {
                                let deltaTracker = TurnDeltaTracker()
                                do {
                                    try turnGeneration.check(generation)
                                    continuation.yield(.route(.privateCloudCompute))
                                    try await runPrivateCloudComputeTurn(
                                        model: cloudModel,
                                        tokenizerModel: tokenizerModel,
                                        client: client,
                                        accountDID: accountDID,
                                        prompt: prompt,
                                        context: context,
                                        history: history,
                                        continuation: continuation,
                                        deltaTracker: deltaTracker,
                                        generation: generation
                                    )
                                    usedPCC = true
                                } catch {
                                    try turnGeneration.check(generation)
                                    guard !Task.isCancelled else {
                                        continuation.finish()
                                        return
                                    }
                                    let hasEmittedDelta = await deltaTracker.hasEmittedDelta
                                    try turnGeneration.check(generation)
                                    if hasEmittedDelta {
                                        continuation.yield(.responseReset)
                                    }
                                    logger.warning("PCC streaming failed: \(error.localizedDescription); falling back to onDevice")
                                }
                            }
                        }
                    }

                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }

                    if !usedPCC {
                        try turnGeneration.check(generation)
                        continuation.yield(.route(.onDevice))
                        let localModel = turnHooks == nil ? prepareModel() : nil
                        guard localModel != nil || turnHooks != nil else {
                            throw BlueskyAgentError.modelUnavailable
                        }
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        try await runOnDeviceTurn(
                            model: localModel,
                            client: client,
                            accountDID: accountDID,
                            prompt: prompt,
                            context: context,
                            history: history,
                            selectedImageID: selectedImageID,
                            imageAuthorization: imageAuthorization,
                            continuation: continuation,
                            generation: generation
                        )
                    }

                    continuation.finish()
                } catch {
                    if Task.isCancelled || error is CancellationError || turnGeneration.value != generation {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            activeTurnTask = producerTask
            continuation.onTermination = { @Sendable _ in
                producerTask.cancel()
            }
        }
    }

    @available(iOS 27.0, macOS 27.0, *)
    private func runPrivateCloudComputeTurn(
        model: PrivateCloudComputeLanguageModel,
        tokenizerModel: SystemLanguageModel,
        client: ATProtoClient,
        accountDID: String,
        prompt: String,
        context: CopilotContext,
        history: [CopilotStoredTurn],
        continuation: AsyncThrowingStream<CopilotTurnEvent, Error>.Continuation,
        deltaTracker: TurnDeltaTracker,
        generation: UInt64
    ) async throws {
        let proposalSink = TurnProposalSink()
        let sourceCollector = TurnSourceCollector()
        let plan = CopilotTurnPlan.make(prompt: prompt, context: context)
        let toolContext = ToolContext(
            client: client, logger: logger, sourceCollector: sourceCollector,
            readBudget: CopilotReadBudget(),
            tokenCounter: { text in
                if #available(iOS 26.4, macOS 26.4, *) {
                    return try await tokenizerModel.tokenCount(for: Prompt(text))
                }
                return text.utf8.count
            }
        )
        let evidence = try await prepareTurnEvidence(context: context, plan: plan, tools: toolContext)
        try Task.checkCancellation()
        let turnTools = makePerTurnTools(
            toolContext: toolContext, context: context, accountDID: accountDID,
            plan: plan, proposalSink: proposalSink
        )

        let maxResponseTokens = 768
        let instructions = Instructions { Self.instructionsText }
        let instructionsTokens = try await tokenizerModel.tokenCount(for: instructions)
        let toolsTokens = try await tokenizerModel.tokenCount(for: turnTools)
        let reservedCost = instructionsTokens + toolsTokens + maxResponseTokens
            + (turnTools.isEmpty ? 0 : AskCatbirdToolPolicy.onDeviceToolResultTokenReserve)

        let contextSize = try await model.contextSize

        let selection = try await CopilotContextBudget.selectHistory(
            turns: history,
            modelContextSize: contextSize,
            reservedTokenCount: reservedCost,
            candidateTokenCount: { candidateHistory in
                let promptText = Self.formatContextualPrompt(
                    context: context,
                    history: candidateHistory,
                    prompt: prompt,
                evidence: evidence
                )
                return try await tokenizerModel.tokenCount(for: Prompt(promptText))
            }
        )

        guard selection.fits else {
            let basePrompt = Self.formatContextualPrompt(context: context, history: [], prompt: prompt, evidence: evidence)
            let basePromptTokens = try await tokenizerModel.tokenCount(for: Prompt(basePrompt))
            throw BlueskyAgentError.contextLimitExceeded(
                limit: selection.tokenLimit,
                required: reservedCost + basePromptTokens
            )
        }

        await sourceCollector.addHistorySources(selection.retainedTurns)
        let fullPrompt = Self.formatContextualPrompt(
            context: context,
            history: selection.retainedTurns,
            prompt: prompt,
            evidence: evidence
        )

        try Task.checkCancellation()
        let session = LanguageModelSession(
            model: model,
            tools: turnTools,
            instructions: instructions
        )

        let options = GenerationOptions(
            temperature: 0.25,
            maximumResponseTokens: maxResponseTokens
        )

        try await streamAndEmit(
            stream: CopilotTurnRuntime.stream(session: session, input: CopilotTurnInput(text: fullPrompt, image: nil, selectedImageID: nil), options: options),
            removedTurnCount: selection.removedTurnCount,
            sourceCollector: sourceCollector,
            proposalSink: proposalSink,
            continuation: continuation,
            deltaTracker: deltaTracker,
            generation: generation
        )
    }

    private func runOnDeviceTurn(
        model: SystemLanguageModel?, client: ATProtoClient, accountDID: String,
        prompt: String, context: CopilotContext, history: [CopilotStoredTurn],
        selectedImageID: String?, imageAuthorization: CopilotImageAuthorization,
        continuation: AsyncThrowingStream<CopilotTurnEvent, Error>.Continuation,
        generation: UInt64
    ) async throws {
        try turnGeneration.check(generation)
        let proposalSink = TurnProposalSink()
        let sourceCollector = TurnSourceCollector()
        let plan = CopilotTurnPlan.make(prompt: prompt, context: context)
        let toolContext = ToolContext(
            client: client, logger: logger, sourceCollector: sourceCollector, readBudget: CopilotReadBudget(),
            tokenCounter: { text in
                if #available(iOS 26.4, macOS 26.4, *), let model {
                    return try await model.tokenCount(for: Prompt(text))
                }
                return text.utf8.count
            }
        )
        let retrievedEvidence: [CopilotEvidence]
        if let turnHooks {
            let material = try await turnHooks.read(client, context)
            try turnGeneration.check(generation)
            retrievedEvidence = material.evidence
            for evidence in material.evidence {
                await sourceCollector.recordEvidence(evidence)
                for source in evidence.sources { await sourceCollector.add(label: source.label, uri: source.uri) }
            }
            if let proposal = material.proposal { _ = await proposalSink.record(proposal) }
        } else {
            retrievedEvidence = try await prepareTurnEvidence(context: context, plan: plan, tools: toolContext)
        }
        try turnGeneration.check(generation)
        let runtime: CopilotTurnRuntime
        if let turnHooks {
            runtime = turnHooks.runtime
        } else {
            guard let model else { throw BlueskyAgentError.modelUnavailable }
            let turnTools = makePerTurnTools(toolContext: toolContext, context: context, accountDID: accountDID,
                                             plan: plan, proposalSink: proposalSink)
            let instructions = Instructions { Self.instructionsText }
            let maxResponseTokens = 768
            let reservedCost: Int
            let countsFullPrompt: Bool
            if #available(iOS 26.4, macOS 26.4, *) {
                let instructionsTokens: Int
                if let cached = cachedInstructionsTokens {
                    instructionsTokens = cached
                } else {
                    let count = try await model.tokenCount(for: instructions)
                    cachedInstructionsTokens = count
                    instructionsTokens = count
                }
                
                let toolsTokens: Int
                if let cached = cachedToolTokens[plan.toolKinds] {
                    toolsTokens = cached
                } else {
                    let count = try await model.tokenCount(for: turnTools)
                    cachedToolTokens[plan.toolKinds] = count
                    toolsTokens = count
                }
                
                reservedCost = instructionsTokens + toolsTokens + maxResponseTokens
                    + (turnTools.isEmpty ? 0 : AskCatbirdToolPolicy.onDeviceToolResultTokenReserve)
                countsFullPrompt = true
            } else {
                reservedCost = 0
                countsFullPrompt = false
            }
            try turnGeneration.check(generation)
            let reason: String?
            if #available(iOS 27.0, macOS 27.0, *) { reason = CopilotImageSupport.unavailableReason(model: model) }
            else { reason = CopilotImageSupport.unavailableReason() }
            let session = LanguageModelSession(model: model, tools: turnTools, instructions: instructions)
            session.prewarm(promptPrefix: Prompt("You are the Bluesky client app \"Catbird\"'s agent."))
            let options = GenerationOptions(temperature: 0.25, maximumResponseTokens: maxResponseTokens)
            runtime = CopilotTurnRuntime(
                contextSize: model.contextSize, reservedTokenCount: reservedCost, countsFullPrompt: countsFullPrompt,
                imageUnavailableReason: reason,
                tokenCount: { input in
                    if #available(iOS 26.4, macOS 26.4, *) { return try await model.tokenCount(for: input.prompt) }
                    return input.text.utf8.count
                },
                stream: { input in
                    CopilotTurnRuntime.stream(session: session, input: input, options: options,
                        validateImageAccess: {
                            try await imageAuthorization.require(context: context, accountDID: accountDID)
                        })
                }
            )
        }
        let loadImage: @Sendable (URL) async throws -> CGImage = turnHooks?.loadImage ?? { try await CopilotImageSupport.loadImage($0) }
        var preparedImage = try await CopilotImageSupport.prepare(
            selectedImageID: selectedImageID, context: context,
            unavailableReason: runtime.imageUnavailableReason,
            authorize: { await imageAuthorization.permits(context, accountDID) }, load: loadImage
        )
        try turnGeneration.check(generation)
        let fullInput: CopilotTurnInput
        let selection: CopilotHistorySelection
        if runtime.countsFullPrompt {
            // Each representation/history candidate is built once. The accepted
            // object counted below is exactly the object submitted to generation.
            var countedInputs: [String: CopilotTurnInput] = [:]
            func key(_ turns: [CopilotStoredTurn], _ image: CopilotPreparedImage) -> String {
                turns.map { $0.id.uuidString }.joined(separator: ",") + "|"
                    + (image.image == nil ? "metadata" : "image") + "|" + (image.evidence?.text ?? "")
            }
            func input(_ turns: [CopilotStoredTurn], _ image: CopilotPreparedImage) -> CopilotTurnInput {
                let inputKey = key(turns, image)
                if let existing = countedInputs[inputKey] { return existing }
                let evidence = retrievedEvidence + (image.evidence.map { [$0] } ?? [])
                let text = Self.formatContextualPrompt(context: context, history: turns, prompt: prompt, evidence: evidence)
                let result = CopilotTurnInput(text: text, image: image.image, selectedImageID: image.candidate?.id)
                countedInputs[inputKey] = result
                return result
            }
            let budget = try await CopilotImageSupport.selectHistory(
                turns: history, preparedImage: preparedImage, modelContextSize: runtime.contextSize,
                reservedTokenCount: runtime.reservedTokenCount,
                candidateTokenCount: { turns, image in
                    if image.image != nil {
                        try await imageAuthorization.require(context: context, accountDID: accountDID)
                    }
                    try self.turnGeneration.check(generation)
                    return try await runtime.tokenCount(input(turns, image))
                }
            )
            try turnGeneration.check(generation)
            preparedImage = budget.image
            selection = budget.history
            guard selection.fits else {
                if preparedImage.image != nil {
                    try await imageAuthorization.require(context: context, accountDID: accountDID)
                }
                let required = try await runtime.tokenCount(input([], preparedImage))
                try turnGeneration.check(generation)
                throw BlueskyAgentError.contextLimitExceeded(limit: selection.tokenLimit, required: runtime.reservedTokenCount + required)
            }
            fullInput = input(selection.retainedTurns, preparedImage)
        } else {
            selection = try await CopilotContextBudget.selectLegacyHistory(
                turns: history, modelContextSize: 1536, reservedTokenCount: 0,
                candidatePrompt: { CopilotContextBudget.formatHistory(turns: $0) }
            )
            let evidence = retrievedEvidence + (preparedImage.evidence.map { [$0] } ?? [])
            fullInput = CopilotTurnInput(
                text: Self.formatContextualPrompt(context: context, history: selection.retainedTurns, prompt: prompt, evidence: evidence),
                image: nil, selectedImageID: nil
            )
        }
        try turnGeneration.check(generation)
        await sourceCollector.addHistorySources(selection.retainedTurns)
        if let evidence = preparedImage.evidence { await sourceCollector.recordEvidence(evidence) }
        try turnGeneration.check(generation)
        if fullInput.image != nil {
            try await imageAuthorization.require(context: context, accountDID: accountDID)
            try turnGeneration.check(generation)
        }
        try await streamAndEmit(stream: runtime.stream(fullInput), removedTurnCount: selection.removedTurnCount,
                                sourceCollector: sourceCollector, proposalSink: proposalSink,
                                continuation: continuation, generation: generation,
                                validateImageAccess: {
                                    if fullInput.image != nil {
                                        try await imageAuthorization.require(context: context, accountDID: accountDID)
                                    }
                                })
    }

    /// Shared streaming + post-processing used by both on-device and PCC turns.
    private func streamAndEmit(
        stream: AsyncThrowingStream<String, Error>,
        removedTurnCount: Int,
        sourceCollector: TurnSourceCollector,
        proposalSink: TurnProposalSink,
        continuation: AsyncThrowingStream<CopilotTurnEvent, Error>.Continuation,
        deltaTracker: TurnDeltaTracker? = nil,
        generation: UInt64,
        validateImageAccess: @Sendable () async throws -> Void = {}
    ) async throws {
        try turnGeneration.check(generation)
        var previousContent = ""
        for try await latestContent in stream {
            try await validateImageAccess()
            try turnGeneration.check(generation)
            if latestContent.count > previousContent.count {
                let delta = String(latestContent.dropFirst(previousContent.count))
                if !(previousContent.isEmpty
                    && latestContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == "null")
                {
                    continuation.yield(.textDelta(delta))
                    await deltaTracker?.markDeltaEmitted()
                }
                previousContent = latestContent
            }
        }

        try await validateImageAccess()
        try turnGeneration.check(generation)
        if removedTurnCount > 0 {
            continuation.yield(.contextTrimmed(removedTurnCount: removedTurnCount))
        }

        let sources = await sourceCollector.allSources()
        try turnGeneration.check(generation)
        for source in sources {
            try await validateImageAccess()
            try turnGeneration.check(generation)
            continuation.yield(.source(source))
        }

        for evidence in await sourceCollector.allEvidence() {
            try await validateImageAccess()
            try turnGeneration.check(generation)
            continuation.yield(.evidence(evidence))
        }

        if let proposal = await proposalSink.proposal {
            try await validateImageAccess()
            try turnGeneration.check(generation)
            continuation.yield(.proposal(proposal))
        }

        try await validateImageAccess()
        try turnGeneration.check(generation)
        continuation.yield(.completed)
    }
    private func prepareTurnEvidence(
        context: CopilotContext, plan: CopilotTurnPlan, tools: ToolContext
    ) async throws -> [CopilotEvidence] {
        try Task.checkCancellation()
        let isSearch = plan.toolKinds.contains { [.searchPosts, .searchProfiles, .searchFeeds].contains($0) }
        let anchor = plan.threadAnchorURI ?? (isSearch ? nil : CopilotTurnPlan.contextAnchor(for: context))
        if case .post(let uri, _, _, _, let snapshot) = context {
            for source in snapshot?.sources ?? [CopilotSource(label: "Selected post", uri: uri)] {
                await tools.recordSource(label: source.label, uri: source.uri)
            }
        }
        if let anchor {
            _ = try await tools.read("selected_thread", bounded: false) {
                try await ThreadFetchTool(context: tools).fetch(arguments: .init(uri: anchor))
            }
        }
        try Task.checkCancellation()
        return await tools.sourceCollector?.allEvidence() ?? []
    }

    private func makePerTurnTools(
        toolContext: ToolContext,
        context: CopilotContext,
        accountDID: String,
        plan: CopilotTurnPlan,
        proposalSink: TurnProposalSink
    ) -> [any Tool] {
        plan.toolKinds.map { kind -> any Tool in
            switch kind {
            case .fetchThread: ThreadFetchTool(context: toolContext)
            case .searchPosts: PostSearchTool(context: toolContext)
            case .searchFeeds: FeedSearchTool(context: toolContext)
            case .searchProfiles: ProfileSearchTool(context: toolContext)
            case .proposeAction:
                ProposeActionTool(context: context, accountDID: accountDID,
                                  sink: proposalSink, allowedActions: plan.allowedActions)
            }
        }
    }

    private static func formatContextualPrompt(
        context: CopilotContext,
        history: [CopilotStoredTurn],
        prompt: String,
        evidence: [CopilotEvidence] = []
    ) -> String {
        CopilotPrompt.format(context: context, history: history, prompt: prompt, evidence: evidence)
    }

    func summarizeThread(at uri: ATProtocolURI, maxSentences: Int = 3) async throws -> String {
        guard client != nil else { throw BlueskyAgentError.missingClient }
        
        var fullSummary = ""
        let stream = streamThreadSummary(at: uri, maxSentences: maxSentences)
        
        for try await chunk in stream {
            fullSummary += chunk
        }
        
        return fullSummary
    }
    
    func streamThreadSummary(at uri: ATProtocolURI, maxSentences: Int = 3) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let client else {
                        continuation.finish(throwing: BlueskyAgentError.missingClient)
                        return
                    }

                    let threadData = try await fetchFullThread(uri: uri, using: client)
                    let posts = flattenThreadForSummary(threadData)

                    guard !posts.isEmpty else {
                        continuation.finish(throwing: BlueskyAgentError.emptyResult("thread (no valid posts)"))
                        return
                    }

                    guard Self.hasMeaningfulThreadContext(posts) else {
                        continuation.finish(throwing: BlueskyAgentError.notAThread)
                        return
                    }

                    let parents = posts.filter { $0.isParent }
                    let mainPost = posts.first { $0.isMain }
                    let replies = posts.filter { !$0.isParent && !$0.isMain }

                    var cumulativeSummary = ""

                    if !parents.isEmpty {
                        logger.debug("Summarizing \(parents.count) parent posts")
                        cumulativeSummary = try await summarizeBatch(
                            posts: parents,
                            context: nil,
                            phase: "context"
                        )
                    }

                    if let mainPost {
                        logger.debug("Summarizing main post")
                        cumulativeSummary = try await summarizeBatch(
                            posts: [mainPost],
                            context: cumulativeSummary.isEmpty ? nil : cumulativeSummary,
                            phase: "main post"
                        )
                    }

                    if !replies.isEmpty {
                        logger.debug("Summarizing \(replies.count) replies in batches")
                        let batchSize = 10
                        for (index, batch) in replies.chunked(into: batchSize).enumerated() {
                            logger.debug("Processing reply batch \(index + 1), size: \(batch.count)")
                            cumulativeSummary = try await summarizeBatch(
                                posts: batch,
                                context: cumulativeSummary,
                                phase: "replies"
                            )
                        }
                    }

                    // Stream the final polished summary into the continuation
                    _ = try await polishSummaryStreaming(
                        cumulativeSummary,
                        maxSentences: maxSentences,
                        continuation: continuation
                    )

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private static func isMeaningfulModelOutput(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            switch trimmed.lowercased() {
            case "null", "nil":
                return false
            default:
                return true
            }
        }

    private static func hasMeaningfulThreadContext(_ posts: [FormattedThreadPost]) -> Bool {
        let parentCount = posts.filter(\.isParent).count
        let replyCount = posts.filter { !$0.isParent && !$0.isMain }.count
        return posts.contains(where: \.isMain) && (parentCount > 0 || replyCount > 0)
    }

    private func summarizeBatch(
        posts: [FormattedThreadPost],
        context: String?,
        phase: String
    ) async throws -> String {
        let postsText = posts.map { $0.text }.joined(separator: "\n")

        let prompt: String
        if let context, !context.isEmpty {
            prompt = """
            Current summary: \(context)

            New \(phase):
            \(postsText)

            Update the summary to incorporate these new posts. Keep it concise (2-3 sentences) and factual. Reference participants by @handle.
            """
        } else {
            prompt = """
            Summarize these posts from a Bluesky thread (\(phase)):
            \(postsText)

            Provide a concise summary (2-3 sentences) that captures the key points. Reference participants by @handle.
            """
        }

        let options = GenerationOptions(
            temperature: 0.3,
            maximumResponseTokens: 300
        )

        // Fresh session per batch to avoid context accumulation —
        // the cumulative summary is already embedded in the prompt.
        let batchSession = try await makeSummarizationSession()

        var lastError: Error?
        for attempt in 1...3 {
            do {
                let response = try await batchSession.respond(to: Prompt(prompt), options: options)
                let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

                if Self.isMeaningfulModelOutput(content) {
                    return content
                }

                logger.warning("Batch summarization attempt \(attempt) returned empty content")
                lastError = BlueskyAgentError.emptyResult("batch summary (attempt \(attempt))")

                if attempt < 3 {
                    try await Task.sleep(for: .milliseconds(300 * attempt))
                }
            } catch {
                logger.warning("Batch summarization attempt \(attempt) failed: \(error.localizedDescription)")
                lastError = error

                if attempt < 3 {
                    try await Task.sleep(for: .milliseconds(300 * attempt))
                }
            }
        }

        throw lastError ?? BlueskyAgentError.emptyResult("batch summary after 3 attempts")
    }
    
    private func polishSummaryStreaming(
        _ summary: String,
        maxSentences: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> String {
        let prompt = """
        Refine this summary to exactly \(maxSentences) sentence\(maxSentences == 1 ? "" : "s"). Keep it factual and concise:

        \(summary)

        Return plain text only — no headings, bullet points, or markdown.
        """

        let options = GenerationOptions(
            temperature: 0.2,
            maximumResponseTokens: 400
        )

        let polishSession = try await makeSummarizationSession()

        var lastError: Error?
        for attempt in 1...3 {
            do {
                var latestContent = ""
                var previousContent = ""
                let stream = polishSession.streamResponse(options: options, prompt: { Prompt(prompt) })

                for try await snapshot in stream {
                    latestContent = snapshot.content

                    if latestContent.count > previousContent.count {
                        let delta = String(latestContent.dropFirst(previousContent.count))
                        if !(previousContent.isEmpty
                            && latestContent.trimmingCharacters(in: .whitespacesAndNewlines)
                                .lowercased() == "null")
                        {
                            continuation.yield(delta)
                        }
                        previousContent = latestContent
                    }
                }

                let content = latestContent.trimmingCharacters(in: .whitespacesAndNewlines)

                if Self.isMeaningfulModelOutput(content) {
                    return content
                }

                logger.warning("Polish attempt \(attempt) returned empty content")
                lastError = BlueskyAgentError.emptyResult("polish (attempt \(attempt))")

                if attempt < 3 {
                    try await Task.sleep(for: .milliseconds(300 * attempt))
                }
            } catch {
                logger.warning("Polish attempt \(attempt) failed: \(error.localizedDescription)")
                lastError = error

                if attempt < 3 {
                    try await Task.sleep(for: .milliseconds(300 * attempt))
                }
            }
        }

        throw lastError ?? BlueskyAgentError.emptyResult("polish after 3 attempts")
    }
    
    private func fetchFullThread(
        uri: ATProtocolURI,
        using client: ATProtoClient
    ) async throws -> AppBskyUnspeccedGetPostThreadV2.Output {
        let params = AppBskyUnspeccedGetPostThreadV2.Parameters(
            anchor: uri,
            above: true,
                below: 20
        )
        
        logger.debug("Fetching full thread for URI: \(uri.uriString())")
        
        let (code, output) = try await client.app.bsky.unspecced.getPostThreadV2(input: params)
        
        guard (200 ... 299).contains(code) else {
            logger.error("Failed to fetch thread: code=\(code)")
            if code == 400 {
                throw BlueskyAgentError.emptyResult("thread (post may be deleted or unavailable)")
            }
            throw BlueskyAgentError.emptyResult("thread fetch (status \(code))")
        }
        
        guard let threadData = output else {
            throw BlueskyAgentError.emptyResult("thread (no data in response)")
        }
        
        guard !threadData.thread.isEmpty else {
            throw BlueskyAgentError.emptyResult("thread (empty array)")
        }
        
        return threadData
    }
    
    private func flattenThreadForSummary(_ threadData: AppBskyUnspeccedGetPostThreadV2.Output) -> [FormattedThreadPost] {
        var posts: [FormattedThreadPost] = []
        let sortedItems = threadData.thread.sorted { $0.depth < $1.depth }
        
        for item in sortedItems {
            guard case .appBskyUnspeccedDefsThreadItemPost(let threadItemPost) = item.value else {
                continue
            }
            
                guard
                    let formatted = ToolFormatter.summarize(
                        post: threadItemPost.post, depth: item.depth, prefix: nil)
                else {
                continue
            }
            
            posts.append(FormattedThreadPost(
                text: formatted,
                depth: item.depth,
                isParent: item.depth < 0,
                isMain: item.depth == 0
            ))
        }
        
        logger.debug("Flattened thread: \(posts.count) posts (parents: \(posts.filter { $0.isParent }.count), main: \(posts.filter { $0.isMain }.count), replies: \(posts.filter { !$0.isParent && !$0.isMain }.count))")
        
        return posts
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
            instructions: Instructions { Self.instructionsText }
        )

        newSession.prewarm(promptPrefix: Prompt("You are the Bluesky client app \"Catbird\"'s agent."))
        session = newSession
        return newSession
    }
    
    /// Creates a fresh session for text-only summarization (no tools, no history).
    /// Each batch gets its own session to avoid context accumulation.
    private func makeSummarizationSession() async throws -> LanguageModelSession {
        guard let model = prepareModel() else {
            throw BlueskyAgentError.modelUnavailable
        }

        return LanguageModelSession(
            model: model,
            tools: [],
            instructions: Instructions { Self.summarizationInstructionsText }
        )
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

    /// Prewarms the underlying system language model and caches instruction token count.
    func prewarm(client: ATProtoClient? = nil) async {
        guard let model = prepareModel() else { return }
        if #available(iOS 26.4, macOS 26.4, *) {
            if cachedInstructionsTokens == nil {
                let instructions = Instructions { Self.instructionsText }
                cachedInstructionsTokens = try? await model.tokenCount(for: instructions)
            }
        }
        if let client {
            _ = await prepareTools(using: client)
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

    static let instructionsText = """
    You are Ask Catbird, the Bluesky assistant inside Catbird.

    Trust boundary:
    \(CopilotPrompt.sourceBoundary)
    - Never invent Bluesky data, identifiers, sources, or action results.

    Answers:
    - Use only the available read tools when the user needs more evidence; a read limit is final.
    - Supplied context may be partial. Explain omissions; never invent missing quote, image, article or reply contents.
    - Drafts are suggestions for review. Distinguish interpretation from supported facts.
    - Ground factual claims in the supplied context or tool results.
    - Be concise, neutral, and explicit when information is unavailable.
    - Refer to posts by their author and a short excerpt, profiles by name or @handle, and feeds by title. Never use AT URIs, DIDs, or CIDs as visible labels.
    - Navigation identifiers in context and tool results are only for tool arguments and link destinations. Use readable labels for links.
    - A tool reporting unavailable data is not evidence about the post contents. Explain the limitation without inventing a result.

    Actions:
    - You cannot mutate Catbird or Bluesky state.
    - When the user explicitly requests a change, call `propose_action` once with a typed desired state for the current Catbird subject.
    - Questions, hypotheticals, and recommendations are not action requests.
    - Never claim a proposal was executed. Catbird revalidates it and requires user confirmation.
    - Publishing, reporting, blocking with MLS consequences, and deletion continue in Catbird's existing dedicated review flows.
    """
    
        private static let summarizationInstructionsText = """
            Role: You are a text summarization assistant for Catbird.

            Task: Summarize the provided Bluesky social media posts efficiently and accurately.

            Constraints:
            - Do NOT use any tools.
            - Do NOT attempt to fetch more data.
            - Rely ONLY on the text provided in the prompt.
            - Reference users by their @handle.
            - Be concise and factual.
            """
}

// MARK: - Tool infrastructure

@available(iOS 26.0, macOS 26.0, *)
private struct FormattedThreadPost {
    let text: String
    let depth: Int
    let isParent: Bool
    let isMain: Bool
}
@available(iOS 26.0, macOS 26.0, *)
private actor TurnDeltaTracker {
    private(set) var hasEmittedDelta = false

    func markDeltaEmitted() {
        hasEmittedDelta = true
    }
}

@available(iOS 26.0, macOS 26.0, *)
private actor TurnProposalSink {
    private(set) var proposal: CopilotProposal?

    func record(_ proposal: CopilotProposal) -> Bool {
        guard !Task.isCancelled, self.proposal == nil else { return false }
        self.proposal = proposal
        return true
    }
}

@available(iOS 26.0, macOS 26.0, *)
private actor TurnSourceCollector {
    private var collectedSources: [CopilotSource] = []
    private var seenURIs: Set<String> = []
    private var evidence: [CopilotEvidence] = []

    func add(label: String, uri: String?) {
        if let uri {
            guard seenURIs.insert(uri).inserted else { return }
        }
        collectedSources.append(CopilotSource(label: label, uri: uri))
    }

    func recordEvidence(_ value: CopilotEvidence) {
        evidence.append(value)
    }

    func allEvidence() -> [CopilotEvidence] { evidence }

    func addHistorySources(_ turns: [CopilotStoredTurn]) {
        for turn in turns {
            for source in (turn.sources ?? []) + (turn.evidence ?? []).flatMap(\.sources) {
                add(label: source.label, uri: source.uri)
            }
        }
    }

    func allSources() -> [CopilotSource] {
        collectedSources
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct ToolContext: @unchecked Sendable {
    let client: ATProtoClient
    let logger: Logger
    let sourceCollector: TurnSourceCollector?
    let readBudget: CopilotReadBudget?
    let tokenCounter: @Sendable (String) async throws -> Int

    init(client: ATProtoClient, logger: Logger, sourceCollector: TurnSourceCollector? = nil,
         readBudget: CopilotReadBudget? = nil,
         tokenCounter: @escaping @Sendable (String) async throws -> Int = { $0.utf8.count }) {
        self.client = client
        self.logger = logger
        self.sourceCollector = sourceCollector
        self.readBudget = readBudget
        self.tokenCounter = tokenCounter
    }

    func read(_ name: String, bounded: Bool = true,
              operation: () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        // Exhaustion escapes the model tool call, ending the turn instead of encouraging retries.
        try await readBudget?.consume()
        let previousSources = await sourceCollector?.allSources() ?? []
        var result: String
        do {
            try Task.checkCancellation()
            result = try await operation()
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            logger.error("Ask Catbird read tool \(name, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            if let agentError = error as? BlueskyAgentError {
                result = "Data unavailable: \(agentError.localizedDescription) Do not infer missing contents."
            } else {
                result = "Data unavailable: Bluesky could not complete this request. Do not infer missing contents."
            }
        }
        let output = bounded && readBudget != nil
            ? try await CopilotToolResult.bounded(result, tokenCount: tokenCounter)
            : (text: result, wasTruncated: false)
        try Task.checkCancellation()
        let sources = await sourceCollector?.allSources() ?? []
        await sourceCollector?.recordEvidence(CopilotEvidence(
            origin: name, text: output.text,
            sources: sources.filter { !previousSources.contains($0) },
            wasTruncated: output.wasTruncated
        ))
        try Task.checkCancellation()
        return output.text
    }

    func recordSource(label: String, uri: String?) async {
        guard !Task.isCancelled else { return }
        await sourceCollector?.add(label: label, uri: uri)
    }
}
@available(iOS 26.0, macOS 26.0, *)
private enum ToolFormatter {
    static func sourceLabel(post: AppBskyFeedDefs.PostView) -> String {
        let author = post.author.handle.description
        if case .knownType(let record) = post.record,
           let feedPost = record as? AppBskyFeedPost {
            let excerpt = sanitize(feedPost.text, limit: 80)
            if !excerpt.isEmpty { return "@\(author): \(excerpt)" }
        }
        return "Post by @\(author)"
    }

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

        var sanitized = sanitize(feedPost.text, limit: maxLength)
        
        // If text is empty, check for embed content
        if sanitized.isEmpty {
            if let embed = post.embed {
                switch embed {
                case .appBskyEmbedImagesView(let imagesView):
                    let altTexts = imagesView.images.compactMap { image -> String? in
                        guard !image.alt.isEmpty else { return nil }
                        return image.alt
                    }
                    if !altTexts.isEmpty {
                        sanitized = "[images: \(altTexts.joined(separator: "; "))]"
                    } else {
                        sanitized = "[image post]"
                    }
                case .appBskyEmbedGalleryView(let galleryView):
                    let galleryAltTexts = galleryView.items.compactMap { item -> String? in
                        guard case .appBskyEmbedGalleryViewImage(let image) = item,
                              !image.alt.isEmpty else { return nil }
                        return image.alt
                    }
                    if !galleryAltTexts.isEmpty {
                        sanitized = "[gallery: \(galleryAltTexts.joined(separator: "; "))]"
                    } else {
                        sanitized = "[gallery: \(galleryView.items.count) photos]"
                    }
                case .appBskyEmbedVideoView(let videoView):
                    if let alt = videoView.alt, !alt.isEmpty {
                        sanitized = "[video: \(alt)]"
                    } else {
                        sanitized = "[video post]"
                    }
                case .appBskyEmbedExternalView(let external):
                    sanitized = "[link: \(external.external.title)]"
                case .appBskyEmbedRecordView:
                    sanitized = "[quoted post]"
                case .appBskyEmbedRecordWithMediaView(let recordWithMedia):
                    // Check for alt text in nested media
                    var mediaDesc = "[post with media]"
                    switch recordWithMedia.media {
                    case .appBskyEmbedImagesView(let imagesView):
                        let altTexts = imagesView.images.compactMap { image -> String? in
                            guard !image.alt.isEmpty else { return nil }
                            return image.alt
                        }
                        if !altTexts.isEmpty {
                            mediaDesc = "[post with images: \(altTexts.joined(separator: "; "))]"
                        }
                    case .appBskyEmbedVideoView(let videoView):
                        if let alt = videoView.alt, !alt.isEmpty {
                            mediaDesc = "[post with video: \(alt)]"
                        }
                    case .appBskyEmbedGalleryView(let galleryView):
                        let altTexts = galleryView.items.compactMap { item -> String? in
                            guard case .appBskyEmbedGalleryViewImage(let image) = item,
                                  !image.alt.isEmpty else { return nil }
                            return image.alt
                        }
                        if !altTexts.isEmpty {
                            mediaDesc = "[post with gallery: \(altTexts.joined(separator: "; "))]"
                        } else {
                            mediaDesc = "[post with gallery: \(galleryView.items.count) photos]"
                        }
                    default:
                        break
                    }
                    sanitized = mediaDesc
                default:
                    sanitized = "[media post]"
                }
            } else {
                // Truly empty post - skip it
                logger.debug("Post has no text and no embed")
                return nil
            }
        }

        sanitized = sanitize(sanitized, limit: maxLength)
        let handle = post.author.handle.description
        let display = sanitize(post.author.displayName ?? handle, limit: 80)
        let timestamp = formatTimestamp(feedPost.createdAt.date)
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

    private static func formatTimestamp(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        } else if interval < 2592000 {
            let weeks = Int(interval / 604800)
            return "\(weeks)w ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }

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

/// The actual fetch tool formatter, exposed internally for controlled transcript tests.
/// Tool.Output is String: compact JSON preserves authored text and unambiguous
/// reply relationships without adding a second generated schema to the session.
@available(iOS 26.0, macOS 26.0, *)
enum AskCatbirdThreadFormatter {
    struct Transcript {
        let text: String
        let sources: [CopilotSource]
    }

    static func format(_ output: AppBskyUnspeccedGetPostThreadV2.Output) throws -> Transcript {
        let ordered = output.thread.sorted {
            AskCatbirdToolPolicy.precedes(depth: $0.depth, otherDepth: $1.depth)
        }
        guard let anchor = ordered.first(where: { $0.depth == 0 }),
              case .appBskyUnspeccedDefsThreadItemPost(let focus) = anchor.value,
              !focus.hiddenByThreadgate, !focus.mutedByViewer,
              CopilotPostEvidenceBuilder.build(focus.post).selectedPost.contentStatus == .available,
              AskCatbirdPostFormatter.hasContent(CopilotPostEvidenceBuilder.build(focus.post)) else {
            throw BlueskyAgentError.emptyResult("the requested post (unavailable, restricted, or unreadable)")
        }

        let isLong = ordered.count > 6
        let selected = Array(ordered.prefix(6))
        var sources: [CopilotSource] = []
        var rows: [[String: Any]] = []
        var serverHasMore = output.hasOtherReplies
        for item in ordered {
            if case .appBskyUnspeccedDefsThreadItemPost(let value) = item.value {
                serverHasMore = serverHasMore || value.moreParents || value.moreReplies > 0
            }
        }
        for item in selected {
            let role = item.depth == 0 ? "focus" : (item.depth < 0 ? "ancestor" : "reply")
            var row: [String: Any] = ["id": item.uri.uriString(), "role": role, "depth": item.depth]
            if case .appBskyUnspeccedDefsThreadItemPost(let value) = item.value,
               !value.hiddenByThreadgate, !value.mutedByViewer {
                let post = value.post
                row["author"] = "@" + post.author.handle.description
                if let name = post.author.displayName, !name.isEmpty { row["authorName"] = name }
                if case .knownType(let record) = post.record, let body = record as? AppBskyFeedPost {
                    // Preserve all authored content in short threads, including newlines.
                    // Unusually token-expensive text can still exceed local model context;
                    // do not silently omit short-thread content to hide that error.
                    let textLimit = item.depth == 0 || !isLong ? 3000 : 200
                    row["text"] = String(body.text.prefix(textLimit))
                    row["textTruncated"] = body.text.count > textLimit
                    row["replyTo"] = body.reply.map { $0.parent.uri.uriString() as Any } ?? NSNull()
                    row["root"] = body.reply.map { $0.root.uri.uriString() as Any } ?? NSNull()
                    let snapshot = CopilotPostEvidenceBuilder.build(post)
                    let evidence = item.depth == 0 ? snapshot : AskCatbirdPostFormatter.compact(snapshot)
                    let data = try JSONEncoder().encode(evidence)
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let selectedPost = object?["selectedPost"] as? [String: Any]
                    row["media"] = selectedPost?["media"]
                    row["quotedPostURI"] = selectedPost?["quotedPostURI"]
                    row["quotedPosts"] = object?["quotedPosts"]
                    row["coverage"] = evidence.coverage + evidence.selectedPost.coverage
                    for source in evidence.sources where !sources.contains(source) { sources.append(source) }
                } else {
                    row["contentStatus"] = "unreadable record; do not infer its contents"
                }
                let source = CopilotSource(label: ToolFormatter.sourceLabel(post: post), uri: post.uri.uriString())
                if !sources.contains(where: { $0.uri == source.uri }) { sources.append(source) }
            } else {
                row["contentStatus"] = "unavailable or restricted; do not infer its contents"
            }
            rows.append(row)
        }
        let payload: [String: Any] = [
            "posts": rows,
            "omittedReturnedItems": max(ordered.count - selected.count, 0),
            "serverReportsAdditionalContext": serverHasMore,
            "coverage": "All returned items are included when there are at most six; longer results contain focus and nearest context. Server request is bounded to two reply levels and three replies per branch. Hidden or restricted replies and deeper branches may be absent. This endpoint has no continuation cursor; fetch a returned post ID to inspect another branch. IDs are tool/navigation identities, never visible labels."
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        return Transcript(text: String(decoding: data, as: UTF8.self), sources: sources)
    }
}

// MARK: - Tools

@available(iOS 26.0, macOS 26.0, *)
private struct ThreadFetchTool: Tool {
    typealias Output = String

    let name = "fetch_thread"
    let description = "Loads a Bluesky conversation thread and returns a compact textual transcript."
    private let context: ToolContext

    init(context: ToolContext) {
        self.context = context
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct Arguments {
        @Guide(description: "The at:// post URI or https://bsky.app/profile/.../post/... link from context or search results. Never invent an identifier.")
        let uri: String

    }

    func call(arguments: Arguments) async throws -> String {
        try await context.read(name) {
            try await self.fetch(arguments: arguments)
        }
    }

    func fetch(arguments: Arguments) async throws -> String {
        context.logger.debug("fetch_thread invoked")
        
        guard let uri = try? AskCatbirdToolPolicy.postURI(arguments.uri) else {
            context.logger.error("Invalid URI format: \(arguments.uri)")
            throw BlueskyAgentError.invalidThreadURI(arguments.uri)
        }

        let params = AppBskyUnspeccedGetPostThreadV2.Parameters(
            anchor: uri,
            above: true,
            below: 2,
            branchingFactor: 3
        )
        
        context.logger.debug("Fetching thread for URI: \(uri.uriString()), above=true, below=2, branchingFactor=3")
        
        let (code, output) = try await context.client.app.bsky.unspecced.getPostThreadV2(input: params)
        try Task.checkCancellation()
        
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

        let transcript = try AskCatbirdThreadFormatter.format(threadData)
        for source in transcript.sources {
            await context.recordSource(label: source.label, uri: source.uri)
        }
        return transcript.text
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct PostSearchTool: Tool {
    typealias Output = String

    let name = "search_posts"
    let description = "Searches Bluesky posts and returns concise matches with author context."
    private let context: ToolContext

    init(context: ToolContext) { self.context = context }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct Arguments {
        @Guide(description: "Free text query to search for.")
        let query: String

        @Guide(description: "Maximum number of posts to return", .range(1 ... 5))
        let limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        try await context.read(name) {
            try await self.fetch(arguments: arguments)
        }
    }

    private func fetch(arguments: Arguments) async throws -> String {
        let limit = min(max(arguments.limit ?? 5, 1), 5)
        let params = AppBskyFeedSearchPosts.Parameters(q: arguments.query, limit: limit)
        let (code, output) = try await context.client.app.bsky.feed.searchPosts(input: params)
        guard (200 ... 299).contains(code), let posts = output?.posts, !posts.isEmpty else {
            throw BlueskyAgentError.emptyResult("post search")
        }
        for post in posts.prefix(limit) {
            await context.recordSource(
                label: ToolFormatter.sourceLabel(post: post),
                uri: post.uri.uriString()
            )
        }

        let snapshots = posts.prefix(limit).map { AskCatbirdPostFormatter.compact(CopilotPostEvidenceBuilder.build($0)) }
        return CopilotPrompt.sourceJSON(AskCatbirdPostFormatter.SearchResult(
            posts: snapshots,
            coverage: "Bounded supplied post, attachment descriptions, link previews and quoted records only. Media bytes and linked pages were not inspected."
        ))
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct FeedSearchTool: Tool {
    typealias Output = String

    let name = "search_feeds"
    let description = "Finds noteworthy feed generators that match a query."
    private let context: ToolContext

    init(context: ToolContext) { self.context = context }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct Arguments {
        @Guide(description: "Keyword to match feed titles or descriptions.")
        let query: String

        @Guide(description: "Maximum feeds to include", .range(1 ... 5))
        let limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        try await context.read(name) {
            try await self.fetch(arguments: arguments)
        }
    }

    private func fetch(arguments: Arguments) async throws -> String {
        let limit = min(max(arguments.limit ?? 5, 1), 5)
        let params = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(limit: limit, query: arguments.query)
        let (code, output) = try await context.client.app.bsky.unspecced.getPopularFeedGenerators(input: params)
        guard (200 ... 299).contains(code), let feeds = output?.feeds, !feeds.isEmpty else {
            throw BlueskyAgentError.emptyResult("feed search")
        }

        for feed in feeds.prefix(limit) {
            await context.recordSource(
                label: "Feed: \(feed.displayName)",
                uri: feed.uri.uriString()
            )
        }

        let summaries = feeds.prefix(limit).map {
            "\(ToolFormatter.summarize(generator: $0, limit: 160))\nNavigation identifier (tool arguments only): \($0.uri.uriString())"
        }
        return "Feed generators for \(arguments.query):\n" + summaries.joined(separator: "\n")
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct ProfileSearchTool: Tool {
    typealias Output = String

    let name = "search_profiles"
    let description = "Finds Bluesky profiles that match a search term."
    private let context: ToolContext

    init(context: ToolContext) { self.context = context }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct Arguments {
        @Guide(description: "Search term or handle to look up.")
        let query: String

        @Guide(description: "Maximum profiles to include", .range(1 ... 5))
        let limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        try await context.read(name) {
            try await self.fetch(arguments: arguments)
        }
    }

    private func fetch(arguments: Arguments) async throws -> String {
        let limit = min(max(arguments.limit ?? 5, 1), 5)
        let params = AppBskyActorSearchActors.Parameters(q: arguments.query, limit: limit)
        let (code, output) = try await context.client.app.bsky.actor.searchActors(input: params)
        guard (200 ... 299).contains(code), let actors = output?.actors, !actors.isEmpty else {
            throw BlueskyAgentError.emptyResult("profile search")
        }

        for profile in actors.prefix(limit) {
            let handle = profile.handle.description
            await context.recordSource(
                label: "Profile: @\(handle)",
                uri: profile.did.description
            )
        }

        let summaries = actors.prefix(limit).map {
            "\(ToolFormatter.summarize(profile: $0, limit: 160))\nNavigation identifier (tool arguments only): \($0.did.description)"
        }
        return "Profiles for \(arguments.query):\n" + summaries.joined(separator: "\n")
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct ProposeActionTool: Tool {
    typealias Output = String

    let name = "propose_action"
    var description: String {
        "Propose only \(allowedActions.sorted().joined(separator: ", ")) for the current request. Requires user confirmation; never executes an action."
    }
    private let context: CopilotContext
    private let accountDID: String
    private let sink: TurnProposalSink
    private let allowedActions: Set<String>

    init(context: CopilotContext, accountDID: String, sink: TurnProposalSink, allowedActions: Set<String>) {
        self.context = context
        self.accountDID = accountDID
        self.sink = sink
        self.allowedActions = allowedActions
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct Arguments {
        @Guide(description: "Use the exact action token allowed by this tool description for the current user request.")
        let action: String

        @Guide(description: "Optional payload text required for certain actions such as reply text, quote text, smart filter rule, or post draft content.")
        let payload: String?
    }

    func call(arguments: Arguments) async throws -> String {
        try Task.checkCancellation()
        guard allowedActions.contains(arguments.action) else {
            return "This action was not requested for this turn. No proposal was created."
        }
        guard let proposal = try? CopilotProposalCoordinator.proposal(
            action: arguments.action,
            payload: arguments.payload,
            context: context,
            accountDID: accountDID
        ) else {
            return "Unable to propose action: invalid action '\(arguments.action)' or incompatible context."
        }

        let recorded = await sink.record(proposal)
        if recorded {
            return "Action '\(arguments.action)' proposed for user confirmation."
        } else {
            return "Only one action proposal is permitted per turn. A proposal was already recorded."
        }
    }
}

// MARK: - Array Extension for Chunking

@available(iOS 26.0, macOS 26.0, *)
private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

#endif
