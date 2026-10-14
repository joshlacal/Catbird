#if os(iOS)
import AVFoundation
import Foundation
import Observation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// The composer shows a spinner tile for each picked photo, then fills the same attachment in
/// place once it decodes (`loadImageForItem` → `applyPreview`, then `finishMediaLoad`). When
/// MediaItem's `==` compared only `id`, SwiftUI took the decoded attachment for the placeholder
/// it had already drawn and kept the spinner until another attachment was removed.
@Suite("Composer attachment tiles refresh", .serialized)
@MainActor
struct ComposerAttachmentTileRefreshTests {
  private func makeViewModel() async -> PostComposerViewModel {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let state = AppState(userDID: "did:plc:composertilerefreshtest", client: client)
    return PostComposerViewModel(appState: state)
  }

  private func jpeg(_ color: UIColor) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(width: 64, height: 48)
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      color.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
    return try #require(image.jpegData(compressionQuality: 0.9))
  }

  /// What `addMediaItems` appends before a picked photo has loaded, with the bytes already read.
  private func placeholder(_ color: UIColor) throws -> PostComposerViewModel.MediaItem {
    var item = PostComposerViewModel.MediaItem()
    item.rawData = try jpeg(color)
    return item
  }

  private func preview(_ color: UIColor) throws -> ComposerImagePreparation.Preview {
    try #require(ComposerImagePreparation.makePreviewSynchronously(from: jpeg(color)))
  }

  private func host<V: View>(_ view: V) throws -> (UIWindow, UIHostingController<V>) {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    )
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 400)
    let controller = UIHostingController(rootView: view)
    window.rootViewController = controller
    window.isHidden = false
    return (window, controller)
  }

  private func settle(_ controller: UIViewController) async {
    for _ in 0..<12 {
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  private func spinners(in view: UIView) -> Int {
    (view is UIActivityIndicatorView ? 1 : 0) + view.subviews.reduce(0) { $0 + spinners(in: $1) }
  }

  /// Every accessibility label the hosted SwiftUI hierarchy exposes: the tiles' buttons
  /// ("Edit Image", "Remove Video") and texts ("Preview unavailable"). Needs
  /// `AppAccessibility.enable()` first.
  private func accessibilityLabels(in view: UIView) -> [String] {
    var labels: [String] = []
    func visit(_ element: Any, depth: Int) {
      guard depth < 60, let object = element as? NSObject else { return }
      if let label = object.accessibilityLabel, !label.isEmpty { labels.append(label) }
      if let elements = object.accessibilityElements, !elements.isEmpty {
        elements.forEach { visit($0, depth: depth + 1) }
        return
      }
      let count = object.accessibilityElementCount()
      if count != NSNotFound, count > 0 {
        for index in 0..<count {
          if let child = object.accessibilityElement(at: index) { visit(child, depth: depth + 1) }
        }
      } else if let view = object as? UIView {
        view.subviews.forEach { visit($0, depth: depth + 1) }
      }
    }
    visit(view, depth: 0)
    return labels
  }

  /// Waits for work the view model started in an unstructured task (a crop).
  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
      try? await Task.sleep(for: .milliseconds(25))
    }
  }

  /// A three-frame movie, for the video tile's thumbnail.
  private func makeMovie() async throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("composer-tile-\(UUID().uuidString)").appendingPathExtension("mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let pool = try #require(adaptor.pixelBufferPool)
    for frame in 0..<3 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
      let pixels = try #require(buffer)
      CVPixelBufferLockBaseAddress(pixels, [])
      memset(CVPixelBufferGetBaseAddress(pixels), 0x60 + Int32(frame) * 0x20, CVPixelBufferGetDataSize(pixels))
      CVPixelBufferUnlockBaseAddress(pixels, [])
      #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    try #require(writer.status == .completed, "fixture: \(String(describing: writer.error))")
    return url
  }

  @Test("Picked photos replace their spinners once they decode")
  func tilesShowDecodedPhotos() async throws {
    let model = await makeViewModel()
    let (window, controller) = try host(AttachmentStrip(model: model))
    defer { window.isHidden = true }
    let items = try [placeholder(.systemRed), placeholder(.systemBlue)]
    model.mediaItems.append(contentsOf: items)
    await settle(controller)
    #expect(spinners(in: controller.view) == 2, "fixture: one spinner per placeholder")

    for item in items {
      await model.loadImageForItem(withId: item.id)
    }
    #expect(model.mediaItems.allSatisfy { $0.image != nil && !$0.isLoading })
    await settle(controller)
    #expect(spinners(in: controller.view) == 0, "a tile still spins although its photo has decoded")
  }

  @Test("A tile that also holds the view model (the video attachment's shape) redraws its preview")
  func tileWithReferenceRedraws() async throws {
    let model = await makeViewModel()
    let log = TileLog()
    let (window, controller) = try host(SingleAttachment(model: model, log: log))
    defer { window.isHidden = true }
    model.videoItem = PostComposerViewModel.MediaItem()
    await settle(controller)
    #expect(log.drewPreview == false)

    model.videoItem?.image = try preview(.systemGreen).image
    model.videoItem?.isLoading = false
    await settle(controller)
    #expect(log.drewPreview == true, "the tile kept drawing the placeholder")
  }

  @Test("Assigning an attachment whose preview arrived notifies observers")
  func wholeValueAssignmentNotifies() async throws {
    let model = await makeViewModel()
    model.mediaItems = [try placeholder(.systemOrange)]
    final class Flag: @unchecked Sendable { var fired = false }
    let flag = Flag()
    withObservationTracking { _ = model.mediaItems } onChange: { flag.fired = true }

    var decoded = model.mediaItems
    decoded[0].applyPreview(try preview(.systemOrange))
    decoded[0].isLoading = false
    model.mediaItems = decoded
    // @Observable skips the notification when `==` calls the new value equal to the old one.
    #expect(flag.fired)
  }

  @Test("A photo that cannot be decoded shows Preview unavailable instead of a spinner")
  func failedPreviewShowsUnavailable() async throws {
    let model = await makeViewModel()
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }
    let (window, controller) = try host(AttachmentStrip(model: model))
    defer { window.isHidden = true }
    var broken = PostComposerViewModel.MediaItem()
    broken.rawData = Data("not an image".utf8)
    model.mediaItems = [broken]
    await settle(controller)
    #expect(spinners(in: controller.view) == 1, "fixture: a spinner while it loads")

    await model.loadImageForItem(withId: broken.id)
    #expect(model.mediaItems.first?.image == nil && model.mediaItems.first?.isLoading == false,
            "fixture: the preview failed and loading ended")
    await settle(controller)

    #expect(spinners(in: controller.view) == 0, "the tile still spins although loading ended")
    let labels = accessibilityLabels(in: controller.view)
    #expect(labels.contains("Preview unavailable"), "labels: \(labels)")
    #expect(labels.contains("Retry"), "labels: \(labels)")
  }

  @Test("Thread-mode gallery tiles replace their spinners once their photos decode")
  func threadGalleryShowsDecodedPhotos() async throws {
    let model = await makeViewModel()
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }
    model.postText = "First post"
    model.enterThreadMode()
    model.addNewThreadEntry()
    let (window, controller) = try host(ThreadGallery(model: model))
    defer { window.isHidden = true }
    let items = try [placeholder(.systemRed), placeholder(.systemBlue)]
    model.mediaItems = items
    model.syncMediaStateToCurrentThread()
    await settle(controller)
    #expect(spinners(in: controller.view) == 2, "fixture: one spinner per placeholder")

    for item in items {
      await model.loadImageForItem(withId: item.id)
    }
    #expect(model.mediaItems.allSatisfy { $0.image != nil && !$0.isLoading })
    await settle(controller)

    #expect(spinners(in: controller.view) == 0, "a gallery tile still spins although its photo has decoded")
    let labels = accessibilityLabels(in: controller.view)
    #expect(labels.filter { $0 == "Remove Image" }.count == 2, "labels: \(labels)")
  }

  @Test("The composer's video tile shows the thumbnail once it is generated")
  func videoTileShowsThumbnail() async throws {
    let model = await makeViewModel()
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }
    model.mediaUploadManager = nil // no eligibility check against a server
    let movie = try await makeMovie()
    defer { try? FileManager.default.removeItem(at: movie) }
    let (window, controller) = try host(VideoTileHost(model: model))
    defer { window.isHidden = true }
    let video = PostComposerViewModel.MediaItem(url: movie)
    model.videoItem = video
    await settle(controller)
    #expect(spinners(in: controller.view) == 1, "fixture: a spinner until the thumbnail exists")

    await model.loadVideoThumbnail(for: video)
    #expect(model.videoItem?.image != nil && model.videoItem?.isLoading == false, "fixture: the thumbnail was made")
    await settle(controller)

    #expect(spinners(in: controller.view) == 0, "the video tile still spins although its thumbnail exists")
    let labels = accessibilityLabels(in: controller.view)
    #expect(labels.contains("Remove Video"), "labels: \(labels)")
    #expect(labels.contains("Add Captions"), "labels: \(labels)")
  }

  @Test("Cropping hides the edit button while it runs and shows it again with the square photo")
  func cropRedrawsTile() async throws {
    let model = await makeViewModel()
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }
    let (window, controller) = try host(AttachmentStrip(model: model, editable: true))
    defer { window.isHidden = true }
    let photo = try placeholder(.systemPurple)
    model.mediaItems = [photo]
    await model.loadImageForItem(withId: photo.id)
    await settle(controller)
    #expect(accessibilityLabels(in: controller.view).contains("Edit Image"), "fixture: a decoded photo can be edited")
    #expect(model.mediaItems.first?.aspectRatio == CGSize(width: 64, height: 48))

    model.cropMediaItemToSquare(id: photo.id)
    #expect(model.mediaItems.first?.isLoading == true, "fixture: the crop is preparing")
    // No suspension until the check, so the crop cannot finish first.
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    #expect(!accessibilityLabels(in: controller.view).contains("Edit Image"),
            "the edit button stays while the crop prepares")

    await waitUntil { model.mediaItems.first?.isLoading == false }
    #expect(model.mediaItems.first?.aspectRatio == CGSize(width: 48, height: 48), "fixture: the crop finished")
    await settle(controller)
    #expect(accessibilityLabels(in: controller.view).contains("Edit Image"),
            "the edit button did not come back with the cropped photo")
    #expect(spinners(in: controller.view) == 0)
  }

  @Test("Attachment equality follows what a tile, a draft or an upload reads")
  func equalityComparesDrawnState() throws {
    let spinner = try placeholder(.systemPink)
    var decoded = spinner
    decoded.applyPreview(try preview(.systemPink))
    #expect(decoded != spinner, "a decoded preview is a change")

    var loaded = decoded
    loaded.isLoading = false
    #expect(loaded != decoded)

    var described = loaded
    described.altText = "A pink rectangle"
    #expect(described != loaded, "alt text flips the badge from Add alt to Edit alt")

    var cropped = described
    cropped.rawData = try jpeg(.systemTeal)
    #expect(cropped != described, "a crop or edit replaces the bytes")

    let copy = cropped
    #expect(copy == cropped)
    #expect(copy.hashValue == spinner.hashValue, "hashing stays by identity")
  }
}

/// SwiftUI builds its accessibility tree only while app accessibility is on, which it is not in a
/// test host. Tests that read the hosted tiles' labels switch it on the way snapshot-testing
/// libraries do (libAccessibility's _AXSApplicationAccessibilitySetEnabled) and restore it.
@MainActor
private enum AppAccessibility {
  static func enable() -> () -> Void {
    guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
          let getter = dlsym(library, "_AXSApplicationAccessibilityEnabled"),
          let setter = dlsym(library, "_AXSApplicationAccessibilitySetEnabled") else {
      Issue.record("libAccessibility is unavailable")
      return {}
    }
    let isEnabled = unsafeBitCast(getter, to: (@convention(c) () -> Bool).self)
    let setEnabled = unsafeBitCast(setter, to: (@convention(c) (Bool) -> Void).self)
    let previous = isEnabled()
    setEnabled(true)
    return { setEnabled(previous) }
  }
}

/// The composer's attachment strip (PostComposerViewUIKit+MediaAttachments): the real tile in a
/// horizontal ScrollView, HStack and ForEach over the view model's attachments.
private struct AttachmentStrip: View {
  let model: PostComposerViewModel
  /// Pass an edit action, as the composer does, so the tile shows its Edit Image button.
  var editable = false

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(model.mediaItems) { item in
          MediaItemView(
            item: item, onRemove: {}, onEditAlt: {}, onEditImage: editable ? {} : nil, onRetry: {}
          )
        }
      }
    }
  }
}

/// The thread-mode media section (PostComposerViewUIKit+Thread): the real gallery, fed the view
/// model's attachments through a Binding and drawn with an enumerated ForEach.
private struct ThreadGallery: View {
  let model: PostComposerViewModel

  var body: some View {
    if !model.mediaItems.isEmpty {
      MediaGalleryView(
        mediaItems: Binding(get: { model.mediaItems }, set: { model.mediaItems = $0 }),
        currentEditingMediaId: .constant(nil),
        isAltTextEditorPresented: .constant(false),
        maxImagesAllowed: model.maxImagesAllowed,
        onAddMore: {},
        onRemove: { model.removeMediaItem(withId: $0) }
      )
    }
  }
}

/// How the composer shows a video: the real tile, made again from `vm.videoItem` on each change.
private struct VideoTileHost: View {
  let model: PostComposerViewModel

  var body: some View {
    if let item = model.videoItem {
      PostComposerUIKitVideoAttachmentView(videoItem: item, vm: model)
    }
  }
}

@MainActor
private final class TileLog {
  var drewPreview: Bool?
}

/// PostComposerUIKitVideoAttachmentView's shape: one optional attachment, a tile that stores the
/// attachment and the view model.
private struct SingleAttachment: View {
  let model: PostComposerViewModel
  let log: TileLog

  var body: some View {
    if let item = model.videoItem {
      RecordingTile(item: item, model: model, log: log)
    }
  }
}

private struct RecordingTile: View {
  let item: PostComposerViewModel.MediaItem
  let model: PostComposerViewModel
  let log: TileLog

  var body: some View {
    log.drewPreview = item.image != nil
    return MediaItemView(item: item, onRemove: {}, onEditAlt: {}, isVideo: true)
  }
}
#endif
