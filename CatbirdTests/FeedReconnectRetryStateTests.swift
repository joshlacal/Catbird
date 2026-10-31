import Foundation
import Testing
@testable import Catbird

@Suite("Feed reconnect retry budget")
struct FeedReconnectRetryStateTests {
  @Test("Only a restoration after the failed request may retry it")
  func waitsForLaterRestoration() {
    var state = FeedReconnectRetryState(restorationGeneration: 3)
    state.requestFailed(URLError(.notConnectedToInternet), allowsAutomaticRetry: true)
    let result1 = state.consumeRestoration(3)
    #expect(!result1)
    let result2 = state.consumeRestoration(4)
    #expect(result2)
    let result3 = state.consumeRestoration(4)
    #expect(!result3)
    let result4 = state.consumeRestoration(5)
    #expect(!result4)
  }

  @Test("An offline error delivered after restoration still gets one retry")
  func lateFailure() {
    var state = FeedReconnectRetryState(restorationGeneration: 0)
    state.requestStarted(restorationGeneration: 0)
    let result5 = state.consumeRestoration(1)
    #expect(!result5)
    state.requestFailed(URLError(.notConnectedToInternet), allowsAutomaticRetry: true)
    #expect(state.failureRevision == 1)
    let result6 = state.consumeRestoration(1)
    #expect(result6)
  }

  @Test("A failed automatic retry cannot rearm itself during path flapping")
  func automaticFailureIsFinal() {
    var state = FeedReconnectRetryState(restorationGeneration: 0)
    state.requestFailed(URLError(.notConnectedToInternet), allowsAutomaticRetry: true)
    let result7 = state.consumeRestoration(1)
    #expect(result7)
    state.requestFailed(URLError(.notConnectedToInternet), allowsAutomaticRetry: false)
    let result8 = state.consumeRestoration(2)
    #expect(!result8)
    let result9 = state.consumeRestoration(3)
    #expect(!result9)
  }

  @Test("A fresh ordinary request gets a new budget without consuming an old edge")
  func explicitRequestCanTryAgain() {
    var state = FeedReconnectRetryState(restorationGeneration: 0)
    state.requestFailed(URLError(.notConnectedToInternet), allowsAutomaticRetry: true)
    let result10 = state.consumeRestoration(1)
    #expect(result10)
    state.requestStarted(restorationGeneration: 1)
    state.requestFailed(URLError(.notConnectedToInternet), allowsAutomaticRetry: true)
    let result11 = state.consumeRestoration(1)
    #expect(!result11)
    let result12 = state.consumeRestoration(2)
    #expect(result12)
  }

  @Test("Cancellation, auth, server, and ambiguous transport errors stay manual", arguments: [
    NSURLErrorCancelled, NSURLErrorUserAuthenticationRequired, NSURLErrorBadServerResponse,
    NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost
  ])
  func unrelatedErrors(code: Int) {
    var state = FeedReconnectRetryState(restorationGeneration: 0)
    state.requestFailed(NSError(domain: NSURLErrorDomain, code: code), allowsAutomaticRetry: true)
    let result13 = state.consumeRestoration(1)
    #expect(!result13)
  }

  @Test("An unrelated domain with the offline numeric code does not retry")
  func checksErrorDomain() {
    var state = FeedReconnectRetryState(restorationGeneration: 0)
    state.requestFailed(NSError(domain: "FeedService", code: NSURLErrorNotConnectedToInternet), allowsAutomaticRetry: true)
    let result14 = state.consumeRestoration(1)
    #expect(!result14)
  }

  @Test("A new request or lifecycle invalidation discards the previous failure")
  func invalidation() {
    var state = FeedReconnectRetryState(restorationGeneration: 0)
    state.requestFailed(URLError(.notConnectedToInternet), allowsAutomaticRetry: true)
    state.invalidate()
    let result15 = state.consumeRestoration(1)
    #expect(!result15)
    state.requestFailed(URLError(.notConnectedToInternet), allowsAutomaticRetry: true)
    state.requestStarted(restorationGeneration: 1)
    let result16 = state.consumeRestoration(2)
    #expect(!result16)
  }
}
