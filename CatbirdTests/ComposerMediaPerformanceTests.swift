import CryptoKit
import Foundation
import ImageIO
import Petrel
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Catbird

@Suite("Composer media performance")
@MainActor
struct ComposerMediaPerformanceTests {
  private func makeViewModel() async -> PostComposerViewModel {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let state = AppState(userDID: "did:plc:composermediaperftest", client: client)
    return PostComposerViewModel(appState: state)
  }

  /// Renders at scale 1, so `size` is the pixel size.
  private func jpeg(color: UIColor, size: CGSize = CGSize(width: 64, height: 48)) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      color.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
    return try #require(image.jpegData(compressionQuality: 0.9))
  }

  private func imageItem(_ data: Data) -> PostComposerViewModel.MediaItem {
    var item = PostComposerViewModel.MediaItem()
    item.rawData = data
    item.isLoading = false
    if let preview = ComposerImagePreparation.makePreviewSynchronously(from: data) {
      item.applyPreview(preview)
    }
    return item
  }

  /// A saved draft attachment whose bytes live in a draft file, as a restored or picked photo has.
  private func restoredItem(_ data: Data) throws -> PostComposerViewModel.MediaItem {
    let urlString = try #require(CodableMediaItem.persistImageData(data))
    let saved = CodableMediaItem(
      altText: "", aspectRatio: nil, isLoading: false, isAudioVisualizerVideo: false,
      rawVideoURLString: nil, rawImageURLString: urlString
    )
    return saved.toMediaItem()
  }

  /// A two-frame GIF, which the composer turns into a video.
  private func animatedGIF() throws -> Data {
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil)
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    for color in [UIColor.systemRed, UIColor.systemBlue] {
      let frame = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
      }
      let properties = [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
      ] as CFDictionary
      CGImageDestinationAddImage(destination, try #require(frame.cgImage), properties)
    }
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<50 where !condition() {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  // MARK: - Draft image files

  @Test("Repeated draft saves reuse each image's file until its bytes change")
  func draftSavesReuseImageFiles() async throws {
    let model = await makeViewModel()
    let original = try jpeg(color: .systemOrange)
    var item = imageItem(original)
    model.mediaItems = [item]

    let first = model.saveDraftState().mediaItems.first?.rawImageURLString
    let firstURL = try #require(first.flatMap(URL.init(string:)))
    #expect(try Data(contentsOf: firstURL) == original)

    model.postText = "An edit that changes the draft"
    let second = model.saveDraftState().mediaItems.first?.rawImageURLString
    #expect(second == first)

    // A crop or edit replaces the bytes, which must produce a new file.
    let edited = try jpeg(color: .systemPurple)
    item.rawData = edited
    model.mediaItems = [item]
    let third = model.saveDraftState().mediaItems.first?.rawImageURLString
    let thirdURL = try #require(third.flatMap(URL.init(string:)))
    #expect(third != first)
    #expect(try Data(contentsOf: thirdURL) == edited)
  }

  @Test("A draft file removed from disk is written again on the next save")
  func missingDraftFileIsRewritten() async throws {
    let model = await makeViewModel()
    let data = try jpeg(color: .systemGreen, size: CGSize(width: 31, height: 17))
    model.mediaItems = [imageItem(data)]
    let saved = try #require(model.saveDraftState().mediaItems.first?.rawImageURLString)
    let url = try #require(URL(string: saved))
    try FileManager.default.removeItem(at: url)

    model.postText = "Saved again"
    let resaved = model.saveDraftState().mediaItems.first?.rawImageURLString

    #expect(resaved == saved)
    #expect(try Data(contentsOf: url) == data)
  }

  @Test("Thread entries reuse the active post's image file")
  func threadCopiesShareImageFile() async throws {
    let model = await makeViewModel()
    let item = imageItem(try jpeg(color: .systemPink))
    model.mediaItems = [item]
    model.isThreadMode = true
    model.threadEntries = [ThreadEntry(mediaItems: [item])]

    let draft = model.saveDraftState()

    #expect(draft.mediaItems.first?.rawImageURLString != nil)
    #expect(draft.threadEntries.first?.mediaItems.first?.rawImageURLString == draft.mediaItems.first?.rawImageURLString)
  }

  @Test("A photo restored from its draft file and then changed saves its new bytes")
  func restoredThenEditedDraftSavesNewBytes() async throws {
    let model = await makeViewModel()
    let original = try jpeg(color: .systemYellow, size: CGSize(width: 41, height: 29))
    var item = try restoredItem(original)
    let restoredURL = try #require(item.rawImageURL)
    #expect(item.rawData == original)

    let edited = try jpeg(color: .systemBrown, size: CGSize(width: 41, height: 29))
    item.rawData = edited
    model.mediaItems = [item]

    let saved = try #require(model.saveDraftState().mediaItems.first?.rawImageURLString)
    #expect(saved != restoredURL.absoluteString)
    #expect(try Data(contentsOf: try #require(URL(string: saved))) == edited)
  }

  @Test("A composer that doesn't own a saved draft writes no draft file when a photo loads")
  func previewLoadWithoutDraftOwnershipWritesNoFile() async throws {
    let model = await makeViewModel()
    #expect(!model.ownsEditingDraft)
    let data = try jpeg(color: .systemTeal, size: CGSize(width: 37, height: 23))
    var item = PostComposerViewModel.MediaItem()
    item.rawData = data
    model.mediaItems = [item]

    await model.loadImageForItem(withId: item.id)

    let loaded = try #require(model.mediaItems.first)
    #expect(loaded.image != nil)
    #expect(!loaded.isLoading)
    #expect(loaded.rawImageURL == nil)
    let container = try #require(FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared"
    ))
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let expected = container.appendingPathComponent("SharedDrafts/draft_image_\(digest).jpg")
    #expect(!FileManager.default.fileExists(atPath: expected.path))
  }

  // MARK: - Thumbnails

  @Test("Restored draft images show a downsampled thumbnail with the full aspect ratio")
  func restoredDraftUsesThumbnail() throws {
    let data = try jpeg(color: .systemBlue, size: CGSize(width: 2400, height: 1200))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("composer-thumb-\(UUID()).jpg")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let saved = CodableMediaItem(
      altText: "", aspectRatio: nil, isLoading: false, isAudioVisualizerVideo: false,
      rawVideoURLString: nil, rawImageURLString: url.absoluteString
    )

    let restored = saved.toMediaItem()

    #expect(restored.image != nil)
    #expect(restored.rawData == data)
    #expect(restored.aspectRatio == CGSize(width: 2400, height: 1200))
  }

  @Test("Removing an earlier photo while a later one decodes leaves the later photo its own thumbnail")
  func previewLandsOnItsOwnPhotoAfterEarlierRemoval() async throws {
    let model = await makeViewModel()
    let first = imageItem(try jpeg(color: .systemRed, size: CGSize(width: 50, height: 50)))
    var second = PostComposerViewModel.MediaItem()
    second.rawData = try jpeg(color: .systemBlue, size: CGSize(width: 3000, height: 2000))
    model.mediaItems = [first, second]

    let load = Task { await model.loadImageForItem(withId: second.id) }
    for _ in 0..<100 where model.mediaItems.last?.isLoading != true {
      await Task.yield()
    }
    // The load is suspended in its background decode; nothing else runs on the main actor
    // until this test awaits again.
    try #require(model.mediaItems.last?.isLoading == true)
    try #require(model.mediaItems.last?.image == nil)
    model.removeMediaItem(withId: first.id)
    await load.value

    #expect(model.mediaItems.count == 1)
    let remaining = try #require(model.mediaItems.first)
    #expect(remaining.id == second.id)
    #expect(remaining.image != nil)
    #expect(remaining.aspectRatio == CGSize(width: 3000, height: 2000))
    #expect(!remaining.isLoading)
  }

  // MARK: - Crop

  @Test("Cropping blocks submit until the square photo replaces the original")
  func cropBlocksSubmitUntilApplied() async throws {
    let model = await makeViewModel()
    let original = try jpeg(color: .systemIndigo, size: CGSize(width: 1200, height: 800))
    let item = imageItem(original)
    model.mediaItems = [item]
    model.postText = "Cropping"

    model.cropMediaItemToSquare(id: item.id)

    #expect(model.mediaItems.first?.isLoading == true)
    #expect(model.submitValidationState.reason == .mediaPreparing)
    try await waitUntil { model.mediaItems.first?.isLoading != true }
    let cropped = try #require(model.mediaItems.first)
    #expect(!cropped.isLoading)
    #expect(cropped.rawData != original)
    #expect(cropped.aspectRatio == CGSize(width: 800, height: 800))
    #expect(cropped.image != nil)
  }

  @Test("A cropped photo that already had a draft file comes back cropped from the draft")
  func cropSurvivesDraftRoundTrip() async throws {
    let model = await makeViewModel()
    let original = try jpeg(color: .systemMint, size: CGSize(width: 120, height: 80))
    let item = try restoredItem(original)
    #expect(item.rawImageURL != nil)
    model.mediaItems = [item]
    _ = model.saveDraftState()

    model.cropMediaItemToSquare(id: item.id)
    try await waitUntil { model.mediaItems.first?.isLoading != true }
    let cropped = try #require(model.mediaItems.first?.rawData)
    #expect(cropped != original)

    let reopened = try #require(model.saveDraftState().mediaItems.first).toMediaItem()
    #expect(reopened.rawData == cropped)
    #expect(reopened.aspectRatio == CGSize(width: 80, height: 80))
  }

  @Test("A crop updates the thread entry's copy of the photo as well")
  func cropUpdatesThreadEntryCopy() async throws {
    let model = await makeViewModel()
    let original = try jpeg(color: .systemCyan, size: CGSize(width: 90, height: 60))
    let item = imageItem(original)
    model.isThreadMode = true
    model.mediaItems = [item]
    model.threadEntries = [ThreadEntry(mediaItems: [item])]

    model.cropMediaItemToSquare(id: item.id)
    try await waitUntil { model.mediaItems.first?.isLoading != true }

    let active = try #require(model.mediaItems.first)
    let entryCopy = try #require(model.threadEntries.first?.mediaItems.first)
    #expect(active.rawData != original)
    #expect(entryCopy.rawData == active.rawData)
    #expect(entryCopy.aspectRatio == CGSize(width: 60, height: 60))
    #expect(!entryCopy.isLoading)
  }

  @Test("A photo that can't be cropped keeps its bytes and says so")
  func failedCropKeepsPhoto() async throws {
    let model = await makeViewModel()
    let bytes = Data("Not an image".utf8)
    var item = PostComposerViewModel.MediaItem()
    item.rawData = bytes
    item.isLoading = false
    model.mediaItems = [item]

    model.cropMediaItemToSquare(id: item.id)
    try await waitUntil { model.mediaItems.first?.isLoading != true }

    #expect(model.mediaItems.first?.isLoading == false)
    #expect(model.mediaItems.first?.rawData == bytes)
    #expect(model.alertItem != nil)
  }

  @Test("A crop that finishes after the composer was cleared changes nothing")
  func cropAfterClearIsDropped() async throws {
    let model = await makeViewModel()
    let original = try jpeg(color: .systemRed, size: CGSize(width: 1200, height: 800))
    var item = imageItem(original)
    model.mediaItems = [item]

    model.cropMediaItemToSquare(id: item.id)
    model.clearAll()
    // The same attachment and bytes come back, as a re-opened draft would bring them. The
    // stale crop only stops this copy from reading as preparing.
    item.isLoading = true
    model.mediaItems = [item]
    try await waitUntil { model.mediaItems.first?.isLoading != true }

    #expect(model.mediaItems.first?.isLoading == false)
    #expect(model.mediaItems.first?.rawData == original)
    #expect(model.mediaItems.first?.aspectRatio == CGSize(width: 1200, height: 800))
    #expect(model.alertItem == nil)
  }

  // MARK: - Paste

  @Test("Pasting an animated GIF and a still together attaches only the GIF")
  func pastedGIFThenStillAttachesOnlyTheGIF() async throws {
    let model = await makeViewModel()
    let gif = try animatedGIF()
    try #require(model.isDataAnimatedGIF(gif))
    let still = try jpeg(color: .systemGreen)
    let providers = [gif, still].map { NSItemProvider(item: $0 as NSData, typeIdentifier: "public.image") }

    await model.handleMediaPaste(providers)

    // The GIF either became the video or stayed as a retryable GIF conversion; the still
    // must not sit next to it, where posting would silently drop one of them.
    #expect(!model.mediaItems.contains { !$0.isGifConversion })
    #expect(model.videoItem != nil || model.mediaItems.contains { $0.isGifConversion })
    #expect(model.alertItem != nil)
  }

  // MARK: - Link-card thumbnails

  private func linkCard(_ url: String, image: String) -> URLCardResponse {
    URLCardResponse(error: "", likelyType: "html", url: url, title: "Card", description: "", image: image)
  }

  @Test("A failed link-card thumbnail upload is dropped, so the next request tries again")
  func failedThumbnailUploadIsRetried() async throws {
    let model = await makeViewModel()
    let url = "https://example.com/article"
    // Nothing listens on port 1, so the thumbnail download fails at once.
    let card = linkCard(url, image: "http://127.0.0.1:1/thumb.png")
    model.urlCards[url] = card
    model.selectedEmbedURL = url

    let first = try #require(model.thumbnailUploadTasks[card.resolvedURL])
    let blob = await first.value
    #expect(blob == nil)
    #expect(model.thumbnailUploadTasks.isEmpty)
    #expect(model.thumbnailCache[card.resolvedURL] == nil)

    model.preUploadThumbnails()
    let second = try #require(model.thumbnailUploadTasks[card.resolvedURL])
    _ = await second.value
    #expect(model.thumbnailUploadTasks.isEmpty)
  }

  @Test("Only the selected link card's thumbnail uploads, and clearing the composer cancels it")
  func onlySelectedCardThumbnailUploads() async throws {
    let model = await makeViewModel()
    let selected = linkCard("https://example.com/a", image: "http://127.0.0.1:1/a.png")
    let other = linkCard("https://example.com/b", image: "http://127.0.0.1:1/b.png")
    model.urlCards = [selected.url: selected, other.url: other]
    #expect(model.thumbnailUploadTasks.isEmpty)

    model.selectedEmbedURL = selected.url

    #expect(Set(model.thumbnailUploadTasks.keys) == [selected.resolvedURL])
    model.clearAll()
    #expect(model.thumbnailUploadTasks.isEmpty)
  }

  @Test("Link-card thumbnails are labelled by their bytes when the server doesn't name an image type")
  func thumbnailUploadMIMEType() {
    let webp = Data([0x52, 0x49, 0x46, 0x46, 0x10, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20])
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let type = PostComposerViewModel.thumbnailUploadMIMEType(declared:data:reencoded:)

    #expect(type("application/octet-stream", webp, false) == "image/webp")
    #expect(type(nil, png, false) == "image/png")
    #expect(type("Image/PNG", png, false) == "image/png")
    #expect(type("image/webp", webp, false) == "image/webp")
    // Bytes re-encoded to fit the blob limit are JPEG, whatever the server said.
    #expect(type("image/png", png, true) == "image/jpeg")
  }
}
