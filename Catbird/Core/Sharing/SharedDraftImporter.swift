import Foundation
import SwiftUI

/// Utility to convert inbound share payloads into a PostComposerDraft.
enum SharedDraftImporter {
  static func makeDraft(text: String?, urls: [URL]?, imageURLs: [URL]?, imagesData: [Data]?, videoURLs: [URL]?) -> PostComposerDraft {
    var combined = text ?? ""
    if let urls = urls, !urls.isEmpty {
      let urlText = urls.map { $0.absoluteString }.joined(separator: " ")
      combined += (combined.isEmpty ? "" : " ") + urlText
    }
    // Build image media items from imageURLs if available
    var mediaItems: [CodableMediaItem] = []
    if let imageURLs = imageURLs, !imageURLs.isEmpty {
      for url in imageURLs.prefix(4) {
        var item = PostComposerViewModel.MediaItem()
        // Defer loading of data until restore; store URL string for persistence
        var codable = CodableMediaItem(from: item)
        // Recreate with URL string
        codable = CodableMediaItem(
          altText: item.altText,
          aspectRatio: item.aspectRatio,
          isLoading: item.isLoading,
          isAudioVisualizerVideo: item.isAudioVisualizerVideo,
          rawVideoURLString: nil,
          rawImageURLString: url.absoluteString
        )
        mediaItems.append(codable)
      }
    } else if let imagesData = imagesData, !imagesData.isEmpty {
      // Legacy path: write imagesData to App Group for consistency
      if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared") {
        let dir = container.appendingPathComponent("SharedDrafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for data in imagesData.prefix(4) {
          let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
          try? data.write(to: url, options: .atomic)
          var item = PostComposerViewModel.MediaItem()
          var codable = CodableMediaItem(from: item)
          codable = CodableMediaItem(
            altText: item.altText,
            aspectRatio: item.aspectRatio,
            isLoading: item.isLoading,
            isAudioVisualizerVideo: item.isAudioVisualizerVideo,
            rawVideoURLString: nil,
            rawImageURLString: url.absoluteString
          )
          mediaItems.append(codable)
        }
      }
    }
    // Prefer first video URL if available
    let videoDraftItem: CodableMediaItem? = {
      guard let url = videoURLs?.first else { return nil }
      // Create a transient MediaItem with URL for the in-memory draft
      var vmItem = PostComposerViewModel.MediaItem(url: url)
      vmItem.isLoading = false
      // Wrap into CodableMediaItem (will not persist URL on disk)
      return CodableMediaItem(from: vmItem)
    }()
    return PostComposerDraft(
      postText: combined,
      mediaItems: mediaItems,
      videoItem: videoDraftItem,
      selectedGif: nil,
      selectedLanguages: [],
      selectedLabels: [],
      outlineTags: [],
      threadEntries: [],
      isThreadMode: false,
      currentThreadIndex: 0
    )
  }
}
