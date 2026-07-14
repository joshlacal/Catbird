import SwiftUI

#if os(iOS)
import UIKit
#endif

extension PostComposerViewModel {
  @MainActor
  func ingestCapturedPhoto(_ data: Data) {
    videoItem = nil
    guard mediaItems.count < maxImagesAllowed else {
      logger.debug("ingestCapturedPhoto: at image limit, ignoring capture")
      return
    }

    var item = MediaItem()
    item.rawData = data
    item.isLoading = false
    #if os(iOS)
    if let image = UIImage(data: data) {
      item.image = Image(uiImage: image)
      item.aspectRatio = image.size
    }
    #endif
    mediaItems.append(item)
    syncMediaStateToCurrentThread()
    saveDraftIfNeeded()
  }

  @MainActor
  func ingestCapturedVideo(_ url: URL) async {
    mediaItems.removeAll()
    var item = MediaItem(url: url)
    item.videoData = try? Data(contentsOf: url)
    item.isLoading = true
    videoItem = item
    syncMediaStateToCurrentThread()
    await loadVideoThumbnail(for: item)
    await checkVideoUploadEligibility(force: true)
    syncMediaStateToCurrentThread()
    saveDraftIfNeeded()
  }
}
