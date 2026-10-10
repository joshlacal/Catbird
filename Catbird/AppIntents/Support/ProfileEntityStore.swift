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
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@available(iOS 18.0, *)
actor ProfileEntityStore {
  static let shared = ProfileEntityStore()

  private let logger = Logger(subsystem: "blue.catbird", category: "ProfileEntityStore")

  private var entities: [String: ProfileEntity] = [:]
  private var order: [String] = []
  private let capacity = 200
  private let defaults: UserDefaults?
  private static let storageKey = "recentProfileEntities.v1"
  private let flushInterval: TimeInterval = 1.5

  private var pendingBuffer: [String: PersistedProfileEntity] = [:]
  private var pendingOrder: [String] = []
  private var cachedPersisted: [PersistedProfileEntity]? = nil
  private var flushTask: Task<Void, Never>? = nil
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    defaults: UserDefaults? = UserDefaults(suiteName: IntentAccountResolver.appGroupSuiteName)
  ) {
    self.defaults = defaults
    #if canImport(UIKit)
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { [weak self] in await self?.flush() }
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { [weak self] in await self?.flush() }
    }
    #elseif canImport(AppKit)
    NotificationCenter.default.addObserver(
      forName: NSApplication.willResignActiveNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { [weak self] in await self?.flush() }
    }
    #endif
  }

  func store(_ entity: ProfileEntity) {
    storeInMemory(entity)
    buffer([entity])
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
    buffer(newEntities)
  }

  func entities(for identifiers: [String]) -> [ProfileEntity] {
    let persisted = persistedEntities()
    let hits = identifiers.compactMap { entities[$0] ?? persisted[$0]?.entity }
    logger.info(
      "resolve: \(hits.count)/\(identifiers.count) from store (\(self.entities.count) cached)")
    return hits
  }
  private func buffer(_ newEntities: [ProfileEntity]) {
    guard !newEntities.isEmpty else { return }
    for entity in newEntities {
      let persisted = PersistedProfileEntity(entity)
      if pendingBuffer.updateValue(persisted, forKey: persisted.id) == nil {
        pendingOrder.append(persisted.id)
      }
    }
    flushTask?.cancel()
    flushTask = Task(priority: .utility) { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(1_500_000_000))
      guard !Task.isCancelled else { return }
      await self?.flush()
    }
  }

  func flush() {
    guard let defaults, !pendingBuffer.isEmpty else { return }
    flushTask?.cancel()
    flushTask = nil

    var persisted = cachedPersisted ?? loadPersistedFromDefaults()
    let pendingList = pendingOrder.reversed().compactMap { pendingBuffer[$0] }
    let pendingIDs = Set(pendingBuffer.keys)

    persisted = pendingList + persisted.filter { !pendingIDs.contains($0.id) }
    if persisted.count > capacity {
      persisted = Array(persisted.prefix(capacity))
    }

    let changed = (cachedPersisted == nil) || (persisted != cachedPersisted!)
    if changed {
      let signpostState = PerformanceSignposts.beginInterval("EntityExport")
      defer { PerformanceSignposts.endInterval("EntityExport", signpostState) }

      do {
        let data = try encoder.encode(persisted)
        defaults.set(data, forKey: Self.storageKey)
        cachedPersisted = persisted
      } catch {
        logger.error("ProfileEntityStore persist failed: \(error.localizedDescription)")
      }
    } else {
      cachedPersisted = persisted
    }
    pendingBuffer.removeAll()
    pendingOrder.removeAll()
  }

  func flushPendingWrites() {
    flush()
  }

  private func loadPersistedFromDefaults() -> [PersistedProfileEntity] {
    guard let defaults,
          let data = defaults.data(forKey: Self.storageKey),
          let values = try? decoder.decode([PersistedProfileEntity].self, from: data) else {
      return []
    }
    return values
  }

  private func persistedEntities() -> [String: PersistedProfileEntity] {
    let persisted = cachedPersisted ?? loadPersistedFromDefaults()
    var dict = Dictionary(persisted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    // Merge pending buffer so in-process reads see entries immediately
    for (id, entity) in pendingBuffer {
      dict[id] = entity
    }
    return dict
  }

}

@available(iOS 18.0, *)
private struct PersistedProfileEntity: Codable, Equatable {
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
