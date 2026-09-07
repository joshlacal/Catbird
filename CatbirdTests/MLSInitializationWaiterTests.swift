import Testing
@testable import Catbird

@MainActor
struct MLSInitializationWaiterTests {
  @Test func cancelledCallerDoesNotTimeoutOrCancelSharedInitialization() async {
    let shared = Task<Int?, Never> {
      try? await Task.sleep(for: .milliseconds(80))
      return Task.isCancelled ? nil : 42
    }
    let waiter = Task {
      await MLSInitializationWaiter.wait(for: shared, timeout: 30)
    }
    waiter.cancel()
    let result = await waiter.value
    guard case .cancelled = result else {
      Issue.record("Cancelled caller must be distinguished from initialization timeout")
      return
    }
    #expect(await shared.value == 42)
    #expect(!shared.isCancelled)
  }

  @Test func cancellingAnActiveWaitReturnsWithoutWaitingForProducer() async {
    let shared = Task<Int?, Never> {
      try? await Task.sleep(for: .milliseconds(300))
      return 42
    }
    var started = false
    let waiter = Task {
      started = true
      return await MLSInitializationWaiter.wait(for: shared, timeout: 30)
    }
    while !started { await Task.yield() }
    let clock = ContinuousClock()
    let start = clock.now
    waiter.cancel()
    let result = await waiter.value
    #expect(clock.now - start < .milliseconds(200))
    guard case .cancelled = result else {
      Issue.record("Active cancellation must not be mistaken for timeout")
      return
    }
    #expect(!shared.isCancelled)
    #expect(await shared.value == 42)
  }

  @Test func failedInitializationIsNotATimeout() async {
    let shared = Task<Int?, Never> { nil }
    let result = await MLSInitializationWaiter.wait(for: shared, timeout: 30)
    guard case .completed(let value) = result else {
      Issue.record("Initialization failure must remain a completed nil result")
      return
    }
    #expect(value == nil)
  }

  @Test func timeoutReturnsBeforeSharedInitializationCompletes() async {
    let shared = Task<Int?, Never> {
      try? await Task.sleep(for: .milliseconds(300))
      return 42
    }
    let clock = ContinuousClock()
    let start = clock.now
    let result = await MLSInitializationWaiter.wait(for: shared, timeout: 0.01)
    #expect(clock.now - start < .milliseconds(200))
    guard case .timedOut = result else {
      Issue.record("Elapsed deadline must report timeout")
      return
    }
    #expect(!shared.isCancelled)
    #expect(await shared.value == 42)
  }

  @Test func cancellingOneWaiterDoesNotAffectAnother() async {
    let shared = Task<Int?, Never> {
      try? await Task.sleep(for: .milliseconds(80))
      return Task.isCancelled ? nil : 42
    }
    let cancelled = Task { await MLSInitializationWaiter.wait(for: shared, timeout: 30) }
    let surviving = Task { await MLSInitializationWaiter.wait(for: shared, timeout: 30) }
    cancelled.cancel()
    _ = await cancelled.value
    let result = await surviving.value
    guard case .completed(let value) = result else {
      Issue.record("Independent waiter must receive initialized value")
      return
    }
    #expect(value == 42)
  }
}
