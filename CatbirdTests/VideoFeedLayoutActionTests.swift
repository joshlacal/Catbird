import Foundation
import Testing
@testable import Catbird

@Suite("Video feed action lifecycle")
@MainActor
struct VideoFeedLayoutActionTests {
  @Test("A repeated tap does not start a second in-flight request")
  func duplicateTapIsIgnored() async throws {
    let coordinator = VideoFeedActionCoordinator()
    let gate = ActionGate()
    var requests = 0
    coordinator.perform {
      requests += 1
      await gate.wait()
    }
    try await eventually { requests == 1 }
    coordinator.perform { requests += 1 }
    #expect(coordinator.isBusy)
    #expect(requests == 1)
    gate.open()
    try await eventually { !coordinator.isBusy }
    #expect(coordinator.errorMessage == nil)
  }

  @Test("A failed action presents an error and the next request can retry")
  func failureCanRetry() async throws {
    let coordinator = VideoFeedActionCoordinator()
    coordinator.perform { throw FixtureFailure.rejected }
    try await eventually { !coordinator.isBusy }
    #expect(coordinator.errorMessage != nil)
    var completed = false
    coordinator.perform { completed = true }
    #expect(coordinator.errorMessage == nil)
    try await eventually { !coordinator.isBusy }
    #expect(completed)
    #expect(coordinator.errorMessage == nil)
  }

  @Test("Leaving a page cancels its request without presenting a failure")
  func cancellationReleasesBusyState() async throws {
    let coordinator = VideoFeedActionCoordinator()
    var started = false
    var completed = false
    coordinator.perform {
      started = true
      try await Task.sleep(for: .seconds(60))
      completed = true
    }
    try await eventually { started }
    coordinator.cancel()
    try await eventually { !coordinator.isBusy }
    #expect(!completed)
    #expect(coordinator.errorMessage == nil)
  }

  @Test("Cancellation before the operation starts prevents dispatch")
  func cancelBeforeDispatch() async throws {
    let coordinator = VideoFeedActionCoordinator()
    var dispatched = false
    coordinator.perform { dispatched = true }
    coordinator.cancel()
    try await eventually { !coordinator.isBusy }
    #expect(!dispatched)
    #expect(coordinator.errorMessage == nil)
  }

  @Test("A cancellation-insensitive operation holds serialization until it returns")
  func pendingCancellationDoesNotOverlapRequests() async throws {
    let coordinator = VideoFeedActionCoordinator()
    let gate = ActionGate()
    var requests = 0
    coordinator.perform {
      requests += 1
      await gate.wait()
      throw FixtureFailure.rejected
    }
    try await eventually { requests == 1 }
    coordinator.cancel()
    coordinator.perform { requests += 1 }
    #expect(requests == 1)
    #expect(coordinator.isBusy)
    gate.open()
    try await eventually { !coordinator.isBusy }
    #expect(coordinator.errorMessage == nil)
    coordinator.perform { requests += 1 }
    try await eventually { !coordinator.isBusy }
    #expect(requests == 2)
  }

  private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<1_000 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("The action did not reach the expected state")
    throw FixtureFailure.timeout
  }
}

@MainActor
private final class ActionGate {
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    continuation?.resume()
    continuation = nil
  }
}

private enum FixtureFailure: Error { case rejected, timeout }
