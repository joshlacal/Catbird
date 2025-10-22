import Foundation
import OSLog
import SwiftData

@available(iOS 26.0, macOS 26.0, *)
@Model
final class AppSettings {
  // MARK: - Identity
  @Attribute(.unique) var id: UUID
  var updatedAt: Date

  // MARK: - Appearance
  var theme: String // "system", "light", "dark"
  var fontScale: Double // 0.8 ... 1.4

  // MARK: - Behavior
  var autoplayVideos: Bool
  var hapticsEnabled: Bool
  var reduceMotion: Bool
  var languageCode: String?

  // MARK: - Init
  init(
    id: UUID = UUID(),
    updatedAt: Date = .now,
    theme: String = "system",
    fontScale: Double = 1.0,
    autoplayVideos: Bool = true,
    hapticsEnabled: Bool = true,
    reduceMotion: Bool = false,
    languageCode: String? = nil
  ) {
    self.id = id
    self.updatedAt = updatedAt
    self.theme = theme
    self.fontScale = fontScale
    self.autoplayVideos = autoplayVideos
    self.hapticsEnabled = hapticsEnabled
    self.reduceMotion = reduceMotion
    self.languageCode = languageCode
  }
}
