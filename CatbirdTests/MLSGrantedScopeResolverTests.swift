import Foundation
import Testing
@testable import Catbird

/// The gateway's session endpoint sits behind its sign-in rate limit, and encrypted chat
/// re-checks eligibility in bursts. These pin that a burst costs one request.
@Suite("MLS Granted Scope Resolver Tests")
@MainActor
struct MLSGrantedScopeResolverTests {
  private struct Offline: Error {}

  @MainActor
  private final class Gateway {
    var calls = 0
    var fail = false
    var delayNanoseconds: UInt64 = 0
    var scopes: Set<String> = ["transition:generic", "atproto"]

    func fetch() async throws -> Set<String> {
      calls += 1
      if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
      if fail { throw Offline() }
      return scopes
    }
  }

  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("A burst of checks makes one gateway request, and the answer is refreshed after the window")
  func burstCostsOneRequest() async {
    let gateway = Gateway()
    let resolver = MLSGrantedScopeResolver()
    var last: [String]?
    for second in 0 ..< 25 {
      last = await resolver.gatewayScopes(now: start.addingTimeInterval(Double(second))) {
        try await gateway.fetch()
      }
    }
    #expect(gateway.calls == 1)
    #expect(last == ["atproto", "transition:generic"])

    _ = await resolver.gatewayScopes(now: start.addingTimeInterval(MLSGrantedScopeResolver.freshness + 1)) {
      try await gateway.fetch()
    }
    #expect(gateway.calls == 2)
  }

  @Test("Concurrent checks share one gateway request")
  func concurrentChecksShareOneRequest() async {
    let gateway = Gateway()
    gateway.delayNanoseconds = 50_000_000
    let resolver = MLSGrantedScopeResolver()
    let now = start
    let tasks = (0 ..< 10).map { _ in
      Task { @MainActor in
        await resolver.gatewayScopes(now: now) { try await gateway.fetch() }
      }
    }
    var answers = 0
    for task in tasks where await task.value != nil { answers += 1 }
    #expect(answers == 10)
    #expect(gateway.calls == 1)
  }

  @Test("A refused request is not repeated until the wait has passed")
  func refusalIsNotRetriedImmediately() async {
    let gateway = Gateway()
    gateway.fail = true
    let resolver = MLSGrantedScopeResolver()
    var answer: [String]? = ["unset"]
    for second in 0 ..< 20 {
      answer = await resolver.gatewayScopes(now: start.addingTimeInterval(Double(second))) {
        try await gateway.fetch()
      }
    }
    #expect(gateway.calls == 1)
    #expect(answer == nil)

    gateway.fail = false
    answer = await resolver.gatewayScopes(
      now: start.addingTimeInterval(MLSGrantedScopeResolver.retryAfterFailure + 1)
    ) {
      try await gateway.fetch()
    }
    #expect(gateway.calls == 2)
    #expect(answer == ["atproto", "transition:generic"])
  }

  @Test("A failed refresh returns the last answer")
  func failedRefreshKeepsTheLastAnswer() async {
    let gateway = Gateway()
    let resolver = MLSGrantedScopeResolver()
    _ = await resolver.gatewayScopes(now: start) { try await gateway.fetch() }
    gateway.fail = true
    let answer = await resolver.gatewayScopes(
      now: start.addingTimeInterval(MLSGrantedScopeResolver.freshness + 5)
    ) {
      try await gateway.fetch()
    }
    #expect(answer == ["atproto", "transition:generic"])
  }

  @Test("A completed upgrade's grant is used without asking the gateway")
  func recordedGrantNeedsNoRequest() async {
    let gateway = Gateway()
    let resolver = MLSGrantedScopeResolver()
    resolver.record(["blob:*/*", "atproto"], now: start)
    let answer = await resolver.gatewayScopes(now: start.addingTimeInterval(10)) {
      try await gateway.fetch()
    }
    #expect(answer == ["atproto", "blob:*/*"])
    #expect(gateway.calls == 0)
  }
}
