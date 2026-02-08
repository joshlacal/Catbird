import Foundation
import Petrel
import SwiftUI

// MARK: - Tenor API Models (shared with GifPickerView)

struct TenorGif: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let content_description: String
    let itemurl: String
    let url: String
    let tags: [String]
    let media_formats: TenorMediaFormats
    let created: Double
    let flags: [String]
    let hasaudio: Bool
    let content_description_source: String
}

struct TenorMediaFormats: Codable, Hashable {
    let gif: TenorMediaItem?
    let mediumgif: TenorMediaItem?
    let tinygif: TenorMediaItem?
    let nanogif: TenorMediaItem?
    let mp4: TenorMediaItem?
    let loopedmp4: TenorMediaItem?
    let tinymp4: TenorMediaItem?
    let nanomp4: TenorMediaItem?
    let webm: TenorMediaItem?
    let tinywebm: TenorMediaItem?
    let nanowebm: TenorMediaItem?
    let webp: TenorMediaItem?
    let gifpreview: TenorMediaItem?
    let tinygifpreview: TenorMediaItem?
    let nanogifpreview: TenorMediaItem?
}

struct TenorMediaItem: Codable, Hashable {
    let url: String
    let dims: [Int]
    let duration: Double?
    let preview: String
    let size: Int?
}

// MARK: - Thread Models

struct ThreadEntry: Identifiable, Hashable {
    let id = UUID()
    var text: String = ""
    var mediaItems: [PostComposerViewModel.MediaItem] = []
    var videoItem: PostComposerViewModel.MediaItem?
    var selectedGif: TenorGif?
    var detectedURLs: [String] = []
    var urlCards: [String: URLCardResponse] = [:]
    var selectedEmbedURL: String?
    var urlsKeptForEmbed: Set<String> = []
    var facets: [AppBskyRichtextFacet]?
    var hashtags: [String] = []
    var selectedLanguages: [LanguageCodeContainer] = []
    var outlineTags: [String] = []
}

// MARK: - Platform Compatibility

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(macOS)
extension PlatformImage {
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(
            using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#endif

// MARK: - Draft State Management

struct PostComposerDraft: Codable, Hashable {
  let postText: String
  let mediaItems: [CodableMediaItem]
  let videoItem: CodableMediaItem?
  let selectedGif: TenorGif?
  let selectedLanguages: [LanguageCodeContainer]
  let selectedLabels: Set<ComAtprotoLabelDefs.LabelValue>
  let outlineTags: [String]
  let threadEntries: [CodableThreadEntry]
  let isThreadMode: Bool
  let currentThreadIndex: Int
  let parentPostURI: String?
  let quotedPostURI: String?
}

// MARK: - Codable Wrappers for Draft State

struct CodableMediaItem: Codable, Hashable {
  let altText: String
  let aspectRatio: CGSize?
  let isLoading: Bool
  let isAudioVisualizerVideo: Bool
  // Optional persisted reference to local files (used for share extension imports)
  let rawVideoURLString: String?
  let rawImageURLString: String?
  
  init(from mediaItem: PostComposerViewModel.MediaItem) {
    self.altText = mediaItem.altText
    self.aspectRatio = mediaItem.aspectRatio
    self.isLoading = mediaItem.isLoading
    self.isAudioVisualizerVideo = mediaItem.isAudioVisualizerVideo
    self.rawVideoURLString = mediaItem.rawVideoURL?.absoluteString
    self.rawImageURLString = nil
    // Note: We don't persist actual media data, images, or URLs for security/space reasons
    // These will need to be re-added after restoration if needed
  }
  
  func toMediaItem() -> PostComposerViewModel.MediaItem {
    var item = PostComposerViewModel.MediaItem()
    item.altText = altText
    item.aspectRatio = aspectRatio
    item.isLoading = isLoading
    item.isAudioVisualizerVideo = isAudioVisualizerVideo
    if let rawVideoURLString, let url = URL(string: rawVideoURLString) {
      item.rawVideoURL = url
    }
    if let rawImageURLString, let url = URL(string: rawImageURLString),
       let data = try? Data(contentsOf: url) {
      item.rawData = data
      if let platformImage = PlatformImage(data: data) {
        #if os(iOS)
        item.image = Image(uiImage: platformImage)
        #elseif os(macOS)
        item.image = Image(nsImage: platformImage)
        #endif
        item.aspectRatio = CGSize(width: platformImage.imageSize.width, height: platformImage.imageSize.height)
        item.isLoading = false
      }
    }
    return item
  }
}

extension CodableMediaItem {
  init(
    altText: String,
    aspectRatio: CGSize?,
    isLoading: Bool,
    isAudioVisualizerVideo: Bool,
    rawVideoURLString: String?,
    rawImageURLString: String?
  ) {
    self.altText = altText
    self.aspectRatio = aspectRatio
    self.isLoading = isLoading
    self.isAudioVisualizerVideo = isAudioVisualizerVideo
    self.rawVideoURLString = rawVideoURLString
    self.rawImageURLString = rawImageURLString
  }
}

struct CodableThreadEntry: Codable, Hashable {
  let text: String
  let mediaItems: [CodableMediaItem]
  let videoItem: CodableMediaItem?
  let selectedGif: TenorGif?
  let detectedURLs: [String]
  let urlCards: [String: URLCardResponse]
  let selectedEmbedURL: String?
  let urlsKeptForEmbed: Set<String>
  let hashtags: [String]
  let parentPostURI: String?
  let quotedPostURI: String?
  
  init(from threadEntry: ThreadEntry, parentPost: AppBskyFeedDefs.PostView?, quotedPost: AppBskyFeedDefs.PostView?) {
    self.text = threadEntry.text
    self.mediaItems = threadEntry.mediaItems.map(CodableMediaItem.init)
    self.videoItem = threadEntry.videoItem.map(CodableMediaItem.init)
    self.selectedGif = threadEntry.selectedGif
    self.detectedURLs = threadEntry.detectedURLs
    self.urlCards = threadEntry.urlCards
    self.selectedEmbedURL = threadEntry.selectedEmbedURL
    self.urlsKeptForEmbed = threadEntry.urlsKeptForEmbed
    self.hashtags = threadEntry.hashtags
    self.parentPostURI = parentPost?.uri.uriString()
    self.quotedPostURI = quotedPost?.uri.uriString()
  }
  
  func toThreadEntry() -> ThreadEntry {
    var entry = ThreadEntry()
    entry.text = text
    entry.mediaItems = mediaItems.map { $0.toMediaItem() }
    entry.videoItem = videoItem?.toMediaItem()
    entry.selectedGif = selectedGif
    entry.detectedURLs = detectedURLs
    entry.urlCards = urlCards
    entry.selectedEmbedURL = selectedEmbedURL
    entry.urlsKeptForEmbed = urlsKeptForEmbed
    entry.hashtags = hashtags
    return entry
  }
}

// MARK: - Language Utilities

import NaturalLanguage

func localeLanguage(from nlLanguage: NLLanguage) -> Locale.Language {
    // NLLanguage uses ISO 639-1 or 639-2 codes, which are compatible with BCP-47
    return Locale.Language(identifier: nlLanguage.rawValue)
}
