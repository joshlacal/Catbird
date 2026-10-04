import Foundation

@main
struct VerifyChatEmbedRequests {
  @MainActor final class Probe {
    var starts = 0
    var cancellations = 0
  }
  enum Failure: Error { case unavailable }

  @MainActor static func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
      if condition() { return }
      await Task.yield()
    }
    preconditionFailure("Request did not reach the expected state")
  }

  @MainActor static func main() async throws {
    let pool = ChatEmbedRequestPool<String, Int>()
    let probe = Probe()
    let gate = AsyncStream<Void>.makeStream()
    let operation: @MainActor @Sendable () async throws -> Int = {
      probe.starts += 1
      for await _ in gate.stream { }
      do { try Task.checkCancellation() } catch { probe.cancellations += 1; throw error }
      return 42
    }
    let prefetch = Task { try await pool.value(for: "accountA/client1/post1", operation: operation) }
    await waitUntil { probe.starts == 1 }
    let visible = Task { try await pool.value(for: "accountA/client1/post1", operation: operation) }
    for _ in 0..<20 { await Task.yield() }
    prefetch.cancel()
    for _ in 0..<20 { await Task.yield() }
    precondition(probe.starts == 1 && probe.cancellations == 0)
    gate.continuation.finish()
    let visibleResult = try await visible.value
    precondition(visibleResult == 42)
    do { _ = try await prefetch.value; preconditionFailure("Cancelled consumer succeeded") }
    catch is CancellationError { }
    precondition(probe.starts == 1)

    // Last-consumer cancellation ends work and a later presentation can retry.
    let cancelledGate = AsyncStream<Void>.makeStream()
    let only = Task {
      try await pool.value(for: "accountA/client1/post2") {
        probe.starts += 1
        for await _ in cancelledGate.stream { }
        do { try Task.checkCancellation() } catch { probe.cancellations += 1; throw error }
        return 10
      }
    }
    await waitUntil { probe.starts == 2 }
    only.cancel()
    do { _ = try await only.value; preconditionFailure("Cancelled request succeeded") }
    catch is CancellationError { }
    await waitUntil { probe.cancellations == 1 }
    let retry = try await pool.value(for: "accountA/client1/post2") { 11 }
    precondition(retry == 11)

    // Failure is not cached as a permanently failed task.
    do {
      _ = try await pool.value(for: "failed") { throw Failure.unavailable }
      preconditionFailure("Failure did not propagate")
    } catch Failure.unavailable { }
    let recovered = try await pool.value(for: "failed") { 12 }
    precondition(recovered == 12)
    async let accountA = pool.value(for: "accountA/client1/post3") { 1 }
    async let accountB = pool.value(for: "accountB/client2/post3") { 2 }
    let separated = try await (accountA, accountB)
    precondition(separated.0 == 1 && separated.1 == 2)
    print("PASS: one request for two consumers, prefetch cancellation preserves visible demand, last consumer cancels, retry after cancellation/error, distinct account/client keys")
  }
}
