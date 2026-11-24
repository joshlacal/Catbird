import Foundation

/// The parts of an Ask Catbird prompt that can be shortened to fit a model's
/// context window. The person's question is never shortened.
struct CopilotPromptContent: Sendable {
  var context: CopilotContext
  var evidence: [CopilotEvidence]
  var history: [CopilotStoredTurn]
}

/// What a turn left out to fit its model, reported to the person with the answer.
struct CopilotContextTrim: Equatable, Sendable {
  var removedTurnCount = 0
  var shortenedSources = false
  var reducedResearch = false

  var isEmpty: Bool { removedTurnCount == 0 && !shortenedSources && !reducedResearch }

  var notice: String? {
    if shortenedSources {
      return removedTurnCount > 0
        ? String(localized: "Earlier messages were left out and parts of the thread and sources were shortened to fit this model's limits.",
                 comment: "Ask Catbird: notice when conversation history and source material were trimmed.")
        : String(localized: "Parts of the thread and sources were shortened to fit this model's limits.",
                 comment: "Ask Catbird: notice when thread posts or retrieved sources were trimmed.")
    }
    if removedTurnCount == 1 {
      return String(localized: "An earlier message was left out to keep this conversation within limits.",
                    comment: "Ask Catbird: notice when one earlier message was trimmed.")
    }
    if removedTurnCount > 1 {
      return String(localized: "Some earlier messages were left out to keep this conversation within limits.",
                    comment: "Ask Catbird: notice when several earlier messages were trimmed.")
    }
    if reducedResearch {
      return String(localized: "Ask Catbird looked up less than usual to fit this model's limits.",
                    comment: "Ask Catbird: notice when the tool or lookup budget was reduced.")
    }
    return nil
  }
}

/// Room a turn sets aside for tools: definitions plus the results of `reads` lookups,
/// or no tools at all.
enum CopilotReserveLevel: Equatable, Hashable, Sendable {
  case tools(reads: Int)
  case noTools
}

/// One way to run a turn and the tokens it reserves outside the prompt:
/// instructions, tool definitions, tool results and the answer.
struct CopilotReserve: Equatable, Sendable {
  let level: CopilotReserveLevel
  let tokens: Int
}

struct CopilotPromptFit: Sendable {
  let content: CopilotPromptContent
  let reserve: CopilotReserve
  let promptTokens: Int
  let tokenLimit: Int
  let trim: CopilotContextTrim
}

enum CopilotPromptFitter {
  /// Fits the prompt into `window`, the model's real context size.
  ///
  /// `reserves` is ordered richest first. The richest reserve that leaves room for
  /// the selected item, its direct parent and the latest exchange is used; fewer
  /// lookups or no tools are used only when it does not. Content then shrinks in
  /// priority order: the selected item and the question always stay, then the
  /// direct parent, the nearest replies, other evidence, deeper replies and further
  /// ancestors, with long texts shortened before items are dropped. Older
  /// conversation turns fill whatever room is left. The turn fails only when the
  /// question and the selected item cannot fit even with the smallest reserve.
  static func fit(
    content: CopilotPromptContent,
    window: Int,
    reserves: [CopilotReserve],
    promptTokens: (CopilotPromptContent) async throws -> Int
  ) async throws -> CopilotPromptFit {
    precondition(!reserves.isEmpty, "A turn needs at least one reserve option")
    try Task.checkCancellation()
    let richest = reserves[0]
    let fullTokens = try await promptTokens(content)
    if richest.tokens + fullTokens <= window {
      return CopilotPromptFit(content: content, reserve: richest, promptTokens: fullTokens,
                              tokenLimit: window, trim: CopilotContextTrim())
    }

    let shrinker = CopilotContextShrinker(content)
    var counts: [CopilotContextShrinker.Key: Int] = [:]
    func tokens(_ key: CopilotContextShrinker.Key) async throws -> Int {
      if let cached = counts[key] { return cached }
      try Task.checkCancellation()
      let count = try await promptTokens(shrinker.candidate(key).content)
      counts[key] = count
      return count
    }

    let latestExchange = CopilotContextBudget.latestPairTurns(in: content.history)
    let minimumTokens = try await tokens(shrinker.minimumKey)
    let coreTokens = try await tokens(shrinker.coreKey(history: latestExchange))
    guard let reserve = reserves.first(where: { $0.tokens + coreTokens <= window })
      ?? reserves.first(where: { $0.tokens + minimumTokens <= window }) else {
      let smallest = reserves.map(\.tokens).min() ?? richest.tokens
      throw BlueskyAgentError.contextLimitExceeded(limit: window, required: smallest + minimumTokens)
    }

    let room = window - reserve.tokens
    var chosen = try await shrinker.largestFit(history: latestExchange) { try await tokens($0) <= room }
    if chosen == nil, !latestExchange.isEmpty {
      chosen = try await shrinker.largestFit(history: []) { try await tokens($0) <= room }
    }
    let key = chosen ?? shrinker.minimumKey

    // Older turns use whatever room the chosen content leaves.
    let history = try await CopilotContextBudget.selectHistory(
      turns: content.history, modelContextSize: window, reservedTokenCount: reserve.tokens,
      candidateTokenCount: { turns in
        try await tokens(CopilotContextShrinker.Key(textLimit: key.textLimit, keep: key.keep, historyIDs: turns.map(\.id)))
      }
    )
    let finalKey = CopilotContextShrinker.Key(
      textLimit: key.textLimit, keep: key.keep, historyIDs: history.retainedTurns.map(\.id)
    )
    let candidate = shrinker.candidate(finalKey)
    let trim = CopilotContextTrim(
      removedTurnCount: content.history.count - history.retainedTurns.count,
      shortenedSources: candidate.shortened,
      reducedResearch: reserve.level != richest.level
    )
    return CopilotPromptFit(content: candidate.content, reserve: reserve,
                            promptTokens: try await tokens(finalKey), tokenLimit: window, trim: trim)
  }
}

/// Builds shortened versions of a prompt's thread and evidence.
struct CopilotContextShrinker {
  /// Character limits for texts other than the selected post, loosest first.
  static let textLimits: [Int?] = [nil, 600, 200, 80]
  /// Non-thread evidence is shortened to this multiple of the post text limit.
  static let evidenceTextMultiplier = 5
  static let omissionNote = "Some thread posts or retrieved sources were left out or shortened to fit this model's context. Do not infer their contents."

  struct Key: Hashable {
    let textLimit: Int
    let keep: Int
    let historyIDs: [UUID]
  }

  private enum Item: Hashable {
    case row(Int)
    case evidence(Int)
  }

  private struct Thread {
    let evidenceIndex: Int
    let payload: [String: Any]
    let rows: [[String: Any]]
  }

  private let base: CopilotPromptContent
  private let thread: Thread?
  private let ranked: [Item]

  var itemCount: Int { ranked.count }
  var minimumKey: Key { Key(textLimit: Self.textLimits.count - 1, keep: 0, historyIDs: []) }

  init(_ content: CopilotPromptContent) {
    base = content
    var found: Thread?
    for (index, evidence) in content.evidence.enumerated() {
      guard let object = try? JSONSerialization.jsonObject(with: Data(evidence.text.utf8)) as? [String: Any],
            let rows = object["posts"] as? [[String: Any]],
            rows.contains(where: { $0["role"] as? String == "focus" }) else { continue }
      found = Thread(evidenceIndex: index, payload: object, rows: rows)
      break
    }
    thread = found

    func depth(_ row: [String: Any]) -> Int? { (row["depth"] as? NSNumber)?.intValue }
    var parent: [Item] = []
    var nearestReplies: [Item] = []
    var deeperReplies: [(Int, Item)] = []
    var ancestors: [(Int, Item)] = []
    for (index, row) in (found?.rows ?? []).enumerated() where row["role"] as? String != "focus" {
      switch depth(row) {
      case .some(-1): parent.append(.row(index))
      case .some(1): nearestReplies.append(.row(index))
      case let value? where value < -1: ancestors.append((value, .row(index)))
      case let value?: deeperReplies.append((value, .row(index)))
      case nil: deeperReplies.append((Int.max, .row(index)))
      }
    }
    let otherEvidence = content.evidence.indices
      .filter { $0 != found?.evidenceIndex }
      .map(Item.evidence)
    ranked = parent + nearestReplies + otherEvidence
      + deeperReplies.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
      + ancestors.enumerated().sorted { ($0.element.0, $0.offset) > ($1.element.0, $1.offset) }.map(\.element.1)
  }

  /// The selected item with its direct parent, at full length, and the given turns.
  func coreKey(history: [CopilotStoredTurn]) -> Key {
    let keep = ranked.first.map { item in
      if case .row(let index) = item, (thread?.rows[index]["depth"] as? NSNumber)?.intValue == -1 { return 1 }
      return 0
    } ?? 0
    return Key(textLimit: 0, keep: keep, historyIDs: history.map(\.id))
  }

  /// The most items that fit, preferring more items with shorter texts over fewer
  /// items at full length. Nil when not even the selected item fits.
  func largestFit(history: [CopilotStoredTurn], fits: (Key) async throws -> Bool) async throws -> Key? {
    let ids = history.map(\.id)
    guard try await fits(Key(textLimit: Self.textLimits.count - 1, keep: 0, historyIDs: ids)) else { return nil }
    var best: Key?
    for limit in Self.textLimits.indices {
      if try await fits(Key(textLimit: limit, keep: itemCount, historyIDs: ids)) {
        return Key(textLimit: limit, keep: itemCount, historyIDs: ids)
      }
      var low = 0
      var high = itemCount - 1
      while low < high {
        let middle = (low + high + 1) / 2
        if try await fits(Key(textLimit: limit, keep: middle, historyIDs: ids)) { low = middle } else { high = middle - 1 }
      }
      if best.map({ low > $0.keep }) ?? true { best = Key(textLimit: limit, keep: low, historyIDs: ids) }
    }
    return best
  }

  func candidate(_ key: Key) -> (content: CopilotPromptContent, shortened: Bool) {
    let limit = Self.textLimits[key.textLimit]
    let kept = Set(ranked.prefix(key.keep))
    var shortened = false
    var evidence: [CopilotEvidence] = []
    var droppedEvidence = 0
    for (index, item) in base.evidence.enumerated() {
      if let thread, index == thread.evidenceIndex {
        let result = threadEvidence(item, thread: thread, kept: kept, limit: limit)
        shortened = shortened || result.shortened
        evidence.append(result.evidence)
        continue
      }
      guard kept.contains(.evidence(index)) else {
        droppedEvidence += 1
        continue
      }
      if let limit, item.text.count > limit * Self.evidenceTextMultiplier {
        shortened = true
        evidence.append(CopilotEvidence(
          origin: item.origin,
          text: String(item.text.prefix(limit * Self.evidenceTextMultiplier))
            + "\n[Shortened to fit this model's context; omitted contents are unknown.]",
          sources: item.sources, wasTruncated: true
        ))
      } else {
        evidence.append(item)
      }
    }
    if droppedEvidence > 0 {
      shortened = true
      evidence.append(CopilotEvidence(origin: "context_budget", text: Self.omissionNote, sources: [], wasTruncated: true))
    }
    let history = key.historyIDs.isEmpty ? [] : base.history.filter { key.historyIDs.contains($0.id) }
    return (CopilotPromptContent(context: base.context, evidence: evidence, history: history), shortened)
  }

  private func threadEvidence(
    _ original: CopilotEvidence, thread: Thread, kept: Set<Item>, limit: Int?
  ) -> (evidence: CopilotEvidence, shortened: Bool) {
    var rows: [[String: Any]] = []
    var dropped = 0
    var shortened = false
    for (index, row) in thread.rows.enumerated() {
      if row["role"] as? String == "focus" {
        rows.append(row)
        continue
      }
      guard kept.contains(.row(index)) else {
        dropped += 1
        continue
      }
      var row = row
      if let limit, let text = row["text"] as? String, text.count > limit {
        row["text"] = String(text.prefix(limit))
        row["textTruncated"] = true
        shortened = true
      }
      if let limit, limit <= 80, row["quotedPosts"] != nil || row["media"] != nil {
        row["quotedPosts"] = nil
        row["media"] = nil
        row["detailsOmitted"] = true
        shortened = true
      }
      rows.append(row)
    }
    guard dropped > 0 || shortened else { return (original, false) }
    var payload = thread.payload
    payload["posts"] = rows
    payload["omittedReturnedItems"] = ((payload["omittedReturnedItems"] as? NSNumber)?.intValue ?? 0) + dropped
    payload["trimmedToFitContext"] = Self.omissionNote
    let text = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
      .map { String(decoding: $0, as: UTF8.self) } ?? original.text
    return (CopilotEvidence(origin: original.origin, text: text, sources: original.sources, wasTruncated: true), true)
  }
}
