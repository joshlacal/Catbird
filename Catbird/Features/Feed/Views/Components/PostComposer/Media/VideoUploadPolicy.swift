import Foundation

enum VideoUploadTransportMode {
  case multipart
  case legacy
}

/// Shared by preparation and the multipart uploader. Account/PDS limits may be lower.
enum VideoUploadPolicy {
  static let maximumBytes: Int64 = 300_000_000
  static let maximumDuration: TimeInterval = 600
  static let sizeMessage = "Videos must be 300 MB or smaller."
  static let durationMessage = "Videos must be 10 minutes or shorter."

  static func mimeType(for url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "mp4", "m4v": return "video/mp4"
    case "mov": return "video/quicktime"
    case "webm": return "video/webm"
    case "mpeg", "mpg": return "video/mpeg"
    default: return nil
    }
  }
}
