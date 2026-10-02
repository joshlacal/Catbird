import Foundation

/// Single source of truth for block/unblock confirmation copy. Red/destructive
/// styling belongs only on the confirm button of the alert that shows these
/// messages.
enum BlockConfirmation {
  static func blockMessage(handle: String) -> String {
    "Block @\(handle)? You won't see each other's posts, and they won't be able to follow you."
  }

  static func unblockMessage(handle: String) -> String {
    "Unblock @\(handle)? They will be able to interact with you again."
  }
}
