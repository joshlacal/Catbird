import Foundation
import OSLog
import SwiftData

@available(iOS 26.0, macOS 26.0, *)
@Model
final class Draft {
  @Attribute(.unique) var id: UUID
  var createdAt: Date
  var updatedAt: Date

  // MARK: - Content
  var text: String
  var replyToURI: String?
  var quoteURI: String?

  // MARK: - Attachments
  @Relationship(deleteRule: .cascade) var attachments: [DraftAttachment]

  init(
    id: UUID = UUID(),
    createdAt: Date = .now,
    updatedAt: Date = .now,
    text: String = "",
    replyToURI: String? = nil,
    quoteURI: String? = nil,
    attachments: [DraftAttachment] = []
  ) {
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.text = text
    self.replyToURI = replyToURI
    self.quoteURI = quoteURI
    self.attachments = attachments
  }
}
