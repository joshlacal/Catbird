#if os(iOS)
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

/// The composer's attachment strip (PostComposerViewUIKit+MediaAttachments): the real tile in a
/// horizontal ScrollView, HStack and ForEach over the view model's attachments.
private struct AttachmentStrip: View {
  let model: PostComposerViewModel

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(model.mediaItems) { item in
          MediaItemView(item: item, onRemove: {}, onEditAlt: {})
        }
      }
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
