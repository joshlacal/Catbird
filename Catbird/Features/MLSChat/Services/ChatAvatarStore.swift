import Foundation
import ImageIO
import Nuke
import OSLog
import UniformTypeIdentifiers

/// Saves a small copy of each encrypted-chat member's profile picture in the App Group, where
/// the Notification Service Extension reads it (`ChatAvatarFiles`).
actor ChatAvatarStore {
  static let shared = ChatAvatarStore()

  /// Longest side of a saved picture, in pixels. A notification avatar is far smaller.
  static let maxPixelSize = 192

  private let logger = Logger(subsystem: "blue.catbird", category: "ChatAvatarStore")
  private let container: URL?
  private let download: @Sendable (URL) async throws -> Data

  init(
    container: URL? = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: MLSAccountPreferenceKeys.appGroupSuiteName),
    download: @escaping @Sendable (URL) async throws -> Data = { url in
      try await ImagePipeline.shared.data(for: ImageRequest(url: url)).0
    }
  ) {
    self.container = container
    self.download = download
  }

  /// Brings the saved pictures in line with `avatars`: saves a new or changed picture, leaves
  /// an unchanged one alone, and removes the copy of a member who no longer has one.
  func save(_ avatars: [(did: String, avatarURL: URL?)]) async {
    guard let container else { return }
    for (did, avatarURL) in avatars {
      let file = ChatAvatarFiles.fileURL(forDID: did, container: container)
      let sourceRecord = ChatAvatarFiles.sourceRecordURL(for: file)
      guard let avatarURL else {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: sourceRecord)
        continue
      }
      let source = avatarURL.absoluteString
      if FileManager.default.fileExists(atPath: file.path),
         (try? String(contentsOf: sourceRecord, encoding: .utf8)) == source
      {
        continue
      }
      do {
        let data = try await download(avatarURL)
        guard let jpeg = Self.thumbnailJPEG(from: data) else {
          logger.debug("Chat member picture could not be decoded; not saved")
          continue
        }
        try FileManager.default.createDirectory(
          at: ChatAvatarFiles.directory(in: container), withIntermediateDirectories: true)
        // The extension runs while the phone is locked, any time after its first unlock.
        try jpeg.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try Data(source.utf8).write(
          to: sourceRecord, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      } catch {
        logger.debug("Chat member picture not saved: \(error.localizedDescription)")
      }
    }
  }

  /// A JPEG no larger than `maxPixelSize` on its longest side, or nil if `data` is not an image.
  static func thumbnailJPEG(from data: Data, maxPixelSize: Int = ChatAvatarStore.maxPixelSize) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
