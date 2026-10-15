import Foundation
import Observation
import OrderedCollections
import OSLog
import Petrel

/// The shared post no longer exists or isn't visible to this account
/// (deleted, or its author blocked the viewer). Retrying won't help.
struct ChatRecordEmbedUnavailableError: Error {}

/// Shared-post cards in DMs, shared by UIKit prefetch and visible SwiftUI cells.
///
/// A record is kept under the accept-labelers scope its labels were hydrated under, and a card shows it
/// only under that scope: the applied `atproto-accept-labelers` header naming exactly the labelers the
/// account's moderation policy trusts. Then the policy can act on every label the record can carry.
/// Two sources qualify:
/// - a getMessages page whose header stayed applied from request to response (`seed`), so the card
///   renders on the first layout without a request (P135), and
/// - one `app.bsky.feed.getPosts` batch sent under the header (`load`), for every other post: pages
///   sent before the header was applied, pages whose header changed in flight, and messages that
///   arrived through getLog.
/// Until a record exists under the current scope the card shows its placeholder, never the post.
///
/// No guessed height is stored: a warm record renders its real text and media aspect ratios on the
/// first sizing pass, at the current width and text size.
@MainActor
@Observable
final class ChatRecordEmbedStore {
  static let shared = ChatRecordEmbedStore()
  typealias Record = AppBskyEmbedRecord.ViewRecordUnion
  /// Hydrates posts under the header the client sends.
  typealias PostsLoader = @MainActor ([ATProtocolURI]) async throws -> [AppBskyFeedDefs.PostView]

  /// The getPosts lexicon's limit on `uris`.
  static let batchSize = 25
  static let capacity = 256
  /// Conversations whose shared posts a load may confirm alongside its own.
  static let conversationCapacity = 8

  /// The account session a record was fetched for.
  struct Context: Hashable, Sendable {
    let account: String
    let state: ObjectIdentifier
    let client: ObjectIdentifier
  }

  /// A session and the labeler DIDs (sorted) a record's labels were hydrated under.
  struct Scope: Hashable, Sendable {
    let context: Context
    let labelers: [String]
  }

  /// A shared post from a getMessages page, with the sorted accept-labelers DIDs that page was hydrated
  /// under, or nil when they are unknown.
  struct Seed: Equatable, Sendable {
    let uri: String
    let record: Record
    let hydratedUnder: [String]?
  }

  /// What a load needs: the scope it confirms under, the scope now in effect, and the request.
  struct Source {
    let scope: Scope
    let currentScope: @MainActor () -> Scope?
    let fetch: PostsLoader
  }

  private struct Key: Hashable, Sendable {
    let scope: Scope
    let uri: String
  }

  private struct Conversation: Hashable, Sendable {
    let context: Context
    let id: String
  }

  private enum Origin: Sendable {
    case messages
    case posts
  }

  private enum Entry: Sendable {
    case record(Record, Origin)
    /// getPosts under this scope did not return the post.
    case unavailable
  }

  private struct Batch {
    let id: UUID
    let task: Task<[String: Record], Error>
  }

  private var entries: OrderedDictionary<Key, Entry> = [:]
  /// Batches are owned by the store: a card that leaves never cancels one another card awaits.
  @ObservationIgnored private var inFlight: [Key: Batch] = [:]
  /// Posts whose last batch failed. They load again only for their own card.
  @ObservationIgnored private var failed: Set<Key> = []
  /// Each recently seeded conversation's shared posts, newest message first.
  @ObservationIgnored private var conversationPosts: OrderedDictionary<Conversation, OrderedSet<String>> = [:]
  /// getMessages records already compared with a getPosts record under the same scope.
  @ObservationIgnored private var parityChecked: Set<Key> = []
  @ObservationIgnored private var labelScopeResolution: Task<Void, Never>?
  @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "ChatRecordEmbedStore")

  init() {}

  // MARK: - Records

  func cachedRecord(uri: String, scope: Scope) -> Record? {
    guard case .record(let record, _)? = entries[Key(scope: scope, uri: uri)] else { return nil }
    return record
  }

  func isUnavailable(uri: String, scope: Scope) -> Bool {
    guard case .unavailable? = entries[Key(scope: scope, uri: uri)] else { return false }
    return true
  }

  /// Records a conversation's shared posts. A seed hydrated under a known header is kept under that
  /// scope; the rest only name the posts a later load confirms in the same batch. Seeding never sends a
  /// request.
  func seed(_ seeds: [Seed], conversation: String, context: Context) {
    var posts = OrderedSet<String>()
    var updated = entries
    var changed = false
    var parity = (compared: 0, lacking: 0)
    if parityChecked.count >= Self.capacity { parityChecked.removeAll() }
    for seed in seeds {
      guard case .appBskyEmbedRecordViewRecord = seed.record else { continue }
      guard posts.count < Self.capacity else { break }
      posts.append(seed.uri)
      guard let labelers = seed.hydratedUnder else { continue }
      let key = Key(scope: Scope(context: context, labelers: labelers.sorted()), uri: seed.uri)
      if merge(seed.record, for: key, into: &updated, parity: &parity) {
        failed.remove(key)
        changed = true
      }
    }
    if changed { entries = updated }

    let conversationKey = Conversation(context: context, id: conversation)
    conversationPosts.removeValue(forKey: conversationKey)
    if conversationPosts.count >= Self.conversationCapacity { conversationPosts.removeFirst() }
    conversationPosts[conversationKey] = posts

    if parity.compared > 0 {
      logger.info(
        "Shared-post label parity: \(parity.compared, privacy: .public) getMessages record(s) compared with getPosts under the same header; \(parity.lacking, privacy: .public) lacked a label or a post getPosts withheld"
      )
    }
  }

  /// Keeps a getMessages record hydrated under `key.scope`, unless getPosts already answered for the
  /// post under that scope with a record carrying a label the chat copy lacks, or with no post. Each
  /// first meeting of the two is counted for the parity log. Returns whether `updated` changed.
  private func merge(
    _ record: Record, for key: Key, into updated: inout OrderedDictionary<Key, Entry>,
    parity: inout (compared: Int, lacking: Int)
  ) -> Bool {
    switch updated[key] {
    case .record(let confirmed, .posts)?:
      let seedLabels = Self.labelSignature(record)
      let confirmedLabels = Self.labelSignature(confirmed)
      let carriesEveryLabel = confirmedLabels.isSubset(of: seedLabels)
      if parityChecked.insert(key).inserted {
        parity.compared += 1
        if !carriesEveryLabel { parity.lacking += 1 }
      }
      // A chat copy carrying every label getPosts returned and more is the fresher record.
      guard carriesEveryLabel, seedLabels != confirmedLabels else { return false }
    case .unavailable?:
      if parityChecked.insert(key).inserted {
        parity.compared += 1
        parity.lacking += 1
      }
      return false
    case .record(let existing, .messages)?:
      guard existing != record else { return false }
    case nil:
      break
    }
    Self.store(.record(record, .messages), for: key, in: &updated)
    return true
  }

  /// The record for `uri` under `source.scope`. When none is kept, one getPosts batch confirms it
  /// together with the unconfirmed shared posts of the conversations that show it, newest first.
  func load(uri: String, source: Source) async throws -> Record {
    try Task.checkCancellation()
    guard let postURI = try? ATProtocolURI(uriString: uri) else { throw URLError(.badURL) }
    let scope = source.scope
    let key = Key(scope: scope, uri: uri)
    switch entries[key] {
    case .record(let record, _)?: return record
    case .unavailable?: throw ChatRecordEmbedUnavailableError()
    case nil: break
    }

    let batch: Batch
    if let running = inFlight[key] {
      batch = running
    } else {
      failed.remove(key)
      let companions = joinablePosts(alongside: uri, scope: scope, limit: Self.batchSize - 1)
      batch = startBatch([(uri, postURI)] + companions, source: source)
    }
    let results = try await batch.task.value
    try Task.checkCancellation()
    guard source.currentScope() == scope else { throw CancellationError() }
    guard let record = results[uri] else { throw ChatRecordEmbedUnavailableError() }
    return record
  }

  private func joinablePosts(alongside uri: String, scope: Scope, limit: Int) -> [(String, ATProtocolURI)] {
    var picked: [(String, ATProtocolURI)] = []
    var seen: Set<String> = [uri]
    for (conversation, posts) in conversationPosts.reversed()
    where conversation.context == scope.context && posts.contains(uri) {
      for other in posts {
        guard picked.count < limit else { return picked }
        guard seen.insert(other).inserted else { continue }
        let key = Key(scope: scope, uri: other)
        guard entries[key] == nil, inFlight[key] == nil, !failed.contains(key),
          let parsed = try? ATProtocolURI(uriString: other)
        else { continue }
        picked.append((other, parsed))
      }
    }
    return picked
  }

  private func startBatch(_ posts: [(String, ATProtocolURI)], source: Source) -> Batch {
    let id = UUID()
    let scope = source.scope
    let keys = posts.map { Key(scope: scope, uri: $0.0) }
    let uris = posts.map(\.1)
    let fetch = source.fetch
    let currentScope = source.currentScope
    let task = Task<[String: Record], Error> { @MainActor [weak self] in
      do {
        let fetched = try await fetch(uris)
        var results: [String: Record] = [:]
        for post in fetched {
          results[post.uri.uriString()] = Self.viewRecord(from: post)
        }
        // The header changed while the request was in flight, so it is unknown which one hydrated it.
        guard currentScope() == scope else { throw CancellationError() }
        self?.finishBatch(id: id, keys: keys, results: results)
        return results
      } catch {
        self?.abandonBatch(id: id, keys: keys, error: error)
        throw error
      }
    }
    let batch = Batch(id: id, task: task)
    for key in keys { inFlight[key] = batch }
    return batch
  }

  private func finishBatch(id: UUID, keys: [Key], results: [String: Record]) {
    var updated = entries
    var confirmed = 0
    var unavailable = 0
    for key in keys where inFlight[key]?.id == id {
      inFlight.removeValue(forKey: key)
      parityChecked.remove(key)
      if let record = results[key.uri] {
        Self.store(.record(record, .posts), for: key, in: &updated)
        confirmed += 1
      } else {
        Self.store(.unavailable, for: key, in: &updated)
        unavailable += 1
      }
    }
    guard confirmed + unavailable > 0 else { return }
    entries = updated
    logger.info(
      "Shared posts confirmed with getPosts: \(confirmed, privacy: .public); unavailable: \(unavailable, privacy: .public)"
    )
  }

  private func abandonBatch(id: UUID, keys: [Key], error: Error) {
    for key in keys where inFlight[key]?.id == id {
      inFlight.removeValue(forKey: key)
      if !(error is CancellationError) { failed.insert(key) }
    }
  }

  /// Writes one entry, dropping the least recently written one at capacity.
  private static func store(_ entry: Entry, for key: Key, in entries: inout OrderedDictionary<Key, Entry>) {
    entries.removeValue(forKey: key)
    if entries.count >= capacity { entries.removeFirst() }
    entries[key] = entry
  }
}

// MARK: - AppState

extension ChatRecordEmbedStore {
  private func isActive(_ state: AppState) -> Bool {
    let lifecycle = AppStateManager.shared.lifecycle
    guard lifecycle.appState === state, lifecycle.userDID == state.userDID else { return false }
    return !state.isTransitioningAccounts
  }

  private func context(for appState: AppState) -> Context? {
    guard isActive(appState), let client = appState.atProtoClient else { return nil }
    return Context(account: appState.userDID, state: ObjectIdentifier(appState), client: ObjectIdentifier(client))
  }

  /// The labelers this account's policy and its applied accept-labelers header agree on. Both are
  /// observed, so a SwiftUI body that reads this follows them.
  static func coveredLabelers(for appState: AppState) -> [String]? {
    let policy = appState.moderationPolicy
    guard policy.accountDID == appState.userDID else { return nil }
    return coveringLabelers(
      policyLabelerDIDs: policy.prefs.labelers.map(\.did),
      applied: appState.preferencesManager.appliedAcceptLabelerDIDs)
  }

  func scope(for appState: AppState) -> Scope? {
    guard let context = context(for: appState), let labelers = Self.coveredLabelers(for: appState) else {
      return nil
    }
    return Scope(context: context, labelers: labelers)
  }

  func source(for appState: AppState) -> Source? {
    guard let scope = scope(for: appState), let client = appState.atProtoClient else { return nil }
    return Source(
      scope: scope,
      currentScope: { [weak self, weak appState] in
        guard let self, let appState else { return nil }
        return self.scope(for: appState)
      },
      fetch: Self.postsLoader(client: client))
  }

  func cachedRecord(uri: String, appState: AppState) -> Record? {
    guard let scope = scope(for: appState) else { return nil }
    return cachedRecord(uri: uri, scope: scope)
  }

  func load(uri: String, appState: AppState) async throws -> Record {
    guard let source = source(for: appState) else { throw CancellationError() }
    return try await load(uri: uri, source: source)
  }

  func seed(_ seeds: [Seed], conversation: String, appState: AppState) {
    guard let context = context(for: appState) else { return }
    seed(seeds, conversation: conversation, context: context)
  }

  /// Brings the accept-labelers header and the moderation policy back into agreement for a card that
  /// waits on them: re-applies the header from the confirmed preferences and rebuilds the policy, or
  /// reads preferences from the server when none are confirmed yet (a failed first sign-in read).
  func resolveLabelScope(appState: AppState) async {
    if let running = labelScopeResolution {
      await running.value
      return
    }
    let task = Task { @MainActor [logger] in
      let preferences = appState.preferencesManager
      if (try? preferences.confirmedFeedFilterPreferences())?.accountDID == appState.userDID {
        await preferences.applyAcceptLabelersHeaderFromConfirmedPreferences()
        appState.refreshModerationPolicy()
      } else {
        do {
          try await preferences.fetchPreferences(forceRefresh: true)
        } catch {
          logger.error("Could not read preferences for shared-post labels: \(error.localizedDescription)")
        }
      }
    }
    labelScopeResolution = task
    await task.value
    labelScopeResolution = nil
  }
}

extension UnifiedEmbed {
  var recordURI: String? {
    switch self {
    case .blueskyRecord(let record): return record.uri
    case .post(let post): return post.uri
    default: return nil
    }
  }
}
