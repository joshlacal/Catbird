import Foundation

/// A conservative tool envelope derived only from the current user's request.
/// This English lexical router is not an intent classifier: unfamiliar or ambiguous
/// phrasing gets fewer tools. Source text and conversation history never grant authority.
struct CopilotTurnPlan: Equatable, Sendable {
  enum ToolKind: String, Equatable, Sendable {
    case fetchThread
    case searchPosts
    case searchProfiles
    case searchFeeds
    case proposeAction
  }

  let toolKinds: [ToolKind]
  let threadAnchorURI: String?
  let allowedActions: Set<String>

  static func make(prompt: String, context: CopilotContext) -> Self {
    let request = normalized(prompt)
    let command = request.replacingOccurrences(
      of: #"^(?:(?:please|can you|could you|would you|will you|help me|i want you to|i'd like you to)\s+)+"#,
      with: "",
      options: .regularExpression
    )

    // Bare command questions are advisory. Explicit polite requests such as
    // "Could you please follow this account?" still request a confirmation proposal.
    let advisoryQuestion = request.hasSuffix("?") && !matches(
      request, #"^(?:(?:please|help me)\s+)*(?:can|could|would|will) you\b"#
    )
    let actions: Set<String> = advisoryQuestion ? [] : allowedActions(command: command, context: context)
    if !actions.isEmpty {
      return .init(toolKinds: [.proposeAction], threadAnchorURI: nil, allowedActions: actions)
    }

    if let anchor = threadAnchor(command: command, context: context) {
      // The caller fetches this known subject before generation, once, using the
      // same read budget as model-selected tools. Do not ask the model to infer it.
      return .init(toolKinds: [], threadAnchorURI: anchor, allowedActions: [])
    }

    if let kind = searchKind(command: command) {
      let kinds: [ToolKind] = kind == .searchPosts ? [.searchPosts, .fetchThread] : [kind]
      return .init(toolKinds: kinds, threadAnchorURI: nil, allowedActions: [])
    }

    return .init(toolKinds: [], threadAnchorURI: nil, allowedActions: [])
  }

  /// Capture known missing context without asking the model to choose an identity.
  static func contextAnchor(for context: CopilotContext) -> String? {
    if case .thread(let anchor) = context { return anchor }
    guard case .post(let uri, _, _, _, let snapshot) = context else { return nil }
    guard let snapshot else { return uri }
    if snapshot.selectedPost.replyToURI != nil || snapshot.selectedPost.contentStatus == .unreadable {
      return uri
    }
    if snapshot.selectedPost.quotedPostURI != nil && snapshot.quotedPosts.isEmpty { return uri }
    return nil
  }

  private static func normalized(_ value: String) -> String {
    value.lowercased(with: Locale(identifier: "en_US_POSIX"))
      .replacingOccurrences(of: "’", with: "'")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func matches(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) != nil
  }

  private static func threadAnchor(command: String, context: CopilotContext) -> String? {
    let readsThread = matches(command, #"^(?:summarize|summarise|explain|read|show|what|why|how)\b"#)
    guard readsThread else { return nil }
    switch context {
    case .thread(let anchor):
      return anchor
    case .post(let uri, _, _, _, _):
      guard matches(command, #"\b(?:thread|conversation|replies)\b"#) else { return nil }
      return uri
    default:
      return nil
    }
  }

  private static func searchKind(command: String) -> ToolKind? {
    guard let range = command.range(
      of: #"^(?:find|search(?: for)?|look for|look up|show me)\s+"#,
      options: .regularExpression
    ) else { return nil }
    let subject = String(command[range.upperBound...])
    // Classify the requested result type, not words later inside the search query.
    let prefix = #"^(?:(?:me|some|a|an|the|more|relevant|recent|latest|popular|new|other)\s+)*"#
    if matches(subject, prefix + #"(?:profiles?|people|users?|accounts?)\b"#) { return .searchProfiles }
    if matches(subject, prefix + #"feeds?\b"#) { return .searchFeeds }
    if matches(subject, prefix + #"posts?\b"#) { return .searchPosts }
    // A generic search is a post search. "Show me" alone needs a result type;
    // otherwise a request such as "show me a shorter version" would search.
    guard !command.hasPrefix("show me ") else { return nil }
    return .searchPosts
  }

  private static func allowedActions(command: String, context: CopilotContext) -> Set<String> {
    // Fail closed on negation, conditional and advisory wording, including
    // corrections later in the request. Confirmation remains mandatory downstream.
    guard !matches(command, #"\b(?:not|never|don't|dont|cannot|can't|without|avoid|if|whether|should|shouldn't|hypothetical)\b"#)
    else { return [] }

    if matches(command, #"^(?:draft|write|prepare|compose) (?:me )?(?:a |the )?(?:new )?(?:post|post draft)\b"#) {
      return ["preparePostDraft"]
    }

    switch context {
    case .post(_, let cid?, _, _, _) where !cid.isEmpty:
      if isDraft(command, subject: "reply") {
        return ["prepareReply"]
      }
      if isDraft(command, subject: "quote(?: post)?") {
        return ["prepareQuote"]
      }
      return action(command, targets: ["this", "it", "this post", "the post"], verbs: [
        "like": "likePost", "unlike": "unlikePost", "repost": "repostPost",
        "unrepost": "unrepostPost", "bookmark": "bookmarkPost", "unbookmark": "unbookmarkPost",
        "hide": "hidePost", "unhide": "unhidePost"
      ])
    case .profile(_, let handle, _):
      return action(command, targets: [
        "this", "them", "this profile", "this account", "this user", "this person", "this author",
        "@" + normalized(handle)
      ], verbs: [
        "follow": "followActor", "unfollow": "unfollowActor", "mute": "muteActor",
        "unmute": "unmuteActor", "block": "blockActor", "unblock": "unblockActor"
      ])
    case .thread:
      return action(command, targets: ["this", "it", "this thread", "the thread", "this conversation"], verbs: [
        "mute": "muteThread", "unmute": "unmuteThread"
      ])
    case .feed(let uri?, _) where !uri.isEmpty:
      return action(command, targets: ["this", "it", "this feed", "the feed"], verbs: [
        "save": "saveFeed", "unsave": "unsaveFeed", "pin": "pinFeed", "unpin": "unpinFeed"
      ])
    case .smartFilter:
      return action(command, targets: ["this", "it", "this filter", "the filter", "this smart filter"], verbs: [
        "enable": "enableSmartFilter", "disable": "disableSmartFilter"
      ])
    default:
      return []
    }
  }

  private static func isDraft(_ command: String, subject: String) -> Bool {
    guard let prefix = command.range(
      of: #"^(?:draft|write|prepare|compose) (?:me )?(?:a |the )?"# + subject + #"\b"#,
      options: .regularExpression
    ) else { return false }
    let remainder = command[prefix.upperBound...].trimmingCharacters(in: .whitespaces)
    // A draft is for the selected post. Do not reinterpret an explicitly different
    // target as the selected post, even though the composer still requires review.
    if matches(remainder, #"^(?:to|for)\s+"#) {
      return matches(remainder, #"^(?:to|for) (?:this(?: post)?|it)(?:$|[.!?:,]| (?:in|saying|that|about|with)\b)"#)
    }
    return true
  }

  private static func action(_ command: String, targets: [String], verbs: [String: String]) -> Set<String> {
    // Exact simple requests keep quoted instructions, questions, different named
    // targets, and multi-action requests out of the proposal tool's authority.
    let plain = command.replacingOccurrences(of: #"(?:,? please)?[.!?]*$"#, with: "", options: .regularExpression)
    for (verb, token) in verbs {
      if targets.contains(where: { plain == "\(verb) \($0)" }) { return [token] }
    }
    return []
  }
}

/// Shared by every read path in one turn, including deterministic prefetches.
/// Attempts count even when the request fails; a model cannot retry without limit.
actor CopilotReadBudget {
  enum BudgetError: LocalizedError, Equatable {
    case exhausted

    var errorDescription: String? {
      "Ask Catbird reached the read limit for this request. Ask a follow-up to load more context."
    }
  }
  private var remaining: Int

  init(maximumReads: Int = 2) {
    remaining = min(2, max(0, maximumReads))
  }

  func consume() throws {
    try Task.checkCancellation()
    guard remaining > 0 else { throw BudgetError.exhausted }
    remaining -= 1
  }
}
