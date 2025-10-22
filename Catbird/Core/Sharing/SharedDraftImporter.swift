import Foundation
import SwiftUI
import OSLog


/// Utility to convert inbound share payloads into a PostComposerDraft.
enum SharedDraftImporter {
    private static let logger = Logger(subsystem: "blue.catbird", category: "SharedDraftImporter")

  static func makeDraft(text: String?, urls: [URL]?, imageURLs: [URL]?, imagesData: [Data]?, videoURLs: [URL]?) -> PostComposerDraft {
    logger.info("🏗️ makeDraft called")
    logger.debug("  Text: \(text?.prefix(50) ?? "nil"), URLs: \(urls?.count ?? 0), Image URLs: \(imageURLs?.count ?? 0), Image data: \(imagesData?.count ?? 0), Video URLs: \(videoURLs?.count ?? 0)")
    
    var combined = text ?? ""
    
    // Safely append URLs if present
    if let urls = urls, !urls.isEmpty {
      let urlText = urls.map { $0.absoluteString }.joined(separator: " ")
      combined += (combined.isEmpty ? "" : " ") + urlText
      logger.debug("  Added \(urls.count) URLs to text")
    }
    
    // Build image media items from imageURLs if available
    var mediaItems: [CodableMediaItem] = []
    if let imageURLs = imageURLs, !imageURLs.isEmpty {
      logger.info("📷 Processing \(imageURLs.count) image URLs (max 4)")
      
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
        logger.debug("  Added image: \(url.lastPathComponent)")
      }
      
      logger.info("  Created \(mediaItems.count) media items from image URLs")
    } else if let imagesData = imagesData, !imagesData.isEmpty {
      logger.info("📷 Processing \(imagesData.count) legacy image data items (max 4)")
      // Legacy path: write imagesData to App Group for consistency
      guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared") else {
        logger.error("❌ Cannot access App Group container - skipping image import")
        // Can't access app group, skip image import
        return PostComposerDraft(
          postText: combined,
          mediaItems: [],
          videoItem: nil,
          selectedGif: nil,
          selectedLanguages: [],
          selectedLabels: [],
          outlineTags: [],
          threadEntries: [],
          isThreadMode: false,
          currentThreadIndex: 0,
          parentPostURI: nil,
          quotedPostURI: nil
        )
      }
      
      let dir = container.appendingPathComponent("SharedDrafts", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      logger.debug("  Created SharedDrafts directory at: \(dir.path)")
      
      for (index, data) in imagesData.prefix(4).enumerated() {
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        do {
          try data.write(to: url, options: .atomic)
          logger.debug("  Wrote image \(index + 1) to: \(url.lastPathComponent) (\(data.count) bytes)")
          
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
        } catch {
          logger.error("  ❌ Failed to write image \(index + 1): \(error.localizedDescription)")
        }
      }
      
      logger.info("  Created \(mediaItems.count) media items from legacy image data")
    }
    
    // Prefer first video URL if available (safely unwrap)
    let videoDraftItem: CodableMediaItem? = {
      guard let videoURLs = videoURLs, let url = videoURLs.first else {
        logger.debug("  No video URLs provided")
        return nil
      }
      
      logger.info("🎥 Processing video URL: \(url.lastPathComponent)")
      
      // Create a transient MediaItem with URL for the in-memory draft
      var vmItem = PostComposerViewModel.MediaItem(url: url)
      vmItem.isLoading = false
      // Wrap into CodableMediaItem (will not persist URL on disk)
      return CodableMediaItem(from: vmItem)
    }()
    
    let draft = PostComposerDraft(
      postText: combined,
      mediaItems: mediaItems,
      videoItem: videoDraftItem,
      selectedGif: nil,
      selectedLanguages: [],
      selectedLabels: [],
      outlineTags: [],
      threadEntries: [],
      isThreadMode: false,
      currentThreadIndex: 0,
      parentPostURI: nil,
      quotedPostURI: nil
    )
    
    logger.info("✅ Draft created - Post text length: \(draft.postText.count), Media items: \(draft.mediaItems.count), Has video: \(draft.videoItem != nil)")
    
    return draft
  }
}
