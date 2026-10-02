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
  private let capacity = 200
  private let defaults: UserDefaults?
  private static let storageKey = "recentProfileEntities.v1"

  init(
    defaults: UserDefaults? = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName)
  ) {
    self.defaults = defaults
  }

  func store(_ entity: ProfileEntity) {
    storeInMemory(entity)
    persist([entity])
  }

  private func storeInMemory(_ entity: ProfileEntity) {
    if entities.updateValue(entity, forKey: entity.id) == nil {
      order.append(entity.id)
      if order.count > capacity {
        entities.removeValue(forKey: order.removeFirst())
      }
    }
  }

  func store(entities newEntities: [ProfileEntity]) {
    for entity in newEntities {
      storeInMemory(entity)
    }
    persist(newEntities)
  }

  func entities(for identifiers: [String]) -> [ProfileEntity] {
    let persisted = persistedEntities()
    let hits = identifiers.compactMap { entities[$0] ?? persisted[$0]?.entity }
    logger.info(
      "resolve: \(hits.count)/\(identifiers.count) from store (\(self.entities.count) cached)")
    return hits
  }

  private func persist(_ newEntities: [ProfileEntity]) {
    guard let defaults, !newEntities.isEmpty else { return }
    let fresh = newEntities.map(PersistedProfileEntity.init)
    let freshIDs = Set(fresh.map(\.id))
    var merged = fresh + persistedEntities().values.filter { !freshIDs.contains($0.id) }
    if merged.count > capacity {
      merged = Array(merged.prefix(capacity))
    }
    guard let data = try? JSONEncoder().encode(merged) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }

  private func persistedEntities() -> [String: PersistedProfileEntity] {
    guard
      let defaults,
      let data = defaults.data(forKey: Self.storageKey),
      let values = try? JSONDecoder().decode([PersistedProfileEntity].self, from: data)
    else { return [:] }
    return Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
}

@available(iOS 18.0, *)
private struct PersistedProfileEntity: Codable {
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
