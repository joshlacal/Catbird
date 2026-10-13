//
//  ProfileEntityStore.swift
//  Catbird
//
//  In-memory registry of recently rendered profiles so App Intents entity
//  resolution can answer Siri's onscreen-context requests without a network
//  round trip. Mirrors PostEntityStore's design but stores ProfileEntity
//  instances directly (multiple source types already produce the same entity).
//

import Foundation
import OSLog
import Petrel

@available(iOS 18.0, *)
actor ProfileEntityStore {
  static let shared = ProfileEntityStore()

  private let logger = Logger(subsystem: "blue.catbird", category: "ProfileEntityStore")

  private var entities: [String: ProfileEntity] = [:]
  private var order: [String] = []
  private static let capacity = 200
  private static let storageKey = "recentProfileEntities.v1"
  /// Coalesces the App Group mirror; nil when there is no App Group suite.
  private let persisted: AppGroupEntityWriteBuffer<PersistedProfileEntity>?

  init(
    defaults: UserDefaults? = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName)
  ) {
    persisted = defaults.map {
      AppGroupEntityWriteBuffer(
        defaults: $0, storageKey: Self.storageKey, capacity: Self.capacity, id: { $0.id })
    }
  }

  func store(_ entity: ProfileEntity) {
    storeInMemory(entity)
    persisted?.enqueue([PersistedProfileEntity(entity)])
  }

  private func storeInMemory(_ entity: ProfileEntity) {
    if entities.updateValue(entity, forKey: entity.id) == nil {
      order.append(entity.id)
      if order.count > Self.capacity {
        entities.removeValue(forKey: order.removeFirst())
      }
    }
  }

  func store(entities newEntities: [ProfileEntity]) {
    for entity in newEntities {
      storeInMemory(entity)
    }
    persisted?.enqueue(newEntities.map(PersistedProfileEntity.init))
  }

  func entities(for identifiers: [String]) -> [ProfileEntity] {
    // Read (and decode) the App Group list only when memory misses something.
    let persisted = identifiers.allSatisfy { entities[$0] != nil } ? [:] : persistedEntities()
    let hits = identifiers.compactMap { entities[$0] ?? persisted[$0]?.entity }
    logger.info(
      "resolve: \(hits.count)/\(identifiers.count) from store (\(self.entities.count) cached)")
    return hits
  }

  /// Writes buffered App Group entries now instead of after the coalescing delay.
  func flushPendingWrites() {
    persisted?.flush()
  }

  /// Forgets every profile, in memory and in the App Group (sign-out, account removal).
  func removeAll() {
    entities.removeAll()
    order.removeAll()
    persisted?.removeAll()
  }

  /// The App Group list, including entries this process hasn't flushed yet.
  private func persistedEntities() -> [String: PersistedProfileEntity] {
    guard let values = persisted?.entries() else { return [:] }
    return Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
}

@available(iOS 18.0, *)
private struct PersistedProfileEntity: Codable, Equatable, Sendable {
  let id: String
  let handle: String
  let displayName: String?
  let description: String?
  let avatar: URL?

  init(_ entity: ProfileEntity) {
    id = entity.id
    handle = entity.handle
    displayName = entity.displayName
    description = entity.description
    avatar = entity.avatar
  }

  var entity: ProfileEntity {
    ProfileEntity(persisted: self)
  }
}

@available(iOS 18.0, *)
private extension ProfileEntity {
  init(persisted: PersistedProfileEntity) {
    id = persisted.id
    handle = persisted.handle
    displayName = persisted.displayName
    description = persisted.description
    avatar = persisted.avatar
  }
}

@available(iOS 18.0, *)
extension ProfileEntity {
  init(displayable profile: any ProfileDisplayable) {
    id = profile.did.didString()
    handle = profile.handle.value
    displayName = profile.displayName
    description = nil
    avatar = profile.finalAvatarURL()
  }
}
