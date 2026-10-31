import Foundation
import Petrel

/// Errors that know the HTTP status they came from.
protocol HTTPStatusCarrying {
  var httpStatusCode: Int { get }
}

extension ATProtoXRPCError: HTTPStatusCarrying {
  var httpStatusCode: Int { statusCode }
}

extension ATProtoError: HTTPStatusCarrying {
  var httpStatusCode: Int { statusCode }
}

/// Short, friendly copy for failures shown in alerts, toasts and empty states.
///
/// Never show `error.localizedDescription`, HTTP status codes, lexicon error names or Swift type
/// names to users; log those with `privacy: .public` where appropriate and show this instead.
enum UserFacingError {
  enum Kind: Equatable {
    case cancelled, offline, timedOut, rateLimited, notFound, notAllowed, signInRequired, server, other
  }

  static func kind(of error: Error) -> Kind {
    if error is CancellationError { return .cancelled }
    if let urlError = error as? URLError { return kind(ofURLErrorCode: urlError.code.rawValue) }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain { return kind(ofURLErrorCode: nsError.code) }
    if let network = error as? Petrel.NetworkError {
      switch network {
      case .responseError(let statusCode), .serverError(let statusCode, _): return kind(ofHTTPStatus: statusCode)
      case .expiredToken, .authenticationRequired, .authenticationFailed, .unauthorized, .oauthManagerNotSet: return .signInRequired
      case .requestFailed: return .offline
      default: return .other
      }
    }
    if let carrier = error as? HTTPStatusCarrying { return kind(ofHTTPStatus: carrier.httpStatusCode) }
    return .other
  }

  /// A complete sentence for `action`, phrased to follow "Couldn't", e.g. `"load this post"`.
  /// Returns `nil` for cancellations, which should not be reported to the user.
  static func message(for error: Error, action: String) -> String? {
    switch kind(of: error) {
    case .cancelled: return nil
    case .offline: return "Couldn’t \(action). Check your connection and try again."
    case .timedOut: return "Couldn’t \(action) because the server took too long. Try again."
    case .rateLimited: return "Couldn’t \(action) right now. Wait a moment and try again."
    case .notFound: return "Couldn’t \(action). It may have been deleted."
    case .notAllowed: return "Couldn’t \(action). You don’t have permission to do that."
    case .signInRequired: return "Couldn’t \(action). Sign in again and try again."
    case .server: return "Couldn’t \(action) because of a server problem. Try again later."
    case .other: return "Couldn’t \(action). Try again."
    }
  }

  private static func kind(ofURLErrorCode code: Int) -> Kind {
    switch code {
    case NSURLErrorCancelled: return .cancelled
    case NSURLErrorTimedOut: return .timedOut
    case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
         NSURLErrorInternationalRoamingOff, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
         NSURLErrorDNSLookupFailed, NSURLErrorCallIsActive:
      return .offline
    default: return .other
    }
  }

  private static func kind(ofHTTPStatus status: Int) -> Kind {
    switch status {
    case 401: return .signInRequired
    case 403: return .notAllowed
    case 404, 410: return .notFound
    case 408, 504: return .timedOut
    case 429: return .rateLimited
    case 500...599: return .server
    default: return .other
    }
  }
}
