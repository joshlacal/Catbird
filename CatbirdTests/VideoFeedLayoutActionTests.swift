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

@Suite("Video feed pagination ownership")
@MainActor
struct VideoFeedLayoutPaginationTests {
  @Test("A failed page stops automatic work until an explicit retry")
  func failureRequiresRetry() async throws {
    let coordinator = VideoFeedPaginationCoordinator()
    var requests = 0
    var successes = 0
    coordinator.request(operation: {
      requests += 1
      throw FixtureFailure.rejected
    }, onSuccess: { successes += 1 })
    try await eventually { !coordinator.isLoading }
    #expect(coordinator.errorMessage != nil)
    #expect(successes == 0)
    coordinator.request(operation: { requests += 1 }, onSuccess: { successes += 1 })
    #expect(requests == 1)
    #expect(!coordinator.isLoading)
    coordinator.request(retrying: true, operation: { requests += 1 }, onSuccess: { successes += 1 })
    #expect(coordinator.errorMessage == nil)
    try await eventually { !coordinator.isLoading }
    #expect(requests == 2)
    #expect(successes == 1)
  }

  @Test("Moving among the last videos does not duplicate the same request")
  func duplicateRequestIsIgnored() async throws {
    let coordinator = VideoFeedPaginationCoordinator()
    let gate = ActionGate()
    var requests = 0
    coordinator.request(operation: {
      requests += 1
      await gate.wait()
    }, onSuccess: {})
    try await eventually { requests == 1 }
    coordinator.request(operation: { requests += 1 }, onSuccess: {})
    #expect(requests == 1)
    gate.open()
    try await eventually { !coordinator.isLoading }
  }

  @Test("An old cancelled completion cannot clear a replacement request")
  func cancellationDoesNotOwnReplacement() async throws {
    let coordinator = VideoFeedPaginationCoordinator()
    let oldGate = ActionGate()
    let newGate = ActionGate()
    var oldStarted = false
    var oldReturned = false
    var newStarted = false
    var oldSuccesses = 0
    var newSuccesses = 0
    coordinator.request(operation: {
      oldStarted = true
      await oldGate.wait()
      oldReturned = true
      throw FixtureFailure.rejected
    }, onSuccess: { oldSuccesses += 1 })
    try await eventually { oldStarted }
    coordinator.cancel()
    coordinator.request(operation: {
      newStarted = true
      await newGate.wait()
    }, onSuccess: { newSuccesses += 1 })
    try await eventually { newStarted }
    oldGate.open()
    try await eventually { oldReturned }
    #expect(coordinator.isLoading)
    #expect(coordinator.errorMessage == nil)
    #expect(oldSuccesses == 0)
    newGate.open()
    try await eventually { !coordinator.isLoading }
    #expect(newSuccesses == 1)
  }

  @Test("A successful empty page can request the next cursor immediately")
  func successfulContinuationOwnsItsState() async throws {
    let coordinator = VideoFeedPaginationCoordinator()
    let gate = ActionGate()
    var requests = 0
    coordinator.request(operation: { requests += 1 }, onSuccess: {
      coordinator.request(operation: {
        requests += 1
        await gate.wait()
      }, onSuccess: {})
    })
    try await eventually { requests == 2 }
    #expect(coordinator.isLoading)
    gate.open()
    try await eventually { !coordinator.isLoading }
  }

  @Test("Cancellation before a pagination dispatch prevents its work")
  func cancellationBeforeDispatch() async throws {
    let coordinator = VideoFeedPaginationCoordinator()
    var dispatched = false
    coordinator.request(operation: { dispatched = true }, onSuccess: {})
    coordinator.cancel()
    try await Task.sleep(for: .milliseconds(5))
    #expect(!dispatched)
    #expect(!coordinator.isLoading)
    #expect(coordinator.errorMessage == nil)
  }

  private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<1_000 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Pagination did not reach the expected state")
    throw FixtureFailure.timeout
  }
}
