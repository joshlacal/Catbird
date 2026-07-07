//
//  IntentError.swift
//  Catbird
//
//  Shared error type + response-unwrapping helper for the hand-written
//  App Intents support layer. Kept dependency-free (no AppState/AppStateManager)
//  so it can be used from any intent that talks to a standalone ATProtoClient.
//

import Foundation

/// Errors surfaced by App Intents while resolving accounts or talking to the network.
enum IntentError: LocalizedError {
  /// No signed-in account could be resolved (no active account in the app group).
  case notSignedIn
  /// The requested account DID isn't known to the app (e.g. removed since last sync).
  case accountUnavailable(String)
  /// The server returned a non-2xx response code.
  case httpError(Int)
  /// The server returned a 2xx response with no body where one was required.
  case emptyResponse
  /// A parameter supplied to the intent was invalid or unusable.
  case invalidParameter(String)

  var errorDescription: String? {
    switch self {
    case .notSignedIn:
      return "You need to sign in to Catbird before using this shortcut."
    case .accountUnavailable(let did):
      return "The account \(did) is no longer available. Try signing in again."
    case .httpError(let code):
      return "The server returned an error (\(code)). Please try again."
    case .emptyResponse:
      return "The server didn't return the expected data. Please try again."
    case .invalidParameter(let detail):
      return detail
    }
  }
}

/// Unwraps a generated Petrel `(responseCode:data:)` tuple into its payload,
/// throwing `IntentError.httpError` for non-2xx responses and `IntentError.emptyResponse`
/// when the response was successful but carried no body.
func unwrapIntentResponse<T>(_ result: (responseCode: Int, data: T?)) throws -> T {
  guard (200..<300).contains(result.responseCode) else {
    throw IntentError.httpError(result.responseCode)
  }
  guard let data = result.data else {
    throw IntentError.emptyResponse
  }
  return data
}
