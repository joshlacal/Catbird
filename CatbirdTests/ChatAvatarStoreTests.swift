import CatbirdMLSCore
import CoreGraphics
import Foundation
import ImageIO
import Intents
import Testing
import UniformTypeIdentifiers

@testable import Catbird

/// Sender pictures in encrypted-chat notifications come from copies the app saved earlier,
/// never from a download made when the message arrives.
@Suite("Chat Avatar Store")
struct ChatAvatarStoreTests {
  private final class Downloads: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var count: Int { lock.withLock { urls.count } }
    func record(_ url: URL) { lock.withLock { urls.append(url) } }
  }

  private func scratchContainer() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ChatAvatarStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func pngData(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
      output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private func pixelSize(of data: Data) throws -> (width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return (image.width, image.height)
  }

  private func preview(senderDid: String, fallbackGeneric: Bool = false) -> NotificationPreview {
    NotificationPreview(
      messageId: "b0b00000-0000-4000-8000-000000000020",
      conversationId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      senderDid: senderDid,
      senderDisplayName: nil,
      groupTitle: nil,
      body: "On my way",
      epoch: 1,
      seq: 3,
      fromCache: false,
      fallbackGeneric: fallbackGeneric,
      darwinNotificationName: MLSAppGroupStorage.nseDidCommitDarwinNotification,
      receiptVerified: false,
      isOwnSiblingSender: false
    )
  }

  @Test("A saved picture is a small JPEG, whatever was downloaded")
  func thumbnailIsSmallJPEG() throws {
    let jpeg = try #require(ChatAvatarStore.thumbnailJPEG(from: try pngData(width: 900, height: 600)))
    let size = try pixelSize(of: jpeg)
    #expect(max(size.width, size.height) == ChatAvatarStore.maxPixelSize)
    #expect(size.width > size.height)
    #expect(ChatAvatarStore.thumbnailJPEG(from: Data("not an image".utf8)) == nil)
  }

  @Test("The store saves a member's picture once, replaces a changed one and removes a dropped one")
  func storeFollowsTheProfile() async throws {
    let container = try scratchContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let downloads = Downloads()
    let image = try pngData(width: 400, height: 400)
    let store = ChatAvatarStore(container: container) { url in
      downloads.record(url)
      return image
    }
    let did = "did:plc:avatarmember0000000000000"
    let file = ChatAvatarFiles.fileURL(forDID: did, container: container)
    let first = URL(string: "https://cdn.example.com/avatar/one.jpg")!
    let second = URL(string: "https://cdn.example.com/avatar/two.jpg")!

    await store.save([(did: did, avatarURL: first)])
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(downloads.count == 1)

    // Unchanged: nothing is downloaded again.
    await store.save([(did: did, avatarURL: first)])
    #expect(downloads.count == 1)

    await store.save([(did: did, avatarURL: second)])
    #expect(downloads.count == 2)

    await store.save([(did: did, avatarURL: nil)])
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(downloads.count == 2)
  }

  @Test("Something that is not a picture is never saved")
  func undecodableDownloadIsNotSaved() async throws {
    let container = try scratchContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let store = ChatAvatarStore(container: container) { _ in Data("<html>blocked</html>".utf8) }
    let did = "did:plc:avatarmember0000000000001"

    await store.save([(did: did, avatarURL: URL(string: "https://cdn.example.com/avatar/x.jpg")!)])
    #expect(!FileManager.default.fileExists(
      atPath: ChatAvatarFiles.fileURL(forDID: did, container: container).path))
  }

  @Test("The extension finds the sender's saved picture by account, whichever device sent")
  func extensionReadsTheSavedPicture() async throws {
    let container = try scratchContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let image = try pngData(width: 300, height: 300)
    let store = ChatAvatarStore(container: container) { _ in image }
    let did = "did:plc:avatarsender00000000000000"
    await store.save([(did: did, avatarURL: URL(string: "https://cdn.example.com/avatar/s.jpg")!)])

    let saved = try #require(NotificationService.savedSenderAvatar(
      for: preview(senderDid: "\(did)#device-7"), container: container))
    #expect(try pixelSize(of: saved).width == ChatAvatarStore.maxPixelSize)

    // No saved picture, or nothing decrypted: no picture, and nothing is fetched.
    #expect(NotificationService.savedSenderAvatar(
      for: preview(senderDid: "did:plc:someoneelse0000000000000000"), container: container) == nil)
    #expect(NotificationService.savedSenderAvatar(
      for: preview(senderDid: did, fallbackGeneric: true), container: container) == nil)

    let withPicture = NotificationService.incomingMessageIntent(
      preview: preview(senderDid: did), senderName: "Robin Lark", senderAvatar: saved)
    #expect(withPicture.sender?.image != nil)
    let withoutPicture = NotificationService.incomingMessageIntent(
      preview: preview(senderDid: did), senderName: "Robin Lark")
    #expect(withoutPicture.sender?.image == nil)
  }
}
