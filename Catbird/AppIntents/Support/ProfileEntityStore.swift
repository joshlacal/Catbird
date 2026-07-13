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

  private init() {}

  func store(_ entity: ProfileEntity) {
    if entities.updateValue(entity, forKey: entity.id) == nil {
      order.append(entity.id)
      if order.count > capacity {
        entities.removeValue(forKey: order.removeFirst())
      }
    }
  }

  func store(entities newEntities: [ProfileEntity]) {
    for entity in newEntities {
      store(entity)
    }
  }

  func entities(for identifiers: [String]) -> [ProfileEntity] {
    let hits = identifiers.compactMap { entities[$0] }
    logger.info(
      "resolve: \(hits.count)/\(identifiers.count) from store (\(self.entities.count) cached)")
    return hits
  }
}
