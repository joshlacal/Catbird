import Foundation
import Testing
@testable import Catbird

#if canImport(FoundationModels)
struct CopilotPromptFitterTests {
  private static let question = "What is this thread arguing about?"
  private static let focusText = "Selected post: " + String(repeating: "focus ", count: 80)

  // MARK: - Routes

  @Test
  func onDeviceRouteFitsAThreadFarLargerThanTheWindow() async throws {
    let content = Self.content(rows: Self.largeThread())
    let window = 4_096
    let reserves = AskCatbirdToolPolicy.Budget(route: .onDevice).reserves(
      instructionsWithTools: 700, instructionsWithoutTools: 500, toolDefinitions: 400, offersTools: true
    )
    #expect(try await Self.tokens(content) > window * 10)

    let fit = try await CopilotPromptFitter.fit(content: content, window: window, reserves: reserves, promptTokens: Self.tokens)

    try await Self.expectFits(fit, window: window)
    let rows = try Self.threadRows(fit.content)
    #expect(rows.first { $0.role == "focus" }?.text == Self.focusText)
    #expect(rows.contains { $0.depth == -1 })
    Self.expectPriorityOrder(rows)
    #expect(fit.trim.shortenedSources)
    #expect(fit.trim.notice != nil)
  }

  @Test
  func privateCloudComputeRouteFitsAThreadFarLargerThanTheWindow() async throws {
    let content = Self.content(rows: Self.largeThread())
    let window = 32_768
    let reserves = AskCatbirdToolPolicy.Budget(route: .privateCloudCompute).reserves(
      instructionsWithTools: 900, instructionsWithoutTools: 600, toolDefinitions: 700, offersTools: true
    )
    #expect(try await Self.tokens(content) > window)

    let fit = try await CopilotPromptFitter.fit(content: content, window: window, reserves: reserves, promptTokens: Self.tokens)

    try await Self.expectFits(fit, window: window)
    // The cloud window leaves room for every planned lookup.
    #expect(fit.reserve.level == .tools(reads: 8))
    #expect(!fit.trim.reducedResearch)
    let rows = try Self.threadRows(fit.content)
    #expect(rows.first { $0.role == "focus" }?.text == Self.focusText)
    #expect(rows.contains { $0.depth == -1 })
    #expect(rows.filter { $0.depth == 1 }.count == 4)
    Self.expectPriorityOrder(rows)
    #expect(fit.trim.shortenedSources)
    #expect(fit.trim.notice != nil)
  }

  @Test
  func cloudRouteNoLongerFailsWhereTheFixedCapDid() async throws {
    // The reported failure: a 17,568-token cloud turn against an 8,192 cap.
    let content = Self.content(rows: Array(Self.largeThread().prefix(8)))
    let reserves = AskCatbirdToolPolicy.Budget(route: .privateCloudCompute).reserves(
      instructionsWithTools: 900, instructionsWithoutTools: 600, toolDefinitions: 700, offersTools: true
    )
    let fit = try await CopilotPromptFitter.fit(content: content, window: 32_768, reserves: reserves, promptTokens: Self.tokens)
    #expect(fit.reserve.tokens > 8_192)
    #expect(fit.trim.isEmpty)
    #expect(fit.trim.notice == nil)
  }

  // MARK: - Reserve

  @Test
  func reserveCloseToTheWindowCutsLookupsBeforeFailing() async throws {
    let content = Self.content(rows: Self.largeThread())
    let window = 4_096
    // Three lookups alone would exceed the window.
    let reserves = AskCatbirdToolPolicy.Budget(route: .onDevice).reserves(
      instructionsWithTools: 1_800, instructionsWithoutTools: 900, toolDefinitions: 400, offersTools: true
    )
    #expect(reserves[0].tokens > window)

    let fit = try await CopilotPromptFitter.fit(content: content, window: window, reserves: reserves, promptTokens: Self.tokens)

    try await Self.expectFits(fit, window: window)
    #expect(fit.reserve.level != .tools(reads: 3))
    #expect(fit.trim.reducedResearch)
    #expect(fit.trim.notice != nil)
  }

  @Test
  func toolsAreDroppedWhenEvenOneLookupDoesNotFit() async throws {
    let content = Self.content(rows: Self.largeThread())
    let reserves = AskCatbirdToolPolicy.Budget(route: .onDevice).reserves(
      instructionsWithTools: 2_600, instructionsWithoutTools: 900, toolDefinitions: 400, offersTools: true
    )
    let fit = try await CopilotPromptFitter.fit(content: content, window: 4_096, reserves: reserves, promptTokens: Self.tokens)
    try await Self.expectFits(fit, window: 4_096)
    #expect(fit.reserve.level == .noTools)
    #expect(fit.trim.reducedResearch)
  }

  // MARK: - Failure

  @Test
  func failsOnlyWhenTheSelectedPostCannotFit() async throws {
    let reserves = [CopilotReserve(level: .noTools, tokens: 1_000)]
    var rows = Self.largeThread()
    rows[0]["text"] = String(repeating: "x", count: 20_000)
    do {
      _ = try await CopilotPromptFitter.fit(
        content: Self.content(rows: rows), window: 4_096, reserves: reserves, promptTokens: Self.tokens
      )
      Issue.record("A selected post larger than the window was accepted")
    } catch BlueskyAgentError.contextLimitExceeded(let limit, let required) {
      #expect(limit == 4_096)
      #expect(required > limit)
    }

    // A selected post that fits on its own always gets an answer, however large the thread.
    let fit = try await CopilotPromptFitter.fit(
      content: Self.content(rows: Self.largeThread()), window: 2_000, reserves: reserves, promptTokens: Self.tokens
    )
    try await Self.expectFits(fit, window: 2_000)
    #expect(try Self.threadRows(fit.content).first { $0.role == "focus" }?.text == Self.focusText)
  }

  // MARK: - Evidence and history

  @Test
  func otherEvidenceIsShortenedOrDroppedWithANote() async throws {
    let lookup = CopilotEvidence(origin: "web_fetch", text: String(repeating: "page ", count: 4_000),
                                 sources: [], wasTruncated: false)
    let content = Self.content(rows: Array(Self.largeThread().prefix(3)), extra: [lookup])
    let reserves = [CopilotReserve(level: .noTools, tokens: 1_500)]
    let fit = try await CopilotPromptFitter.fit(content: content, window: 4_096, reserves: reserves, promptTokens: Self.tokens)
    try await Self.expectFits(fit, window: 4_096)
    let other = fit.content.evidence.filter { $0.origin != "selected_thread" }
    let allShortened = other.allSatisfy { $0.wasTruncated }
    #expect(allShortened)
    let explainsOmission = other.contains(where: { $0.text.contains("context") })
    #expect(explainsOmission)
    #expect(fit.trim.shortenedSources)
  }

  @Test
  func latestExchangeIsKeptAndOlderTurnsAreTrimmedFirst() async throws {
    let turns = (0..<6).map { index in
      CopilotStoredTurn(role: index.isMultiple(of: 2) ? .user : .assistant,
                        text: String(repeating: "turn\(index) ", count: 150),
                        createdAt: Date(timeIntervalSince1970: Double(index)))
    }
    let content = Self.content(rows: Self.largeThread(), history: turns)
    let reserves = AskCatbirdToolPolicy.Budget(route: .onDevice).reserves(
      instructionsWithTools: 700, instructionsWithoutTools: 500, toolDefinitions: 400, offersTools: true
    )
    let fit = try await CopilotPromptFitter.fit(content: content, window: 4_096, reserves: reserves, promptTokens: Self.tokens)
    try await Self.expectFits(fit, window: 4_096)
    #expect(Array(fit.content.history.map(\.id).suffix(2)) == turns.suffix(2).map(\.id))
    #expect(fit.trim.removedTurnCount == turns.count - fit.content.history.count)
    #expect(fit.trim.removedTurnCount > 0)
  }

  // MARK: - Fixtures

  /// Rough counter: four characters per token over the real prompt format.
  private static func tokens(_ content: CopilotPromptContent) async throws -> Int {
    guard #available(iOS 26.0, macOS 26.0, *) else {
      throw CancellationError()
    }
    return BlueskyIntelligenceAgent.formatContextualPrompt(
      context: content.context, history: content.history, prompt: question, evidence: content.evidence
    ).count / 4
  }

  /// Sixty posts of 3,000 characters around the selected post: three ancestors,
  /// four direct replies and deeper replies.
  private static func largeThread() -> [[String: Any]] {
    var rows: [[String: Any]] = [["role": "focus", "depth": 0, "text": focusText, "uri": "at://did:plc:a/app.bsky.feed.post/focus"]]
    for depth in [-3, -2, -1] {
      rows.append(row(role: "ancestor", depth: depth, index: rows.count))
    }
    for index in 0..<56 {
      let depth = index < 4 ? 1 : 2 + index % 3
      rows.append(row(role: "reply", depth: depth, index: rows.count))
    }
    return rows
  }

  private static func row(role: String, depth: Int, index: Int) -> [String: Any] {
    ["role": role, "depth": depth, "uri": "at://did:plc:a/app.bsky.feed.post/\(index)",
     "text": "post\(index) " + String(repeating: "word ", count: 600),
     "quotedPosts": [["text": "quoted"]]]
  }

  private static func content(
    rows: [[String: Any]], extra: [CopilotEvidence] = [], history: [CopilotStoredTurn] = []
  ) -> CopilotPromptContent {
    let payload: [String: Any] = ["posts": rows, "omittedReturnedItems": 0, "coverage": "complete"]
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    let thread = CopilotEvidence(origin: "selected_thread", text: String(decoding: data ?? Data(), as: UTF8.self),
                                 sources: [], wasTruncated: false)
    return CopilotPromptContent(
      context: .post(uri: "at://did:plc:a/app.bsky.feed.post/focus", cid: nil, authorDID: "did:plc:a", text: focusText),
      evidence: [thread] + extra, history: history
    )
  }

  private struct Row {
    let role: String
    let depth: Int
    let text: String
  }

  private static func threadRows(_ content: CopilotPromptContent) throws -> [Row] {
    let thread = try #require(content.evidence.first { $0.origin == "selected_thread" })
    let object = try #require(try JSONSerialization.jsonObject(with: Data(thread.text.utf8)) as? [String: Any])
    let posts = try #require(object["posts"] as? [[String: Any]])
    return posts.map { Row(role: $0["role"] as? String ?? "", depth: ($0["depth"] as? NSNumber)?.intValue ?? 0,
                           text: $0["text"] as? String ?? "") }
  }

  private static func expectFits(_ fit: CopilotPromptFit, window: Int) async throws {
    #expect(fit.tokenLimit == window)
    #expect(fit.promptTokens + fit.reserve.tokens <= window)
    #expect(try await tokens(fit.content) == fit.promptTokens)
  }

  /// The parent comes before direct replies, and direct replies before anything further away.
  private static func expectPriorityOrder(_ rows: [Row]) {
    let kept = Set(rows.map(\.depth))
    if kept.contains(1) { #expect(kept.contains(-1)) }
    if kept.contains(where: { $0 >= 2 || $0 <= -2 }) {
      #expect(rows.filter { $0.depth == 1 }.count == 4)
    }
  }
}
#endif
