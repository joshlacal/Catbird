import Foundation
import Petrel

// An immutable, Sendable snapshot of everything the moderation engine needs
// for one signed-in account. The app builds a new policy whenever preferences,
// subscribed labelers or labeler definitions change, and hands it to views and
// services; the policy itself never mutates.
/// Thread-safe LRU cache for label moderation decisions.
/// Memoizes decisions per (uri, cid, policyGeneration, fingerprint).
final class ModerationDecisionCache: @unchecked Sendable {
  static let shared = ModerationDecisionCache()

  /// Fingerprint of all post, embed, and author inputs the moderation engine reads.
  struct PostFingerprint: Hashable, Sendable {
    let authorDID: String
    let postLabels: [ComAtprotoLabelDefs.Label]
    let authorLabels: [ComAtprotoLabelDefs.Label]
    let selfLabels: [String]
    let quoteAuthorDID: String?
    let quoteLabels: [ComAtprotoLabelDefs.Label]?
    let quoteAuthorLabels: [ComAtprotoLabelDefs.Label]?
    let quoteSelfLabels: [String]?
    let blockedAuthorDID: String?

    static let empty = PostFingerprint(
      authorDID: "",
      postLabels: [],
      authorLabels: [],
      selfLabels: [],
      quoteAuthorDID: nil,
      quoteLabels: nil,
      quoteAuthorLabels: nil,
      quoteSelfLabels: nil,
      blockedAuthorDID: nil
    )

    static func recordSelfLabels(_ record: ATProtocolValueContainer?) -> [String] {
      guard let record,
            case .knownType(let value) = record,
            let post = value as? AppBskyFeedPost,
            case .comAtprotoLabelDefsSelfLabels(let selfLabels)? = post.labels
      else { return [] }
      return selfLabels.values.map(\.val)
    }

    init(post: AppBskyFeedDefs.PostView) {
      self.authorDID = post.author.did.didString()
      self.postLabels = post.labels ?? []
      self.authorLabels = post.author.labels ?? []
      self.selfLabels = Self.recordSelfLabels(post.record)

      let recordUnion: AppBskyEmbedRecord.ViewRecordUnion? = {
        switch post.embed {
        case .appBskyEmbedRecordView(let view): return view.record
        case .appBskyEmbedRecordWithMediaView(let view): return view.record.record
        default: return nil
        }
      }()

      switch recordUnion {
      case .appBskyEmbedRecordViewRecord(let quoted):
        self.quoteAuthorDID = quoted.author.did.didString()
        self.quoteLabels = quoted.labels ?? []
        self.quoteAuthorLabels = quoted.author.labels ?? []
        self.quoteSelfLabels = Self.recordSelfLabels(quoted.value)
        self.blockedAuthorDID = nil
      case .appBskyEmbedRecordViewBlocked(let blocked):
        self.quoteAuthorDID = nil
        self.quoteLabels = nil
        self.quoteAuthorLabels = nil
        self.quoteSelfLabels = nil
        self.blockedAuthorDID = blocked.author.did.didString()
      default:
        self.quoteAuthorDID = nil
        self.quoteLabels = nil
        self.quoteAuthorLabels = nil
        self.quoteSelfLabels = nil
        self.blockedAuthorDID = nil
      }
    }

    init(quoted: AppBskyEmbedRecord.ViewRecord) {
      self.authorDID = quoted.author.did.didString()
      self.postLabels = quoted.labels ?? []
      self.authorLabels = quoted.author.labels ?? []
      self.selfLabels = Self.recordSelfLabels(quoted.value)
      self.quoteAuthorDID = nil
      self.quoteLabels = nil
      self.quoteAuthorLabels = nil
      self.quoteSelfLabels = nil
      self.blockedAuthorDID = nil
    }

    init(
      authorDID: String,
      postLabels: [ComAtprotoLabelDefs.Label],
      authorLabels: [ComAtprotoLabelDefs.Label],
      selfLabels: [String],
      quoteAuthorDID: String?,
      quoteLabels: [ComAtprotoLabelDefs.Label]?,
      quoteAuthorLabels: [ComAtprotoLabelDefs.Label]?,
      quoteSelfLabels: [String]?,
      blockedAuthorDID: String?
    ) {
      self.authorDID = authorDID
      self.postLabels = postLabels
      self.authorLabels = authorLabels
      self.selfLabels = selfLabels
      self.quoteAuthorDID = quoteAuthorDID
      self.quoteLabels = quoteLabels
      self.quoteAuthorLabels = quoteAuthorLabels
      self.quoteSelfLabels = quoteSelfLabels
      self.blockedAuthorDID = blockedAuthorDID
    }

    /// Whether any labels exist on the post, its author, or its quoted post/author.
    var hasLabels: Bool {
      !postLabels.isEmpty
        || !authorLabels.isEmpty
        || (quoteLabels?.isEmpty == false)
        || (quoteAuthorLabels?.isEmpty == false)
    }

    /// Whether any labels have an expiration date (`exp != nil`).
    var hasExpiringLabels: Bool {
      postLabels.contains { $0.exp != nil }
        || authorLabels.contains { $0.exp != nil }
        || (quoteLabels?.contains { $0.exp != nil } ?? false)
        || (quoteAuthorLabels?.contains { $0.exp != nil } ?? false)
    }

    /// Decisions are cacheable only when labels exist (non-trivial computation)
    /// and none have an expiration date (which would freeze expiry).
    var isCacheable: Bool {
      hasLabels && !hasExpiringLabels
    }
  }

  struct Key: Hashable {
    let uri: String
    let cid: String
    let generation: UInt64
    let fingerprint: PostFingerprint
  }

  private let lock = NSLock()
  private var storage: [Key: ModerationDecision] = [:]
  private var ring: [Key?]
  private var ringIndex: Int = 0
  private let capacity: Int

  init(capacity: Int = 4096) {
    self.capacity = capacity
    self.ring = Array(repeating: nil, count: capacity)
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage.count
  }

  func decision(uri: String, cid: String, generation: UInt64, fingerprint: PostFingerprint) -> ModerationDecision? {
    lock.lock()
    defer { lock.unlock() }
    let key = Key(uri: uri, cid: cid, generation: generation, fingerprint: fingerprint)
    return storage[key]
  }

  func decision(uri: String, cid: String, generation: UInt64) -> ModerationDecision? {
    lock.lock()
    defer { lock.unlock() }
    return storage.first { $0.key.uri == uri && $0.key.cid == cid && $0.key.generation == generation }?.value
  }

  func setDecision(_ decision: ModerationDecision, uri: String, cid: String, generation: UInt64, fingerprint: PostFingerprint) {
    lock.lock()
    defer { lock.unlock() }
    let key = Key(uri: uri, cid: cid, generation: generation, fingerprint: fingerprint)
    if storage[key] == nil {
      if let evicted = ring[ringIndex] {
        storage.removeValue(forKey: evicted)
      }
      ring[ringIndex] = key
      ringIndex = (ringIndex + 1) % capacity
    }
    storage[key] = decision
  }

  func setDecision(_ decision: ModerationDecision, uri: String, cid: String, generation: UInt64) {
    setDecision(decision, uri: uri, cid: cid, generation: generation, fingerprint: .empty)
  }

  func invalidate() {
    lock.lock()
    defer { lock.unlock() }
    storage.removeAll(keepingCapacity: true)
    ring = Array(repeating: nil, count: capacity)
    ringIndex = 0
  }

  func invalidate(generation: UInt64) {
    lock.lock()
    defer { lock.unlock() }
    storage = storage.filter { $0.key.generation != generation }
    for i in 0..<capacity {
      if ring[i]?.generation == generation {
        ring[i] = nil
      }
    }
  }
}

struct ModerationPolicy: Sendable, Equatable {
  private static let nextGenerationLock = NSLock()
  private static var nextGenerationValue: UInt64 = 1

  static func nextGeneration() -> UInt64 {
    nextGenerationLock.lock()
    defer { nextGenerationLock.unlock() }
    let gen = nextGenerationValue
    nextGenerationValue &+= 1
    return gen
  }

  /// DID of the signed-in account, or `nil` when no account is active.
  let accountDID: String?
  /// Preferences with the EFFECTIVE adult-content value already applied.
  let prefs: ModerationPrefs
  /// Interpreted custom definitions of subscribed labelers, keyed by labeler DID.
  let labelDefinitions: [String: [ModerationLabelDefinition]]
  /// Whether this session has confirmed preferences with the server.
  let isConfirmed: Bool
  /// Generation sequence for this policy instance, used for memoization invalidation.
  let generation: UInt64

  /// Build a policy from stored server state.
  ///
  /// Adult content is effective only when the server preference is on and this
  /// session has confirmed preferences. Only subscribed labelers' definitions
  /// are kept.
  init(
    accountDID: String?,
    serverAdultContentEnabled: Bool,
    contentLabelPrefs: [ContentLabelPreference],
    labelerDIDs: [String],
    labelerDefinitions: [String: [ComAtprotoLabelDefs.LabelValueDefinition]],
    isConfirmed: Bool
  ) {
    let prefs = ModerationPrefs(
      adultContentEnabled: serverAdultContentEnabled && isConfirmed,
      contentLabelPrefs: contentLabelPrefs,
      labelerDIDs: labelerDIDs)

    let subscribed = Set(prefs.labelers.map(\.did))
    var interpreted: [String: [ModerationLabelDefinition]] = [:]
    for (did, definitions) in labelerDefinitions where subscribed.contains(did) {
      let valid = ModerationLabelDefinition.interpretAll(definitions, definedBy: did)
      if !valid.isEmpty { interpreted[did] = valid }
    }

    self.init(accountDID: accountDID, prefs: prefs, labelDefinitions: interpreted, isConfirmed: isConfirmed)
  }

  /// Direct construction from already-normalized values.
  init(
    accountDID: String?,
    prefs: ModerationPrefs,
    labelDefinitions: [String: [ModerationLabelDefinition]] = [:],
    isConfirmed: Bool
  ) {
    self.accountDID = accountDID
    self.prefs = prefs
    self.labelDefinitions = labelDefinitions
    self.isConfirmed = isConfirmed
    self.generation = ModerationPolicy.nextGeneration()
  }

  /// Content-based equality: two policies with identical configuration compare equal regardless of generation.
  static func == (lhs: ModerationPolicy, rhs: ModerationPolicy) -> Bool {
    lhs.accountDID == rhs.accountDID
      && lhs.isConfirmed == rhs.isConfirmed
      && lhs.prefs == rhs.prefs
      && lhs.labelDefinitions == rhs.labelDefinitions
  }

  /// The policy used before preferences are known: no account, adult content
  /// off, builtin defaults, the Bluesky moderation service only.
  static let failClosed = ModerationPolicy(
    accountDID: nil,
    serverAdultContentEnabled: false,
    contentLabelPrefs: [],
    labelerDIDs: [],
    labelerDefinitions: [:],
    isConfirmed: false)

  /// The effective adult-content setting.
  var adultContentEnabled: Bool { prefs.adultContentEnabled }

  func options(now: Date = Date()) -> ModerationOptions {
    ModerationOptions(userDID: accountDID, prefs: prefs, labelDefinitions: labelDefinitions, now: now)
  }

  /// Adds only a platform restriction. Call on the unchanged confirmed base policy,
  /// so removing the extra ceiling can never invent a preference or lose its value.
  func restrictingMatureContent(_ restricted: Bool) -> ModerationPolicy {
    guard restricted, prefs.adultContentEnabled else { return self }
    var effective = prefs
    effective.adultContentEnabled = false
    return ModerationPolicy(
      accountDID: accountDID, prefs: effective,
      labelDefinitions: labelDefinitions, isConfirmed: isConfirmed)
  }

  // MARK: - Decisions

  func decide(post: AppBskyFeedDefs.PostView) -> ModerationDecision {
    let fingerprint = ModerationDecisionCache.PostFingerprint(post: post)
    guard fingerprint.isCacheable else {
      return ModerationSubjects.decidePost(post, options: options())
    }
    let uri = post.uri.uriString()
    let cid = post.cid.string
    if let cached = ModerationDecisionCache.shared.decision(uri: uri, cid: cid, generation: generation, fingerprint: fingerprint) {
      return cached
    }
    let decision = ModerationSubjects.decidePost(post, options: options())
    ModerationDecisionCache.shared.setDecision(decision, uri: uri, cid: cid, generation: generation, fingerprint: fingerprint)
    return decision
  }

  func decide(quotedPost: AppBskyEmbedRecord.ViewRecord) -> ModerationDecision {
    let fingerprint = ModerationDecisionCache.PostFingerprint(quoted: quotedPost)
    guard fingerprint.isCacheable else {
      return ModerationSubjects.decideQuotedPost(quotedPost, options: options())
    }
    let uri = quotedPost.uri.uriString()
    let cid = quotedPost.cid.string
    if let cached = ModerationDecisionCache.shared.decision(uri: uri, cid: cid, generation: generation, fingerprint: fingerprint) {
      return cached
    }
    let decision = ModerationSubjects.decideQuotedPost(quotedPost, options: options())
    ModerationDecisionCache.shared.setDecision(decision, uri: uri, cid: cid, generation: generation, fingerprint: fingerprint)
    return decision
  }

  /// Account-level labels only.
  func decide(account: some ModerationAccountSubject) -> ModerationDecision {
    ModerationSubjects.decideAccount(account, options: options())
  }

  /// Account and profile labels merged, as `moderateProfile` does upstream.
  func decide(profile: some ModerationAccountSubject) -> ModerationDecision {
    ModerationSubjects.decideProfileSubject(profile, options: options())
  }

  // MARK: - Conveniences

  /// Whether feed rows should drop this post (`contentList` filter).
  func listFilter(post: AppBskyFeedDefs.PostView) -> Bool {
    decide(post: post).ui(.contentList).filter
  }

  /// The definition behind a label, for display. Resolves builtins first, then
  /// the issuing labeler's own definitions.
  func definition(for label: ComAtprotoLabelDefs.Label) -> ModerationLabelDefinition? {
    ModerationLabelDefinition.resolve(
      labelValue: label.val, labelerDID: label.src.didString(), custom: labelDefinitions)
  }
}
