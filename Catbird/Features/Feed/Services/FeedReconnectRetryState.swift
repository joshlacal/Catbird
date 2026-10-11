import Foundation
import Petrel

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

  mutating func requestFailed(_ error: Error, allowsAutomaticRetry: Bool, isPathSatisfied: Bool = false) {
    failureRevision &+= 1
    failedRequestRestorationGeneration = nil
    guard allowsAutomaticRetry else { return }

    let isOffline: Bool
    if let urlError = error as? URLError {
      if urlError.code == .notConnectedToInternet {
        isOffline = true
      } else if !isPathSatisfied && (urlError.code == .cannotFindHost || urlError.code == .dnsLookupFailed) {
        isOffline = true
      } else {
        isOffline = false
      }
    } else if let networkError = error as? Petrel.NetworkError {
      switch networkError {
      case .requestFailed:
        isOffline = !isPathSatisfied
      default:
        isOffline = false
      }
    } else {
      let failure = error as NSError
      if failure.domain == NSURLErrorDomain {
        if failure.code == NSURLErrorNotConnectedToInternet {
          isOffline = true
        } else if !isPathSatisfied && (failure.code == NSURLErrorCannotFindHost || failure.code == NSURLErrorDNSLookupFailed) {
          isOffline = true
        } else {
          isOffline = false
        }
      } else {
        isOffline = false
      }
    }

    guard isOffline else { return }
    failedRequestRestorationGeneration = requestRestorationGeneration
  }

  mutating func requestFailed(_ error: Error, allowsAutomaticRetry: Bool) {
    requestFailed(error, allowsAutomaticRetry: allowsAutomaticRetry, isPathSatisfied: false)
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
