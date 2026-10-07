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
    if let fileError = error as? VideoUploadFileError { return fileError.errorDescription }
    if let uploadError = error as? VideoMultipartError {
      switch uploadError {
      case .startUncertain, .processingTimedOut, .transferTimedOut, .alreadyRunning, .ownerChanged:
        return uploadError.errorDescription
      case .sessionTerminal:
        return "The previous video upload ended. Your attachment is still here; retry to start a new attempt."
      case .processingFailed(let code, _):
        if code == "pds_upload_unsupported_blob_size" {
          return "Your account’s server can’t accept a video this large. Try a smaller video. Your draft has been kept."
        }
        return "The server couldn’t process this video. Your attachment is still here; retry or choose another video."
      case .invalidPlan, .invalidReceipt, .invalidStatus:
        return "The video service returned an unexpected response. Your attachment is still here; try again later."
      }
    }
    if let serviceError = error as? VideoMultipartTransportError {
      if serviceError.isAuthenticationFailure || serviceError.statusCode == 403 || serviceError.code == "ServiceAuthDenied" {
        return "Your account couldn’t authorize this video upload. Your draft has been kept."
      }
      return "Couldn’t upload your video. Your attachment is still here; try again later."
    }
    if error is MediaPreviewLoadError {
      return "Video preparation took too long. Your attachment is still here; try again when it is available on this device."
    }
    let nsError = error as NSError
    if userFacingDomains.contains(nsError.domain) {
      return nsError.localizedDescription
    }
    return UserFacingError.message(for: error, action: isThread ? "post your thread" : "send your post")
  }
}
