import Foundation

/// Single source of truth for block/unblock confirmation copy, including the
/// MLS shared-conversation warning. Red/destructive styling belongs only on
/// the confirm button of the alert that shows these messages.
enum BlockConfirmation {
  static func blockMessage(handle: String, affectedConvoCount: Int) -> String {
    if affectedConvoCount > 0 {
      let plural = affectedConvoCount == 1 ? "" : "s"
      return "Block @\(handle)? You won't see each other's posts, and you'll leave \(affectedConvoCount) shared conversation\(plural). This can't be undone — unblocking will not rejoin the conversations."
    }
    return "Block @\(handle)? You won't see each other's posts, and they won't be able to follow you."
  }

  static func unblockMessage(handle: String) -> String {
    "Unblock @\(handle)? They will be able to interact with you again. Note: previously-left conversations will NOT be rejoined — you'll need a fresh invite."
  }
}
