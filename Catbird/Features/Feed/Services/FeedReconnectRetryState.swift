import Foundation

/// One automatic retry for an offline first-page request, after a later restored path.
struct FeedReconnectRetryState {
  private(set) var failureRevision: UInt64 = 0
  private var requestRestorationGeneration: UInt64
  private var failedRequestRestorationGeneration: UInt64?

  init(restorationGeneration: UInt64) {
    requestRestorationGeneration = restorationGeneration
  }

  mutating func requestStarted(restorationGeneration: UInt64) {
    requestRestorationGeneration = restorationGeneration
    failedRequestRestorationGeneration = nil
  }

  mutating func requestFailed(_ error: Error, allowsAutomaticRetry: Bool) {
    failureRevision &+= 1
    failedRequestRestorationGeneration = nil
    let failure = error as NSError
    guard allowsAutomaticRetry,
          failure.domain == NSURLErrorDomain,
          failure.code == NSURLErrorNotConnectedToInternet else { return }
    failedRequestRestorationGeneration = requestRestorationGeneration
  }

  mutating func consumeRestoration(_ generation: UInt64) -> Bool {
    guard let failedGeneration = failedRequestRestorationGeneration,
          generation > failedGeneration else { return false }
    failedRequestRestorationGeneration = nil
    return true
  }

  mutating func invalidate() {
    failedRequestRestorationGeneration = nil
  }
}

struct FeedReconnectRetryKey: Hashable {
  let restorationGeneration: UInt64
  let failureRevision: UInt64
  let isEligible: Bool
}
