import Foundation
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
  static let shared = ContentLabelDefinitionLookup()
  private var cached: [Key: Definitions] = [:]
  private var cacheOrder: [Key] = []
  private var inFlight: [Key: (id: UUID, task: Task<Definitions, Error>)] = [:]

  func definitions(
    for key: Key, isCurrent: @escaping @MainActor () -> Bool,
    load: @escaping @MainActor () async throws -> Definitions
  ) async throws -> Definitions {
    guard isCurrent() else { throw PreferencesManagerError.accountChanged }
    try Task.checkCancellation()
    if let result = cached[key] { return result }
    let request: (id: UUID, task: Task<Definitions, Error>)
    if let existing = inFlight[key] { request = existing }
    else {
      request = (UUID(), Task { @MainActor in
        guard isCurrent() else { throw PreferencesManagerError.accountChanged }
        return try await load()
      })
      inFlight[key] = request
    }
    do {
      let result = try await request.task.value
      guard isCurrent() else { throw PreferencesManagerError.accountChanged }
      try Task.checkCancellation()
      if inFlight[key]?.id == request.id {
        inFlight.removeValue(forKey: key)
        cached[key] = result
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > 4 { cached.removeValue(forKey: cacheOrder.removeFirst()) }
      }
      return result
    } catch {
      // Failures are never recorded as a confirmed empty definition collection.
      if inFlight[key]?.id == request.id { inFlight.removeValue(forKey: key) }
      throw error
    }
  }
}

/// Custom canonical labels only. Builtin and self-label policy remains in ContentLabelManager.
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
    let account = appState.userDID
    let manager = appState.preferencesManager
    let dids = try subscribedLabelerDIDs(preferences)
    let key = Key(accountDID: account, clientIdentity: ObjectIdentifier(client), subscriptions: dids.map { $0.didString() })
    return try await shared.definitions(for: key,
      isCurrent: { appState.userDID == account && appState.atProtoClient === client && manager.accountDID == account },
      load: {
        let finishAccountIO = try manager.beginSettingsAccountIO()
        defer { finishAccountIO?() }
        let (code, output) = try await client.app.bsky.labeler.getServices(input: .init(dids: dids, detailed: true))
        guard (200..<300).contains(code), let output else { throw PreferencesManagerError.invalidData }
        var result: Definitions = [:]
        for value in output.views {
          if case .appBskyLabelerDefsLabelerViewDetailed(let service) = value {
            result[service.creator.did.didString()] = service.policies.labelValueDefinitions ?? []
          }
        }
        return result
      })
  }
}
