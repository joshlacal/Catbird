import Foundation
import OSLog
import SwiftData

@available(iOS 26.0, macOS 26.0, *)
@Model
final class DraftAttachment {
  @Attribute(.unique) var id: UUID
  var createdAt: Date

  // MARK: - Metadata
  var kind: String // "image", "video", "gif"
  var localIdentifier: String? // PHAsset id or file path
  var mimeType: String?
  var byteSize: Int?
  var width: Int?
  var height: Int?
  var sha256: Data?

  // Small preview for cross-device context; originals should be reattached locally
  var thumbnail: Data?

  init(
    id: UUID = UUID(),
    createdAt: Date = .now,
    kind: String,
    localIdentifier: String? = nil,
    mimeType: String? = nil,
    byteSize: Int? = nil,
    width: Int? = nil,
    height: Int? = nil,
    sha256: Data? = nil,
    thumbnail: Data? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.kind = kind
    self.localIdentifier = localIdentifier
    self.mimeType = mimeType
    self.byteSize = byteSize
    self.width = width
    self.height = height
    self.sha256 = sha256
    self.thumbnail = thumbnail
  }
}
