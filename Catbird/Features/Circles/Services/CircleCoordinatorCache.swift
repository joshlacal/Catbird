//
//  CircleCoordinatorCache.swift
//  Catbird
//
//  Fix wave 1, I5: one encrypted-Circle object per live MLS coordinator.
//  The cache holds the coordinator weakly and compares by identity (`===`),
//  so a freed coordinator whose address is reused can never hand back the
//  previous account's key manager (an `ObjectIdentifier` of a freed object
//  can collide with a new one).
//

import Foundation

/// Not thread-safe: owned and used only from `AppState`'s main-actor methods.
final class CircleCoordinatorCache<Value> {
  private weak var owner: AnyObject?
  private var value: Value?

  /// The cached value for `coordinator`, built with `make` when there is none
  /// or it belongs to a different (or freed) coordinator.
  func value(for coordinator: AnyObject, make: () -> Value) -> Value {
    if let owner, owner === coordinator, let value { return value }
    let made = make()
    owner = coordinator
    value = made
    return made
  }

  /// The cached value only if it belongs to `coordinator`.
  func cached(for coordinator: AnyObject) -> Value? {
    guard let owner, owner === coordinator else { return nil }
    return value
  }

  func reset() {
    owner = nil
    value = nil
  }
}
