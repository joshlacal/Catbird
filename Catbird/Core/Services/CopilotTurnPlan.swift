import Foundation

/// The tools, task approach and authority for one Ask Catbird turn, derived only
/// from the current user's request, the selected subject and the model route.
///
/// Read tools are offered generously: they are read-only, share a fixed per-turn
/// budget, and their results are bounded untrusted source material. Actions stay
/// conservative. This English lexical router is not an intent classifier, so
/// unfamiliar, negated or conditional phrasing never authorizes an action, and
/// source text and conversation history never grant authority.
typealias CopilotToolKind = CopilotTurnPlan.ToolKind

struct CopilotTurnPlan: Equatable, Sendable {
  enum ToolKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case fetchThread
    case searchPosts
    case searchProfiles
    case searchFeeds
    case getProfile
    case getAuthorPosts
    case getSimilarAccounts
    case getPosts
    case getQuotes
    case getFeedPosts
    case getTrends
    case fetchWebPage
    case proposeAction
  }

  /// A task approach: which evidence to gather first and how to shape the answer.
  enum Skill: String, CaseIterable, Equatable, Hashable, Sendable {
    case general
    case explainThread
    case profileOverview
    case factCheck
    case catchUp
    case compareViewpoints
    case feedOverview
    case draft
  }

  let toolKinds: [ToolKind]
  let threadAnchorURI: String?
  let allowedActions: Set<String>
  let skill: Skill

  init(toolKinds: [ToolKind], threadAnchorURI: String?, allowedActions: Set<String>, skill: Skill = .general) {
    self.toolKinds = toolKinds
    self.threadAnchorURI = threadAnchorURI
    self.allowedActions = allowedActions
    self.skill = skill
  }

  /// On device, every tool definition spends the 4K context window, so the set
  /// is focused on the task. Private Cloud Compute gets every read tool.
  static let onDeviceToolLimit = 3

  static func make(prompt: String, context: CopilotContext, route: CopilotModelRoute = .onDevice) -> Self {
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
      return .init(toolKinds: [.proposeAction], threadAnchorURI: nil, allowedActions: actions, skill: .draft)
    }

    let search = searchKind(command: command)
    let skill = skill(command: command, context: context, search: search)
    // The caller fetches a known thread subject before generation, once, using the
    // same read budget as model-selected tools. Do not ask the model to infer it.
    let anchor = search == nil ? threadAnchor(command: command, context: context) : nil
    let hasLink = promptHasLink(prompt) || contextHasLink(context)
    let kinds = toolKinds(skill: skill, search: search, context: context, hasLink: hasLink, route: route)
    return .init(toolKinds: kinds, threadAnchorURI: anchor, allowedActions: [], skill: skill)
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

  // MARK: - Task approach

  private static func skill(command: String, context: CopilotContext, search: ToolKind?) -> Skill {
    if matches(command, #"\b(?:fact[- ]?check|is (?:this|it|that) (?:true|accurate|real|correct|legit|misleading)|verify|debunk|true or false|sources? (?:for|on)|evidence (?:for|that))\b"#) {
      return .factCheck
    }
    if matches(command, #"\b(?:view ?points|perspectives|both sides|sides of|opinions on|people (?:think|are saying|are reacting)|react(?:ion|ions|ing)|debate|controvers(?:y|ial)|disagree)\b"#) {
      return .compareViewpoints
    }
    if matches(command, #"\b(?:catch me up|what'?s (?:happening|going on|new|trending)|trending|news|latest on|what did i miss|today on bluesky)\b"#) {
      return .catchUp
    }
    if matches(command, #"^(?:rewrite|reword|rephrase|translate|proofread|shorten|draft|write|compose|polish)\b"#) {
      return .draft
    }
    if search == .searchProfiles || matches(command, #"\b(?:who is|who's|who are|tell me about (?:this|them)|what do(?:es)? (?:they|this account|this person) post|similar accounts|accounts like)\b"#) {
      return .profileOverview
    }
    if search == .searchFeeds { return .feedOverview }
    switch context {
    case .profile:
      return .profileOverview
    case .thread:
      return .explainThread
    case .post:
      if matches(command, #"^(?:summarize|summarise|explain|what|why|how|context|background)\b"#)
        || matches(command, #"\b(?:thread|conversation|replies|context)\b"#) {
        return .explainThread
      }
    case .feed:
      return .feedOverview
    case .topic:
      return .catchUp
    default:
      break
    }
    return .general
  }

  private static func toolKinds(
    skill: Skill, search: ToolKind?, context: CopilotContext, hasLink: Bool, route: CopilotModelRoute
  ) -> [ToolKind] {
    var preferred: [ToolKind] = []
    if let search { preferred.append(search) }
    if search == .searchPosts { preferred.append(.fetchThread) }
    switch skill {
    case .explainThread:
      preferred += [.fetchThread, .getQuotes]
      if hasLink { preferred.append(.fetchWebPage) }
      preferred += [.getProfile, .searchPosts]
    case .profileOverview:
      preferred += [.getProfile, .getAuthorPosts, .getSimilarAccounts, .searchProfiles]
    case .factCheck:
      if hasLink { preferred.append(.fetchWebPage) }
      preferred += [.searchPosts, .fetchThread, .getQuotes]
    case .catchUp:
      preferred += [.getTrends, .searchPosts, .fetchThread]
      if hasLink { preferred.append(.fetchWebPage) }
    case .compareViewpoints:
      preferred += [.searchPosts, .getQuotes, .fetchThread, .getProfile]
    case .feedOverview:
      preferred += [.getFeedPosts, .searchFeeds, .getProfile]
    case .draft:
      if hasLink { preferred.append(.fetchWebPage) }
      switch context {
      case .post, .thread: preferred.append(.fetchThread)
      case .profile: preferred.append(.getAuthorPosts)
      default: break
      }
    case .general:
      if hasLink { preferred.append(.fetchWebPage) }
      switch context {
      case .post, .thread: preferred += [.fetchThread, .getQuotes, .getProfile]
      case .profile: preferred += [.getProfile, .getAuthorPosts]
      case .feed: preferred += [.getFeedPosts, .searchFeeds]
      default: preferred += [.searchPosts, .searchProfiles, .getTrends]
      }
    }

    var seen: Set<ToolKind> = []
    let focused = preferred.filter { seen.insert($0).inserted }
    switch route {
    case .onDevice:
      return Array(focused.prefix(onDeviceToolLimit))
    case .privateCloudCompute:
      let everyReadTool = ToolKind.allCases.filter { $0 != .proposeAction }
      return focused + everyReadTool.filter { !focused.contains($0) }
    }
  }

  private static func promptHasLink(_ prompt: String) -> Bool {
    matches(prompt.lowercased(), #"\bhttps?://|\bwww\.[a-z0-9-]+\.|\b[a-z0-9-]+\.(?:com|org|net|io|co|news|gov|edu|dev|app|blue)/"#)
  }

  private static func contextHasLink(_ context: CopilotContext) -> Bool {
    switch context {
    case .topic(_, _, let link):
      return link.hasPrefix("http")
    case .post(_, _, _, let text, let evidence):
      if text.contains("http://") || text.contains("https://") { return true }
      guard let evidence else { return false }
      return (evidence.selectedPost.media + evidence.quotedPosts.flatMap(\.media)).contains { media in
        media.uri?.hasPrefix("http") == true
      }
    default:
      return false
    }
  }

  // MARK: - Lexical helpers

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

  // MARK: - Actions

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
      String(
        localized: "Ask Catbird reached the read limit for this request. Ask a follow-up to load more context.",
        comment: "Error shown when Ask Catbird exhausts its per-turn read budget."
      )
    }
  }

  /// Reads allowed per turn on each route. On device, results share a 4K
  /// context window; Private Cloud Compute has room to research.
  static func maximumReads(for route: CopilotModelRoute) -> Int {
    route == .privateCloudCompute ? 8 : 3
  }

  static let hardLimit = 8

  private var remaining: Int
  private var attemptsAfterExhaustion = 0

  init(maximumReads: Int = 3) {
    remaining = min(Self.hardLimit, max(0, maximumReads))
  }

  /// Spends one read when available. Once the budget is spent the model is told
  /// to answer with the evidence it has; repeated attempts after that end the turn.
  func tryConsume() throws -> Bool {
    try Task.checkCancellation()
    if remaining > 0 {
      remaining -= 1
      return true
    }
    attemptsAfterExhaustion += 1
    guard attemptsAfterExhaustion <= 2 else { throw BudgetError.exhausted }
    return false
  }

  func consume() throws {
    try Task.checkCancellation()
    guard remaining > 0 else { throw BudgetError.exhausted }
    remaining -= 1
  }
}
