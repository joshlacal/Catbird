//
//  CircleCoordinatorCacheTests.swift
//  CatbirdTests
//
//  Fix wave 1, I5: one key manager per coordinator, cleared on reset.
//

import Foundation
import Testing
@testable import Catbird

private final class FakeCoordinator {}
private final class Built {}

@Suite("Circle coordinator cache (I5)")
@MainActor
struct CircleCoordinatorCacheTests {
  @Test func twoLookupsReturnTheSameInstance() {
    let cache = CircleCoordinatorCache<Built>()
    let coordinator = FakeCoordinator()
    var builds = 0
    let first = cache.value(for: coordinator) { builds += 1; return Built() }
    let second = cache.value(for: coordinator) { builds += 1; return Built() }
    #expect(first === second)
    #expect(builds == 1)
  }

  @Test func resetBuildsANewInstance() {
    let cache = CircleCoordinatorCache<Built>()
    let coordinator = FakeCoordinator()
    let first = cache.value(for: coordinator) { Built() }
    cache.reset()
    #expect(cache.cached(for: coordinator) == nil)
    let second = cache.value(for: coordinator) { Built() }
    #expect(first !== second)
  }

  @Test func anotherCoordinatorGetsItsOwnInstance() {
    let cache = CircleCoordinatorCache<Built>()
    let a = FakeCoordinator()
    let b = FakeCoordinator()
    let first = cache.value(for: a) { Built() }
    let second = cache.value(for: b) { Built() }
    #expect(first !== second)
    #expect(cache.cached(for: a) == nil)
  }

  @Test func freedCoordinatorIsNeverMatched() {
    let cache = CircleCoordinatorCache<Built>()
    var coordinator: FakeCoordinator? = FakeCoordinator()
    _ = cache.value(for: coordinator!) { Built() }
    coordinator = nil
    let replacement = FakeCoordinator()
    #expect(cache.cached(for: replacement) == nil)
  }
}
