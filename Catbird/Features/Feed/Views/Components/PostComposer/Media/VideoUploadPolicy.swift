import Foundation

enum VideoUploadTransportMode {
  case multipart
  case legacy
}

/// Shared by preparation and the multipart uploader. Account/PDS limits may be lower.
enum VideoUploadPolicy {
  static let maximumBytes: Int64 = 300_000_000
  static let maximumDuration: TimeInterval = 600
  static var sizeMessage: String {
    String(localized: "Videos must be 300 MB or smaller.", comment: "Validation message when selected video exceeds 300 MB size limit")
  }
  static var durationMessage: String {
    String(localized: "Videos must be 10 minutes or shorter.", comment: "Validation message when selected video exceeds 10 minute duration limit")
  }

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
