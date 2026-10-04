import Foundation
import Testing
@testable import Catbird

@Suite("Trending preview prefetch lifecycle", .serialized)
@MainActor
struct TopicPreviewPrefetchTests {
  @Test("Early loading admits six unique nonempty topic links")
  func boundedUniqueBatch() {
    #expect(TopicPreviewPrefetchCoordinator.boundedLinks(["", "a", "a", "b", "c", "d", "e", "f", "g"]) == ["a", "b", "c", "d", "e", "f"])
  }

  @Test("Repeated metadata coalesces while the same batch is running")
  func identicalMetadataCoalesces() async throws {
    let coordinator = TopicPreviewPrefetchCoordinator()
    var started = 0
    var finished = 0
    let load: @MainActor (String) async -> Void = { _ in
      started += 1
      do { try await Task.sleep(for: .seconds(60)) } catch {}
      finished += 1
    }
    #expect(coordinator.start(owner: .search, identity: "same", links: ["one"], load: load))
    try await waitUntil { started == 1 }
    #expect(!coordinator.start(owner: .search, identity: "same", links: ["one"], load: load))
    coordinator.cancelAll()
    try await waitUntil { finished == 1 }
    #expect(started == 1)
  }

  @Test("Search and timeline prefetch share two feed slots and cancellation drains queued work")
  func sharedAdmissionAndQueuedCancellation() async throws {
    let coordinator = TopicPreviewPrefetchCoordinator()
    let gate = TopicPreviewRequestGate()
    var active = 0
    var maximum = 0
    var started = 0
    let load: @MainActor (String) async -> Void = { link in
      do {
        try await gate.acquire(link)
        defer { gate.release(link) }
        try Task.checkCancellation()
        active += 1
        defer { active -= 1 }
        maximum = max(maximum, active)
        started += 1
        try await Task.sleep(for: .seconds(60))
      } catch {}
    }
    _ = coordinator.start(owner: .search, identity: "search", links: (0..<6).map { "s-\($0)" }, load: load)
    _ = coordinator.start(owner: .timeline, identity: "timeline", links: (0..<6).map { "t-\($0)" }, load: load)
    try await waitUntil { active == 2 }
    coordinator.cancelAll()
    try await waitUntil { active == 0 }
    #expect(maximum == 2)
    #expect(started == 2, "Cancelled queued previews must never enter their fetch")
    try await gate.acquire("visible-row-after-cancellation")
    gate.release("visible-row-after-cancellation")
  }

  @Test("Leaving Search cancels its work without cancelling timeline prefetch")
  func ownersCancelIndependently() async throws {
    let coordinator = TopicPreviewPrefetchCoordinator()
    var started = Set<String>()
    var finished = Set<String>()
    let load: @MainActor (String) async -> Void = { link in
      started.insert(link)
      do { try await Task.sleep(for: .seconds(60)) } catch {}
      finished.insert(link)
    }
    _ = coordinator.start(owner: .search, identity: "search", links: ["search"], load: load)
    _ = coordinator.start(owner: .timeline, identity: "timeline", links: ["timeline"], load: load)
    try await waitUntil { started.count == 2 }
    coordinator.cancel(owner: .search)
    try await waitUntil { finished.contains("search") }
    #expect(!finished.contains("timeline"))
    coordinator.cancelAll()
    try await waitUntil { finished.count == 2 }
  }

  @Test("An old cancellation-resistant completion cannot remove a newer batch")
  func replacedBatchIgnoresStaleCompletion() async throws {
    let coordinator = TopicPreviewPrefetchCoordinator()
    var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    var finished = Set<String>()
    let load: @MainActor (String) async -> Void = { link in
      await withCheckedContinuation { continuations[link] = $0 }
      finished.insert(link)
    }
    _ = coordinator.start(owner: .search, identity: "old", links: ["old"], load: load)
    try await waitUntil { continuations["old"] != nil }
    _ = coordinator.start(owner: .search, identity: "new", links: ["new"], load: load)
    try await waitUntil { continuations["new"] != nil }
    continuations.removeValue(forKey: "old")?.resume()
    try await waitUntil { finished.contains("old") }
    // Allow the old parent's completion bookkeeping to run before testing the new identity.
    for _ in 0..<20 { await Task.yield() }
    #expect(!coordinator.start(owner: .search, identity: "new", links: ["new"], load: load))
    coordinator.cancelAll()
    continuations.removeValue(forKey: "new")?.resume()
    try await waitUntil { finished.contains("new") }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw PrefetchTestError.timeout }
      await Task.yield()
    }
  }
}

private enum PrefetchTestError: Error { case timeout }
