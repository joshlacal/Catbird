import Foundation
import OSLog
import Petrel

/// Read-only, successful-result-only definitions cache for the content warning consumer.
@MainActor
final class ContentLabelDefinitionLookup {
  struct Key: Hashable {
    let accountDID: String
    let clientIdentity: ObjectIdentifier
    let subscriptions: [String]
    init(accountDID: String, clientIdentity: ObjectIdentifier, subscriptions: [String]) {
      self.accountDID = accountDID
      self.clientIdentity = clientIdentity
      self.subscriptions = Array(Set(subscriptions).sorted().prefix(20))
    }
  }
  typealias Definitions = [String: [ComAtprotoLabelDefs.LabelValueDefinition]]
  typealias Services = [String: AppBskyLabelerDefs.LabelerViewDetailed]
  struct Catalog {
    let definitions: Definitions
    let services: Services
  }
  /// One shared load and the callers awaiting it. The load holds the settings account-I/O lease
  /// until it finishes, so it is cancelled as soon as its last waiter is cancelled: an account switch
  /// cancels the account's tasks and then drains the lease, and a slow labeler service must not keep
  /// that drain waiting. The load's request wait returns on cancellation (`returningOnCancellation`),
  /// which releases the lease at once.
  private struct InFlight {
    let id: UUID
    let task: Task<Catalog, Error>
    var waiters: Int
  }
  static let shared = ContentLabelDefinitionLookup()
  private var cached: [Key: Catalog] = [:]
  private var cacheOrder: [Key] = []
  private var inFlight: [Key: InFlight] = [:]

  func definitions(
    for key: Key, isCurrent: @escaping @MainActor () -> Bool,
    load: @escaping @MainActor () async throws -> Definitions
  ) async throws -> Definitions {
    try await catalog(for: key, isCurrent: isCurrent, load: {
      Catalog(definitions: try await load(), services: [:])
    }).definitions
  }

  func catalog(
    for key: Key, isCurrent: @escaping @MainActor () -> Bool,
    load: @escaping @MainActor () async throws -> Catalog
  ) async throws -> Catalog {
    guard isCurrent() else { throw PreferencesManagerError.accountChanged }
    try Task.checkCancellation()
    if let result = cached[key] { return result }
    let request: InFlight
    if var existing = inFlight[key], !existing.task.isCancelled {
      existing.waiters += 1
      inFlight[key] = existing
      request = existing
    } else {
      request = InFlight(id: UUID(), task: Task { @MainActor in
        guard isCurrent() else { throw PreferencesManagerError.accountChanged }
        return try await load()
      }, waiters: 1)
      inFlight[key] = request
    }
    let id = request.id
    do {
      let result = try await withTaskCancellationHandler {
        try await request.task.value
      } onCancel: {
        // The handler runs on the cancelling thread; the bookkeeping is main-actor state.
        Task { @MainActor in self.waiterWasCancelled(key: key, id: id) }
      }
      guard isCurrent() else { throw PreferencesManagerError.accountChanged }
      try Task.checkCancellation()
      if inFlight[key]?.id == id {
        inFlight.removeValue(forKey: key)
        cached[key] = result
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > 4 { cached.removeValue(forKey: cacheOrder.removeFirst()) }
      }
      return result
    } catch {
      // Failures are never recorded as a confirmed empty definition collection.
      if inFlight[key]?.id == id { inFlight.removeValue(forKey: key) }
      throw error
    }
  }

  /// Drops one waiter of a shared load. When it was the last one, the load itself is cancelled, which
  /// returns its request wait and releases the lease it holds; a later caller starts a fresh load.
  private func waiterWasCancelled(key: Key, id: UUID) {
    guard var entry = inFlight[key], entry.id == id else { return }
    entry.waiters -= 1
    if entry.waiters > 0 {
      inFlight[key] = entry
    } else {
      inFlight.removeValue(forKey: key)
      entry.task.cancel()
    }
  }
}

/// The last successfully loaded label value definitions of an account's subscribed labelers, kept on
/// disk so the first feed frame after launch already resolves custom labels instead of waiting for
/// `app.bsky.labeler.getServices`.
///
/// It holds only the labelers' raw published definitions. Preferences, adult-content state and
/// platform age restrictions are never stored here; the effective policy is always rebuilt at runtime
/// from the server-confirmed preferences row. An entry is used only for the exact account and
/// subscribed-labeler set it was stored for, and the network refresh always runs and overwrites it.
enum LabelerDefinitionsDiskCache {
  typealias Definitions = [String: [ComAtprotoLabelDefs.LabelValueDefinition]]

  private struct Entry: Codable {
    let accountDID: String
    let labelerDIDs: [String]
    let definitions: Definitions
  }

  private static let logger = Logger(subsystem: "blue.catbird", category: "LabelerDefinitionsDiskCache")
  /// Serializes writes and removals so an older write never lands after a newer one.
  private static let ioQueue = DispatchQueue(label: "blue.catbird.labeler-definitions-cache", qos: .utility)

  /// The cache key for a subscription list: deduplicated and sorted.
  static func normalizedLabelerDIDs(_ labelerDIDs: [String]) -> [String] {
    Array(Set(labelerDIDs)).sorted()
  }

  /// Synchronously reads the entry for this account, if it was stored for exactly these labelers.
  static func load(accountDID: String, labelerDIDs: [String]) -> Definitions? {
    guard let url = fileURL(accountDID: accountDID),
          let data = try? Data(contentsOf: url) else { return nil }
    do {
      let entry = try JSONDecoder().decode(Entry.self, from: data)
      guard entry.accountDID == accountDID,
            entry.labelerDIDs == normalizedLabelerDIDs(labelerDIDs) else { return nil }
      return entry.definitions
    } catch {
      logger.error("Discarding unreadable labeler definitions cache: \(error.localizedDescription)")
      ioQueue.async { try? FileManager.default.removeItem(at: url) }
      return nil
    }
  }

  /// Replaces this account's entry in the background.
  static func store(_ definitions: Definitions, accountDID: String, labelerDIDs: [String]) {
    guard let url = fileURL(accountDID: accountDID) else { return }
    let entry = Entry(
      accountDID: accountDID, labelerDIDs: normalizedLabelerDIDs(labelerDIDs), definitions: definitions)
    ioQueue.async {
      do {
        let data = try JSONEncoder().encode(entry)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
      } catch {
        logger.error("Could not encode or write labeler definitions cache: \(error.localizedDescription)")
      }
    }
  }

  /// Removes this account's entry, e.g. on sign-out.
  static func remove(accountDID: String) {
    guard let url = fileURL(accountDID: accountDID) else { return }
    ioQueue.async { try? FileManager.default.removeItem(at: url) }
  }

  private static func fileURL(accountDID: String) -> URL? {
    guard !accountDID.isEmpty,
          let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
          let name = accountDID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
    return base.appendingPathComponent("LabelerDefinitions", isDirectory: true)
      .appendingPathComponent("\(name).json", isDirectory: false)
  }
}

/// Custom canonical labels only, for the trending topic preview. Post rendering
/// and feed filtering evaluate every label through `ModerationPolicy`.
enum CustomContentLabelPolicy {
  static func visibility(
    labelValue: String, labelerDID: DID, preferences: [ContentLabelPreference],
    definition: ComAtprotoLabelDefs.LabelValueDefinition?, contentType: String, isActive: Bool
  ) -> ContentVisibility? {
    guard isActive, !labelValue.hasPrefix("!"),
          !ContentLabels.contentWarningLabels.contains(labelValue.lowercased()) else { return nil }
    let definition = definition.flatMap { $0.identifier == labelValue ? $0 : nil }
    let scoped = preferences.first { $0.label == labelValue && $0.labelerDid == labelerDID }
    let global = preferences.first { $0.label == labelValue && $0.labelerDid == nil }
    let explicit = scoped ?? global
    if let definition {
      // Informational definitions do not blur content. Media definitions only cover media wrappers.
      guard definition.blurs == "content" || (definition.blurs == "media" && contentType == "media") else { return .show }
    }
    if let explicit { return ContentVisibility(fromPreference: explicit.visibility) }
    guard let definition, let value = definition.defaultSetting else { return nil }
    return ContentVisibility(fromPreference: value)
  }
}

extension ContentLabelDefinitionLookup {
  /// The default moderation service plus the account's subscribed labelers, capped like the accept-labelers header.
  static func subscribedLabelerDIDs(_ preferences: Preferences) throws -> [DID] {
    var dids = [try DID(didString: "did:plc:ar7c4by46qjdydhdevvrndac")]
    for item in preferences.labelers where !dids.contains(item.did) { dids.append(item.did) }
    return Array(dids.prefix(20))
  }

  /// Label value definitions for every subscribed labeler, shared through the account-scoped cache.
  @MainActor
  static func subscribedDefinitions(
    appState: AppState, preferences: Preferences, client: ATProtoClient
  ) async throws -> Definitions {
    try await subscribedCatalog(appState: appState, preferences: preferences, client: client).definitions
  }

  /// Display metadata shares the same response, account fence, coalescing and bounded cache as policy.
  @MainActor
  static func subscribedServices(
    appState: AppState, preferences: Preferences, client: ATProtoClient
  ) async throws -> Services {
    try await subscribedCatalog(appState: appState, preferences: preferences, client: client).services
  }

  @MainActor
  private static func subscribedCatalog(
    appState: AppState, preferences: Preferences, client: ATProtoClient
  ) async throws -> Catalog {
    let account = appState.userDID
    let manager = appState.preferencesManager
    let dids = try subscribedLabelerDIDs(preferences)
    let key = Key(accountDID: account, clientIdentity: ObjectIdentifier(client), subscriptions: dids.map { $0.didString() })
    return try await shared.catalog(for: key,
      isCurrent: { appState.userDID == account && appState.atProtoClient === client && manager.accountDID == account },
      load: {
        let finishAccountIO = try manager.beginSettingsAccountIO()
        defer { finishAccountIO?() }
        let (code, output) = try await returningOnCancellation {
          try await client.app.bsky.labeler.getServices(input: .init(dids: dids, detailed: true))
        }
        guard (200..<300).contains(code), let output else { throw PreferencesManagerError.invalidData }
        var result: Definitions = [:]
        var services: Services = [:]
        for value in output.views {
          if case .appBskyLabelerDefsLabelerViewDetailed(let service) = value {
            result[service.creator.did.didString()] = service.policies.labelValueDefinitions ?? []
            services[service.creator.did.didString()] = service
          }
        }
        return Catalog(definitions: result, services: services)
      })
  }

  /// Runs `operation` so that cancelling the caller returns at once with `CancellationError`.
  ///
  /// Petrel coalesces identical GETs through an unstructured task that a cancelled caller does not
  /// cancel, so awaiting the request directly would hold the settings account-I/O lease until the
  /// response arrives and time out an account switch's drain. The request is left to finish on its
  /// own; a result that arrives after cancellation is dropped.
  private static func returningOnCancellation<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let request = Task { try await operation() }
    let gate = CancellationGate<Value>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        Task { gate.resume(with: await request.result) }
      }
    } onCancel: {
      request.cancel()
      gate.resume(with: .failure(CancellationError()))
    }
  }
}

/// Resumes one continuation exactly once, from whichever of completion and cancellation comes first.
/// A result that arrives before the continuation is installed is delivered on installation.
private final class CancellationGate<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var early: Result<Value, Error>?
  private var isResumed = false

  func install(_ continuation: CheckedContinuation<Value, Error>) {
    lock.lock()
    if let early {
      self.early = nil
      isResumed = true
      lock.unlock()
      continuation.resume(with: early)
    } else {
      self.continuation = continuation
      lock.unlock()
    }
  }

  func resume(with result: Result<Value, Error>) {
    lock.lock()
    if let continuation {
      self.continuation = nil
      isResumed = true
      lock.unlock()
      continuation.resume(with: result)
    } else {
      if !isResumed, early == nil { early = result }
      lock.unlock()
    }
  }
}
