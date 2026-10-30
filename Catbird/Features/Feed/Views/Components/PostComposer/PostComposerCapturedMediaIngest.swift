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
    // A thumbnail decode, not the full camera bitmap.
    if let preview = ComposerImagePreparation.makePreviewSynchronously(from: data) {
      item.applyPreview(preview)
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
