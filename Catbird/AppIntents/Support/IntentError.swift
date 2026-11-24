//
//  IntentError.swift
//  Catbird
//
//  Shared error type + response-unwrapping helper for the hand-written
//  App Intents support layer. Kept dependency-free (no AppState/AppStateManager)
//  so it can be used from any intent that talks to a standalone ATProtoClient.
//

import AppIntents
import Foundation

/// Errors surfaced by App Intents while resolving accounts or talking to the network.
///
/// Siri and Shortcuts only present a thrown error's own message when the error is
/// `CustomLocalizedStringResourceConvertible`; any other error (including a plain
/// `LocalizedError`) reaches the person as a generic failure.
enum IntentError: Error, CustomLocalizedStringResourceConvertible, LocalizedError {
  /// No signed-in account could be resolved (no active account in the app group).
  case notSignedIn
  /// The requested account DID isn't known to the app (e.g. removed since last sync).
  case accountUnavailable(String)
  /// The server returned a non-2xx response code.
  case httpError(Int)
  /// The server returned a 2xx response with no body where one was required.
  case emptyResponse
  /// A parameter supplied to the intent was invalid or unusable.
  case invalidParameter(LocalizedStringResource)
  /// A required app or system service is temporarily unavailable.
  case serviceUnavailable(LocalizedStringResource)

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notSignedIn:
      return LocalizedStringResource(
        "You need to sign in to Catbird before using this shortcut.",
        comment: "Error spoken by Siri or shown in Shortcuts when no Bluesky account is signed in."
      )
    case .accountUnavailable:
      return LocalizedStringResource(
        "That account is no longer signed in to Catbird. Open Catbird to sign in again.",
        comment: "Error spoken by Siri or shown in Shortcuts when the selected Bluesky account is no longer available."
      )
    case .httpError:
      return LocalizedStringResource(
        "Bluesky couldn’t complete the request. Please try again.",
        comment: "Error spoken by Siri or shown in Shortcuts when a Bluesky server request fails."
      )
    case .emptyResponse:
      return LocalizedStringResource(
        "Bluesky didn’t return the expected information. Please try again.",
        comment: "Error spoken by Siri or shown in Shortcuts when a Bluesky server response has an empty body."
      )
    case .invalidParameter(let detail), .serviceUnavailable(let detail):
      return detail
    }
  }

  var errorDescription: String? {
    String(localized: localizedStringResource)
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
