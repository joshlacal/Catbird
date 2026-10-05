import Foundation

/// A non-success response while uploading an attachment for a post.
enum PostComposerUploadError: Error, HTTPStatusCarrying {
  case badResponse(Int)

  var httpStatusCode: Int {
    switch self {
    case .badResponse(let code): return code
    }
  }
}

/// Friendly copy for failures that happen while posting from the composer.
enum PostComposerErrorCopy {
  /// Error domains whose localized descriptions are written for users.
  private static let userFacingDomains: Set<String> = ["ComposerEditingSession", "PostError"]

  /// A sentence explaining why the post or thread wasn’t sent, or `nil` for cancellations.
  static func message(for error: Error, isThread: Bool) -> String? {
    if let videoError = error as? VideoUploadError {
      return videoError.errorDescription
    }
    let nsError = error as NSError
    if userFacingDomains.contains(nsError.domain) {
      return nsError.localizedDescription
    }
    return UserFacingError.message(for: error, action: isThread ? "post your thread" : "send your post")
  }
}
