import SwiftUI

#if os(iOS)
import UIKit
#endif

extension PostComposerViewModel.MediaItem {
  static func capturedVideo(url: URL) -> Self {
    var item = Self(url: url)
    item.isLoading = true
    item.videoData = nil
    return item
  }
}

extension PostComposerViewModel {
  @MainActor
  func ingestCapturedPhoto(_ data: Data) {
    videoItem = nil
    selectedGif = nil
    guard mediaItems.count < maxImagesAllowed else {
      logger.debug("ingestCapturedPhoto: at image limit, ignoring capture")
      return
    }

    var item = MediaItem()
    item.rawData = data
    item.isLoading = false
    #if os(iOS)
    if let (thumbnail, originalSize) = ComposerImageProcessor.syncPreview(from: data, maxPixel: 360) {
      item.image = Image(uiImage: UIImage(cgImage: thumbnail))
      item.aspectRatio = originalSize
    } else if let image = UIImage(data: data) {
      item.image = Image(uiImage: image)
      item.aspectRatio = image.size
    }
    #endif
    let itemID = item.id
    Task.detached(priority: .utility) {
      if let urlString = CodableMediaItem.persistImageData(data) {
        CodableMediaItem.recordPersistedURL(urlString, for: itemID)
      }
    }
    mediaItems.append(item)
    syncMediaStateToCurrentThread()
    saveDraftIfNeeded()
  }

  @MainActor
  func ingestCapturedVideo(_ url: URL) async {
    mediaItems.removeAll()
    selectedGif = nil
    let item = MediaItem.capturedVideo(url: url)
    videoItem = item
    syncMediaStateToCurrentThread()
    saveDraftIfNeeded()
    await loadVideoThumbnail(for: item)
    await checkVideoUploadEligibility(force: true)
    syncMediaStateToCurrentThread()
    saveDraftIfNeeded()
  }
}
